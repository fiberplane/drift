const std = @import("std");
const schema_gen = @import("drift_check_schema_gen");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var iter = try init.minimal.args.iterateAllocator(gpa);
    defer iter.deinit();

    _ = iter.next(); // exe
    const out_path = iter.next() orelse {
        std.debug.print("usage: gen-drift-check-schema <output.json>\n", .{});
        std.process.exit(2);
    };

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer file.close(io);

    var buf: [512 * 1024]u8 = undefined;
    var w = file.writer(io, &buf);
    defer w.interface.flush() catch {};
    try schema_gen.writeJsonSchema(gpa, &w.interface);
}
