const std = @import("std");
const scanner = @import("../scanner.zig");
const lint = @import("lint.zig");

const Spec = scanner.Spec;
pub const Format = lint.Format;

pub fn run(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer, format: Format) !void {
    var specs: std.ArrayList(Spec) = .{};
    defer {
        for (specs.items) |*s| s.deinit(allocator);
        specs.deinit(allocator);
    }

    try scanner.findAndSortSpecs(allocator, &specs);

    switch (format) {
        .json => writeSpecsJson(stdout_w, specs.items),
        .text => writeSpecsText(stdout_w, specs.items),
    }

    _ = stderr_w;
}

fn writeSpecsText(w: *std.io.Writer, specs: []const Spec) void {
    if (specs.len == 0) return;

    for (specs, 0..) |spec, idx| {
        w.print("{s} ({d} anchor{s})\n", .{
            spec.path,
            spec.anchors.items.len,
            if (spec.anchors.items.len == 1) "" else "s",
        }) catch {};

        if (spec.origin) |origin| {
            w.print("  origin: {s}\n", .{origin}) catch {};
        }

        if (spec.anchors.items.len > 0) {
            w.print("  files:\n", .{}) catch {};
            for (spec.anchors.items) |anchor| {
                w.print("    - {s}\n", .{anchor}) catch {};
            }
        }

        if (idx < specs.len - 1) {
            w.print("\n", .{}) catch {};
        }
    }
}

fn writeSpecsJson(w: *std.io.Writer, specs: []const Spec) void {
    var json_w: std.json.Stringify = .{ .writer = w, .options = .{} };

    json_w.beginArray() catch return;
    for (specs) |spec| {
        if (spec.origin) |origin| {
            json_w.write(.{
                .spec = spec.path,
                .origin = origin,
                .files = spec.anchors.items,
            }) catch return;
        } else {
            json_w.write(.{
                .spec = spec.path,
                .files = spec.anchors.items,
            }) catch return;
        }
    }
    json_w.endArray() catch return;
    w.writeByte('\n') catch {};
}
