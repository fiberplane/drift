const std = @import("std");
const frontmatter = @import("../frontmatter.zig");
const lockfile = @import("../lockfile.zig");
const symbols = @import("../symbols.zig");

pub fn run(
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    doc_path: []const u8,
    optional_anchor: ?[]const u8,
) !void {
    const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch |err| {
        stderr_w.print("cannot resolve cwd: {s}\n", .{@errorName(err)}) catch {};
        return err;
    };
    defer allocator.free(cwd_path);

    var lf = try lockfile.discover(allocator, cwd_path);
    defer lf.deinit(allocator);

    const content = std.fs.cwd().readFileAlloc(allocator, doc_path, 1024 * 1024) catch |err| {
        stderr_w.print("cannot read {s}: {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return err;
    };
    defer allocator.free(content);

    const normalized_doc_path = try normalizeSpecPath(allocator, lf.root_path, cwd_path, doc_path);
    defer allocator.free(normalized_doc_path);

    const parsed_legacy = frontmatter.parseDriftDoc(allocator, content);
    defer if (parsed_legacy) |legacy| {
        var owned = legacy;
        for (owned.anchors.items) |anchor| allocator.free(anchor);
        owned.anchors.deinit(allocator);
        if (owned.origin) |origin| allocator.free(origin);
    };

    if (parsed_legacy) |legacy| {
        try migrateLegacyBindings(allocator, &lf, cwd_path, normalized_doc_path, legacy.anchors.items, legacy.origin);
    }

    if (optional_anchor) |raw_anchor| {
        const normalized_target = try normalizeTargetPath(allocator, lf.root_path, cwd_path, raw_anchor);
        defer allocator.free(normalized_target);

        try upsertBinding(allocator, &lf, cwd_path, normalized_doc_path, normalized_target, if (parsed_legacy) |legacy| legacy.origin else null);
        try lockfile.writeFile(&lf, allocator);

        if (parsed_legacy != null) {
            try stripLegacySpecFile(allocator, doc_path, content, stderr_w);
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
        try refreshBindingSig(allocator, cwd_path, lf.root_path, binding);
        relinked_any = true;
    }

    if (!relinked_any and parsed_legacy == null) {
        stderr_w.print("no bindings found for {s}\n", .{normalized_doc_path}) catch {};
        return error.NoBindingsForDoc;
    }

    try lockfile.writeFile(&lf, allocator);

    if (parsed_legacy != null) {
        try stripLegacySpecFile(allocator, doc_path, content, stderr_w);
    }

    stdout_w.print("relinked all anchors in {s}\n", .{normalized_doc_path}) catch {};
}

fn migrateLegacyBindings(
    allocator: std.mem.Allocator,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    legacy_anchors: []const []const u8,
    origin: ?[]const u8,
) !void {
    for (legacy_anchors) |legacy_anchor| {
        const normalized_target = try normalizeTargetPath(allocator, lf.root_path, cwd_path, legacy_anchor);
        defer allocator.free(normalized_target);
        try upsertBinding(allocator, lf, cwd_path, normalized_doc_path, normalized_target, origin);
    }
}

fn upsertBinding(
    allocator: std.mem.Allocator,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    normalized_target: []const u8,
    origin: ?[]const u8,
) !void {
    if (findBinding(lf.bindings.items, normalized_doc_path, normalized_target)) |binding| {
        try refreshBindingSig(allocator, cwd_path, lf.root_path, binding);
        if (origin) |o| {
            try binding.setField(allocator, "origin", o);
        }
        return;
    }

    var binding = lockfile.Binding{
        .doc_path = try allocator.dupe(u8, normalized_doc_path),
        .target = try allocator.dupe(u8, normalized_target),
        .metadata = .{},
    };
    errdefer binding.deinit(allocator);

    try refreshBindingSig(allocator, cwd_path, lf.root_path, &binding);
    if (origin) |o| {
        try binding.setField(allocator, "origin", o);
    }

    try lf.bindings.append(allocator, binding);
}

fn refreshBindingSig(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    root_path: []const u8,
    binding: *lockfile.Binding,
) !void {
    const sig = try computeTargetSig(allocator, cwd_path, root_path, binding.target);
    defer allocator.free(sig);
    try binding.setField(allocator, "sig", sig["sig:".len..]);
}

fn computeTargetSig(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    root_path: []const u8,
    target: []const u8,
) ![]const u8 {
    const identity = frontmatter.anchorFileIdentity(target);
    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_part = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    const absolute_path = try resolveInputPath(allocator, root_path, cwd_path, file_part);
    defer allocator.free(absolute_path);

    const content = try readResolvedFile(allocator, absolute_path);
    defer allocator.free(content);

    return symbols.computeContentSigFromSource(allocator, content, file_part, symbol_name) orelse error.CannotComputeFingerprint;
}

fn stripLegacySpecFile(
    allocator: std.mem.Allocator,
    doc_path: []const u8,
    content: []const u8,
    stderr_w: *std.io.Writer,
) !void {
    const stripped = try frontmatter.stripLegacyDriftMetadata(allocator, content);
    defer allocator.free(stripped);

    const file = std.fs.cwd().createFile(doc_path, .{ .truncate = true }) catch |err| {
        stderr_w.print("cannot write {s}: {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return err;
    };
    defer file.close();
    try file.writeAll(stripped);
}

fn normalizeSpecPath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cwd_path: []const u8,
    doc_path: []const u8,
) ![]const u8 {
    const absolute = try resolveInputPath(allocator, root_path, cwd_path, doc_path);
    defer allocator.free(absolute);
    return try std.fs.path.relative(allocator, root_path, absolute);
}

fn normalizeTargetPath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cwd_path: []const u8,
    raw_target: []const u8,
) ![]const u8 {
    const identity = frontmatter.anchorFileIdentity(raw_target);
    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_part = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    const absolute = try resolveInputPath(allocator, root_path, cwd_path, file_part);
    defer allocator.free(absolute);

    const relative = try std.fs.path.relative(allocator, root_path, absolute);
    errdefer allocator.free(relative);

    if (symbol_name) |symbol| {
        return try std.fmt.allocPrint(allocator, "{s}#{s}", .{ relative, symbol });
    }
    return relative;
}

fn resolveInputPath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    cwd_path: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return try allocator.dupe(u8, path);
    }

    const cwd_candidate = try std.fs.path.resolve(allocator, &.{ cwd_path, path });
    errdefer allocator.free(cwd_candidate);
    if (pathExists(cwd_candidate)) return cwd_candidate;
    allocator.free(cwd_candidate);

    return try std.fs.path.resolve(allocator, &.{ root_path, path });
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readResolvedFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, 1024 * 1024);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn findBinding(bindings: []lockfile.Binding, doc_path: []const u8, target: []const u8) ?*lockfile.Binding {
    for (bindings) |*binding| {
        if (std.mem.eql(u8, binding.doc_path, doc_path) and std.mem.eql(u8, binding.target, target)) {
            return binding;
        }
    }
    return null;
}
