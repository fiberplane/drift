const std = @import("std");
const markdown = @import("markdown.zig");

/// Extract the file identity from an anchor string: strip `@change` suffix but keep `#Symbol`.
/// E.g. "src/file.ts@abc" -> "src/file.ts", "src/lib.ts#Foo@abc" -> "src/lib.ts#Foo"
pub fn anchorFileIdentity(anchor: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, anchor, '@')) |at_pos| {
        return anchor[0..at_pos];
    }
    return anchor;
}

/// Parsed `drift:` subtree in YAML frontmatter or in an HTML comment body: non-`files` lines
/// (e.g. `  origin:`, `  owner:`) plus the file anchor list. Used for parse → mutate → emit.
const DriftBlock = struct {
    lines_before_files: std.ArrayList([]const u8),
    files: std.ArrayList([]const u8),

    fn deinit(self: *DriftBlock, allocator: std.mem.Allocator) void {
        for (self.lines_before_files.items) |s| allocator.free(s);
        self.lines_before_files.deinit(allocator);
        for (self.files.items) |s| allocator.free(s);
        self.files.deinit(allocator);
    }
};

const FrontmatterSplit = struct {
    before: std.ArrayList([]const u8),
    drift_header: []const u8,
    block: DriftBlock,
    after: std.ArrayList([]const u8),
    has_drift: bool,

    fn deinit(self: *FrontmatterSplit, allocator: std.mem.Allocator) void {
        for (self.before.items) |s| allocator.free(s);
        self.before.deinit(allocator);
        allocator.free(self.drift_header);
        self.block.deinit(allocator);
        for (self.after.items) |s| allocator.free(s);
        self.after.deinit(allocator);
    }
};

fn parseDriftSectionFm(allocator: std.mem.Allocator, lines: []const []const u8, start: usize) !struct { end: usize, block: DriftBlock } {
    var block = DriftBlock{
        .lines_before_files = .{},
        .files = .{},
    };
    errdefer block.deinit(allocator);

    var i = start;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (line.len > 0 and !std.mem.startsWith(u8, line, " ")) {
            return .{ .end = i, .block = block };
        }

        if (std.mem.startsWith(u8, line, "  files:")) {
            i += 1;
            while (i < lines.len) : (i += 1) {
                const ln = lines[i];
                if (std.mem.startsWith(u8, ln, "    - ")) {
                    const anchor = try allocator.dupe(u8, ln["    - ".len..]);
                    try block.files.append(allocator, anchor);
                } else break;
            }
            i -= 1;
            continue;
        }

        const line_dup = try allocator.dupe(u8, line);
        try block.lines_before_files.append(allocator, line_dup);
    }
    return .{ .end = lines.len, .block = block };
}

fn parseFrontmatterSplit(allocator: std.mem.Allocator, fm: []const u8) !FrontmatterSplit {
    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, fm, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, line);
    }

    var drift_idx: ?usize = null;
    for (lines.items, 0..) |line, idx| {
        if (std.mem.eql(u8, line, "drift:") or std.mem.startsWith(u8, line, "drift:")) {
            drift_idx = idx;
            break;
        }
    }

    if (drift_idx == null) {
        var before: std.ArrayList([]const u8) = .{};
        errdefer {
            for (before.items) |s| allocator.free(s);
            before.deinit(allocator);
        }
        for (lines.items) |line| {
            try before.append(allocator, try allocator.dupe(u8, line));
        }
        return .{
            .before = before,
            .drift_header = try allocator.dupe(u8, ""),
            .block = DriftBlock{ .lines_before_files = .{}, .files = .{} },
            .after = .{},
            .has_drift = false,
        };
    }

    const di = drift_idx.?;

    var before: std.ArrayList([]const u8) = .{};
    errdefer {
        for (before.items) |s| allocator.free(s);
        before.deinit(allocator);
    }
    for (lines.items[0..di]) |line| {
        try before.append(allocator, try allocator.dupe(u8, line));
    }

    const drift_header = try allocator.dupe(u8, lines.items[di]);

    const parsed = try parseDriftSectionFm(allocator, lines.items, di + 1);
    var block = parsed.block;
    errdefer block.deinit(allocator);

    var after: std.ArrayList([]const u8) = .{};
    errdefer {
        for (after.items) |s| allocator.free(s);
        after.deinit(allocator);
    }
    for (lines.items[parsed.end..]) |line| {
        try after.append(allocator, try allocator.dupe(u8, line));
    }

    return .{
        .before = before,
        .drift_header = drift_header,
        .block = block,
        .after = after,
        .has_drift = true,
    };
}

fn writeDriftBlock(writer: anytype, block: *const DriftBlock) !void {
    for (block.lines_before_files.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    try writer.writeAll("  files:\n");
    for (block.files.items) |a| {
        try writer.print("    - {s}\n", .{a});
    }
}

fn linkDriftBlock(block: *DriftBlock, allocator: std.mem.Allocator, anchor: []const u8) !void {
    const new_identity = anchorFileIdentity(anchor);
    for (block.files.items, 0..) |existing, idx| {
        if (std.mem.eql(u8, anchorFileIdentity(existing), new_identity)) {
            allocator.free(existing);
            block.files.items[idx] = try allocator.dupe(u8, anchor);
            return;
        }
    }
    try block.files.append(allocator, try allocator.dupe(u8, anchor));
}

fn unlinkDriftBlock(block: *DriftBlock, allocator: std.mem.Allocator, target_identity: []const u8) bool {
    var removed = false;
    var i: usize = 0;
    while (i < block.files.items.len) {
        if (std.mem.eql(u8, anchorFileIdentity(block.files.items[i]), target_identity)) {
            allocator.free(block.files.items[i]);
            _ = block.files.swapRemove(i);
            removed = true;
        } else {
            i += 1;
        }
    }
    return removed;
}

fn relinkDriftBlock(block: *DriftBlock, allocator: std.mem.Allocator, change_id: []const u8) !void {
    for (block.files.items, 0..) |existing, idx| {
        const identity = anchorFileIdentity(existing);
        allocator.free(block.files.items[idx]);
        block.files.items[idx] = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ identity, change_id });
    }
}

fn originFromDriftBlockLines(allocator: std.mem.Allocator, block: *const DriftBlock) !?[]const u8 {
    for (block.lines_before_files.items) |line| {
        if (std.mem.startsWith(u8, line, "  origin: ")) {
            const value = line["  origin: ".len..];
            if (value.len > 0) return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn originFromCommentBlock(allocator: std.mem.Allocator, block: *const DriftBlock) !?[]const u8 {
    for (block.lines_before_files.items) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "origin: ")) {
            const value = trimmed["origin: ".len..];
            if (value.len > 0) return try allocator.dupe(u8, value);
        }
    }
    return null;
}

fn emitFrontmatterToOwned(
    allocator: std.mem.Allocator,
    split: *const FrontmatterSplit,
    body_start: usize,
    content: []const u8,
) ![]const u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    for (split.before.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    try writer.writeAll(split.drift_header);
    try writer.writeByte('\n');
    try writeDriftBlock(writer, &split.block);
    for (split.after.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    try writer.writeAll("---\n");
    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }
    return try output.toOwnedSlice(allocator);
}

fn emitFrontmatterInsertDrift(
    allocator: std.mem.Allocator,
    split: *const FrontmatterSplit,
    anchor: []const u8,
    body_start: usize,
    content: []const u8,
) ![]const u8 {
    var block = DriftBlock{
        .lines_before_files = .{},
        .files = .{},
    };
    defer block.deinit(allocator);
    try linkDriftBlock(&block, allocator, anchor);

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    for (split.before.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    try writer.writeAll("drift:\n");
    try writeDriftBlock(writer, &block);
    try writer.writeAll("---\n");
    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }
    return try output.toOwnedSlice(allocator);
}

fn parseDriftBlockCommentBody(allocator: std.mem.Allocator, block_content: []const u8) !DriftBlock {
    var block = DriftBlock{
        .lines_before_files = .{},
        .files = .{},
    };
    errdefer block.deinit(allocator);

    var in_files_section = false;
    var lines_iter = std.mem.splitScalar(u8, block_content, '\n');
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "origin: ")) {
            const value = trimmed["origin: ".len..];
            if (value.len > 0) {
                const stored = try std.fmt.allocPrint(allocator, "  origin: {s}", .{value});
                errdefer allocator.free(stored);
                try block.lines_before_files.append(allocator, stored);
            }
            in_files_section = false;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "files:")) {
            in_files_section = true;
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, trimmed, "- ")) {
            const anchor_text = trimmed["- ".len..];
            if (anchor_text.len > 0) {
                try block.files.append(allocator, try allocator.dupe(u8, anchor_text));
            }
            continue;
        }

        if (in_files_section and trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "- ")) {
            in_files_section = false;
        }
    }
    return block;
}

/// Result of parsing a drift doc: anchors list plus optional origin qualifier.
pub const DriftDoc = struct {
    anchors: std.ArrayList([]const u8),
    origin: ?[]const u8,
};

/// Internal parse result from sub-parsers.
const ParseResult = struct {
    anchors: std.ArrayList([]const u8),
    origin: ?[]const u8,
};

/// Parse drift frontmatter from file content. Returns anchors list and origin if this is a drift doc, null otherwise.
/// Checks both YAML frontmatter and HTML comment-based anchors, merging results.
pub fn parseDriftDoc(allocator: std.mem.Allocator, content: []const u8) !?DriftDoc {
    var anchors: std.ArrayList([]const u8) = .{};
    var found_source = false;
    var origin: ?[]const u8 = null;

    // 1. Parse YAML frontmatter anchors
    if (try parseFrontmatterAnchors(allocator, content)) |fm_result| {
        var fm_anchors = fm_result.anchors;
        found_source = true;
        if (fm_result.origin) |o| {
            if (origin == null) origin = o else allocator.free(o);
        }
        for (fm_anchors.items) |b| {
            try anchors.append(allocator, b);
        }
        fm_anchors.deinit(allocator);
    }

    // 2. Parse HTML comment-based anchors
    if (try parseCommentAnchors(allocator, content)) |comment_result| {
        var comment_anchors = comment_result.anchors;
        found_source = true;
        if (comment_result.origin) |o| {
            if (origin == null) origin = o else allocator.free(o);
        }
        for (comment_anchors.items) |b| {
            try anchors.append(allocator, b);
        }
        comment_anchors.deinit(allocator);
    }

    if (!found_source) {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
        if (origin) |o| allocator.free(o);
        return null;
    }

    return .{ .anchors = anchors, .origin = origin };
}

/// Parse anchors from YAML frontmatter (--- ... --- block).
fn parseFrontmatterAnchors(allocator: std.mem.Allocator, content: []const u8) !?ParseResult {
    const fm = markdown.yamlFrontmatterInner(content) orelse return null;
    var split = try parseFrontmatterSplit(allocator, fm);
    defer split.deinit(allocator);
    if (!split.has_drift) return null;

    var anchors: std.ArrayList([]const u8) = .{};
    errdefer {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
    }

    for (split.block.files.items) |s| {
        const duped = try allocator.dupe(u8, s);
        try anchors.append(allocator, duped);
    }

    const origin = try originFromDriftBlockLines(allocator, &split.block);

    return .{ .anchors = anchors, .origin = origin };
}

/// Parse anchors from `<!-- drift: ... -->` HTML comment blocks.
/// Returns null if no comment-based anchors are found.
fn parseCommentAnchors(allocator: std.mem.Allocator, content: []const u8) !?ParseResult {
    const marker = markdown.drift_html_comment_prefix;
    var anchors: std.ArrayList([]const u8) = .{};
    var found = false;
    var origin: ?[]const u8 = null;

    var pos: usize = 0;
    while (markdown.nextDriftCommentMarker(content, pos)) |abs_marker_pos| {
        const block_start = abs_marker_pos + marker.len;

        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse break;
        const block_content = content[block_start .. block_start + close_offset];

        var block = try parseDriftBlockCommentBody(allocator, block_content);
        defer block.deinit(allocator);

        for (block.files.items) |s| {
            const duped = try allocator.dupe(u8, s);
            try anchors.append(allocator, duped);
            found = true;
        }

        if (origin == null) {
            origin = try originFromCommentBlock(allocator, &block);
        }

        pos = block_start + close_offset + 3;
    }

    if (!found and origin == null) {
        for (anchors.items) |b| allocator.free(b);
        anchors.deinit(allocator);
        return null;
    }

    return .{ .anchors = anchors, .origin = origin };
}

/// Check if content has a `<!-- drift: ... -->` comment block outside of code contexts.
fn hasCommentAnchors(content: []const u8) bool {
    return markdown.nextDriftCommentMarker(content, 0) != null;
}

/// Add or update an anchor inside a `<!-- drift: ... -->` comment block.
fn linkCommentAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) ![]const u8 {
    const marker = markdown.drift_html_comment_prefix;

    const marker_pos = markdown.nextDriftCommentMarker(content, 0) orelse
        return try allocator.dupe(u8, content);
    const block_start = marker_pos + marker.len;
    const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
        return try allocator.dupe(u8, content);
    };
    const block_content = content[block_start .. block_start + close_offset];
    const block_end = block_start + close_offset;

    var block = try parseDriftBlockCommentBody(allocator, block_content);
    defer block.deinit(allocator);
    try linkDriftBlock(&block, allocator, anchor);

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll(content[0..block_start]);
    try writeDriftBlock(writer, &block);
    try writer.writeAll(content[block_end..]);

    return try output.toOwnedSlice(allocator);
}

/// Update all anchors in `<!-- drift: ... -->` comment blocks with a new provenance change ID.
fn relinkCommentAnchors(allocator: std.mem.Allocator, content: []const u8, change_id: []const u8) ![]const u8 {
    const marker = markdown.drift_html_comment_prefix;

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    var pos: usize = 0;
    while (markdown.nextDriftCommentMarker(content, pos)) |abs_marker_pos| {
        const block_start = abs_marker_pos + marker.len;

        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
            try writer.writeAll(content[pos..]);
            return try output.toOwnedSlice(allocator);
        };
        const block_content = content[block_start .. block_start + close_offset];
        const block_end = block_start + close_offset;

        try writer.writeAll(content[pos..block_start]);

        var block = try parseDriftBlockCommentBody(allocator, block_content);
        defer block.deinit(allocator);
        try relinkDriftBlock(&block, allocator, change_id);
        try writeDriftBlock(writer, &block);

        pos = block_end;
    }

    try writer.writeAll(content[pos..]);
    return try output.toOwnedSlice(allocator);
}

/// Core logic: given file content and an anchor, produce new file content with the anchor added/updated.
pub fn linkAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) ![]const u8 {
    if (markdown.yamlFrontmatterInnerAndBody(content)) |bounds| {
        const fm = bounds.inner;
        const body_start = bounds.body_start;

        var split = try parseFrontmatterSplit(allocator, fm);
        defer split.deinit(allocator);

        if (!split.has_drift) {
            if (hasCommentAnchors(content)) {
                return try linkCommentAnchor(allocator, content, anchor);
            }
            return try emitFrontmatterInsertDrift(allocator, &split, anchor, body_start, content);
        }

        try linkDriftBlock(&split.block, allocator, anchor);
        return try emitFrontmatterToOwned(allocator, &split, body_start, content);
    }

    if (hasCommentAnchors(content)) {
        return try linkCommentAnchor(allocator, content, anchor);
    }

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    try writer.writeAll("drift:\n");
    try writer.writeAll("  files:\n");
    try writer.print("    - {s}\n", .{anchor});
    try writer.writeAll("---\n");
    try writer.writeAll(content);

    return try output.toOwnedSlice(allocator);
}

/// Update all anchors in frontmatter and comment blocks with a new provenance change ID.
/// Returns the full updated content.
pub fn relinkAllAnchors(
    allocator: std.mem.Allocator,
    content: []const u8,
    change_id: []const u8,
) ![]const u8 {
    var intermediate: []const u8 = blk: {
        const bounds = markdown.yamlFrontmatterInnerAndBody(content) orelse {
            break :blk try allocator.dupe(u8, content);
        };
        const fm = bounds.inner;
        const body_start = bounds.body_start;

        var split = try parseFrontmatterSplit(allocator, fm);
        defer split.deinit(allocator);

        if (!split.has_drift) {
            break :blk try allocator.dupe(u8, content);
        }

        try relinkDriftBlock(&split.block, allocator, change_id);
        break :blk try emitFrontmatterToOwned(allocator, &split, body_start, content);
    };

    if (hasCommentAnchors(intermediate)) {
        const updated = try relinkCommentAnchors(allocator, intermediate, change_id);
        allocator.free(intermediate);
        intermediate = updated;
    }

    return intermediate;
}

fn emitFrontmatterWithoutDrift(
    allocator: std.mem.Allocator,
    split: *const FrontmatterSplit,
    body_start: usize,
    content: []const u8,
) ![]const u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    if (split.before.items.len > 0 or split.after.items.len > 0) {
        try writer.writeAll("---\n");
        for (split.before.items) |line| {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        for (split.after.items) |line| {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        try writer.writeAll("---\n");
    }

    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }
    return try output.toOwnedSlice(allocator);
}

fn stripCommentAnchors(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const marker = markdown.drift_html_comment_prefix;

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    var pos: usize = 0;
    while (markdown.nextDriftCommentMarker(content, pos)) |abs_marker_pos| {
        try writer.writeAll(content[pos..abs_marker_pos]);

        const block_start = abs_marker_pos + marker.len;
        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
            try writer.writeAll(content[abs_marker_pos..]);
            return try output.toOwnedSlice(allocator);
        };
        pos = block_start + close_offset + 3;
        if (pos < content.len and content[pos] == '\n') pos += 1;
    }

    try writer.writeAll(content[pos..]);
    return try output.toOwnedSlice(allocator);
}

/// Remove legacy embedded drift metadata from a doc while preserving its markdown body.
/// This strips YAML `drift:` frontmatter blocks and `<!-- drift: ... -->` comment blocks.
pub fn stripLegacyDriftMetadata(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var intermediate: []const u8 = blk: {
        const bounds = markdown.yamlFrontmatterInnerAndBody(content) orelse {
            break :blk try allocator.dupe(u8, content);
        };
        const fm = bounds.inner;
        const body_start = bounds.body_start;

        var split = try parseFrontmatterSplit(allocator, fm);
        defer split.deinit(allocator);

        if (!split.has_drift) {
            break :blk try allocator.dupe(u8, content);
        }

        break :blk try emitFrontmatterWithoutDrift(allocator, &split, body_start, content);
    };

    if (hasCommentAnchors(intermediate)) {
        const stripped = try stripCommentAnchors(allocator, intermediate);
        allocator.free(intermediate);
        intermediate = stripped;
    }

    return intermediate;
}

pub const UnlinkResult = struct {
    content: []const u8,
    removed: bool,
};

fn unlinkFrontmatterAnchor(
    allocator: std.mem.Allocator,
    content: []const u8,
    target_identity: []const u8,
) !UnlinkResult {
    const bounds = markdown.yamlFrontmatterInnerAndBody(content) orelse {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    };
    const frontmatter = bounds.inner;
    const body_start = bounds.body_start;

    var split = try parseFrontmatterSplit(allocator, frontmatter);
    defer split.deinit(allocator);

    if (!split.has_drift) {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    }

    const removed = unlinkDriftBlock(&split.block, allocator, target_identity);
    if (!removed) {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    }

    const new_content = try emitFrontmatterToOwned(allocator, &split, body_start, content);
    return .{ .content = new_content, .removed = true };
}

fn unlinkCommentAnchor(
    allocator: std.mem.Allocator,
    content: []const u8,
    target_identity: []const u8,
) !UnlinkResult {
    const marker = markdown.drift_html_comment_prefix;

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    var removed = false;
    var pos: usize = 0;
    while (markdown.nextDriftCommentMarker(content, pos)) |abs_marker_pos| {
        const block_start = abs_marker_pos + marker.len;
        const close_offset = std.mem.indexOf(u8, content[block_start..], "-->") orelse {
            try writer.writeAll(content[pos..]);
            return .{ .content = try output.toOwnedSlice(allocator), .removed = removed };
        };
        const block_content = content[block_start .. block_start + close_offset];
        const block_end = block_start + close_offset;

        try writer.writeAll(content[pos..block_start]);

        var block = try parseDriftBlockCommentBody(allocator, block_content);
        defer block.deinit(allocator);
        if (unlinkDriftBlock(&block, allocator, target_identity)) {
            removed = true;
        }
        try writeDriftBlock(writer, &block);

        pos = block_end;
    }

    try writer.writeAll(content[pos..]);
    return .{ .content = try output.toOwnedSlice(allocator), .removed = removed };
}

/// Core logic: given file content and an anchor, produce new file content with the anchor removed.
/// Matches on file identity (stripping @provenance from both the existing anchor and the argument).
pub fn unlinkAnchor(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) !UnlinkResult {
    const target_identity = anchorFileIdentity(anchor);

    var result = try unlinkFrontmatterAnchor(allocator, content, target_identity);
    errdefer allocator.free(result.content);

    if (hasCommentAnchors(result.content)) {
        const comment_result = try unlinkCommentAnchor(allocator, result.content, target_identity);
        allocator.free(result.content);
        result = .{
            .content = comment_result.content,
            .removed = result.removed or comment_result.removed,
        };
    }

    return result;
}

// --- unit tests for unlinkAnchor ---

test "unlinkAnchor removes matching anchor" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n    - src/b.ts\n---\n# Doc\n";
    const result = try unlinkAnchor(allocator, content, "src/a.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/b.ts") != null);
}

test "unlinkAnchor matches by file identity ignoring provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@abc123\n---\n# Doc\n";
    const result = try unlinkAnchor(allocator, content, "src/file.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/file.ts") == null);
}

test "unlinkAnchor returns removed=false when anchor not found" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n# Doc\n";
    const result = try unlinkAnchor(allocator, content, "src/missing.ts");
    defer allocator.free(result.content);
    try std.testing.expect(!result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") != null);
}

test "unlinkAnchor removes symbol anchor" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/lib.ts#Foo\n---\n# Doc\n";
    const result = try unlinkAnchor(allocator, content, "src/lib.ts#Foo");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/lib.ts#Foo") == null);
}

test "unlinkAnchor removes comment-based anchor" {
    const allocator = std.testing.allocator;
    const content =
        "# Doc\n\n" ++
        "<!-- drift:\n" ++
        "  files:\n" ++
        "    - src/a.ts\n" ++
        "    - src/b.ts\n" ++
        "-->\n";
    const result = try unlinkAnchor(allocator, content, "src/a.ts");
    defer allocator.free(result.content);

    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/b.ts") != null);
}

test "unlinkAnchor removes comment-based anchor with unrelated frontmatter" {
    const allocator = std.testing.allocator;
    const content =
        "---\n" ++
        "title: My Doc\n" ++
        "---\n\n" ++
        "<!-- drift:\n" ++
        "  files:\n" ++
        "    - src/a.ts\n" ++
        "-->\n";
    const result = try unlinkAnchor(allocator, content, "src/a.ts");
    defer allocator.free(result.content);

    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "title: My Doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
}

// --- unit tests for linkAnchor ---

test "linkAnchor adds anchor to empty files list" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n---\n# Doc\n";
    const result = try linkAnchor(allocator, content, "src/new.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Doc") != null);
}

test "linkAnchor updates existing anchor provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@old\n---\n# Doc\n";
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

test "linkAnchor preserves existing non-drift frontmatter" {
    const allocator = std.testing.allocator;
    const content =
        "---\n" ++
        "title: My Doc\n" ++
        "tags:\n" ++
        "  - docs\n" ++
        "---\n" ++
        "# Doc\n";
    const result = try linkAnchor(allocator, content, "src/target.ts");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "title: My Doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "drift:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "  files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    - src/target.ts") != null);

    var doc = (try parseDriftDoc(allocator, result)) orelse return error.TestUnexpectedResult;
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/target.ts", doc.anchors.items[0]);
}

test "linkAnchor adds files section when drift exists without files" {
    const allocator = std.testing.allocator;
    const content =
        "---\n" ++
        "drift:\n" ++
        "  owner: docs\n" ++
        "title: My Doc\n" ++
        "---\n" ++
        "# Doc\n";
    const result = try linkAnchor(allocator, content, "src/target.ts");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "  owner: docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "title: My Doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "  files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    - src/target.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "title: My Doc\n  files:") == null);

    var doc = (try parseDriftDoc(allocator, result)) orelse return error.TestUnexpectedResult;
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/target.ts", doc.anchors.items[0]);
}

// --- unit tests for comment-based anchors ---

test "parseDriftDoc parses comment-based anchors" {
    const allocator = std.testing.allocator;
    const content = "# My Doc\n\n<!-- drift:\n  files:\n    - src/main.zig\n    - src/vcs.zig\n-->\n\nSome content.\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 2), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/main.zig", doc.anchors.items[0]);
    try std.testing.expectEqualStrings("src/vcs.zig", doc.anchors.items[1]);
}

test "parseDriftDoc merges frontmatter and comment anchors" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n\n<!-- drift:\n  files:\n    - src/b.ts\n-->\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 2), doc.anchors.items.len);
}

test "parseDriftDoc parses comment with provenance" {
    const allocator = std.testing.allocator;
    const content = "<!-- drift:\n  files:\n    - src/main.zig@abc123\n-->\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/main.zig@abc123", doc.anchors.items[0]);
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

test "linkAnchor preserves comment-based drift when unrelated frontmatter exists" {
    const allocator = std.testing.allocator;
    const content =
        "---\n" ++
        "title: My Doc\n" ++
        "---\n\n" ++
        "<!-- drift:\n" ++
        "  files:\n" ++
        "    - src/existing.ts\n" ++
        "-->\n\n" ++
        "Body.\n";
    const result = try linkAnchor(allocator, content, "src/new.ts@abc");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "title: My Doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/existing.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts@abc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "---\n\n<!-- drift:") != null);
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

test "anchorFileIdentity handles sig: provenance prefix" {
    try std.testing.expectEqualStrings("src/file.ts", anchorFileIdentity("src/file.ts@sig:abc123"));
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
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/real.zig", doc.anchors.items[0]);
}

// --- unit tests for origin parsing ---

test "parseDriftDoc parses origin from YAML frontmatter" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  origin: github:owner/repo\n  files:\n    - src/main.zig\n---\n# Doc\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("github:owner/repo", doc.origin.?);
}

test "parseDriftDoc returns null origin when not present" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/main.zig\n---\n# Doc\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expect(doc.origin == null);
}

test "parseDriftDoc parses origin from comment-based anchors" {
    const allocator = std.testing.allocator;
    const content = "# Doc\n\n<!-- drift:\n  origin: github:acme/lib\n  files:\n    - src/main.zig\n-->\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("github:acme/lib", doc.origin.?);
}

test "parseDriftDoc parses anchor with quoted path segment" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/main\"file.ts\n---\n# Doc\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.anchors.items.len);
    try std.testing.expectEqualStrings("src/main\"file.ts", doc.anchors.items[0]);
}

test "parseDriftDoc origin before files in frontmatter" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  origin: github:test/proj\n  files:\n    - src/a.ts\n    - src/b.ts\n---\n";
    var doc = (try parseDriftDoc(allocator, content)) orelse {
        return error.TestUnexpectedResult;
    };
    defer {
        for (doc.anchors.items) |b| allocator.free(b);
        doc.anchors.deinit(allocator);
        if (doc.origin) |o| allocator.free(o);
    }
    try std.testing.expectEqual(@as(usize, 2), doc.anchors.items.len);
    try std.testing.expectEqualStrings("github:test/proj", doc.origin.?);
}
