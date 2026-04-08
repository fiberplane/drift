const std = @import("std");
const lint = @import("lint.zig");
const lockfile = @import("../lockfile.zig");

pub const Format = lint.Format;

pub fn run(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer, format: Format) !void {
    _ = stderr_w;

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var lf = try lockfile.discover(allocator, cwd_path);
    defer lf.deinit(allocator);

    var specs = try lockfile.groupBySpec(allocator, lf.bindings.items);
    defer {
        for (specs.items) |*spec| spec.deinit(allocator);
        specs.deinit(allocator);
    }

    switch (format) {
        .json => try writeSpecsJson(stdout_w, specs.items),
        .text => writeSpecsText(stdout_w, specs.items),
    }
}

fn writeSpecsText(w: *std.io.Writer, specs: []const lockfile.SpecBindings) void {
    if (specs.len == 0) return;

    for (specs, 0..) |spec, idx| {
        w.print("{s} ({d} anchor{s})\n", .{
            spec.path,
            spec.bindings.items.len,
            if (spec.bindings.items.len == 1) "" else "s",
        }) catch {};

        if (spec.bindings.items.len > 0) {
            w.print("  files:\n", .{}) catch {};
            for (spec.bindings.items) |binding| {
                w.print("    - {s}\n", .{binding.target}) catch {};
            }
        }

        if (idx < specs.len - 1) {
            w.print("\n", .{}) catch {};
        }
    }
}

fn writeSpecsJson(w: *std.io.Writer, specs: []const lockfile.SpecBindings) !void {
    var json_w: std.json.Stringify = .{ .writer = w, .options = .{} };

    try json_w.beginArray();
    for (specs) |spec| {
        try json_w.beginObject();
        try json_w.objectField("spec");
        try json_w.write(spec.path);
        try json_w.objectField("files");
        try json_w.beginArray();
        for (spec.bindings.items) |binding| {
            try json_w.write(binding.target);
        }
        try json_w.endArray();
        try json_w.endObject();
    }
    try json_w.endArray();
    try w.writeByte('\n');
}
