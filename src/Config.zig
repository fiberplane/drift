//! Project configuration loaded from `<root>/.drift/config.toml`.
//!
//! The config reuses the lockfile's TOML subset (docs/DECISIONS.md §11):
//! a mandatory `version = 1` header, bare keys, single-line basic strings,
//! full-line comments. A missing file yields `Config.default`; unknown keys
//! or tables are hard errors, matching lockfile strictness.

const std = @import("std");
const toml = @import("toml.zig");

const Config = @This();

/// Schema version from the mandatory `version = 1` header.
version: u32,
/// True when `.drift/config.toml` was found on disk.
exists: bool,

pub const default: Config = .{ .version = 1, .exists = false };

pub const max_config_bytes = 64 * 1024;

pub const LoadError = error{
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

    return parse(content, diagnostics);
}

/// Parses config content against the version-only schema. Later revisions
/// add `[[repos]]`; until then every table and non-version key is rejected.
pub fn parse(content: []const u8, diagnostics: *Diagnostics) LoadError!Config {
    var lines: toml.LineIterator = .init(content);
    var version: ?u32 = null;

    while (lines.next()) |line| {
        diagnostics.line_number = lines.line_number;

        if (toml.arrayTableName(line) != null) return error.ConfigUnknownTable;

        const pair = toml.splitKeyValue(line) orelse return error.ConfigSyntax;
        if (!toml.isValidBareKey(pair.key)) return error.ConfigSyntax;
        if (!std.mem.eql(u8, pair.key, "version")) return error.ConfigUnknownKey;

        if (version != null) return error.ConfigSyntax;
        const parsed = std.fmt.parseUnsigned(u32, pair.raw_value, 10) catch return error.ConfigSyntax;
        if (parsed != 1) return error.ConfigVersionUnsupported;
        version = parsed;
    }

    return .{
        .version = version orelse return error.ConfigVersionMissing,
        .exists = true,
    };
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

test "parse requires the version header" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.ConfigVersionMissing, parse("", &diagnostics));
    try std.testing.expectError(error.ConfigVersionMissing, parse("# comments only\n\n", &diagnostics));
}

test "parse rejects unsupported versions and duplicate headers" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.ConfigVersionUnsupported, parse("version = 2\n", &diagnostics));
    try std.testing.expectError(error.ConfigSyntax, parse("version = 1\nversion = 1\n", &diagnostics));
    try std.testing.expectError(error.ConfigSyntax, parse("version = one\n", &diagnostics));
}

test "parse rejects unknown keys and tables with line numbers" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.ConfigUnknownKey, parse("version = 1\n\nname = \"drift\"\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);

    diagnostics = .{};
    try std.testing.expectError(error.ConfigUnknownTable, parse("version = 1\n[[repos]]\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.line_number);
}

test "parse reports the line number of malformed lines" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.ConfigSyntax, parse("# header\nversion = 1\nnot a key value\n", &diagnostics));
    try std.testing.expectEqual(@as(usize, 3), diagnostics.line_number);
}
