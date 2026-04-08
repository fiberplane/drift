const std = @import("std");
const ts = @import("tree_sitter");

const Allocator = std.mem.Allocator;

// --- tree-sitter language externs ---

extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;
extern fn tree_sitter_rust() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_java() callconv(.c) *const ts.Language;

pub const LanguageQuery = struct {
    language: *const ts.Language,
    query_source: []const u8,
};

/// Map a file extension to a tree-sitter language and query source.
pub fn languageForExtension(ext: []const u8) ?LanguageQuery {
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx"))
    {
        return .{ .language = tree_sitter_typescript(), .query_source = @embedFile("queries/typescript.scm") };
    }
    if (std.mem.eql(u8, ext, ".py")) {
        return .{ .language = tree_sitter_python(), .query_source = @embedFile("queries/python.scm") };
    }
    if (std.mem.eql(u8, ext, ".rs")) {
        return .{ .language = tree_sitter_rust(), .query_source = @embedFile("queries/rust.scm") };
    }
    if (std.mem.eql(u8, ext, ".go")) {
        return .{ .language = tree_sitter_go(), .query_source = @embedFile("queries/go.scm") };
    }
    if (std.mem.eql(u8, ext, ".zig")) {
        return .{ .language = tree_sitter_zig(), .query_source = @embedFile("queries/zig.scm") };
    }
    if (std.mem.eql(u8, ext, ".java")) {
        return .{ .language = tree_sitter_java(), .query_source = @embedFile("queries/java.scm") };
    }
    return null;
}

/// Reused parser + compiled query per language for lint runs (avoids N× query compile).
pub const ParserCache = struct {
    map: std.AutoHashMap(usize, CachedParser),

    pub const CachedParser = struct {
        parser: *ts.Parser,
        query: *ts.Query,
    };

    pub fn init(allocator: Allocator) ParserCache {
        return .{ .map = std.AutoHashMap(usize, CachedParser).init(allocator) };
    }

    pub fn deinit(self: *ParserCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |cp| {
            cp.parser.destroy();
            cp.query.destroy();
        }
        self.map.deinit();
    }

    fn getOrPut(self: *ParserCache, lq: LanguageQuery) !*CachedParser {
        const key = @intFromPtr(lq.language);
        const gop = try self.map.getOrPut(key);
        if (!gop.found_existing) {
            const parser = ts.Parser.create();
            parser.setLanguage(lq.language) catch {
                parser.destroy();
                _ = self.map.remove(key);
                return error.SetLanguageFailed;
            };
            var err_offset: u32 = 0;
            const query = ts.Query.create(lq.language, lq.query_source, &err_offset) catch {
                parser.destroy();
                _ = self.map.remove(key);
                return error.QueryCreateFailed;
            };
            gop.value_ptr.* = .{ .parser = parser, .query = query };
        }
        return gop.value_ptr;
    }
};

fn findMatchingDefinitionNode(query: *const ts.Query, root: ts.Node, source: []const u8, target_symbol: []const u8) ?ts.Node {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, root);

    while (cursor.nextMatch()) |match| {
        var name_matches = false;
        var definition_node: ?ts.Node = null;

        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;
            if (std.mem.eql(u8, capture_name, "name")) {
                const node_text = source[capture.node.startByte()..capture.node.endByte()];
                if (std.mem.eql(u8, node_text, target_symbol)) {
                    name_matches = true;
                }
            } else if (std.mem.eql(u8, capture_name, "definition")) {
                definition_node = capture.node;
            }
        }

        if (name_matches) {
            return definition_node;
        }
    }

    return null;
}

fn hashTaggedBytes(hasher: *std.hash.XxHash3, tag: u8, bytes: []const u8) void {
    hasher.update(&[_]u8{tag});

    var len: u64 = @intCast(bytes.len);
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn hashNormalizedNodeSyntax(hasher: *std.hash.XxHash3, source: []const u8, node: ts.Node) void {
    hashTaggedBytes(hasher, '(', node.kind());

    const child_count = node.childCount();
    if (child_count == 0) {
        hashTaggedBytes(hasher, 't', source[node.startByte()..node.endByte()]);
    } else {
        var child_index: u32 = 0;
        while (child_index < child_count) : (child_index += 1) {
            const child = node.child(child_index) orelse continue;
            hashNormalizedNodeSyntax(hasher, source, child);
        }
    }

    hashTaggedBytes(hasher, ')', node.kind());
}

fn fingerprintNodeSyntax(source: []const u8, node: ts.Node) u64 {
    var hasher = std.hash.XxHash3.init(0);
    hashNormalizedNodeSyntax(&hasher, source, node);
    return hasher.final();
}

/// Compute a normalized syntax fingerprint for an entire file.
///
/// The fingerprint is based on the file's tree-sitter syntax tree, not its raw
/// source bytes, so formatting-only changes do not affect the result.
pub fn fingerprintFileSyntax(source: []const u8, lang_query: LanguageQuery) ?u64 {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(lang_query.language) catch return null;

    const tree = parser.parseString(source, null) orelse return null;
    defer tree.destroy();

    return fingerprintNodeSyntax(source, tree.rootNode());
}

/// Compute a normalized syntax fingerprint for a named symbol.
///
/// The fingerprint is based on the symbol's tree-sitter subtree, not its raw
/// source bytes, so formatting-only changes (line wrapping, indentation,
/// spacing) do not affect the result.
pub fn fingerprintSymbolSyntax(
    source: []const u8,
    lang_query: LanguageQuery,
    target_symbol: []const u8,
) ?u64 {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(lang_query.language) catch return null;

    const tree = parser.parseString(source, null) orelse return null;
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang_query.language, lang_query.query_source, &error_offset) catch return null;
    defer query.destroy();

    const definition_node = findMatchingDefinitionNode(query, tree.rootNode(), source, target_symbol) orelse return null;
    return fingerprintNodeSyntax(source, definition_node);
}

/// Extract the byte range [start, end] of the definition node for the target symbol.
/// Returns null if the symbol is not found. The caller can slice source[start..end] to get the content.
pub fn extractSymbolContent(
    source: []const u8,
    lang_query: LanguageQuery,
    target_symbol: []const u8,
) ?[2]u32 {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(lang_query.language) catch return null;

    const tree = parser.parseString(source, null) orelse return null;
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang_query.language, lang_query.query_source, &error_offset) catch return null;
    defer query.destroy();

    const definition_node = findMatchingDefinitionNode(query, tree.rootNode(), source, target_symbol) orelse return null;
    return .{ definition_node.startByte(), definition_node.endByte() };
}

/// Check if a named symbol exists in the given source file using tree-sitter.
/// Returns true if the symbol is found, false otherwise.
pub fn resolveSymbolWithTreeSitter(source: []const u8, lang_query: LanguageQuery, target_symbol: []const u8) bool {
    return fingerprintSymbolSyntax(source, lang_query, target_symbol) != null;
}

pub fn fingerprintFileSyntaxCached(cache: *ParserCache, source: []const u8, lq: LanguageQuery) ?u64 {
    const cp = cache.getOrPut(lq) catch return null;
    const tree = cp.parser.parseString(source, null) orelse return null;
    defer tree.destroy();
    return fingerprintNodeSyntax(source, tree.rootNode());
}

pub fn fingerprintSymbolSyntaxCached(cache: *ParserCache, source: []const u8, lq: LanguageQuery, target_symbol: []const u8) ?u64 {
    const cp = cache.getOrPut(lq) catch return null;
    const tree = cp.parser.parseString(source, null) orelse return null;
    defer tree.destroy();
    const definition_node = findMatchingDefinitionNode(cp.query, tree.rootNode(), source, target_symbol) orelse return null;
    return fingerprintNodeSyntax(source, definition_node);
}

pub fn resolveSymbolWithTreeSitterCached(cache: *ParserCache, source: []const u8, lang_query: LanguageQuery, target_symbol: []const u8) bool {
    return fingerprintSymbolSyntaxCached(cache, source, lang_query, target_symbol) != null;
}

/// Compute a fingerprint for a file or symbol, dispatching to the appropriate
/// tree-sitter language when available and falling back to raw XxHash3.
pub fn computeFingerprint(content: []const u8, file_path: []const u8, symbol_name: ?[]const u8) ?u64 {
    const ext = std.fs.path.extension(file_path);
    if (symbol_name) |sym| {
        const lang_query = languageForExtension(ext) orelse return null;
        return fingerprintSymbolSyntax(content, lang_query, sym);
    }
    if (languageForExtension(ext)) |lang_query| {
        return fingerprintFileSyntax(content, lang_query);
    }
    var hasher = std.hash.XxHash3.init(0);
    hasher.update(content);
    return hasher.final();
}

/// Same as `computeFingerprint` but reuses cached parsers/queries per language (for hot paths like `lint`).
pub fn computeFingerprintCached(cache: *ParserCache, content: []const u8, file_path: []const u8, symbol_name: ?[]const u8) ?u64 {
    const ext = std.fs.path.extension(file_path);
    if (symbol_name) |sym| {
        const lang_query = languageForExtension(ext) orelse return null;
        return fingerprintSymbolSyntaxCached(cache, content, lang_query, sym);
    }
    if (languageForExtension(ext)) |lang_query| {
        return fingerprintFileSyntaxCached(cache, content, lang_query);
    }
    var hasher = std.hash.XxHash3.init(0);
    hasher.update(content);
    return hasher.final();
}

/// Writes 16 lowercase hex digits of the fingerprint into `hex_ascii_out`.
pub fn writeFingerprintHex(hex_ascii_out: *[16]u8, content: []const u8, file_path: []const u8, symbol_name: ?[]const u8) bool {
    const fingerprint = computeFingerprint(content, file_path, symbol_name) orelse return false;
    _ = std.fmt.bufPrint(hex_ascii_out, "{x:0>16}", .{fingerprint}) catch return false;
    return true;
}

/// Writes `sig:` plus 16 hex digits into `sig_out` (20 bytes). Returns the written slice.
pub fn formatSigLine(sig_out: *[20]u8, content: []const u8, file_path: []const u8, symbol_name: ?[]const u8) ?[]const u8 {
    const fingerprint = computeFingerprint(content, file_path, symbol_name) orelse return null;
    return std.fmt.bufPrint(sig_out, "sig:{x:0>16}", .{fingerprint}) catch null;
}

test "fingerprintFileSyntaxCached works for zig source" {
    const allocator = std.testing.allocator;
    const source = "const std = @import(\"std\");\npub fn main() void {}\n";
    var cache = ParserCache.init(allocator);
    defer cache.deinit();
    const lq = languageForExtension(".zig") orelse return error.TestUnexpectedResult;
    const fp = fingerprintFileSyntaxCached(&cache, source, lq);
    try std.testing.expect(fp != null);

    const fp_non_cached = fingerprintFileSyntax(source, lq);
    try std.testing.expect(fp_non_cached != null);
    try std.testing.expectEqual(fp.?, fp_non_cached.?);
}
