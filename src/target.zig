const std = @import("std");

pub const ParsedTarget = struct {
    identity: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,

    pub fn isHeading(self: ParsedTarget) bool {
        return self.symbol_name != null and std.mem.eql(u8, std.fs.path.extension(self.file_path), ".md");
    }

    pub fn kind(self: ParsedTarget) []const u8 {
        if (self.isHeading()) return "heading";
        if (self.symbol_name != null) return "symbol";
        return "file";
    }
};

pub fn parse(raw_target: []const u8) ParsedTarget {
    const hash_pos = std.mem.indexOfScalar(u8, raw_target, '#');
    return .{
        .identity = raw_target,
        .file_path = if (hash_pos) |pos| raw_target[0..pos] else raw_target,
        .symbol_name = if (hash_pos) |pos| raw_target[pos + 1 ..] else null,
    };
}
