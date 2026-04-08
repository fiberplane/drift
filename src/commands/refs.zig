const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const frontmatter = @import("../frontmatter.zig");
const lockfile = @import("../lockfile.zig");

pub fn run(ctx: CommandContext, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer, raw_target: []const u8) !void {
    _ = stderr_w;

    const cwd_path = try std.fs.cwd().realpathAlloc(ctx.run_arena, ".");

    const lf = try lockfile.discover(ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    if (!lf.exists) return;

    ctx.resetScratch();
    const normalized_target = try normalizeTargetPath(ctx, lf.root_path, cwd_path, raw_target);

    var printed: std.StringHashMap(void) = std.StringHashMap(void).init(ctx.run_arena);
    defer printed.deinit();

    for (lf.bindings.items) |binding| {
        if (!std.mem.eql(u8, binding.target, normalized_target)) continue;
        if (printed.contains(binding.doc_path)) continue;
        try printed.put(binding.doc_path, {});
        stdout_w.print("{s}\n", .{binding.doc_path}) catch {};
    }
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
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
