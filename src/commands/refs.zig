const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const lockfile = @import("../lockfile.zig");
const repo_path = @import("../repo_path.zig");
const target = @import("../target.zig");

pub fn run(ctx: CommandContext, stdout_w: *std.Io.Writer, stderr_w: *std.Io.Writer, raw_target: []const u8) !void {
    _ = stderr_w;

    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.run_arena);

    const lf = try lockfile.discover(ctx.io, ctx.run_arena, ctx.scratch(), cwd_path);
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
    const parsed = target.parse(raw_target);
    const file_part = parsed.file_path;
    const symbol_name = parsed.symbol_name;

    const absolute = try resolveInputPath(ctx, root_path, cwd_path, file_part);
    const relative = repo_path.normalize(try std.Io.Dir.path.relative(ctx.run_arena, "", null, root_path, absolute));
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
    if (std.Io.Dir.path.isAbsolute(path)) {
        return try ctx.scratch().dupe(u8, path);
    }

    const cwd_candidate = try std.Io.Dir.path.resolve(ctx.scratch(), &.{ cwd_path, path });
    if (pathExists(ctx.io, cwd_candidate)) return cwd_candidate;

    return try std.Io.Dir.path.resolve(ctx.scratch(), &.{ root_path, path });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
