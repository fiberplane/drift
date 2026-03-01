const std = @import("std");
const ts = @import("tree_sitter");

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

// Tree-sitter query sources for symbol extraction, embedded as string literals.
// These match the @name captures in the query patterns to resolve symbol bindings.
const ts_query_typescript =
    \\[
    \\  (function_declaration
    \\    name: (identifier) @name) @definition
    \\  (class_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (type_alias_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (interface_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (enum_declaration
    \\    name: (identifier) @name) @definition
    \\  (lexical_declaration
    \\    (variable_declarator
    \\      name: (identifier) @name)) @definition
    \\]
;

const ts_query_python =
    \\[
    \\  (function_definition
    \\    name: (identifier) @name) @definition
    \\  (class_definition
    \\    name: (identifier) @name) @definition
    \\]
;

const ts_query_rust =
    \\[
    \\  (function_item
    \\    name: (identifier) @name) @definition
    \\  (struct_item
    \\    name: (type_identifier) @name) @definition
    \\  (enum_item
    \\    name: (type_identifier) @name) @definition
    \\  (trait_item
    \\    name: (type_identifier) @name) @definition
    \\  (type_item
    \\    name: (type_identifier) @name) @definition
    \\  (impl_item
    \\    type: (type_identifier) @name) @definition
    \\  (const_item
    \\    name: (identifier) @name) @definition
    \\  (static_item
    \\    name: (identifier) @name) @definition
    \\]
;

const ts_query_go =
    \\[
    \\  (function_declaration
    \\    name: (identifier) @name) @definition
    \\  (method_declaration
    \\    name: (field_identifier) @name) @definition
    \\  (type_declaration
    \\    (type_spec
    \\      name: (type_identifier) @name)) @definition
    \\  (const_declaration
    \\    (const_spec
    \\      name: (identifier) @name)) @definition
    \\  (var_declaration
    \\    (var_spec
    \\      name: (identifier) @name)) @definition
    \\]
;

const ts_query_zig_lang =
    \\[
    \\  (TopLevelDecl
    \\    (FnDecl
    \\      (IDENTIFIER) @name)) @definition
    \\  (VarDecl
    \\    (IDENTIFIER) @name) @definition
    \\]
;

const ts_query_java =
    \\[
    \\  (class_declaration
    \\    name: (identifier) @name) @definition
    \\  (interface_declaration
    \\    name: (identifier) @name) @definition
    \\  (method_declaration
    \\    name: (identifier) @name) @definition
    \\  (enum_declaration
    \\    name: (identifier) @name) @definition
    \\  (record_declaration
    \\    name: (identifier) @name) @definition
    \\]
;

/// Map a file extension to a tree-sitter language and query source.
pub fn languageForExtension(ext: []const u8) ?LanguageQuery {
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx"))
    {
        return .{ .language = tree_sitter_typescript(), .query_source = ts_query_typescript };
    }
    if (std.mem.eql(u8, ext, ".py")) {
        return .{ .language = tree_sitter_python(), .query_source = ts_query_python };
    }
    if (std.mem.eql(u8, ext, ".rs")) {
        return .{ .language = tree_sitter_rust(), .query_source = ts_query_rust };
    }
    if (std.mem.eql(u8, ext, ".go")) {
        return .{ .language = tree_sitter_go(), .query_source = ts_query_go };
    }
    if (std.mem.eql(u8, ext, ".zig")) {
        return .{ .language = tree_sitter_zig(), .query_source = ts_query_zig_lang };
    }
    if (std.mem.eql(u8, ext, ".java")) {
        return .{ .language = tree_sitter_java(), .query_source = ts_query_java };
    }
    return null;
}

/// Check if a named symbol exists in the given source file using tree-sitter.
/// Returns true if the symbol is found, false otherwise.
pub fn resolveSymbolWithTreeSitter(source: []const u8, lang_query: LanguageQuery, target_symbol: []const u8) bool {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(lang_query.language) catch return false;

    const tree = parser.parseString(source, null) orelse return false;
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang_query.language, lang_query.query_source, &error_offset) catch return false;
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    while (cursor.nextMatch()) |match| {
        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;
            if (std.mem.eql(u8, capture_name, "name")) {
                const node_text = source[capture.node.startByte()..capture.node.endByte()];
                if (std.mem.eql(u8, node_text, target_symbol)) {
                    return true;
                }
            }
        }
    }

    return false;
}
