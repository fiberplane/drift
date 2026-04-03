const std = @import("std");
const build_options = @import("build_options");
const clap = @import("clap");

const lint = @import("commands/lint.zig");
const status = @import("commands/status.zig");
const link = @import("commands/link.zig");
const unlink = @import("commands/unlink.zig");

const version = build_options.version;

const SubCommand = enum {
    check,
    lint,
    status,
    link,
    unlink,
    help,
};

const main_params = clap.parseParamsComptime(
    \\-h, --help    Show this help message.
    \\-V, --version Show version.
    \\<command>
    \\
);

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommand),
};

const check_params = clap.parseParamsComptime(
    \\--format <str>
    \\
);

const status_params = clap.parseParamsComptime(
    \\--format <str>
    \\
);

const link_params = clap.parseParamsComptime(
    \\<spec>
    \\
);

const link_parsers = .{
    .spec = clap.parsers.string,
};

const unlink_params = clap.parseParamsComptime(
    \\<spec>
    \\<anchor>
    \\
);

const unlink_parsers = .{
    .spec = clap.parsers.string,
    .anchor = clap.parsers.string,
};

const clap_parse_all = std.math.maxInt(usize);

/// `clap.parseEx` with diagnostics on failure. `terminating_positional` matches clap's option (use `0` to stop after the first positional).
fn parseExOrReport(
    comptime params: []const clap.Param(clap.Help),
    comptime value_parsers: anytype,
    allocator: std.mem.Allocator,
    diag: *clap.Diagnostic,
    stderr_w: *std.Io.Writer,
    iter: *std.process.ArgIterator,
    terminating_positional: usize,
) !clap.ResultEx(clap.Help, params, value_parsers) {
    return clap.parseEx(clap.Help, params, value_parsers, iter, .{
        .diagnostic = diag,
        .allocator = allocator,
        .terminating_positional = terminating_positional,
    }) catch |err| {
        diag.report(stderr_w, err) catch {};
        return err;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_w = std.fs.File.stderr().writer(&stderr_buf);
    defer stdout_w.interface.flush() catch {};
    defer stderr_w.interface.flush() catch {};

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip executable name

    var diag = clap.Diagnostic{};
    var res = try parseExOrReport(&main_params, main_parsers, allocator, &diag, &stderr_w.interface, &iter, 0);
    defer res.deinit();

    if (res.args.help != 0) {
        printUsage(&stdout_w.interface);
        return;
    }

    if (res.args.version != 0) {
        stdout_w.interface.print("drift {s}\n", .{version}) catch return error.WriteFailed;
        return;
    }

    const command = res.positionals[0] orelse {
        printUsage(&stdout_w.interface);
        return;
    };

    switch (command) {
        .check, .lint => {
            var sub = try parseExOrReport(&check_params, clap.parsers.default, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            if (iter.next()) |_| {
                stderr_w.interface.print("usage: drift check [--format json]\n", .{}) catch {};
                return error.InvalidArgument;
            }
            const format_json = if (sub.args.format) |f| std.mem.eql(u8, f, "json") else false;
            lint.run(allocator, &stdout_w.interface, &stderr_w.interface, format_json) catch |err| {
                exitWithCommandError(&stderr_w.interface, "check", err);
            };
        },
        .status => {
            var sub = try parseExOrReport(&status_params, clap.parsers.default, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            if (iter.next()) |_| {
                stderr_w.interface.print("usage: drift status [--format json]\n", .{}) catch {};
                return error.InvalidArgument;
            }
            const format_json = if (sub.args.format) |f| std.mem.eql(u8, f, "json") else false;
            status.run(allocator, &stdout_w.interface, &stderr_w.interface, format_json) catch |err| {
                exitWithCommandError(&stderr_w.interface, "status", err);
            };
        },
        .link => {
            var sub = try parseExOrReport(&link_params, link_parsers, allocator, &diag, &stderr_w.interface, &iter, 0);
            defer sub.deinit();
            const spec_path = sub.positionals[0] orelse {
                stderr_w.interface.print("usage: drift link <spec-path> [anchor]\n", .{}) catch {};
                return error.MissingArguments;
            };
            const optional_anchor = iter.next();
            if (iter.next()) |_| {
                stderr_w.interface.print("usage: drift link <spec-path> [anchor]\n", .{}) catch {};
                return error.InvalidArgument;
            }
            link.run(allocator, &stdout_w.interface, &stderr_w.interface, spec_path, optional_anchor) catch |err| {
                exitWithCommandError(&stderr_w.interface, "link", err);
            };
        },
        .unlink => {
            var sub = try parseExOrReport(&unlink_params, unlink_parsers, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            const spec_path = sub.positionals[0] orelse {
                stderr_w.interface.print("usage: drift unlink <spec-path> <anchor>\n", .{}) catch {};
                return error.MissingArguments;
            };
            const anchor = sub.positionals[1] orelse {
                stderr_w.interface.print("usage: drift unlink <spec-path> <anchor>\n", .{}) catch {};
                return error.MissingArguments;
            };
            if (iter.next()) |_| {
                stderr_w.interface.print("usage: drift unlink <spec-path> <anchor>\n", .{}) catch {};
                return error.InvalidArgument;
            }
            unlink.run(allocator, &stdout_w.interface, &stderr_w.interface, spec_path, anchor) catch |err| {
                exitWithCommandError(&stderr_w.interface, "unlink", err);
            };
        },
        .help => printUsage(&stdout_w.interface),
    }
}

fn printUsage(w: *std.io.Writer) void {
    w.print(
        \\drift — bind specs to code, lint for drift
        \\
        \\Usage: drift <command> [options]
        \\
        \\Commands:
        \\  check     Check all specs for staleness
        \\  status    Show all specs and their anchors
        \\  link      Add anchors to a spec
        \\  unlink    Remove anchors from a spec
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -V, --version  Show version
        \\
    , .{}) catch {};
}

fn exitWithCommandError(stderr_w: *std.io.Writer, command: []const u8, err: anyerror) noreturn {
    stderr_w.print("{s} error: {s}\n", .{ command, @errorName(err) }) catch {};
    stderr_w.flush() catch {};
    std.process.exit(1);
}
