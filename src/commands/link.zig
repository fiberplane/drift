const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const lockfile = @import("../lockfile.zig");
const markdown = @import("../markdown.zig");
const symbols = @import("../symbols.zig");
const target = @import("../target.zig");

pub const RunError = error{ DocReadFailed, NoBindingsForDoc, CannotComputeFingerprint, TargetNotFound, HeadingNotFound };

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

    _ = std.fs.cwd().readFileAlloc(ctx.scratch(), doc_path, 1024 * 1024) catch |err| {
        stderr_w.print("error: cannot read '{s}': {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return error.DocReadFailed;
    };
    ctx.resetScratch();

    const normalized_doc_path = try normalizeDocPath(ctx, lf.root_path, cwd_path, doc_path);
    ctx.resetScratch();

    if (optional_anchor) |raw_anchor| {
        const normalized_target = normalizeTargetPath(ctx, lf.root_path, cwd_path, raw_anchor) catch |err| switch (err) {
            error.TargetNotFound => {
                stderr_w.print("error: target not found: {s}\n", .{raw_anchor}) catch {};
                return err;
            },
            error.HeadingNotFound => {
                stderr_w.print("error: heading not found in target doc: {s}\n", .{raw_anchor}) catch {};
                return err;
            },
            else => return err,
        };
        ctx.resetScratch();

        try upsertBinding(ctx, &lf, cwd_path, normalized_doc_path, normalized_target);
        try lockfile.writeFile(&lf, ctx.scratch());

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

    if (!relinked_any) {
        stderr_w.print("no bindings found for {s}\n", .{normalized_doc_path}) catch {};
        return error.NoBindingsForDoc;
    }

    try lockfile.writeFile(&lf, ctx.scratch());
    stdout_w.print("relinked all anchors in {s}\n", .{normalized_doc_path}) catch {};
}

fn upsertBinding(
    ctx: CommandContext,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    normalized_target: []const u8,
) !void {
    if (findBinding(lf.bindings.items, normalized_doc_path, normalized_target)) |binding| {
        try refreshBindingSig(ctx, cwd_path, lf.root_path, binding);
        return;
    }

    var binding = lockfile.Binding{
        .doc_path = try ctx.run_arena.dupe(u8, normalized_doc_path),
        .target = try ctx.run_arena.dupe(u8, normalized_target),
        .metadata = .{},
    };
    errdefer binding.metadata.deinit(ctx.run_arena);

    try refreshBindingSig(ctx, cwd_path, lf.root_path, &binding);
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
    raw_target: []const u8,
    hex_out: *[16]u8,
) !void {
    const parsed = target.parse(raw_target);
    const absolute_path = try resolveInputPath(ctx, root_path, cwd_path, parsed.file_path);
    const content = try readResolvedFile(ctx, absolute_path);
    if (!symbols.writeFingerprintHex(hex_out, content, parsed.file_path, parsed.symbol_name)) {
        ctx.resetScratch();
        return error.CannotComputeFingerprint;
    }
    ctx.resetScratch();
}

fn normalizeDocPath(
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
    const parsed = target.parse(raw_target);
    const absolute = try resolveInputPath(ctx, root_path, cwd_path, parsed.file_path);
    if (!pathExists(absolute)) {
        ctx.resetScratch();
        return error.TargetNotFound;
    }

    const relative = try std.fs.path.relative(ctx.run_arena, root_path, absolute);

    if (parsed.symbol_name) |symbol| {
        if (parsed.isHeading()) {
            const content = try readResolvedFile(ctx, absolute);
            const slug_buf = try ctx.scratch().alloc(u8, symbol.len);
            const slug = markdown.headingToSlug(slug_buf, symbol);
            if (!markdown.headingExists(content, slug)) {
                ctx.resetScratch();
                return error.HeadingNotFound;
            }
            const normalized = try std.fmt.allocPrint(ctx.run_arena, "{s}#{s}", .{ relative, slug });
            ctx.resetScratch();
            return normalized;
        }
        const normalized = try std.fmt.allocPrint(ctx.run_arena, "{s}#{s}", .{ relative, symbol });
        ctx.resetScratch();
        return normalized;
    }

    ctx.resetScratch();
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
    std.fs.accessAbsolute(path, .{}) catch return false;
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

fn findBinding(bindings: []lockfile.Binding, doc_path: []const u8, normalized_target: []const u8) ?*lockfile.Binding {
    for (bindings) |*binding| {
        if (std.mem.eql(u8, binding.doc_path, doc_path) and std.mem.eql(u8, binding.target, normalized_target)) {
            return binding;
        }
    }
    return null;
}
