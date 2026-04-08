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
        .specs = &.{},
    };
}

test "validateJsonDocument rejects verification_state full when specs_skipped nonzero" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "full",
        .specs_total = 1,
        .specs_checked = 0,
        .specs_skipped = 1,
        .specs_fresh = 0,
        .specs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
    })));
}

test "validateJsonDocument rejects verification_state none when specs_total zero" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "none",
        .specs_total = 0,
        .specs_checked = 0,
        .specs_skipped = 0,
        .specs_fresh = 0,
        .specs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
    })));
}

test "validateJsonDocument rejects verification_state partial when nothing skipped" {
    try std.testing.expectError(error.BadDriftCheckPayload, payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "partial",
        .specs_total = 1,
        .specs_checked = 1,
        .specs_skipped = 0,
        .specs_fresh = 1,
        .specs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
    })));
}

test "validateJsonDocument accepts verification_state full with zero specs" {
    try payload.validateJsonDocument(docWithSummary(.{
        .result = "pass",
        .verification_state = "full",
        .specs_total = 0,
        .specs_checked = 0,
        .specs_skipped = 0,
        .specs_fresh = 0,
        .specs_stale = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
    }));
}
