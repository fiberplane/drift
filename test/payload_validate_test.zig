const std = @import("std");
const payload = @import("payload");

fn docWithSummary(summary: payload.Summary) payload.DriftCheckV1 {
    return .{
        .schema_version = "drift.check.v1",
        .tool = "drift",
        .tool_version = "0.0.0",
        .repo = null,
        .checked_at_ms = 0,
        .summary = summary,
        .docs = &.{},
    };
}

test "validateJsonDocument rejects verification_state full when docs_skipped nonzero" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "full",
        .docs_total = 1,
        .docs_checked = 0,
        .docs_skipped = 1,
        .docs_fresh = 0,
        .docs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
        .links_total = 0,
        .links_broken = 0,
    })));
}

test "validateJsonDocument rejects verification_state none when docs_total zero" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "none",
        .docs_total = 0,
        .docs_checked = 0,
        .docs_skipped = 0,
        .docs_fresh = 0,
        .docs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
        .links_total = 0,
        .links_broken = 0,
    })));
}

test "validateJsonDocument rejects verification_state partial when nothing skipped" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "partial",
        .docs_total = 1,
        .docs_checked = 1,
        .docs_skipped = 0,
        .docs_fresh = 1,
        .docs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
        .links_total = 0,
        .links_broken = 0,
    })));
}

test "validateJsonDocument accepts verification_state full with zero docs" {
    try payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "full",
        .docs_total = 0,
        .docs_checked = 0,
        .docs_skipped = 0,
        .docs_fresh = 0,
        .docs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
        .links_total = 0,
        .links_broken = 0,
    }));
}
