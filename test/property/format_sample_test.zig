//! One-shot: dump each format variant's output for a hand-picked fixture so
//! humans can eyeball readability alongside the conflict-rate numbers.
//! Gated on the same -Dformat-experiment flag as the measurement harness.

const std = @import("std");
const lockfile = @import("../../src/lockfile.zig");
const helpers = @import("helpers");
const experiment = @import("format_experiment_test.zig");

test "sample: render fixture under each format variant" {
    if (!helpers.run_format_experiment) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const mk = struct {
        fn binding(
            alloc: std.mem.Allocator,
            doc_path: []const u8,
            target: []const u8,
            pairs: []const [2][]const u8,
        ) !lockfile.Binding {
            var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
            for (pairs) |p| {
                try metadata.append(alloc, .{
                    .key = try alloc.dupe(u8, p[0]),
                    .value = try alloc.dupe(u8, p[1]),
                });
            }
            return .{
                .doc_path = try alloc.dupe(u8, doc_path),
                .target = try alloc.dupe(u8, target),
                .metadata = metadata,
            };
        }
    }.binding;

    var bindings: std.ArrayList(lockfile.Binding) = .empty;
    try bindings.append(a, try mk(a, "docs/auth.md", "src/auth/login.ts", &.{
        .{ "sig", "a1b2c3d4e5f6a7b8" },
        .{ "origin", "github" },
    }));
    try bindings.append(a, try mk(a, "docs/auth.md", "src/auth/provider.ts", &.{
        .{ "sig", "1a2b3c4d5e6f7890" },
    }));
    try bindings.append(a, try mk(a, "docs/billing.md", "src/billing/invoice.ts", &.{
        .{ "sig", "deadbeefcafebabe" },
        .{ "origin", "local" },
        .{ "lang", "ts" },
    }));

    const names = [_][]const u8{
        "V0 baseline",
        "V1 multiline-blocks",
        "V2 sectioned-single",
        "V3 sectioned-multi",
        "V4 toml-tables (A, flat)",
        "V5 yaml-nested",
        "V6 hr-separator",
        "V7 aligned-cols",
        "V8 ini-blocks",
        "V9 toml (B, nested)",
        "V10 toml (C, grouped)",
        "V11 hash-V0 b=8",
        "V12 hash-V0 b=16",
        "V13 hash-V0 b=32",
        "V14 hash-V0 b=64",
        "V15 hash-V4 b=8",
        "V16 hash-V4 b=16",
        "V17 hash-V4 b=32",
        "V18 hash-V4 b=64",
        "V19 sem-V4 a-z (first letter of doc basename)",
    };
    for (names, 0..) |name, i| {
        const text = try experiment.VARIANT_FNS[i](a, bindings.items);
        std.debug.print("\n=== {s} ===\n{s}", .{ name, text });
        if (text.len > 0 and text[text.len - 1] != '\n') std.debug.print("\n", .{});
        std.debug.print("    ({d} bytes)\n", .{text.len});
    }
}
