const std = @import("std");

pub const VcsKind = enum { git, jj };

/// Detect whether the current working directory uses jj or git.
/// Prefers jj (checks `.jj/` first), falls back to git.
pub fn detectVcs() VcsKind {
    std.fs.cwd().access(".jj", .{}) catch {
        return .git;
    };
    return .jj;
}

/// Get the last commit/change ID that touched a given file path.
pub fn getLastCommit(allocator: std.mem.Allocator, cwd_path: []const u8, file_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "log", "-1", "--format=%H", "--", file_path },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "latest(::@ & file(\"{s}\"))", .{file_path});
            defer allocator.free(revset);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    // Trim trailing newline
    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const commit = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return commit;
}

/// Check if a bound file was modified after the given commit/change.
pub fn checkStaleness(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    spec_commit: []const u8,
    bound_file: []const u8,
    vcs: VcsKind,
) !bool {
    const result = switch (vcs) {
        .git => blk: {
            const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{spec_commit});
            defer allocator.free(range);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "log", "--oneline", range, "--", bound_file },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "{s}..@ & file(\"{s}\")", .{ spec_commit, bound_file });
            defer allocator.free(revset);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
    return trimmed.len > 0;
}

/// Get the current change/commit ID (short form) for auto-provenance.
pub fn getCurrentChangeId(allocator: std.mem.Allocator, cwd_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
        .jj => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.shortest(8)", "--color=never" },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const id = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return id;
}
