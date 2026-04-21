//! Smoke test for the minish property-testing wiring.
//! If this file fails to compile or the test fails, the minish import is broken.

const std = @import("std");
const minish = @import("minish");
const helpers = @import("helpers");

test "minish: trivial int property (a + 0 == a)" {
    const identity = struct {
        fn prop(x: i32) !void {
            try std.testing.expectEqual(x, x + 0);
        }
    }.prop;

    try minish.check(
        std.testing.allocator,
        minish.gen.intRange(i32, -1000, 1000),
        identity,
        .{ .num_runs = 25, .seed = helpers.minish_seed },
    );
}
