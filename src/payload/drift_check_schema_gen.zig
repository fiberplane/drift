//! JSON Schema (Draft 2020-12) for `drift.check.v1`, generated from `drift_check_v1.zig` types.
//! Used by `zig build gen-check-schema`.

const std = @import("std");
const json = std.json;
const P = @import("payload");

pub fn writeJsonSchema(allocator: std.mem.Allocator, writer: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try buildDocument(a);
    try json.Stringify.value(root, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

fn buildDocument(a: std.mem.Allocator) !json.Value {
    var root = json.ObjectMap.init(a);

    try root.put("$schema", .{ .string = "https://json-schema.org/draft/2020-12/schema" });
    try root.put("$id", .{ .string = "drift.check.v1.json" });
    try root.put("title", .{ .string = "drift check / lint JSON output" });
    try root.put("description", .{ .string = 
        \\Wire format emitted by `drift check --format json` and `drift lint --format json`. Match top-level `schema_version` to "drift.check.v1". Unknown properties may appear in future drift versions; consumers should ignore them. See docs/check-json-schema.md.
    });
    try root.put("type", .{ .string = "object" });
    try root.put("additionalProperties", .{ .bool = true });
    try root.put("required", try requiredNamesArray(a, P.DriftCheckV1));

    var props = json.ObjectMap.init(a);
    try props.put("schema_version", try stringConst(a, "drift.check.v1"));
    try props.put("tool", try stringConst(a, "drift"));
    try putStringDesc(a, &props, "tool_version", "Drift binary version string.");
    try props.put("repo", try nullableStringDesc(a,
        \\Repository identity when detectable (e.g. github:owner/name), else null.
    ));
    try putIntegerDesc(a, &props, "checked_at_ms",
        \\Wall-clock time of the run, milliseconds since Unix epoch.
    );
    try props.put("summary", try refObj(a, "#/$defs/summary"));

    var specs_map = json.ObjectMap.init(a);
    try specs_map.put("type", .{ .string = "array" });
    try specs_map.put("description", .{ .string = "Discovered docs in scanner order." });
    var item_ref = json.ObjectMap.init(a);
    try item_ref.put("$ref", .{ .string = "#/$defs/doc" });
    try specs_map.put("items", .{ .object = item_ref });
    try props.put("docs", .{ .object = specs_map });

    try root.put("properties", .{ .object = props });

    var defs = json.ObjectMap.init(a);
    try defs.put("summary", .{ .object = try defSummary(a) });
    try defs.put("doc", .{ .object = try defDoc(a) });
    try defs.put("anchor", .{ .object = try defAnchor(a) });
    try defs.put("provenance", .{ .object = try defProvenance(a) });
    try defs.put("reason", .{ .object = try defReason(a) });
    try defs.put("blame", .{ .object = try defBlame(a) });
    try root.put("$defs", .{ .object = defs });

    return .{ .object = root };
}

fn requiredNamesArray(a: std.mem.Allocator, comptime T: type) !json.Value {
    const fields = std.meta.fields(T);
    var arr = json.Array.init(a);
    inline for (fields) |f| {
        try arr.append(.{ .string = f.name });
    }
    return .{ .array = arr };
}

fn stringArray(a: std.mem.Allocator, names: []const []const u8) !json.Value {
    var arr = json.Array.init(a);
    for (names) |n| {
        try arr.append(.{ .string = n });
    }
    return .{ .array = arr };
}

fn refObj(a: std.mem.Allocator, path: []const u8) !json.Value {
    var m = json.ObjectMap.init(a);
    try m.put("$ref", .{ .string = path });
    return .{ .object = m };
}

fn stringConst(a: std.mem.Allocator, comptime c: []const u8) !json.Value {
    var m = json.ObjectMap.init(a);
    try m.put("type", .{ .string = "string" });
    try m.put("const", .{ .string = c });
    return .{ .object = m };
}

fn nullableStringDesc(a: std.mem.Allocator, comptime desc: []const u8) !json.Value {
    var m = json.ObjectMap.init(a);
    try m.put("description", .{ .string = desc });
    var types = json.Array.init(a);
    try types.append(.{ .string = "string" });
    try types.append(.{ .string = "null" });
    try m.put("type", .{ .array = types });
    return .{ .object = m };
}

fn putStringDesc(a: std.mem.Allocator, props: *json.ObjectMap, key: []const u8, comptime desc: []const u8) !void {
    var m = json.ObjectMap.init(a);
    try m.put("type", .{ .string = "string" });
    try m.put("description", .{ .string = desc });
    try props.put(key, .{ .object = m });
}

fn putIntegerDesc(a: std.mem.Allocator, props: *json.ObjectMap, key: []const u8, comptime desc: []const u8) !void {
    var m = json.ObjectMap.init(a);
    try m.put("type", .{ .string = "integer" });
    try m.put("description", .{ .string = desc });
    try props.put(key, .{ .object = m });
}

fn uintSchema(a: std.mem.Allocator) !json.ObjectMap {
    var m = json.ObjectMap.init(a);
    try m.put("type", .{ .string = "integer" });
    try m.put("minimum", .{ .integer = 0 });
    return m;
}

fn defSummary(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Summary));
    var props = json.ObjectMap.init(a);

    var result = json.ObjectMap.init(a);
    try result.put("type", .{ .string = "string" });
    try result.put("enum", try stringArray(a, &.{ "pass", "fail" }));
    try result.put("description", .{ .string = 
        \\fail iff any anchor is stale; mirrors process exit code (0 pass, 1 fail).
    });
    try props.put("result", .{ .object = result });

    var vs = json.ObjectMap.init(a);
    try vs.put("type", .{ .string = "string" });
    try vs.put("enum", try stringArray(a, &.{ "none", "partial", "full" }));
    try vs.put("description", .{ .string = 
        \\Coverage of verification: none = all docs skipped; partial = mix; full = nothing skipped (including zero docs).
    });
    try props.put("verification_state", .{ .object = vs });

    try props.put("docs_total", .{ .object = try uintSchema(a) });
    var sc = json.ObjectMap.init(a);
    try sc.put("type", .{ .string = "integer" });
    try sc.put("minimum", .{ .integer = 0 });
    try sc.put("description", .{ .string = "docs_fresh + docs_stale (docs not skipped)." });
    try props.put("docs_checked", .{ .object = sc });
    try props.put("docs_skipped", .{ .object = try uintSchema(a) });
    try props.put("docs_fresh", .{ .object = try uintSchema(a) });
    try props.put("docs_stale", .{ .object = try uintSchema(a) });
    try props.put("anchors_total", .{ .object = try uintSchema(a) });
    try props.put("anchors_fresh", .{ .object = try uintSchema(a) });
    try props.put("anchors_stale", .{ .object = try uintSchema(a) });
    try props.put("anchors_skipped", .{ .object = try uintSchema(a) });

    try o.put("properties", .{ .object = props });
    return o;
}

fn defDoc(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Doc));
    var props = json.ObjectMap.init(a);
    try props.put("path", .{ .object = try stringType(a) });
    try props.put("origin", try nullableStringDesc(a,
        \\Doc drift.origin frontmatter when present.
    ));
    var res = json.ObjectMap.init(a);
    try res.put("type", .{ .string = "string" });
    try res.put("enum", try stringArray(a, &.{ "fresh", "stale", "skip" }));
    try res.put("description", .{ .string = "Worst of child anchors; zero anchors => fresh." });
    try props.put("result", .{ .object = res });
    var anchors = json.ObjectMap.init(a);
    try anchors.put("type", .{ .string = "array" });
    var ar = json.ObjectMap.init(a);
    try ar.put("$ref", .{ .string = "#/$defs/anchor" });
    try anchors.put("items", .{ .object = ar });
    try props.put("anchors", .{ .object = anchors });
    try o.put("properties", .{ .object = props });
    return o;
}

fn stringType(a: std.mem.Allocator) !json.ObjectMap {
    var m = json.ObjectMap.init(a);
    try m.put("type", .{ .string = "string" });
    return m;
}

fn defAnchor(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Anchor));
    var props = json.ObjectMap.init(a);

    var id = json.ObjectMap.init(a);
    try id.put("type", .{ .string = "string" });
    try id.put("description", .{ .string = "Anchor without @provenance suffix." });
    try props.put("identity", .{ .object = id });

    var raw = json.ObjectMap.init(a);
    try raw.put("type", .{ .string = "string" });
    try raw.put("description", .{ .string = "Full anchor string from the doc." });
    try props.put("raw", .{ .object = raw });

    var kind = json.ObjectMap.init(a);
    try kind.put("type", .{ .string = "string" });
    try kind.put("enum", try stringArray(a, &.{ "file", "symbol" }));
    try props.put("kind", .{ .object = kind });

    try props.put("path", .{ .object = try stringType(a) });

    var sym = json.ObjectMap.init(a);
    try sym.put("description", .{ .string = "Symbol segment when kind is symbol." });
    var st = json.Array.init(a);
    try st.append(.{ .string = "string" });
    try st.append(.{ .string = "null" });
    try sym.put("type", .{ .array = st });
    try props.put("symbol", .{ .object = sym });

    var prov = json.ObjectMap.init(a);
    try prov.put("description", .{ .string = "null when anchor has no provenance suffix." });
    var ptypes = json.Array.init(a);
    try ptypes.append(.{ .string = "null" });
    var pref = json.ObjectMap.init(a);
    try pref.put("$ref", .{ .string = "#/$defs/provenance" });
    try ptypes.append(.{ .object = pref });
    try prov.put("type", .{ .array = ptypes });
    try props.put("provenance", .{ .object = prov });

    var ares = json.ObjectMap.init(a);
    try ares.put("type", .{ .string = "string" });
    try ares.put("enum", try stringArray(a, &.{ "fresh", "stale", "skip" }));
    try props.put("result", .{ .object = ares });

    var reason = json.ObjectMap.init(a);
    try reason.put("description", .{ .string = "null when anchor is fresh." });
    var rtypes = json.Array.init(a);
    try rtypes.append(.{ .string = "null" });
    var rref = json.ObjectMap.init(a);
    try rref.put("$ref", .{ .string = "#/$defs/reason" });
    try rtypes.append(.{ .object = rref });
    try reason.put("type", .{ .array = rtypes });
    try props.put("reason", .{ .object = reason });

    var blame = json.ObjectMap.init(a);
    try blame.put("description", .{ .string = "null when not applicable or unavailable." });
    var btypes = json.Array.init(a);
    try btypes.append(.{ .string = "null" });
    var bref = json.ObjectMap.init(a);
    try bref.put("$ref", .{ .string = "#/$defs/blame" });
    try btypes.append(.{ .object = bref });
    try blame.put("type", .{ .array = btypes });
    try props.put("blame", .{ .object = blame });

    try o.put("properties", .{ .object = props });
    return o;
}

fn defProvenance(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Provenance));
    var props = json.ObjectMap.init(a);
    var k = json.ObjectMap.init(a);
    try k.put("type", .{ .string = "string" });
    try k.put("enum", try stringArray(a, &.{ "sig", "vcs" }));
    try props.put("kind", .{ .object = k });
    try props.put("value", .{ .object = try stringType(a) });
    try o.put("properties", .{ .object = props });
    return o;
}

fn defReason(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Reason));
    var props = json.ObjectMap.init(a);
    var code = json.ObjectMap.init(a);
    try code.put("type", .{ .string = "string" });
    try code.put("description", .{ .string = "Machine-stable reason; new values may be added over time." });
    try props.put("code", .{ .object = code });
    var msg = json.ObjectMap.init(a);
    try msg.put("type", .{ .string = "string" });
    try msg.put("description", .{ .string = "Human-readable English; stable for a given code in drift.check.v1." });
    try props.put("message", .{ .object = msg });
    try o.put("properties", .{ .object = props });
    return o;
}

fn defBlame(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.init(a);
    try o.put("type", .{ .string = "object" });
    try o.put("additionalProperties", .{ .bool = true });
    try o.put("required", try requiredNamesArray(a, P.Blame));
    var props = json.ObjectMap.init(a);
    try props.put("author", .{ .object = try stringType(a) });
    var commit = json.ObjectMap.init(a);
    try commit.put("type", .{ .string = "string" });
    try commit.put("description", .{ .string = "Full Git object id (40 hex chars for SHA-1)." });
    try props.put("commit", .{ .object = commit });
    var date = json.ObjectMap.init(a);
    try date.put("type", .{ .string = "string" });
    try date.put("description", .{ .string = "Committer date, ISO 8601 strict (git --date=iso-strict)." });
    try props.put("date", .{ .object = date });
    try props.put("subject", .{ .object = try stringType(a) });
    try o.put("properties", .{ .object = props });
    return o;
}
