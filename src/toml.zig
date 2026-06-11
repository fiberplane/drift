//! Shared helpers for drift's TOML subset (docs/DECISIONS.md §11).
//!
//! The dialect is intentionally small: bare keys (`[A-Za-z0-9_-]+`),
//! single-line basic strings with the common escapes (`\b \t \n \f \r \" \\`),
//! `[[array-of-tables]]` headers, full-line `#` comments, and blank lines.
//! Inline comments, dotted keys, multiline strings, and other general TOML
//! features are outside the subset. Consumers: src/lockfile.zig, src/Config.zig.

const std = @import("std");

pub const StringError = error{InvalidString};

/// Yields trimmed, non-blank, non-comment lines while tracking 1-based line
/// numbers for parser diagnostics.
pub const LineIterator = struct {
    split: std.mem.SplitIterator(u8, .scalar),
    line_number: usize,

    pub fn init(content: []const u8) LineIterator {
        return .{
            .split = std.mem.splitScalar(u8, content, '\n'),
            .line_number = 0,
        };
    }

    /// Returns the next line trimmed of spaces, tabs, and carriage returns,
    /// skipping blank lines and full-line `#` comments. `line_number` reports
    /// the position of the returned line in the original content.
    pub fn next(self: *LineIterator) ?[]const u8 {
        while (self.split.next()) |line| {
            self.line_number += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            return trimmed;
        }
        return null;
    }
};

pub const KeyValue = struct {
    key: []const u8,
    raw_value: []const u8,
};

/// Splits `key = value` at the first '=', trimming spaces and tabs around both
/// parts. Returns null when the line contains no '='. Does not validate the
/// key or decode the value.
pub fn splitKeyValue(line: []const u8) ?KeyValue {
    const equals = std.mem.findScalar(u8, line, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..equals], " \t"),
        .raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t"),
    };
}

/// Returns the table name when `line` is an `[[name]]` array-of-tables header
/// with a valid bare-key name; null otherwise. Whitespace inside the brackets
/// is outside the subset.
pub fn arrayTableName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "[[") or !std.mem.endsWith(u8, line, "]]")) return null;
    if (line.len < 4) return null;
    const name = line[2 .. line.len - 2];
    if (!isValidBareKey(name)) return null;
    return name;
}

/// Bare keys are `[A-Za-z0-9_-]+`.
pub fn isValidBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Decodes a single-line TOML basic string (`"..."`), resolving the supported
/// escapes. Rejects control characters, raw newlines, invalid UTF-8, and
/// escapes outside the subset. Caller owns the returned slice.
pub fn parseString(allocator: std.mem.Allocator, raw: []const u8) (StringError || std.mem.Allocator.Error)![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidString;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 1;
    while (i < raw.len - 1) : (i += 1) {
        const c = raw[i];
        if (c == '\\') {
            i += 1;
            if (i >= raw.len - 1) return error.InvalidString;
            switch (raw[i]) {
                'b' => try out.append(allocator, '\x08'),
                't' => try out.append(allocator, '\t'),
                'n' => try out.append(allocator, '\n'),
                'f' => try out.append(allocator, '\x0c'),
                'r' => try out.append(allocator, '\r'),
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                else => return error.InvalidString,
            }
        } else {
            if (c == '"' or c == '\n' or c == '\r' or c < 0x20 or c == 0x7f) return error.InvalidString;
            try out.append(allocator, c);
        }
    }

    const value = try out.toOwnedSlice(allocator);
    errdefer allocator.free(value);
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidString;
    return value;
}

/// Encodes `value` as a single-line TOML basic string, escaping the supported
/// control characters. Rejects invalid UTF-8 and control characters that have
/// no escape in the subset.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) (StringError || std.Io.Writer.Error)!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidString;

    try writer.writeByte('"');
    for (value) |c| switch (c) {
        '\x08' => try writer.writeAll("\\b"),
        '\t' => try writer.writeAll("\\t"),
        '\n' => try writer.writeAll("\\n"),
        '\x0c' => try writer.writeAll("\\f"),
        '\r' => try writer.writeAll("\\r"),
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => return error.InvalidString,
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

test "LineIterator skips blanks and comments while tracking line numbers" {
    var lines: LineIterator = .init("# header\n\nversion = 1\r\n  # indented comment\n[[bindings]]\n");

    try std.testing.expectEqualStrings("version = 1", lines.next().?);
    try std.testing.expectEqual(@as(usize, 3), lines.line_number);
    try std.testing.expectEqualStrings("[[bindings]]", lines.next().?);
    try std.testing.expectEqual(@as(usize, 5), lines.line_number);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}

test "LineIterator yields nothing for empty or comment-only content" {
    var empty: LineIterator = .init("");
    try std.testing.expectEqual(@as(?[]const u8, null), empty.next());

    var comments: LineIterator = .init("# a\n   \n\t\n# b\n");
    try std.testing.expectEqual(@as(?[]const u8, null), comments.next());
}

test "splitKeyValue splits at first equals and trims" {
    const pair = splitKeyValue("key = \"a = b\"").?;
    try std.testing.expectEqualStrings("key", pair.key);
    try std.testing.expectEqualStrings("\"a = b\"", pair.raw_value);

    try std.testing.expectEqual(@as(?KeyValue, null), splitKeyValue("[[bindings]]"));
}

test "arrayTableName recognizes valid headers only" {
    try std.testing.expectEqualStrings("bindings", arrayTableName("[[bindings]]").?);
    try std.testing.expectEqualStrings("repos", arrayTableName("[[repos]]").?);
    try std.testing.expectEqual(@as(?[]const u8, null), arrayTableName("[bindings]"));
    try std.testing.expectEqual(@as(?[]const u8, null), arrayTableName("[[]]"));
    try std.testing.expectEqual(@as(?[]const u8, null), arrayTableName("[[ bindings ]]"));
    try std.testing.expectEqual(@as(?[]const u8, null), arrayTableName("[[a.b]]"));
}

test "isValidBareKey accepts the bare-key alphabet only" {
    try std.testing.expect(isValidBareKey("sig"));
    try std.testing.expect(isValidBareKey("a-b_C9"));
    try std.testing.expect(!isValidBareKey(""));
    try std.testing.expect(!isValidBareKey("a.b"));
    try std.testing.expect(!isValidBareKey("a b"));
}

test "parseString and writeString round-trip every supported escape" {
    const allocator = std.testing.allocator;
    const original = "quote\" slash\\ tab\t line\n carriage\r backspace\x08 formfeed\x0c plain";

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try writeString(&encoded.writer, original);

    const decoded = try parseString(allocator, encoded.written());
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(original, decoded);
}

test "parseString rejects strings outside the subset" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "unquoted",
        "\"unterminated",
        "\"trailing\\\"",
        "\"bad\\u1234\"",
        "\"raw\nnewline\"",
        "\"\xff\"",
        "\"",
    };
    for (cases) |raw| {
        try std.testing.expectError(error.InvalidString, parseString(allocator, raw));
    }
}

test "writeString rejects unescapable control characters and invalid UTF-8" {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try std.testing.expectError(error.InvalidString, writeString(&discard.writer, "nul\x00"));
    try std.testing.expectError(error.InvalidString, writeString(&discard.writer, "bad\xff"));
}
