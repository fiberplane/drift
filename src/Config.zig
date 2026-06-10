//! Project configuration loaded from `<root>/.drift/config.toml`.
//!
//! The config reuses the lockfile's TOML subset (docs/DECISIONS.md §11):
//! a mandatory `version = 1` header, bare keys, single-line basic strings,
//! full-line comments. A missing file yields `Config.default`; unknown keys
//! or tables are hard errors, matching lockfile strictness.

const std = @import("std");
const repo_map = @import("repo_map.zig");
const toml = @import("toml.zig");

const Config = @This();

/// Schema version from the mandatory `version = 1` header.
version: u32,
/// True when `.drift/config.toml` was found on disk.
exists: bool,
/// Origin → checkout-path mappings from `[[repos]]` tables. Paths are kept
/// verbatim; `repo_map.RepoMap.buildMerged` resolves them against the
/// lockfile root.
repos: []const repo_map.Entry,

pub const default: Config = .{ .version = 1, .exists = false, .repos = &.{} };

pub const max_config_bytes = 64 * 1024;

pub const LoadError = error{
    ConfigRepoInvalid,
    ConfigSyntax,
    ConfigUnknownKey,
    ConfigUnknownTable,
    ConfigUnreadable,
    ConfigVersionMissing,
    ConfigVersionUnsupported,
    OutOfMemory,
};

/// Identifies the offending line when `load` or `parse` fails. 1-based;
/// 0 when no line has been read (empty file).
pub const Diagnostics = struct {
    line_number: usize = 0,
};

/// Reads and parses `<root_path>/.drift/config.toml`. A missing file is not
/// an error: the default Config is returned. All allocations come from
/// `arena_allocator` and are freed by arena teardown, not by the caller.
pub fn load(io: std.Io, arena_allocator: std.mem.Allocator, root_path: []const u8, diagnostics: *Diagnostics) LoadError!Config {
    const config_path = std.Io.Dir.path.join(arena_allocator, &.{ root_path, ".drift", "config.toml" }) catch return error.OutOfMemory;

    const content = readFileAt(io, arena_allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => return .default,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigUnreadable,
    };

    return parse(arena_allocator, content, diagnostics);
}

/// A `[[repos]]` table under construction: exactly the keys `origin` and
/// `path`, both mandatory. `header_line` points diagnostics at the table
/// header when a key is missing.
const PendingRepo = struct {
    origin: ?[]const u8 = null,
    path: ?[]const u8 = null,
    header_line: usize,
};

/// Parses config content: the mandatory `version = 1` header followed by zero
/// or more `[[repos]]` tables. Unknown keys and tables are hard errors.
/// Parsed strings live in `arena_allocator` storage.
pub fn parse(arena_allocator: std.mem.Allocator, content: []const u8, diagnostics: *Diagnostics) LoadError!Config {
    var lines: toml.LineIterator = .init(content);
    var version: ?u32 = null;
    var repos: std.ArrayList(repo_map.Entry) = .empty;
    var pending: ?PendingRepo = null;

    while (lines.next()) |line| {
        diagnostics.line_number = lines.line_number;

        if (toml.arrayTableName(line)) |table_name| {
            if (!std.mem.eql(u8, table_name, "repos")) return error.ConfigUnknownTable;
            if (version == null) return error.ConfigVersionMissing;
            if (pending) |p| try repos.append(arena_allocator, try parseFinishRepo(p, diagnostics));
            pending = .{ .header_line = lines.line_number };
            continue;
        }

        const pair = toml.splitKeyValue(line) orelse return error.ConfigSyntax;
        if (!toml.isValidBareKey(pair.key)) return error.ConfigSyntax;

        if (pending) |*repo| {
            try parseRepoKey(arena_allocator, pair, repo);
            continue;
        }

        if (!std.mem.eql(u8, pair.key, "version")) return error.ConfigUnknownKey;
        if (version != null) return error.ConfigSyntax;
        const parsed = std.fmt.parseUnsigned(u32, pair.raw_value, 10) catch return error.ConfigSyntax;
        if (parsed != 1) return error.ConfigVersionUnsupported;
        version = parsed;
    }

    if (pending) |p| try repos.append(arena_allocator, try parseFinishRepo(p, diagnostics));

    return .{
        .version = version orelse return error.ConfigVersionMissing,
        .exists = true,
        .repos = repos.items,
    };
}

fn parseRepoKey(arena_allocator: std.mem.Allocator, pair: toml.KeyValue, repo: *PendingRepo) LoadError!void {
    const value = toml.parseString(arena_allocator, pair.raw_value) catch |err| switch (err) {
        error.InvalidString => return error.ConfigSyntax,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (std.mem.eql(u8, pair.key, "origin")) {
        if (repo.origin != null) return error.ConfigSyntax;
        repo.origin = value;
    } else if (std.mem.eql(u8, pair.key, "path")) {
        if (repo.path != null) return error.ConfigSyntax;
        repo.path = value;
    } else {
        return error.ConfigUnknownKey;
    }
}

/// Completes a `[[repos]]` table, enforcing that both keys are present and
/// that the entry passes the same shape validation as `--repo` flag specs
/// (`repo_map.validate`). Missing keys point diagnostics at the table header.
fn parseFinishRepo(pending: PendingRepo, diagnostics: *Diagnostics) LoadError!repo_map.Entry {
    const entry: repo_map.Entry = .{
        .origin = pending.origin orelse {
            diagnostics.line_number = pending.header_line;
            return error.ConfigRepoInvalid;
        },
        .path = pending.path orelse {
            diagnostics.line_number = pending.header_line;
            return error.ConfigRepoInvalid;
        },
    };
    repo_map.validate(entry) catch {
        diagnostics.line_number = pending.header_line;
        return error.ConfigRepoInvalid;
    };
    return entry;
}

fn readFileAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = if (std.Io.Dir.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(allocator, .limited(max_config_bytes));
}

test "load returns default Config when file is missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var diagnostics: Diagnostics = .{};
    const config = try load(io, arena.allocator(), root_path, &diagnostics);
    try std.testing.expect(!config.exists);
    try std.testing.expectEqual(@as(u32, 1), config.version);
}

test "load reads version header with comments and blank lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".drift");
    try tmp.dir.writeFile(io, .{
        .sub_path = ".drift/config.toml",
        .data = "# drift config\n\nversion = 1\n",
    });

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var diagnostics: Diagnostics = .{};
    const config = try load(io, arena.allocator(), root_path, &diagnostics);
    try std.testing.expect(config.exists);
    try std.testing.expectEqual(@as(u32, 1), config.version);
}

/// Test helper: parse with a throwaway arena, returning only the error (if
/// any). Keeps error-path tests leak-free under std.testing.allocator.
fn testParseError(content: []const u8, diagnostics: *Diagnostics) ?LoadError {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = parse(arena.allocator(), content, diagnostics) catch |err| return err;
    return null;
}

test "parse requires the version header" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(@as(?LoadError, error.ConfigVersionMissing), testParseError("", &diagnostics));
    try std.testing.expectEqual(@as(?LoadError, error.ConfigVersionMissing), testParseError("# comments only\n\n", &diagnostics));
    try std.testing.expectEqual(@as(?LoadError, error.ConfigVersionMissing), testParseError("[[repos]]\norigin = \"github:acme/server\"\npath = \"../server\"\n", &diagnostics));
}

test "parse rejects unsupported versions and duplicate headers" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(@as(?LoadError, error.ConfigVersionUnsupported), testParseError("version = 2\n", &diagnostics));
    try std.testing.expectEqual(@as(?LoadError, error.ConfigSyntax), testParseError("version = 1\nversion = 1\n", &diagnostics));
    try std.testing.expectEqual(@as(?LoadError, error.ConfigSyntax), testParseError("version = one\n", &diagnostics));
}

test "parse rejects unknown keys and tables with line numbers" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(@as(?LoadError, error.ConfigUnknownKey), testParseError("version = 1\n\nname = \"drift\"\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);

    diagnostics = .{};
    try std.testing.expectEqual(@as(?LoadError, error.ConfigUnknownTable), testParseError("version = 1\n[[remotes]]\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.line_number);
}

test "parse reports the line number of malformed lines" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(@as(?LoadError, error.ConfigSyntax), testParseError("# header\nversion = 1\nnot a key value\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);
}

test "parse reads [[repos]] tables with origin and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diagnostics: Diagnostics = .{};
    const config = try parse(arena.allocator(),
        \\version = 1
        \\
        \\[[repos]]
        \\origin = "github:acme/server"
        \\path = "../server"
        \\
        \\[[repos]]
        \\path = "/checkouts/client"
        \\origin = "github:acme/client"
        \\
    , &diagnostics);

    try std.testing.expectEqual(@as(usize, 2), config.repos.len);
    try std.testing.expectEqualStrings("github:acme/server", config.repos[0].origin);
    try std.testing.expectEqualStrings("../server", config.repos[0].path);
    try std.testing.expectEqualStrings("github:acme/client", config.repos[1].origin);
    try std.testing.expectEqualStrings("/checkouts/client", config.repos[1].path);
}

test "parse rejects unknown keys inside [[repos]]" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(
        @as(?LoadError, error.ConfigUnknownKey),
        testParseError("version = 1\n[[repos]]\norigin = \"github:acme/server\"\nbranch = \"main\"\npath = \"../server\"\n", &diagnostics),
    );
    try std.testing.expectEqual(@as(usize, 4), diagnostics.line_number);
}

test "parse rejects [[repos]] entries missing origin or path" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(
        @as(?LoadError, error.ConfigRepoInvalid),
        testParseError("version = 1\n\n[[repos]]\npath = \"../server\"\n", &diagnostics),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);

    diagnostics = .{};
    try std.testing.expectEqual(
        @as(?LoadError, error.ConfigRepoInvalid),
        testParseError("version = 1\n\n[[repos]]\norigin = \"github:acme/server\"\n", &diagnostics),
    );
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);
}

test "parse applies the same origin validation as --repo specs" {
    var diagnostics: Diagnostics = .{};
    const invalid_origins = [_][]const u8{
        "acme/server", // missing github: prefix
        "github:acme", // no owner/repo split
        "github:acme/server.git", // .git suffix never survives normalization
        "gitlab:acme/server", // unsupported forge
    };
    for (invalid_origins) |origin| {
        var content_buf: [256]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "version = 1\n[[repos]]\norigin = \"{s}\"\npath = \"../server\"\n", .{origin});
        try std.testing.expectEqual(@as(?LoadError, error.ConfigRepoInvalid), testParseError(content, &diagnostics));
    }
}

test "parse rejects duplicate keys inside a [[repos]] table" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectEqual(
        @as(?LoadError, error.ConfigSyntax),
        testParseError("version = 1\n[[repos]]\norigin = \"github:acme/server\"\norigin = \"github:acme/other\"\npath = \"../server\"\n", &diagnostics),
    );
    try std.testing.expectEqual(@as(usize, 4), diagnostics.line_number);
}
