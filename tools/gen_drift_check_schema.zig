const std = @import("std");
const schema_gen = @import("drift_check_schema_gen");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("usage: {s} <output.json>\n", .{args[0]});
        std.process.exit(2);
    }

    var file = try std.fs.cwd().createFile(args[1], .{});
    defer file.close();

    var buf: [512 * 1024]u8 = undefined;
    var w = file.writer(&buf);
    defer w.interface.flush() catch {};
    try schema_gen.writeJsonSchema(allocator, &w.interface);
}
