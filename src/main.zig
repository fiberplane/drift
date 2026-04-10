const std = @import("std");
const build_options = @import("build_options");
const clap = @import("clap");

const CommandContext = @import("context.zig").CommandContext;
const lint = @import("commands/lint.zig");
const status = @import("commands/status.zig");
const link = @import("commands/link.zig");
const unlink = @import("commands/unlink.zig");
const refs = @import("commands/refs.zig");

const version = build_options.version;

const SubCommand = enum {
    check,
    lint,
    status,
    link,
    unlink,
    refs,
    help,
};

const main_params = clap.parseParamsComptime(
    \\-h, --help    Show this help message.
    \\-V, --version Show version.
    \\<command>
    \\
);

var failed_command: []const u8 = "";

fn parseCommand(in: []const u8) error{NameNotPartOfEnum}!SubCommand {
    return std.meta.stringToEnum(SubCommand, in) orelse {
        failed_command = in;
        return error.NameNotPartOfEnum;
    };
}

const main_parsers = .{
    .command = parseCommand,
};

// Shared by `status`. Validation lives in `parseFormat` so an unknown value errors out
// instead of silently falling through to text.
const format_params = clap.parseParamsComptime(
    \\--format <str>
    \\
);

const check_params = clap.parseParamsComptime(
    \\--format <str>
    \\--changed <str>
    \\
);

fn parseFormat(maybe_value: ?[]const u8, stderr_w: *std.Io.Writer) lint.Format {
    const value = maybe_value orelse return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "text")) return .text;
    fatal(stderr_w, "error: unknown --format value '{s}' (expected 'text' or 'json')\n", .{value});
}

const link_params = clap.parseParamsComptime(
    \\--doc-is-still-accurate
    \\<doc>
    \\
);

const link_parsers = .{
    .doc = clap.parsers.string,
};

const unlink_params = clap.parseParamsComptime(
    \\<doc>
    \\<anchor>
    \\
);

const unlink_parsers = .{
    .doc = clap.parsers.string,
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
) clap.ResultEx(clap.Help, params, value_parsers) {
    return clap.parseEx(clap.Help, params, value_parsers, iter, .{
        .diagnostic = diag,
        .allocator = allocator,
        .terminating_positional = terminating_positional,
    }) catch |err| {
        diag.report(stderr_w, err) catch {};
        fatal(stderr_w, "", .{});
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
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| switch (err) {
        error.NameNotPartOfEnum => {
            stderr_w.interface.print("unknown command: '{s}'\n\n", .{failed_command}) catch {};
            printUsage(&stderr_w.interface);
            fatal(&stderr_w.interface, "", .{});
        },
        else => {
            diag.report(&stderr_w.interface, err) catch {};
            fatal(&stderr_w.interface, "", .{});
        },
    };
    defer res.deinit();

    if (res.args.help != 0) {
        printUsage(&stdout_w.interface);
        return;
    }

    if (res.args.version != 0) {
        stdout_w.interface.print("drift {s}\n", .{version}) catch {
            std.process.exit(1);
        };
        return;
    }

    const command = res.positionals[0] orelse {
        printUsage(&stdout_w.interface);
        return;
    };

    switch (command) {
        .check, .lint => {
            var sub = parseExOrReport(&check_params, clap.parsers.default, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            if (iter.next()) |_| {
                fatal(&stderr_w.interface, "usage: drift check [--format text|json] [--changed <path>]\n", .{});
            }
            const format = parseFormat(sub.args.format, &stderr_w.interface);
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            var scratch_arena = std.heap.ArenaAllocator.init(allocator);
            defer scratch_arena.deinit();
            const ctx = CommandContext{ .run_arena = run_arena.allocator(), .scratch_arena = &scratch_arena };
            const run_status = lint.run(ctx, &stdout_w.interface, &stderr_w.interface, format, sub.args.changed) catch |err| switch (err) {
                error.LintCheckFailed => {
                    stdout_w.interface.flush() catch {};
                    stderr_w.interface.flush() catch {};
                    std.process.exit(1);
                },
                else => exitWithError(&stderr_w.interface, err),
            };
            // Exit-on-stale lives here (not in lint.run) so all `defer`s in run unwind
            // before the process dies. std.process.exit calls libc exit, which does not
            // run Zig defers — putting the exit in run leaks the result model.
            if (run_status == .fail) {
                stdout_w.interface.flush() catch {};
                stderr_w.interface.flush() catch {};
                std.process.exit(1);
            }
        },
        .status => {
            var sub = parseExOrReport(&format_params, clap.parsers.default, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            if (iter.next()) |_| {
                fatal(&stderr_w.interface, "usage: drift status [--format text|json]\n", .{});
            }
            const format = parseFormat(sub.args.format, &stderr_w.interface);
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            var scratch_arena = std.heap.ArenaAllocator.init(allocator);
            defer scratch_arena.deinit();
            const ctx = CommandContext{ .run_arena = run_arena.allocator(), .scratch_arena = &scratch_arena };
            status.run(ctx, &stdout_w.interface, &stderr_w.interface, format) catch |err| {
                exitWithError(&stderr_w.interface, err);
            };
        },
        .link => {
            var sub = parseExOrReport(&link_params, link_parsers, allocator, &diag, &stderr_w.interface, &iter, 0);
            defer sub.deinit();
            var doc_is_still_accurate = sub.args.@"doc-is-still-accurate" != 0;
            const doc_path = sub.positionals[0] orelse {
                fatal(&stderr_w.interface, "usage: drift link <doc-path> [anchor] [--doc-is-still-accurate]\n", .{});
            };
            // Remaining args after the first positional: optional anchor and/or --doc-is-still-accurate
            var optional_anchor: ?[]const u8 = null;
            var has_extra_args = false;
            while (iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "--doc-is-still-accurate")) {
                    doc_is_still_accurate = true;
                } else if (optional_anchor == null) {
                    optional_anchor = arg;
                } else {
                    has_extra_args = true;
                }
            }
            if (has_extra_args) {
                fatal(&stderr_w.interface, "usage: drift link <doc-path> [anchor] [--doc-is-still-accurate]\n", .{});
            }
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            var scratch_arena = std.heap.ArenaAllocator.init(allocator);
            defer scratch_arena.deinit();
            const ctx = CommandContext{ .run_arena = run_arena.allocator(), .scratch_arena = &scratch_arena };
            link.run(ctx, &stdout_w.interface, &stderr_w.interface, doc_path, optional_anchor, doc_is_still_accurate) catch |err| switch (err) {
                error.DocReadFailed, error.NoBindingsForDoc => {
                    fatal(&stderr_w.interface, "", .{});
                },
                error.TargetNotFound, error.HeadingNotFound => {
                    fatal(&stderr_w.interface, "", .{});
                },
                error.CannotComputeFingerprint => {
                    fatal(&stderr_w.interface, "error: cannot compute fingerprint for anchor in '{s}'\n", .{doc_path});
                },
                error.DocUnchanged => {
                    fatal(&stderr_w.interface, "", .{});
                },
                else => exitWithError(&stderr_w.interface, err),
            };
        },
        .unlink => {
            var sub = parseExOrReport(&unlink_params, unlink_parsers, allocator, &diag, &stderr_w.interface, &iter, clap_parse_all);
            defer sub.deinit();
            const doc_path = sub.positionals[0] orelse {
                fatal(&stderr_w.interface, "usage: drift unlink <doc-path> <anchor>\n", .{});
            };
            const anchor = sub.positionals[1] orelse {
                fatal(&stderr_w.interface, "usage: drift unlink <doc-path> <anchor>\n", .{});
            };
            if (iter.next()) |_| {
                fatal(&stderr_w.interface, "usage: drift unlink <doc-path> <anchor>\n", .{});
            }
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            var scratch_arena = std.heap.ArenaAllocator.init(allocator);
            defer scratch_arena.deinit();
            const ctx = CommandContext{ .run_arena = run_arena.allocator(), .scratch_arena = &scratch_arena };
            unlink.run(ctx, &stdout_w.interface, &stderr_w.interface, doc_path, anchor) catch |err| {
                exitWithError(&stderr_w.interface, err);
            };
        },
        .refs => {
            const target = iter.next() orelse {
                fatal(&stderr_w.interface, "usage: drift refs <path>\n", .{});
            };
            if (iter.next()) |_| {
                fatal(&stderr_w.interface, "usage: drift refs <path>\n", .{});
            }
            var run_arena = std.heap.ArenaAllocator.init(allocator);
            defer run_arena.deinit();
            var scratch_arena = std.heap.ArenaAllocator.init(allocator);
            defer scratch_arena.deinit();
            const ctx = CommandContext{ .run_arena = run_arena.allocator(), .scratch_arena = &scratch_arena };
            refs.run(ctx, &stdout_w.interface, &stderr_w.interface, target) catch |err| {
                exitWithError(&stderr_w.interface, err);
            };
        },
        .help => printUsage(&stdout_w.interface),
    }
}

fn printUsage(w: *std.io.Writer) void {
    w.print(
        \\drift — bind docs to code, lint for drift
        \\
        \\Usage: drift <command> [options]
        \\
        \\Commands:
        \\  check     Check all docs for staleness  [--format text|json] [--changed <path>]
        \\  status    Show all docs and their anchors  [--format text|json]
        \\  link      Add anchors to a doc  [--doc-is-still-accurate]
        \\  unlink    Remove anchors from a doc
        \\  refs      Show which docs reference a target
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -V, --version  Show version
        \\
        \\JSON output is documented in docs/check-json-schema.md (drift.check.v1).
        \\
    , .{}) catch {};
}

fn fatal(stderr_w: *std.io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    stderr_w.print(fmt, args) catch {};
    stderr_w.flush() catch {};
    std.process.exit(1);
}

fn exitWithError(stderr_w: *std.io.Writer, err: anyerror) noreturn {
    const message: []const u8 = switch (err) {
        error.InvalidBindingLine => "malformed binding in drift.lock",
        error.InvalidMetadataField => "malformed metadata field in drift.lock",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
    fatal(stderr_w, "error: {s}\n", .{message});
}
