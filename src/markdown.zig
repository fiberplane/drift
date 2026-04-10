const std = @import("std");
const ts = @import("tree_sitter");

const Allocator = std.mem.Allocator;

extern fn tree_sitter_markdown() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown_inline() callconv(.c) *const ts.Language;

/// Relative markdown link extracted from a document.
/// `target` is a slice into the caller-owned markdown source bytes.
pub const Link = struct {
    target: []const u8,
    line: u32,
};

pub const ParsedDoc = struct {
    links: std.ArrayList(Link),
    allocator: Allocator,

    pub fn deinit(self: *ParsedDoc) void {
        self.links.deinit(self.allocator);
    }
};

pub fn parseDocument(allocator: Allocator, source: []const u8) !?ParsedDoc {
    const block_tree = parseBlockTree(source) orelse return null;
    defer block_tree.destroy();

    var ranges: std.ArrayList(ts.Range) = .{};
    defer ranges.deinit(allocator);
    try collectInlineRangesForNode(allocator, block_tree.rootNode(), &ranges);

    if (ranges.items.len == 0) {
        return .{ .links = .{}, .allocator = allocator };
    }

    var inline_parser = ts.Parser.create();
    defer inline_parser.destroy();
    inline_parser.setLanguage(tree_sitter_markdown_inline()) catch return null;
    inline_parser.setIncludedRanges(ranges.items) catch return null;

    const inline_tree = inline_parser.parseString(source, null) orelse return null;
    defer inline_tree.destroy();

    var links: std.ArrayList(Link) = .{};
    errdefer links.deinit(allocator);
    try collectInlineLinks(allocator, source, inline_tree.rootNode(), &links);

    return .{ .links = links, .allocator = allocator };
}

pub fn fingerprintDocumentSyntax(source: []const u8) ?u64 {
    return fingerprintBytes(source);
}

/// Slugify heading text for lockfile storage and fragment matching.
/// Output is at most `heading_text.len` bytes.
pub fn headingToSlug(buf: []u8, heading_text: []const u8) []const u8 {
    var out: usize = 0;
    var pending_hyphen = false;

    for (heading_text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_hyphen and out > 0 and out < buf.len) {
                buf[out] = '-';
                out += 1;
            }
            pending_hyphen = false;
            if (out >= buf.len) break;
            buf[out] = std.ascii.toLower(c);
            out += 1;
        } else if (out > 0) {
            pending_hyphen = true;
        }
    }

    return buf[0..out];
}

pub fn fingerprintHeadingSection(source: []const u8, heading_fragment: []const u8) ?u64 {
    const block_tree = parseBlockTree(source) orelse return null;
    defer block_tree.destroy();

    const section = findHeadingSection(block_tree.rootNode(), source, heading_fragment) orelse return null;
    return fingerprintBytes(source[section.startByte()..section.endByte()]);
}

pub fn headingExists(source: []const u8, heading_fragment: []const u8) bool {
    const block_tree = parseBlockTree(source) orelse return false;
    defer block_tree.destroy();
    return findHeadingSection(block_tree.rootNode(), source, heading_fragment) != null;
}

/// Extract the byte range [start, end) of a heading section matching the given fragment.
/// Returns null if the heading is not found or parsing fails.
pub fn extractHeadingSectionContent(source: []const u8, heading_fragment: []const u8) ?[2]u32 {
    const block_tree = parseBlockTree(source) orelse return null;
    defer block_tree.destroy();

    const section = findHeadingSection(block_tree.rootNode(), source, heading_fragment) orelse return null;
    return .{ section.startByte(), section.endByte() };
}

fn parseBlockTree(source: []const u8) ?*ts.Tree {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(tree_sitter_markdown()) catch return null;
    return parser.parseString(source, null);
}

fn collectInlineRangesForNode(
    allocator: Allocator,
    node: ts.Node,
    ranges: *std.ArrayList(ts.Range),
) !void {
    if (std.mem.eql(u8, node.kind(), "inline") or std.mem.eql(u8, node.kind(), "pipe_table_cell")) {
        try appendInlineRanges(allocator, node, ranges);
    }

    const child_count = node.namedChildCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        try collectInlineRangesForNode(allocator, child, ranges);
    }
}

fn appendInlineRanges(
    allocator: Allocator,
    parent: ts.Node,
    ranges: *std.ArrayList(ts.Range),
) !void {
    var remaining = parent.range();
    const child_count = parent.childCount();
    var child_index: u32 = 0;
    while (child_index < child_count) : (child_index += 1) {
        const child = parent.child(child_index) orelse continue;
        if (!child.isNamed()) continue;

        const child_range = child.range();
        if (remaining.start_byte < child_range.start_byte) {
            try ranges.append(allocator, .{
                .start_byte = remaining.start_byte,
                .start_point = remaining.start_point,
                .end_byte = child_range.start_byte,
                .end_point = child_range.start_point,
            });
        }
        remaining.start_byte = child_range.end_byte;
        remaining.start_point = child_range.end_point;
    }

    if (remaining.start_byte < remaining.end_byte) {
        try ranges.append(allocator, remaining);
    }
}

fn collectInlineLinks(
    allocator: Allocator,
    source: []const u8,
    node: ts.Node,
    links: *std.ArrayList(Link),
) !void {
    if (std.mem.eql(u8, node.kind(), "inline_link")) {
        const destination = findNamedChild(node, "link_destination");
        if (destination) |dest| {
            var target = source[dest.startByte()..dest.endByte()];
            target = std.mem.trim(u8, target, " \t\r\n<>");
            if (target.len > 0) {
                try links.append(allocator, .{
                    .target = target,
                    .line = dest.startPoint().row + 1,
                });
            }
        }
    }

    const child_count = node.namedChildCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        try collectInlineLinks(allocator, source, child, links);
    }
}

fn findNamedChild(node: ts.Node, kind: []const u8) ?ts.Node {
    const child_count = node.namedChildCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (std.mem.eql(u8, child.kind(), kind)) return child;
    }
    return null;
}

fn findHeadingSection(node: ts.Node, source: []const u8, heading_fragment: []const u8) ?ts.Node {
    var wanted_buf: [512]u8 = undefined;
    const wanted = headingToSlug(&wanted_buf, heading_fragment);

    return findHeadingSectionBySlug(node, source, wanted);
}

fn findHeadingSectionBySlug(node: ts.Node, source: []const u8, wanted_slug: []const u8) ?ts.Node {
    if (std.mem.eql(u8, node.kind(), "section")) {
        if (sectionHeadingText(node, source)) |text| {
            var slug_buf: [512]u8 = undefined;
            const slug = headingToSlug(&slug_buf, text);
            if (std.mem.eql(u8, slug, wanted_slug)) return node;
        }
    }

    const child_count = node.namedChildCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.namedChild(i) orelse continue;
        if (findHeadingSectionBySlug(child, source, wanted_slug)) |section| return section;
    }
    return null;
}

fn sectionHeadingText(section: ts.Node, source: []const u8) ?[]const u8 {
    const child_count = section.namedChildCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = section.namedChild(i) orelse continue;
        if (std.mem.eql(u8, child.kind(), "atx_heading") or std.mem.eql(u8, child.kind(), "setext_heading")) {
            const content = child.childByFieldName("heading_content") orelse return null;
            return std.mem.trim(u8, source[content.startByte()..content.endByte()], " \t\r\n");
        }
        if (child.isNamed()) break;
    }
    return null;
}

fn fingerprintBytes(bytes: []const u8) u64 {
    var hasher = std.hash.XxHash3.init(0);
    hasher.update(bytes);
    return hasher.final();
}

test "parseDocument extracts links from inline grammar" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\See [auth](docs/auth.md#Authentication) and [site](https://example.com).
        \\`[skip](docs/code.md)`
    ;

    var doc = (try parseDocument(allocator, source)) orelse return error.TestUnexpectedResult;
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.links.items.len);
    try std.testing.expectEqualStrings("docs/auth.md#Authentication", doc.links.items[0].target);
    try std.testing.expectEqual(@as(u32, 3), doc.links.items[0].line);
    try std.testing.expectEqualStrings("https://example.com", doc.links.items[1].target);
}

test "headingToSlug normalizes heading fragments" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("authentication", headingToSlug(&buf, "Authentication"));
    try std.testing.expectEqualStrings("token-validation", headingToSlug(&buf, "Token Validation"));
    try std.testing.expectEqualStrings("api-v2-beta", headingToSlug(&buf, "API v2 (Beta)"));
}

test "fingerprintHeadingSection finds markdown sections by slug or raw heading text" {
    const source =
        \\# Intro
        \\
        \\Hello.
        \\
        \\## Token Validation
        \\
        \\Use tokens.
    ;

    try std.testing.expect(headingExists(source, "Token Validation"));
    try std.testing.expect(headingExists(source, "token-validation"));
    try std.testing.expect(fingerprintHeadingSection(source, "missing") == null);
}

test "fingerprintHeadingSection changes when section body changes" {
    const before =
        \\# Auth
        \\
        \\## Authentication
        \\
        \\Use tokens.
    ;
    const after =
        \\# Auth
        \\
        \\## Authentication
        \\
        \\Use signed tokens.
    ;

    const before_fp = fingerprintHeadingSection(before, "authentication") orelse return error.TestUnexpectedResult;
    const after_fp = fingerprintHeadingSection(after, "authentication") orelse return error.TestUnexpectedResult;
    try std.testing.expect(before_fp != after_fp);
}
