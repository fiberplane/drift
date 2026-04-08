const std = @import("std");
const frontmatter = @import("../frontmatter.zig");
const lockfile = @import("../lockfile.zig");

pub fn run(
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    doc_path: []const u8,
    anchor: []const u8,
) !void {
    _ = stderr_w;

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var lf = try lockfile.discover(allocator, cwd_path);
    defer lf.deinit(allocator);

    if (!lf.exists) return;

    const normalized_doc_path = try normalizeSpecPath(allocator, lf.root_path, cwd_path, doc_path);
    defer allocator.free(normalized_doc_path);

    const normalized_target = try normalizeTargetPath(allocator, lf.root_path, cwd_path, anchor);
    defer allocator.free(normalized_target);

    var removed = false;
    var i: usize = 0;
    while (i < lf.bindings.items.len) {
        const binding = &lf.bindings.items[i];
        if (std.mem.eql(u8, binding.doc_path, normalized_doc_path) and std.mem.eql(u8, binding.target, normalized_target)) {
            binding.deinit(allocator);
            _ = lf.bindings.orderedRemove(i);
            removed = true;
            continue;
        }
        i += 1;
    }

    if (!removed) return;

    try lockfile.writeFile(&lf, allocator);
    stdout_w.print("removed {s} -> {s} from drift.lock\n", .{ normalized_doc_path, normalized_target }) catch {};
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
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
