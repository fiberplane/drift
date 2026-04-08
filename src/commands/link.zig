const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const frontmatter = @import("../frontmatter.zig");
const lockfile = @import("../lockfile.zig");
const symbols = @import("../symbols.zig");

pub const RunError = error{ DocReadFailed, DocWriteFailed, NoBindingsForDoc, CannotComputeFingerprint };

pub fn run(
    ctx: CommandContext,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    doc_path: []const u8,
    optional_anchor: ?[]const u8,
) !void {
    const cwd_path = try std.fs.cwd().realpathAlloc(ctx.run_arena, ".");

    var lf = try lockfile.discover(ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    const content = std.fs.cwd().readFileAlloc(ctx.run_arena, doc_path, 1024 * 1024) catch |err| {
        stderr_w.print("error: cannot read '{s}': {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return error.DocReadFailed;
    };

    ctx.resetScratch();
    const normalized_doc_path = try normalizeSpecPath(ctx, lf.root_path, cwd_path, doc_path);
    ctx.resetScratch();

    const parsed_legacy = try frontmatter.parseDriftDoc(ctx.run_arena, content);

    if (parsed_legacy) |legacy| {
        try migrateLegacyBindings(ctx, &lf, cwd_path, normalized_doc_path, legacy.anchors.items, legacy.origin);
    }

    if (optional_anchor) |raw_anchor| {
        ctx.resetScratch();
        const normalized_target = try normalizeTargetPath(ctx, lf.root_path, cwd_path, raw_anchor);
        ctx.resetScratch();

        try upsertBinding(ctx, &lf, cwd_path, normalized_doc_path, normalized_target, if (parsed_legacy) |legacy| legacy.origin else null);
        try lockfile.writeFile(&lf, ctx.scratch());

        if (parsed_legacy != null) {
            try stripLegacySpecFile(ctx, doc_path, content, stderr_w);
        }

        const binding = findBinding(lf.bindings.items, normalized_doc_path, normalized_target).?;
        stdout_w.print("added {s} -> {s}", .{ normalized_doc_path, binding.target }) catch {};
        if (binding.fieldValue("sig")) |sig| {
            stdout_w.print(" sig:{s}", .{sig}) catch {};
        }
        stdout_w.print("\n", .{}) catch {};
        return;
    }

    var relinked_any = false;
    for (lf.bindings.items) |*binding| {
        if (!std.mem.eql(u8, binding.doc_path, normalized_doc_path)) continue;
        try refreshBindingSig(ctx, cwd_path, lf.root_path, binding);
        relinked_any = true;
    }

    if (!relinked_any and parsed_legacy == null) {
        stderr_w.print("no bindings found for {s}\n", .{normalized_doc_path}) catch {};
        return error.NoBindingsForDoc;
    }

    try lockfile.writeFile(&lf, ctx.scratch());

    if (parsed_legacy != null) {
        try stripLegacySpecFile(ctx, doc_path, content, stderr_w);
    }

    stdout_w.print("relinked all anchors in {s}\n", .{normalized_doc_path}) catch {};
}

fn migrateLegacyBindings(
    ctx: CommandContext,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    legacy_anchors: []const []const u8,
    origin: ?[]const u8,
) !void {
    for (legacy_anchors) |legacy_anchor| {
        ctx.resetScratch();
        const normalized_target = try normalizeTargetPath(ctx, lf.root_path, cwd_path, legacy_anchor);
        ctx.resetScratch();
        try upsertBinding(ctx, lf, cwd_path, normalized_doc_path, normalized_target, origin);
    }
}

fn upsertBinding(
    ctx: CommandContext,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    normalized_target: []const u8,
    origin: ?[]const u8,
) !void {
    if (findBinding(lf.bindings.items, normalized_doc_path, normalized_target)) |binding| {
        try refreshBindingSig(ctx, cwd_path, lf.root_path, binding);
        if (origin) |o| {
            try binding.setField(ctx.run_arena, "origin", o);
        }
        return;
    }

    var binding = lockfile.Binding{
        .doc_path = try ctx.run_arena.dupe(u8, normalized_doc_path),
        .target = try ctx.run_arena.dupe(u8, normalized_target),
        .metadata = .{},
    };
    errdefer binding.metadata.deinit(ctx.run_arena);

    try refreshBindingSig(ctx, cwd_path, lf.root_path, &binding);
    if (origin) |o| {
        try binding.setField(ctx.run_arena, "origin", o);
    }

    try lf.bindings.append(ctx.run_arena, binding);
}

fn refreshBindingSig(
    ctx: CommandContext,
    cwd_path: []const u8,
    root_path: []const u8,
    binding: *lockfile.Binding,
) !void {
    var hex: [16]u8 = undefined;
    try computeTargetSigInto(ctx, cwd_path, root_path, binding.target, &hex);
    try binding.setField(ctx.run_arena, "sig", hex[0..16]);
}

fn computeTargetSigInto(
    ctx: CommandContext,
    cwd_path: []const u8,
    root_path: []const u8,
    target: []const u8,
    hex_out: *[16]u8,
) !void {
    const identity = frontmatter.anchorFileIdentity(target);
    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_part = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    const absolute_path = try resolveInputPath(ctx, root_path, cwd_path, file_part);
    const content = try readResolvedFile(ctx, absolute_path);
    if (!symbols.writeFingerprintHex(hex_out, content, file_part, symbol_name)) {
        ctx.resetScratch();
        return error.CannotComputeFingerprint;
    }
    ctx.resetScratch();
}

fn stripLegacySpecFile(
    ctx: CommandContext,
    doc_path: []const u8,
    content: []const u8,
    stderr_w: *std.io.Writer,
) !void {
    const stripped = try frontmatter.stripLegacyDriftMetadata(ctx.run_arena, content);

    const file = std.fs.cwd().createFile(doc_path, .{ .truncate = true }) catch |err| {
        stderr_w.print("error: cannot write '{s}': {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return error.DocWriteFailed;
    };
    defer file.close();
    try file.writeAll(stripped);
}

fn normalizeSpecPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    doc_path: []const u8,
) ![]const u8 {
    const absolute = try resolveInputPath(ctx, root_path, cwd_path, doc_path);
    const relative = try std.fs.path.relative(ctx.run_arena, root_path, absolute);
    ctx.resetScratch();
    return relative;
}

fn normalizeTargetPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    raw_target: []const u8,
) ![]const u8 {
    const identity = frontmatter.anchorFileIdentity(raw_target);
    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_part = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    const absolute = try resolveInputPath(ctx, root_path, cwd_path, file_part);
    const relative = try std.fs.path.relative(ctx.run_arena, root_path, absolute);
    ctx.resetScratch();

    if (symbol_name) |symbol| {
        return try std.fmt.allocPrint(ctx.run_arena, "{s}#{s}", .{ relative, symbol });
    }
    return relative;
}

fn resolveInputPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try ctx.scratch().dupe(u8, path);
    }

    const cwd_candidate = try std.fs.path.resolve(ctx.scratch(), &.{ cwd_path, path });
    if (pathExists(cwd_candidate)) return cwd_candidate;

    return try std.fs.path.resolve(ctx.scratch(), &.{ root_path, path });
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readResolvedFile(ctx: CommandContext, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(ctx.scratch(), 1024 * 1024);
    }
    return try std.fs.cwd().readFileAlloc(ctx.scratch(), path, 1024 * 1024);
}

fn findBinding(bindings: []lockfile.Binding, doc_path: []const u8, target: []const u8) ?*lockfile.Binding {
    for (bindings) |*binding| {
        if (std.mem.eql(u8, binding.doc_path, doc_path) and std.mem.eql(u8, binding.target, target)) {
            return binding;
        }
    }
    return null;
}
