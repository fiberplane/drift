const std = @import("std");
const frontmatter = @import("frontmatter.zig");

pub const Spec = struct {
    path: []const u8,
    anchors: std.ArrayList([]const u8),

    pub fn deinit(self: *Spec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.anchors.items) |b| allocator.free(b);
        self.anchors.deinit(allocator);
    }
};

pub const skip_dirs = [_][]const u8{ ".git", ".jj", "node_modules", "vendor", ".zig-cache" };

pub fn shouldSkipDir(name: []const u8) bool {
    // Skip hidden directories (starting with '.')
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

pub fn walkForSpecs(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, specs: *std.ArrayList(Spec)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.name)) continue;

            const sub_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(sub_prefix);

            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkForSpecs(allocator, sub_dir, sub_prefix, specs);
        } else if (entry.kind == .file) {
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const file_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

            const content = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
                allocator.free(file_path);
                continue;
            };
            defer allocator.free(content);

            if (frontmatter.parseDriftSpec(allocator, content)) |anchors| {
                try specs.append(allocator, .{
                    .path = file_path,
                    .anchors = anchors,
                });
            } else {
                allocator.free(file_path);
            }
        }
    }
}

/// Parse inline anchors (@./path references) from markdown content body.
pub fn parseInlineAnchors(allocator: std.mem.Allocator, content: []const u8) std.ArrayList([]const u8) {
    var anchors: std.ArrayList([]const u8) = .{};

    // Find body: skip frontmatter if present
    const body = blk: {
        if (std.mem.startsWith(u8, content, "---\n")) {
            const after_open = content[4..];
            if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
                break :blk after_open[close_offset + 5 ..];
            }
            if (std.mem.indexOf(u8, after_open, "\n---")) |close_offset| {
                const end = close_offset + 4; // skip "\n---"
                if (end <= after_open.len) {
                    break :blk after_open[end..];
                }
            }
        }
        break :blk content;
    };

    // Compute body offset within content for isInCodeContext
    const body_offset = @intFromPtr(body.ptr) - @intFromPtr(content.ptr);

    // Scan for @./ references, skipping code blocks and inline code
    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOf(u8, body[pos..], "@./")) |offset| {
            const ref_pos = pos + offset;

            // Skip references inside fenced code blocks or inline backtick spans
            if (isInCodeContext(content, body_offset + ref_pos)) {
                pos = ref_pos + 3;
                continue;
            }

            const path_start = ref_pos + 3; // skip "@./"

            // Find end of path: next whitespace or end of body
            var path_end = path_start;
            while (path_end < body.len and !isPathTerminator(body[path_end])) {
                path_end += 1;
            }

            // Strip trailing punctuation
            while (path_end > path_start and isTrailingPunctuation(body[path_end - 1])) {
                path_end -= 1;
            }

            if (path_end > path_start) {
                const path = body[path_start..path_end];
                const duped = allocator.dupe(u8, path) catch {
                    pos = path_end;
                    continue;
                };
                anchors.append(allocator, duped) catch {
                    allocator.free(duped);
                    pos = path_end;
                    continue;
                };
            }

            pos = path_end;
        } else {
            break;
        }
    }

    return anchors;
}

/// Update inline `@./` references with a new provenance change ID.
/// If `target_file` is non-null, only update refs whose file identity matches.
/// If null, update all inline refs. Returns the full updated content.
pub fn updateInlineAnchors(
    allocator: std.mem.Allocator,
    content: []const u8,
    target_file: ?[]const u8,
    change_id: []const u8,
) ![]const u8 {
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        if (std.mem.indexOf(u8, content[pos..], "@./")) |offset| {
            const ref_start = pos + offset; // position of '@' in "@./"

            // Skip references inside fenced code blocks or inline backtick spans
            if (isInCodeContext(content, ref_start)) {
                try writer.writeAll(content[pos .. ref_start + 3]);
                pos = ref_start + 3;
                continue;
            }

            const path_start = ref_start + 3; // skip "@./"

            // Find end of reference: next whitespace or end of content
            var path_end = path_start;
            while (path_end < content.len and !isPathTerminator(content[path_end])) {
                path_end += 1;
            }

            // Strip trailing punctuation
            var ref_end = path_end;
            while (ref_end > path_start and isTrailingPunctuation(content[ref_end - 1])) {
                ref_end -= 1;
            }

            if (ref_end > path_start) {
                const ref_path = content[path_start..ref_end]; // path after "@./"

                // Get file identity (strips @provenance)
                const ref_identity = frontmatter.anchorFileIdentity(ref_path);

                // Get file path portion (strips #symbol) for matching
                const ref_hash_pos = std.mem.indexOfScalar(u8, ref_identity, '#');
                const ref_file_path = if (ref_hash_pos) |hp| ref_identity[0..hp] else ref_identity;

                // Check if we should update this ref
                const should_update = if (target_file) |tf|
                    std.mem.eql(u8, ref_file_path, tf)
                else
                    true;

                if (should_update) {
                    // Write everything before this reference
                    try writer.writeAll(content[pos..ref_start]);
                    // Write updated reference: @./identity@change_id
                    try writer.writeAll("@./");
                    try writer.writeAll(ref_identity);
                    try writer.writeByte('@');
                    try writer.writeAll(change_id);
                    // Write any trailing punctuation that was stripped
                    try writer.writeAll(content[ref_end..path_end]);
                    pos = path_end;
                    continue;
                }
            }

            // Not updating this ref, copy it as-is
            try writer.writeAll(content[pos..path_end]);
            pos = path_end;
        } else {
            // No more @./ references, copy the rest
            try writer.writeAll(content[pos..]);
            break;
        }
    }

    return try allocator.dupe(u8, output.items);
}

/// Returns true if `pos` in `text` falls inside a fenced code block or inline code span.
pub const isInCodeContext = frontmatter.isInCodeContext;

pub fn isPathTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn isTrailingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == ')' or c == ']' or c == '}' or c == '!' or c == '?';
}
