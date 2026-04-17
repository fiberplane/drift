//! JSON document shape for `schema_version: "drift.check.v1"` (`drift check --format json`).
//! This is the stable payload type for stdout JSON. Regenerate `docs/schemas/drift.check.v1.json` with `zig build gen-check-schema`.

const std = @import("std");

pub const DriftCheckV1 = struct {
    schema_version: []const u8,
    tool: []const u8,
    tool_version: []const u8,
    repo: ?[]const u8,
    checked_at_ms: i64,
    summary: Summary,
    docs: []const Doc,
};

pub const Summary = struct {
    result: []const u8,
    verification_state: []const u8,
    docs_total: u32,
    docs_checked: u32,
    docs_skipped: u32,
    docs_fresh: u32,
    docs_stale: u32,
    anchors_total: u32,
    anchors_fresh: u32,
    anchors_stale: u32,
    anchors_skipped: u32,
    links_total: u32,
    links_broken: u32,
};

pub const Doc = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: []const u8,
    anchors: []const Anchor,
    links: []const Link,
};

pub const Anchor = struct {
    identity: []const u8,
    raw: []const u8,
    kind: []const u8,
    path: []const u8,
    symbol: ?[]const u8,
    provenance: ?Provenance,
    result: []const u8,
    reason: ?Reason,
    blame: ?Blame,
};

pub const Link = struct {
    target: []const u8,
    line: u32,
    result: []const u8,
    reason: ?Reason,
};

pub const Provenance = struct {
    kind: []const u8,
    value: []const u8,
};

pub const Reason = struct {
    code: []const u8,
    message: []const u8,
};

pub const Blame = struct {
    author: []const u8,
    commit: []const u8,
    date: []const u8,
    subject: []const u8,
};

pub fn writeJson(w: *std.Io.Writer, doc: DriftCheckV1) !void {
    try std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

pub const ValidateJsonError = error{
    BadDriftCheckPayload,
};

/// Stricter checks than JSON typing alone (enums, count identities). Used by integration tests.
pub fn validateJsonDocument(doc: DriftCheckV1) ValidateJsonError!void {
    if (!std.mem.eql(u8, doc.schema_version, "drift.check.v1")) return error.BadDriftCheckPayload;
    if (!std.mem.eql(u8, doc.tool, "drift")) return error.BadDriftCheckPayload;
    if (doc.tool_version.len == 0) return error.BadDriftCheckPayload;

    try validateSummary(doc.summary);
    for (doc.docs) |d| {
        try validateDoc(d);
    }
}

fn validateSummary(s: Summary) ValidateJsonError!void {
    try oneOf(s.result, &.{ "pass", "fail" });
    try oneOf(s.verification_state, &.{ "none", "partial", "full" });

    const spec_sum = @as(u64, s.docs_fresh) + @as(u64, s.docs_stale) + @as(u64, s.docs_skipped);
    if (spec_sum != s.docs_total) return error.BadDriftCheckPayload;
    const checked = @as(u64, s.docs_fresh) + @as(u64, s.docs_stale);
    if (checked != s.docs_checked) return error.BadDriftCheckPayload;

    const anchor_sum = @as(u64, s.anchors_fresh) + @as(u64, s.anchors_stale) + @as(u64, s.anchors_skipped);
    if (anchor_sum != s.anchors_total) return error.BadDriftCheckPayload;
    if (s.links_broken > s.links_total) return error.BadDriftCheckPayload;

    // Coverage label must match counts; see docs/check-json-schema.md (summary).
    if (std.mem.eql(u8, s.verification_state, "none")) {
        if (s.docs_total == 0) return error.BadDriftCheckPayload;
        if (s.docs_checked != 0) return error.BadDriftCheckPayload;
    } else if (std.mem.eql(u8, s.verification_state, "partial")) {
        if (s.docs_checked == 0) return error.BadDriftCheckPayload;
        if (s.docs_skipped == 0) return error.BadDriftCheckPayload;
    } else {
        // "full" — nothing skipped (including docs_total == 0).
        if (s.docs_skipped != 0) return error.BadDriftCheckPayload;
    }
}

fn validateDoc(doc: Doc) ValidateJsonError!void {
    if (doc.path.len == 0) return error.BadDriftCheckPayload;
    try oneOf(doc.result, &.{ "fresh", "stale", "skip", "broken" });
    for (doc.anchors) |a| {
        try validateAnchor(a);
    }
    for (doc.links) |l| {
        try validateLink(l);
    }
}

fn validateAnchor(a: Anchor) ValidateJsonError!void {
    if (a.identity.len == 0 or a.raw.len == 0 or a.path.len == 0) return error.BadDriftCheckPayload;
    try oneOf(a.kind, &.{ "file", "symbol", "heading" });
    try oneOf(a.result, &.{ "fresh", "stale", "skip" });

    if (a.provenance) |pr| {
        try oneOf(pr.kind, &.{ "sig", "vcs" });
        if (pr.value.len == 0) return error.BadDriftCheckPayload;
    }
    if (a.reason) |r| {
        if (r.code.len == 0) return error.BadDriftCheckPayload;
    }
    if (a.blame) |b| {
        if (b.author.len == 0 or b.commit.len == 0 or b.date.len == 0 or b.subject.len == 0) {
            return error.BadDriftCheckPayload;
        }
    }
}

fn validateLink(link: Link) ValidateJsonError!void {
    if (link.target.len == 0 or link.line == 0) return error.BadDriftCheckPayload;
    try oneOf(link.result, &.{ "ok", "broken" });
    if (std.mem.eql(u8, link.result, "ok")) {
        if (link.reason != null) return error.BadDriftCheckPayload;
    } else if (link.reason == null) {
        return error.BadDriftCheckPayload;
    }
}

fn oneOf(have: []const u8, choices: []const []const u8) ValidateJsonError!void {
    for (choices) |c| {
        if (std.mem.eql(u8, have, c)) return;
    }
    return error.BadDriftCheckPayload;
}
