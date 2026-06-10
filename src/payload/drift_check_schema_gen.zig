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
    var root = json.ObjectMap.empty;

    try root.put(a, "$schema", .{ .string = "https://json-schema.org/draft/2020-12/schema" });
    try root.put(a, "$id", .{ .string = "drift.check.v1.json" });
    try root.put(a, "title", .{ .string = "drift check / lint JSON output" });
    try root.put(a, "description", .{ .string =
        \\Wire format emitted by `drift check --format json` and `drift lint --format json`. Match top-level `schema_version` to "drift.check.v1". Unknown properties may appear in future drift versions; consumers should ignore them. See docs/check-json-schema.md.
    });
    try root.put(a, "type", .{ .string = "object" });
    try root.put(a, "additionalProperties", .{ .bool = true });
    try root.put(a, "required", try requiredNamesArray(a, P.DriftCheckV1));

    var props = json.ObjectMap.empty;
    try props.put(a, "schema_version", try stringConst(a, "drift.check.v1"));
    try props.put(a, "tool", try stringConst(a, "drift"));
    try putStringDesc(a, &props, "tool_version", "Drift binary version string.");
    try props.put(a, "repo", try nullableStringDesc(a,
        \\Repository identity when detectable (e.g. github:owner/name), else null.
    ));
    try putIntegerDesc(a, &props, "checked_at_ms",
        \\Wall-clock time of the run, milliseconds since Unix epoch.
    );
    try props.put(a, "summary", try refObj(a, "#/$defs/summary"));

    var specs_map = json.ObjectMap.empty;
    try specs_map.put(a, "type", .{ .string = "array" });
    try specs_map.put(a, "description", .{ .string = "Discovered docs in scanner order." });
    var item_ref = json.ObjectMap.empty;
    try item_ref.put(a, "$ref", .{ .string = "#/$defs/doc" });
    try specs_map.put(a, "items", .{ .object = item_ref });
    try props.put(a, "docs", .{ .object = specs_map });

    try root.put(a, "properties", .{ .object = props });

    var defs = json.ObjectMap.empty;
    try defs.put(a, "summary", .{ .object = try defSummary(a) });
    try defs.put(a, "doc", .{ .object = try defDoc(a) });
    try defs.put(a, "anchor", .{ .object = try defAnchor(a) });
    try defs.put(a, "link", .{ .object = try defLink(a) });
    try defs.put(a, "provenance", .{ .object = try defProvenance(a) });
    try defs.put(a, "reason", .{ .object = try defReason(a) });
    try defs.put(a, "blame", .{ .object = try defBlame(a) });
    try root.put(a, "$defs", .{ .object = defs });

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
    var m = json.ObjectMap.empty;
    try m.put(a, "$ref", .{ .string = path });
    return .{ .object = m };
}

fn stringConst(a: std.mem.Allocator, comptime c: []const u8) !json.Value {
    var m = json.ObjectMap.empty;
    try m.put(a, "type", .{ .string = "string" });
    try m.put(a, "const", .{ .string = c });
    return .{ .object = m };
}

fn nullableStringDesc(a: std.mem.Allocator, comptime desc: []const u8) !json.Value {
    var m = json.ObjectMap.empty;
    try m.put(a, "description", .{ .string = desc });
    var types = json.Array.init(a);
    try types.append(.{ .string = "string" });
    try types.append(.{ .string = "null" });
    try m.put(a, "type", .{ .array = types });
    return .{ .object = m };
}

fn putStringDesc(a: std.mem.Allocator, props: *json.ObjectMap, key: []const u8, comptime desc: []const u8) !void {
    var m = json.ObjectMap.empty;
    try m.put(a, "type", .{ .string = "string" });
    try m.put(a, "description", .{ .string = desc });
    try props.put(a, key, .{ .object = m });
}

fn putIntegerDesc(a: std.mem.Allocator, props: *json.ObjectMap, key: []const u8, comptime desc: []const u8) !void {
    var m = json.ObjectMap.empty;
    try m.put(a, "type", .{ .string = "integer" });
    try m.put(a, "description", .{ .string = desc });
    try props.put(a, key, .{ .object = m });
}

fn uintSchema(a: std.mem.Allocator) !json.ObjectMap {
    var m = json.ObjectMap.empty;
    try m.put(a, "type", .{ .string = "integer" });
    try m.put(a, "minimum", .{ .integer = 0 });
    return m;
}

fn defSummary(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Summary));
    var props = json.ObjectMap.empty;

    var result = json.ObjectMap.empty;
    try result.put(a, "type", .{ .string = "string" });
    try result.put(a, "enum", try stringArray(a, &.{ "pass", "fail" }));
    try result.put(a, "description", .{ .string =
        \\fail iff any anchor is stale or any link is broken; mirrors process exit code (0 pass, 1 fail).
    });
    try props.put(a, "result", .{ .object = result });

    var vs = json.ObjectMap.empty;
    try vs.put(a, "type", .{ .string = "string" });
    try vs.put(a, "enum", try stringArray(a, &.{ "none", "partial", "full" }));
    try vs.put(a, "description", .{ .string =
        \\Coverage of verification: none = all docs skipped; partial = mix; full = nothing skipped (including zero docs).
    });
    try props.put(a, "verification_state", .{ .object = vs });

    try props.put(a, "docs_total", .{ .object = try uintSchema(a) });
    var sc = json.ObjectMap.empty;
    try sc.put(a, "type", .{ .string = "integer" });
    try sc.put(a, "minimum", .{ .integer = 0 });
    try sc.put(a, "description", .{ .string = "docs_fresh + docs_stale (docs not skipped)." });
    try props.put(a, "docs_checked", .{ .object = sc });
    try props.put(a, "docs_skipped", .{ .object = try uintSchema(a) });
    try props.put(a, "docs_fresh", .{ .object = try uintSchema(a) });
    try props.put(a, "docs_stale", .{ .object = try uintSchema(a) });
    try props.put(a, "anchors_total", .{ .object = try uintSchema(a) });
    try props.put(a, "anchors_fresh", .{ .object = try uintSchema(a) });
    try props.put(a, "anchors_stale", .{ .object = try uintSchema(a) });
    try props.put(a, "anchors_skipped", .{ .object = try uintSchema(a) });
    try props.put(a, "links_total", .{ .object = try uintSchema(a) });
    try props.put(a, "links_broken", .{ .object = try uintSchema(a) });

    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn defDoc(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Doc));
    var props = json.ObjectMap.empty;
    try props.put(a, "path", .{ .object = try stringType(a) });
    try props.put(a, "origin", try nullableStringDesc(a,
        \\Common origin qualifier for the doc's bindings when present, else null.
    ));
    var res = json.ObjectMap.empty;
    try res.put(a, "type", .{ .string = "string" });
    try res.put(a, "enum", try stringArray(a, &.{ "fresh", "stale", "skip", "broken" }));
    try res.put(a, "description", .{ .string = "Worst of child anchors and links; broken > stale > skip > fresh." });
    try props.put(a, "result", .{ .object = res });
    var anchors = json.ObjectMap.empty;
    try anchors.put(a, "type", .{ .string = "array" });
    var ar = json.ObjectMap.empty;
    try ar.put(a, "$ref", .{ .string = "#/$defs/anchor" });
    try anchors.put(a, "items", .{ .object = ar });
    try props.put(a, "anchors", .{ .object = anchors });
    var links = json.ObjectMap.empty;
    try links.put(a, "type", .{ .string = "array" });
    var lr = json.ObjectMap.empty;
    try lr.put(a, "$ref", .{ .string = "#/$defs/link" });
    try links.put(a, "items", .{ .object = lr });
    try props.put(a, "links", .{ .object = links });
    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn stringType(a: std.mem.Allocator) !json.ObjectMap {
    var m = json.ObjectMap.empty;
    try m.put(a, "type", .{ .string = "string" });
    return m;
}

fn defAnchor(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Anchor));
    var props = json.ObjectMap.empty;

    var id = json.ObjectMap.empty;
    try id.put(a, "type", .{ .string = "string" });
    try id.put(a, "description", .{ .string = "Anchor without @provenance suffix." });
    try props.put(a, "identity", .{ .object = id });

    var raw = json.ObjectMap.empty;
    try raw.put(a, "type", .{ .string = "string" });
    try raw.put(a, "description", .{ .string = "Full anchor string from the doc." });
    try props.put(a, "raw", .{ .object = raw });

    var kind = json.ObjectMap.empty;
    try kind.put(a, "type", .{ .string = "string" });
    try kind.put(a, "enum", try stringArray(a, &.{ "file", "symbol", "heading" }));
    try props.put(a, "kind", .{ .object = kind });

    try props.put(a, "path", .{ .object = try stringType(a) });

    var sym = json.ObjectMap.empty;
    try sym.put(a, "description", .{ .string = "Symbol segment when kind is symbol." });
    var st = json.Array.init(a);
    try st.append(.{ .string = "string" });
    try st.append(.{ .string = "null" });
    try sym.put(a, "type", .{ .array = st });
    try props.put(a, "symbol", .{ .object = sym });

    var prov = json.ObjectMap.empty;
    try prov.put(a, "description", .{ .string = "null when anchor has no provenance suffix." });
    var ptypes = json.Array.init(a);
    try ptypes.append(.{ .string = "null" });
    var pref = json.ObjectMap.empty;
    try pref.put(a, "$ref", .{ .string = "#/$defs/provenance" });
    try ptypes.append(.{ .object = pref });
    try prov.put(a, "type", .{ .array = ptypes });
    try props.put(a, "provenance", .{ .object = prov });

    var ares = json.ObjectMap.empty;
    try ares.put(a, "type", .{ .string = "string" });
    try ares.put(a, "enum", try stringArray(a, &.{ "fresh", "stale", "skip" }));
    try props.put(a, "result", .{ .object = ares });

    var reason = json.ObjectMap.empty;
    try reason.put(a, "description", .{ .string = "null when anchor is fresh." });
    var rtypes = json.Array.init(a);
    try rtypes.append(.{ .string = "null" });
    var rref = json.ObjectMap.empty;
    try rref.put(a, "$ref", .{ .string = "#/$defs/reason" });
    try rtypes.append(.{ .object = rref });
    try reason.put(a, "type", .{ .array = rtypes });
    try props.put(a, "reason", .{ .object = reason });

    var blame = json.ObjectMap.empty;
    try blame.put(a, "description", .{ .string = "null when not applicable or unavailable." });
    var btypes = json.Array.init(a);
    try btypes.append(.{ .string = "null" });
    var bref = json.ObjectMap.empty;
    try bref.put(a, "$ref", .{ .string = "#/$defs/blame" });
    try btypes.append(.{ .object = bref });
    try blame.put(a, "type", .{ .array = btypes });
    try props.put(a, "blame", .{ .object = blame });

    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn defLink(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Link));
    var props = json.ObjectMap.empty;
    try props.put(a, "target", .{ .object = try stringType(a) });
    try props.put(a, "line", .{ .object = try uintSchema(a) });
    var result = json.ObjectMap.empty;
    try result.put(a, "type", .{ .string = "string" });
    try result.put(a, "enum", try stringArray(a, &.{ "ok", "broken" }));
    try props.put(a, "result", .{ .object = result });

    var reason = json.ObjectMap.empty;
    try reason.put(a, "description", .{ .string = "null when link result is ok." });
    var rtypes = json.Array.init(a);
    try rtypes.append(.{ .string = "null" });
    var rref = json.ObjectMap.empty;
    try rref.put(a, "$ref", .{ .string = "#/$defs/reason" });
    try rtypes.append(.{ .object = rref });
    try reason.put(a, "type", .{ .array = rtypes });
    try props.put(a, "reason", .{ .object = reason });

    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn defProvenance(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Provenance));
    var props = json.ObjectMap.empty;
    var k = json.ObjectMap.empty;
    try k.put(a, "type", .{ .string = "string" });
    try k.put(a, "enum", try stringArray(a, &.{ "sig", "vcs" }));
    try props.put(a, "kind", .{ .object = k });
    try props.put(a, "value", .{ .object = try stringType(a) });
    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn defReason(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Reason));
    var props = json.ObjectMap.empty;
    var code = json.ObjectMap.empty;
    try code.put(a, "type", .{ .string = "string" });
    try code.put(a, "description", .{ .string = "Machine-stable reason; new values may be added over time." });
    try props.put(a, "code", .{ .object = code });
    var msg = json.ObjectMap.empty;
    try msg.put(a, "type", .{ .string = "string" });
    try msg.put(a, "description", .{ .string = "Human-readable English; stable for a given code in drift.check.v1." });
    try props.put(a, "message", .{ .object = msg });
    try o.put(a, "properties", .{ .object = props });
    return o;
}

fn defBlame(a: std.mem.Allocator) !json.ObjectMap {
    var o = json.ObjectMap.empty;
    try o.put(a, "type", .{ .string = "object" });
    try o.put(a, "additionalProperties", .{ .bool = true });
    try o.put(a, "required", try requiredNamesArray(a, P.Blame));
    var props = json.ObjectMap.empty;
    try props.put(a, "author", .{ .object = try stringType(a) });
    var commit = json.ObjectMap.empty;
    try commit.put(a, "type", .{ .string = "string" });
    try commit.put(a, "description", .{ .string = "Full Git object id (40 hex chars for SHA-1)." });
    try props.put(a, "commit", .{ .object = commit });
    var date = json.ObjectMap.empty;
    try date.put(a, "type", .{ .string = "string" });
    try date.put(a, "description", .{ .string = "Committer date, ISO 8601 strict (git --date=iso-strict)." });
    try props.put(a, "date", .{ .object = date });
    try props.put(a, "subject", .{ .object = try stringType(a) });
    try o.put(a, "properties", .{ .object = props });
    return o;
}
