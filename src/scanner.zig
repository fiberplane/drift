const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const markdown = @import("markdown.zig");

pub const Doc = struct {
    path: []const u8,
    anchors: std.ArrayList([]const u8),
    origin: ?[]const u8 = null,

    pub fn deinit(self: *Doc, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.anchors.items) |b| allocator.free(b);
        self.anchors.deinit(allocator);
        if (self.origin) |o| allocator.free(o);
    }
};

fn isMarkdownTrackedPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md");
}

/// Append inline `@./` anchors from `content` into `anchors`, skipping duplicates of existing entries.
fn mergeInlineAnchors(allocator: std.mem.Allocator, anchors: *std.ArrayList([]const u8), content: []const u8) !void {
    var inline_anchors = try parseInlineAnchors(allocator, content);
    defer inline_anchors.deinit(allocator);

    for (inline_anchors.items) |anchor| {
        var already_bound = false;
        for (anchors.items) |existing| {
            if (std.mem.eql(u8, existing, anchor)) {
                already_bound = true;
                break;
            }
        }

        if (already_bound) {
            allocator.free(anchor);
            continue;
        }

        try anchors.append(allocator, anchor);
    }
}

/// Discover docs by listing git-tracked markdown files.
/// Respects .gitignore — untracked/ignored files are never scanned.
/// Uses `-z` (NUL-terminated paths) so unusual paths are raw bytes (newline mode C-escapes
/// names with quotes). Filters `.md` in-process so pathspec globs are not required.
pub fn findDocs(allocator: std.mem.Allocator, docs: *std.ArrayList(Doc)) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var offset: usize = 0;
    while (offset < result.stdout.len) {
        const rest = result.stdout[offset..];
        const rel_end = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        const line = rest[0..rel_end];
        offset += rel_end + 1;

        if (line.len == 0) continue;
        if (!isMarkdownTrackedPath(line)) continue;

        const file_path = try allocator.dupe(u8, line);

        const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch {
            allocator.free(file_path);
            continue;
        };
        defer allocator.free(content);

        if (try frontmatter.parseDriftDoc(allocator, content)) |drift_doc| {
            var doc = drift_doc;
            errdefer {
                for (doc.anchors.items) |b| allocator.free(b);
                doc.anchors.deinit(allocator);
                if (doc.origin) |o| allocator.free(o);
            }
            try mergeInlineAnchors(allocator, &doc.anchors, content);
            try docs.append(allocator, .{
                .path = file_path,
                .anchors = doc.anchors,
                .origin = doc.origin,
            });
        } else {
            allocator.free(file_path);
        }
    }
}

/// Discover docs, merge inline anchors, and sort by path.
pub fn findAndSortDocs(allocator: std.mem.Allocator, docs: *std.ArrayList(Doc)) !void {
    try findDocs(allocator, docs);

    std.mem.sort(Doc, docs.items, {}, struct {
        fn lessThan(_: void, a: Doc, b: Doc) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
}

/// Parse inline anchors (@./path references) from markdown content body.
pub fn parseInlineAnchors(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
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
            if (markdown.isInCodeContext(content, body_offset + ref_pos)) {
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
                const duped = try allocator.dupe(u8, path);
                try anchors.append(allocator, duped);
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
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        if (std.mem.indexOf(u8, content[pos..], "@./")) |offset| {
            const ref_start = pos + offset; // position of '@' in "@./"

            // Skip references inside fenced code blocks or inline backtick spans
            if (markdown.isInCodeContext(content, ref_start)) {
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

    return try output.toOwnedSlice(allocator);
}

pub fn isPathTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn isTrailingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == ')' or c == ']' or c == '}' or c == '!' or c == '?' or c == '"' or c == '\'' or c == '>';
}

// --- unit tests ---

test "parseInlineAnchors strips surrounding quote punctuation" {
    const allocator = std.testing.allocator;
    const content =
        \\# Doc
        \\
        \\See "@./src/main.ts" and '@./src/lib.ts#Foo'.
        \\
    ;

    var anchors = try parseInlineAnchors(allocator, content);
    defer {
        for (anchors.items) |anchor| allocator.free(anchor);
        anchors.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), anchors.items.len);
    try std.testing.expectEqualStrings("src/main.ts", anchors.items[0]);
    try std.testing.expectEqualStrings("src/lib.ts#Foo", anchors.items[1]);
}

test "updateInlineAnchors preserves surrounding quote punctuation" {
    const allocator = std.testing.allocator;
    const content =
        \\# Doc
        \\
        \\See "@./src/main.ts" and '@./src/lib.ts#Foo'.
        \\
    ;

    const result = try updateInlineAnchors(allocator, content, null, "abc123");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"@./src/main.ts@abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "'@./src/lib.ts#Foo@abc123'") != null);
}
