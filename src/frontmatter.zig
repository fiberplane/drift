const std = @import("std");

/// Returns true if `pos` in `text` falls inside a fenced code block or inline code span.
pub fn isInCodeContext(text: []const u8, pos: usize) bool {
    var i: usize = 0;
    var in_fence = false;

    while (i < text.len and i <= pos) {
        // Fenced code blocks: ``` or ~~~ at line start (optionally indented up to 3 spaces)
        if (i == 0 or (i > 0 and text[i - 1] == '\n')) {
            var fi = i;
            var spaces: usize = 0;
            while (fi < text.len and text[fi] == ' ' and spaces < 3) {
                fi += 1;
                spaces += 1;
            }
            if (fi < text.len and (text[fi] == '`' or text[fi] == '~')) {
                const fence_char = text[fi];
                var fence_len: usize = 0;
                while (fi + fence_len < text.len and text[fi + fence_len] == fence_char) fence_len += 1;
                if (fence_len >= 3) {
                    in_fence = !in_fence;
                    var skip = fi + fence_len;
                    while (skip < text.len and text[skip] != '\n') skip += 1;
                    if (skip < text.len) skip += 1;
                    if (pos < skip) return in_fence;
                    i = skip;
                    continue;
                }
            }
        }

        if (in_fence) {
            if (i == pos) return true;
            if (text[i] == '\n') {
                i += 1;
            } else {
                while (i < text.len and text[i] != '\n') i += 1;
                if (i < text.len) i += 1;
            }
            continue;
        }

        // Inline code: `...` or ``...``
        if (text[i] == '`') {
            var open_count: usize = 0;
            var oi = i;
            while (oi < text.len and text[oi] == '`') {
                oi += 1;
                open_count += 1;
            }
            // Search for matching closing backtick sequence
            var si = oi;
            while (si < text.len) {
                if (text[si] == '`') {
                    var ci = si;
                    var close_count: usize = 0;
                    while (ci < text.len and text[ci] == '`') {
                        ci += 1;
                        close_count += 1;
                    }
                    if (close_count == open_count) {
                        if (pos >= i and pos < ci) return true;
                        i = ci;
                        break;
                    }
                    si = ci;
                } else {
                    si += 1;
                }
            }
            if (si >= text.len) {
                i = oi; // no matching close, treat backticks as literal
            }
            continue;
        }

        i += 1;
    }

    return in_fence;
}

/// Extract the file identity from an anchor string: strip `@change` suffix but keep `#Symbol`.
/// E.g. "src/file.ts@abc" -> "src/file.ts", "src/lib.ts#Foo@abc" -> "src/lib.ts#Foo"
pub fn anchorFileIdentity(anchor: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, anchor, '@')) |at_pos| {
        return anchor[0..at_pos];
    }
    return anchor;
}

/// Parse drift frontmatter from file content. Returns anchors list if this is a drift spec, null otherwise.
/// Checks both YAML frontmatter and HTML comment-based anchors, merging results.
pub fn parseDriftSpec(allocator: std.mem.Allocator, content: []const u8) ?std.ArrayList([]const u8) {
    var anchors: std.ArrayList([]const u8) = .{};
    var found_source = false;

    // 1. Parse YAML frontmatter anchors
    if (parseFrontmatterAnchors(allocator, content)) |fm_result| {
        var fm_anchors = fm_result;
        found_source = true;
        for (fm_anchors.items) |b| {
            anchors.append(allocator, b) catch {
                allocator.free(b);
            };
        }
        fm_anchors.deinit(allocator);
    }

    // 2. Parse HTML comment-based anchors
    if (parseCommentAnchors(allocator, content)) |comment_result| {
        var comment_anchors = comment_result;
        found_source = true;
        for (comment_anchors.items) |b| {
            anchors.append(allocator, b) catch {
                allocator.free(b);
            };
        }
        comment_anchors.deinit(allocator);
    }

    if (!found_source) {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
        return null;
    }

    return anchors;
}

/// Parse anchors from YAML frontmatter (--- ... --- block).
fn parseFrontmatterAnchors(allocator: std.mem.Allocator, content: []const u8) ?std.ArrayList([]const u8) {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse
        std.mem.indexOf(u8, after_open, "\n---") orelse return null;
    const fm = after_open[0..close_offset];

    var has_drift = false;
    var in_files_section = false;
    var anchors: std.ArrayList([]const u8) = .{};

    var lines_iter = std.mem.splitScalar(u8, fm, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.eql(u8, line, "drift:") or std.mem.startsWith(u8, line, "drift:")) {
            has_drift = true;
            continue;
        }

        if (has_drift and std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const anchor_text = line["    - ".len..];
            const duped = allocator.dupe(u8, anchor_text) catch continue;
            anchors.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            continue;
        }

        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }
    }

    if (!has_drift) {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
        return null;
    }

    return anchors;
}

/// Parse anchors from `<!-- drift: ... -->` HTML comment blocks.
/// Returns null if no comment-based anchors are found.
fn parseCommentAnchors(allocator: std.mem.Allocator, content: []const u8) ?std.ArrayList([]const u8) {
    const marker = "<!-- drift:";
    var anchors: std.ArrayList([]const u8) = .{};
    var found = false;

    var pos: usize = 0;
    while (pos < content.len) {
        const marker_offset = std.mem.indexOf(u8, content[pos..], marker) orelse break;
        const abs_marker_pos = pos + marker_offset;

        // Skip markers inside fenced code blocks or inline code spans
        if (isInCodeContext(content, abs_marker_pos)) {
            pos = abs_marker_pos + marker.len;
            continue;
        }

        const block_start = abs_marker_pos + marker.len;

        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse break;
        const block_content = content[block_start .. block_start + close_offset];

        // Parse lines inside the comment block using the same YAML-like format
        var in_files_section = false;
        var lines_iter = std.mem.splitScalar(u8, block_content, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "files:")) {
                in_files_section = true;
                continue;
            }

            if (in_files_section and std.mem.startsWith(u8, trimmed, "- ")) {
                const anchor_text = trimmed["- ".len..];
                if (anchor_text.len > 0) {
                    const duped = allocator.dupe(u8, anchor_text) catch continue;
                    anchors.append(allocator, duped) catch {
                        allocator.free(duped);
                        continue;
                    };
                    found = true;
                }
                continue;
            }

            // Non-empty, non-list line ends files section
            if (in_files_section and trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "- ")) {
                in_files_section = false;
            }
        }

        pos = block_start + close_offset + 3; // skip past "-->"
    }

    if (!found) {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
        return null;
    }

    return anchors;
}

/// Check if content has a `<!-- drift: ... -->` comment block outside of code contexts.
fn hasCommentAnchors(content: []const u8) bool {
    const marker = "<!-- drift:";
    var pos: usize = 0;
    while (pos < content.len) {
        const marker_offset = std.mem.indexOf(u8, content[pos..], marker) orelse return false;
        const abs_marker_pos = pos + marker_offset;
        if (!isInCodeContext(content, abs_marker_pos)) return true;
        pos = abs_marker_pos + marker.len;
    }
    return false;
}

/// Add or update an anchor inside a `<!-- drift: ... -->` comment block.
fn linkCommentAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) ![]const u8 {
    const new_identity = anchorFileIdentity(anchor);
    const marker = "<!-- drift:";

    // Find the first marker outside of code contexts
    const marker_pos = blk: {
        var search_pos: usize = 0;
        while (search_pos < content.len) {
            const offset = std.mem.indexOf(u8, content[search_pos..], marker) orelse
                return try allocator.dupe(u8, content);
            const abs_pos = search_pos + offset;
            if (!isInCodeContext(content, abs_pos)) break :blk abs_pos;
            search_pos = abs_pos + marker.len;
        }
        return try allocator.dupe(u8, content);
    };
    const block_start = marker_pos + marker.len;
    const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
        return try allocator.dupe(u8, content);
    };
    const block_content = content[block_start .. block_start + close_offset];
    const block_end = block_start + close_offset; // position of "-->"

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    // Write everything before the comment block content
    try writer.writeAll(content[0..block_start]);

    // Rewrite the comment block content with the anchor added/updated
    var found_existing = false;
    var in_files_section = false;
    var wrote_anchor = false;
    var lines_iter = std.mem.splitScalar(u8, block_content, '\n');

    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "files:")) {
            in_files_section = true;
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, trimmed, "- ")) {
            const existing_anchor = trimmed["- ".len..];
            const existing_identity = anchorFileIdentity(existing_anchor);

            if (std.mem.eql(u8, existing_identity, new_identity)) {
                try writer.writeAll("    - ");
                try writer.writeAll(anchor);
                try writer.writeByte('\n');
                found_existing = true;
                wrote_anchor = true;
                continue;
            }
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (in_files_section and trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "- ")) {
            if (!found_existing and !wrote_anchor) {
                try writer.writeAll("    - ");
                try writer.writeAll(anchor);
                try writer.writeByte('\n');
                wrote_anchor = true;
            }
            in_files_section = false;
        }

        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    // If still in files section at end, append
    if (!wrote_anchor) {
        try writer.writeAll("    - ");
        try writer.writeAll(anchor);
        try writer.writeByte('\n');
    }

    // Write the closing --> and everything after
    try writer.writeAll(content[block_end..]);

    return try allocator.dupe(u8, output.items);
}

/// Update all anchors in `<!-- drift: ... -->` comment blocks with a new provenance change ID.
fn relinkCommentAnchors(allocator: std.mem.Allocator, content: []const u8, change_id: []const u8) ![]const u8 {
    const marker = "<!-- drift:";

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    var pos: usize = 0;
    while (pos < content.len) {
        const marker_offset = std.mem.indexOf(u8, content[pos..], marker) orelse {
            try writer.writeAll(content[pos..]);
            break;
        };
        const abs_marker_pos = pos + marker_offset;

        // Skip markers inside fenced code blocks or inline code spans
        if (isInCodeContext(content, abs_marker_pos)) {
            try writer.writeAll(content[pos .. abs_marker_pos + marker.len]);
            pos = abs_marker_pos + marker.len;
            continue;
        }

        const block_start = abs_marker_pos + marker.len;

        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
            try writer.writeAll(content[pos..]);
            break;
        };
        const block_content = content[block_start .. block_start + close_offset];
        const block_end = block_start + close_offset;

        // Write everything before the comment block content
        try writer.writeAll(content[pos..block_start]);

        // Rewrite the comment block content with updated provenance
        var in_files_section = false;
        var lines_iter = std.mem.splitScalar(u8, block_content, '\n');

        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            if (std.mem.startsWith(u8, trimmed, "files:")) {
                in_files_section = true;
                try writer.writeAll(line);
                try writer.writeByte('\n');
                continue;
            }

            if (in_files_section and std.mem.startsWith(u8, trimmed, "- ")) {
                const existing_anchor = trimmed["- ".len..];
                const identity = anchorFileIdentity(existing_anchor);
                try writer.writeAll("    - ");
                try writer.writeAll(identity);
                try writer.writeByte('@');
                try writer.writeAll(change_id);
                try writer.writeByte('\n');
                continue;
            }

            if (in_files_section and trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "- ")) {
                in_files_section = false;
            }

            try writer.writeAll(line);
            try writer.writeByte('\n');
        }

        // Continue after the closing -->
        pos = block_end;
    }

    return try allocator.dupe(u8, output.items);
}

/// Core logic: given file content and an anchor, produce new file content with the anchor added/updated.
pub fn linkAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) ![]const u8 {
    const new_identity = anchorFileIdentity(anchor);

    // Check if file has YAML frontmatter (starts with "---\n")
    if (std.mem.startsWith(u8, content, "---\n")) {
        // Find the closing "---\n"
        const after_open = content[4..];
        if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
            // close_offset is index in after_open where "\n---\n" starts
            const frontmatter = after_open[0..close_offset]; // text between the two ---
            const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

            // Process the frontmatter lines
            var output: std.ArrayList(u8) = .{};
            defer output.deinit(allocator);
            const writer = output.writer(allocator);

            try writer.writeAll("---\n");

            var found_existing = false;
            var in_files_section = false;
            var wrote_anchor = false;
            var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

            while (lines_iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "  files:")) {
                    in_files_section = true;
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
                    const existing_anchor = line["    - ".len..];
                    const existing_identity = anchorFileIdentity(existing_anchor);

                    if (std.mem.eql(u8, existing_identity, new_identity)) {
                        // Replace this line with the new anchor
                        try writer.print("    - {s}\n", .{anchor});
                        found_existing = true;
                        wrote_anchor = true;
                        continue;
                    }
                    // Keep the existing line
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                // If we were in files section and hit a non-list line, we left it
                if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
                    // Before leaving files section, append new anchor if not found
                    if (!found_existing and !wrote_anchor) {
                        try writer.print("    - {s}\n", .{anchor});
                        wrote_anchor = true;
                    }
                    in_files_section = false;
                }

                try writer.writeAll(line);
                try writer.writeByte('\n');
            }

            // If we were still in files section at end of frontmatter, append
            if (!wrote_anchor) {
                try writer.print("    - {s}\n", .{anchor});
            }

            try writer.writeAll("---\n");

            // Append the body
            if (body_start <= content.len) {
                try writer.writeAll(content[body_start..]);
            }

            return try allocator.dupe(u8, output.items);
        }
    }

    // No YAML frontmatter: check for comment-based anchors
    if (hasCommentAnchors(content)) {
        return try linkCommentAnchor(allocator, content, anchor);
    }

    // No frontmatter and no comment block: prepend a complete frontmatter block
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    try writer.writeAll("drift:\n");
    try writer.writeAll("  files:\n");
    try writer.print("    - {s}\n", .{anchor});
    try writer.writeAll("---\n");
    try writer.writeAll(content);

    return try allocator.dupe(u8, output.items);
}

/// Update all anchors in frontmatter and comment blocks with a new provenance change ID.
/// Returns the full updated content.
pub fn relinkAllAnchors(
    allocator: std.mem.Allocator,
    content: []const u8,
    change_id: []const u8,
) ![]const u8 {
    // Step 1: Update frontmatter anchors
    var intermediate: []const u8 = blk: {
        if (!std.mem.startsWith(u8, content, "---\n")) {
            break :blk try allocator.dupe(u8, content);
        }

        const after_open = content[4..];
        const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
            break :blk try allocator.dupe(u8, content);
        };

        const fm = after_open[0..close_offset];
        const body_start = 4 + close_offset + 5;

        var output: std.ArrayList(u8) = .{};
        defer output.deinit(allocator);
        const writer = output.writer(allocator);

        try writer.writeAll("---\n");

        var in_files_section = false;
        var lines_iter = std.mem.splitScalar(u8, fm, '\n');

        while (lines_iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "  files:")) {
                in_files_section = true;
                try writer.writeAll(line);
                try writer.writeByte('\n');
                continue;
            }

            if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
                const existing_anchor = line["    - ".len..];
                const identity = anchorFileIdentity(existing_anchor);
                try writer.print("    - {s}@{s}\n", .{ identity, change_id });
                continue;
            }

            if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
                in_files_section = false;
            }

            try writer.writeAll(line);
            try writer.writeByte('\n');
        }

        try writer.writeAll("---\n");

        if (body_start <= content.len) {
            try writer.writeAll(content[body_start..]);
        }

        break :blk try allocator.dupe(u8, output.items);
    };

    // Step 2: Update comment-based anchors
    if (hasCommentAnchors(intermediate)) {
        const updated = try relinkCommentAnchors(allocator, intermediate, change_id);
        allocator.free(intermediate);
        intermediate = updated;
    }

    return intermediate;
}

pub const UnlinkResult = struct {
    content: []const u8,
    removed: bool,
};

/// Core logic: given file content and an anchor, produce new file content with the anchor removed.
/// Matches on file identity (stripping @provenance from both the existing anchor and the argument).
pub fn unlinkAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) !UnlinkResult {
    const target_identity = anchorFileIdentity(anchor);

    // Must have YAML frontmatter to contain anchors
    if (!std.mem.startsWith(u8, content, "---\n")) {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    }

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    };

    const frontmatter = after_open[0..close_offset];
    const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");

    var removed = false;
    var in_files_section = false;
    var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const existing_anchor = line["    - ".len..];
            const existing_identity = anchorFileIdentity(existing_anchor);

            if (std.mem.eql(u8, existing_identity, target_identity)) {
                // Skip this line (remove the anchor)
                removed = true;
                continue;
            }
        }

        // Non-list-item line ends the files section
        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }

        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    try writer.writeAll("---\n");

    // Append the body
    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }

    return .{ .content = try allocator.dupe(u8, output.items), .removed = removed };
}

// --- unit tests for unlinkAnchor ---

test "unlinkAnchor removes matching anchor" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n    - src/b.ts\n---\n# Spec\n";
    const result = try unlinkAnchor(allocator, content, "src/a.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/b.ts") != null);
}

test "unlinkAnchor matches by file identity ignoring provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@abc123\n---\n# Spec\n";
    const result = try unlinkAnchor(allocator, content, "src/file.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/file.ts") == null);
}

test "unlinkAnchor returns removed=false when anchor not found" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n# Spec\n";
    const result = try unlinkAnchor(allocator, content, "src/missing.ts");
    defer allocator.free(result.content);
    try std.testing.expect(!result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") != null);
}

test "unlinkAnchor removes symbol anchor" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/lib.ts#Foo\n---\n# Spec\n";
    const result = try unlinkAnchor(allocator, content, "src/lib.ts#Foo");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/lib.ts#Foo") == null);
}

// --- unit tests for linkAnchor ---

test "linkAnchor adds anchor to empty files list" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n---\n# Spec\n";
    const result = try linkAnchor(allocator, content, "src/new.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Spec") != null);
}

test "linkAnchor updates existing anchor provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@old\n---\n# Spec\n";
    const result = try linkAnchor(allocator, content, "src/file.ts@new");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@new") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@old") == null);
}

test "linkAnchor adds frontmatter to plain markdown" {
    const allocator = std.testing.allocator;
    const content = "# Just a plain markdown file\n\nSome content.\n";
    const result = try linkAnchor(allocator, content, "src/target.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "drift:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/target.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Just a plain markdown file") != null);
}

// --- unit tests for comment-based anchors ---

test "parseDriftSpec parses comment-based anchors" {
    const allocator = std.testing.allocator;
    const content = "# My Doc\n\n<!-- drift:\n  files:\n    - src/main.zig\n    - src/vcs.zig\n-->\n\nSome content.\n";
    const anchors = parseDriftSpec(allocator, content) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), anchors.items.len);
    try std.testing.expectEqualStrings("src/main.zig", anchors.items[0]);
    try std.testing.expectEqualStrings("src/vcs.zig", anchors.items[1]);
}

test "parseDriftSpec merges frontmatter and comment anchors" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n\n<!-- drift:\n  files:\n    - src/b.ts\n-->\n";
    const anchors = parseDriftSpec(allocator, content) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), anchors.items.len);
}

test "parseDriftSpec parses comment with provenance" {
    const allocator = std.testing.allocator;
    const content = "<!-- drift:\n  files:\n    - src/main.zig@abc123\n-->\n";
    const anchors = parseDriftSpec(allocator, content) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), anchors.items.len);
    try std.testing.expectEqualStrings("src/main.zig@abc123", anchors.items[0]);
}

test "linkAnchor updates comment-based anchor" {
    const allocator = std.testing.allocator;
    const content = "# Doc\n\n<!-- drift:\n  files:\n    - src/old.ts@abc\n-->\n\nBody.\n";
    const result = try linkAnchor(allocator, content, "src/old.ts@def");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/old.ts@def") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/old.ts@abc") == null);
}

test "linkAnchor adds to comment-based anchor" {
    const allocator = std.testing.allocator;
    const content = "# Doc\n\n<!-- drift:\n  files:\n    - src/existing.ts\n-->\n\nBody.\n";
    const result = try linkAnchor(allocator, content, "src/new.ts@abc");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/existing.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts@abc") != null);
}

test "relinkAllAnchors updates comment-based anchors" {
    const allocator = std.testing.allocator;
    const content = "# Doc\n\n<!-- drift:\n  files:\n    - src/main.zig@old\n    - src/vcs.zig\n-->\n\nBody.\n";
    const result = try relinkAllAnchors(allocator, content, "newchange");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/main.zig@newchange") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/vcs.zig@newchange") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "@old") == null);
}

test "parseCommentAnchors skips markers inside fenced code blocks" {
    const allocator = std.testing.allocator;
    const content =
        \\<!-- drift:
        \\  files:
        \\    - src/real.zig
        \\-->
        \\
        \\# Example
        \\
        \\```markdown
        \\<!-- drift:
        \\  files:
        \\    - src/fake.ts
        \\-->
        \\```
    ;
    const anchors = parseDriftSpec(allocator, content) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), anchors.items.len);
    try std.testing.expectEqualStrings("src/real.zig", anchors.items[0]);
}
