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
    specs: []const Spec,
};

pub const Summary = struct {
    result: []const u8,
    verification_state: []const u8,
    specs_total: u32,
    specs_checked: u32,
    specs_skipped: u32,
    specs_fresh: u32,
    specs_stale: u32,
    anchors_total: u32,
    anchors_fresh: u32,
    anchors_stale: u32,
    anchors_skipped: u32,
};

pub const Spec = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: []const u8,
    anchors: []const Anchor,
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

pub fn writeJson(w: *std.io.Writer, doc: DriftCheckV1) !void {
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
    for (doc.specs) |spec| {
        try validateSpec(spec);
    }
}

fn validateSummary(s: Summary) ValidateJsonError!void {
    try oneOf(s.result, &.{ "pass", "fail" });
    try oneOf(s.verification_state, &.{ "none", "partial", "full" });

    const spec_sum = @as(u64, s.specs_fresh) + @as(u64, s.specs_stale) + @as(u64, s.specs_skipped);
    if (spec_sum != s.specs_total) return error.BadDriftCheckPayload;
    const checked = @as(u64, s.specs_fresh) + @as(u64, s.specs_stale);
    if (checked != s.specs_checked) return error.BadDriftCheckPayload;

    const anchor_sum = @as(u64, s.anchors_fresh) + @as(u64, s.anchors_stale) + @as(u64, s.anchors_skipped);
    if (anchor_sum != s.anchors_total) return error.BadDriftCheckPayload;

    // Coverage label must match counts; see docs/check-json-schema.md (summary).
    if (std.mem.eql(u8, s.verification_state, "none")) {
        if (s.specs_total == 0) return error.BadDriftCheckPayload;
        if (s.specs_checked != 0) return error.BadDriftCheckPayload;
    } else if (std.mem.eql(u8, s.verification_state, "partial")) {
        if (s.specs_checked == 0) return error.BadDriftCheckPayload;
        if (s.specs_skipped == 0) return error.BadDriftCheckPayload;
    } else {
        // "full" — nothing skipped (including specs_total == 0).
        if (s.specs_skipped != 0) return error.BadDriftCheckPayload;
    }
}

fn validateSpec(spec: Spec) ValidateJsonError!void {
    if (spec.path.len == 0) return error.BadDriftCheckPayload;
    try oneOf(spec.result, &.{ "fresh", "stale", "skip" });
    for (spec.anchors) |a| {
        try validateAnchor(a);
    }
}

fn validateAnchor(a: Anchor) ValidateJsonError!void {
    if (a.identity.len == 0 or a.raw.len == 0 or a.path.len == 0) return error.BadDriftCheckPayload;
    try oneOf(a.kind, &.{ "file", "symbol" });
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

fn oneOf(have: []const u8, choices: []const []const u8) ValidateJsonError!void {
    for (choices) |c| {
        if (std.mem.eql(u8, have, c)) return;
    }
    return error.BadDriftCheckPayload;
}
