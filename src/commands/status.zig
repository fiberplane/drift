const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const lint = @import("lint.zig");
const lockfile = @import("../lockfile.zig");

pub const Format = lint.Format;

pub fn run(ctx: CommandContext, stdout_w: *std.Io.Writer, stderr_w: *std.Io.Writer, format: Format) !void {
    _ = stderr_w;

    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.run_arena);

    const lf = try lockfile.discover(ctx.io, ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    var docs = try lockfile.groupByDoc(ctx.run_arena, lf.bindings.items);
    defer {
        for (docs.items) |*doc| doc.bindings.deinit(ctx.run_arena);
        docs.deinit(ctx.run_arena);
    }

    switch (format) {
        .json => try writeDocsJson(stdout_w, docs.items),
        .text => writeDocsText(stdout_w, docs.items),
    }
}

fn writeDocsText(w: *std.Io.Writer, docs: []const lockfile.DocBindings) void {
    if (docs.len == 0) return;

    for (docs, 0..) |doc, idx| {
        w.print("{s} ({d} anchor{s})\n", .{
            doc.path,
            doc.bindings.items.len,
            if (doc.bindings.items.len == 1) "" else "s",
        }) catch {};

        if (doc.bindings.items.len > 0) {
            w.print("  files:\n", .{}) catch {};
            for (doc.bindings.items) |binding| {
                w.print("    - {s}\n", .{binding.target}) catch {};
            }
        }

        if (idx < docs.len - 1) {
            w.print("\n", .{}) catch {};
        }
    }
}

fn writeDocsJson(w: *std.Io.Writer, docs: []const lockfile.DocBindings) !void {
    var json_w: std.json.Stringify = .{ .writer = w, .options = .{} };

    try json_w.beginArray();
    for (docs) |doc| {
        try json_w.beginObject();
        try json_w.objectField("doc");
        try json_w.write(doc.path);
        try json_w.objectField("files");
        try json_w.beginArray();
        for (doc.bindings.items) |binding| {
            try json_w.write(binding.target);
        }
        try json_w.endArray();
        try json_w.endObject();
    }
    try json_w.endArray();
    try w.writeByte('\n');
}
