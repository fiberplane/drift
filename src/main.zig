const std = @import("std");
const clap = @import("clap");
const frontmatter = @import("frontmatter.zig");
const scanner = @import("scanner.zig");
const symbols = @import("symbols.zig");
const vcs = @import("vcs.zig");

const Spec = scanner.Spec;

const version = "0.1.0";

const SubCommand = enum {
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
    .command = clap.parsers.string,
};

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

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &main_params, main_parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        diag.report(&stderr_w.interface, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        printUsage(&stdout_w.interface);
        return;
    }

    if (res.args.version != 0) {
        stdout_w.interface.print("drift {s}\n", .{version}) catch return error.WriteFailed;
        return;
    }

    const command_str = res.positionals[0] orelse {
        printUsage(&stdout_w.interface);
        return;
    };

    const command = std.meta.stringToEnum(SubCommand, command_str) orelse {
        stderr_w.interface.print("unknown command: {s}\n", .{command_str}) catch {};
        stderr_w.interface.print("available commands: lint, status, link, unlink\n", .{}) catch {};
        return error.InvalidCommand;
    };

    switch (command) {
        .lint => runLint(allocator, &stdout_w.interface, &stderr_w.interface) catch |err| {
            stderr_w.interface.print("lint error: {s}\n", .{@errorName(err)}) catch {};
        },
        .status => runStatus(allocator, &stdout_w.interface, &stderr_w.interface) catch |err| {
            stderr_w.interface.print("status error: {s}\n", .{@errorName(err)}) catch {};
        },
        .link => runLink(allocator, &stdout_w.interface, &stderr_w.interface) catch |err| {
            stderr_w.interface.print("link error: {s}\n", .{@errorName(err)}) catch {};
        },
        .unlink => runUnlink(allocator, &stdout_w.interface, &stderr_w.interface) catch |err| {
            stderr_w.interface.print("unlink error: {s}\n", .{@errorName(err)}) catch {};
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
        \\  lint      Check all specs for staleness
        \\  status    Show all specs and their bindings
        \\  link      Add bindings to a spec
        \\  unlink    Remove bindings from a spec
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -V, --version  Show version
        \\
    , .{}) catch {};
}

fn runLint(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer) !void {
    var specs: std.ArrayList(Spec) = .{};
    defer {
        for (specs.items) |*s| s.deinit(allocator);
        specs.deinit(allocator);
    }

    var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer root_dir.close();
    try scanner.walkForSpecs(allocator, root_dir, "", &specs);

    // Also parse inline bindings from body content of each spec
    for (specs.items) |*spec| {
        const content = std.fs.cwd().readFileAlloc(allocator, spec.path, 1024 * 1024) catch continue;
        defer allocator.free(content);

        var inline_bindings = scanner.parseInlineBindings(allocator, content);
        for (inline_bindings.items) |ib| {
            // Avoid duplicates
            var already_bound = false;
            for (spec.bindings.items) |existing| {
                if (std.mem.eql(u8, existing, ib)) {
                    already_bound = true;
                    break;
                }
            }
            if (!already_bound) {
                spec.bindings.append(allocator, ib) catch {
                    allocator.free(ib);
                    continue;
                };
            } else {
                allocator.free(ib);
            }
        }
        inline_bindings.deinit(allocator);
    }

    // Sort specs by path for deterministic output
    std.mem.sort(Spec, specs.items, {}, struct {
        fn lessThan(_: void, a: Spec, b: Spec) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    // Get absolute cwd for VCS commands
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const detected_vcs = vcs.detectVcs();
    var has_issues = false;

    for (specs.items) |spec| {
        stdout_w.print("{s}\n", .{spec.path}) catch {};

        if (spec.bindings.items.len == 0) {
            stdout_w.print("  ok\n", .{}) catch {};
            continue;
        }

        // Get last commit/change that touched the spec file
        const spec_commit = vcs.getLastCommit(allocator, cwd_path, spec.path, detected_vcs) catch |err| {
            stderr_w.print("vcs error for {s}: {s}\n", .{ spec.path, @errorName(err) }) catch {};
            continue;
        };
        defer if (spec_commit) |c| allocator.free(c);

        var all_ok = true;

        for (spec.bindings.items) |binding| {
            const status = checkBinding(allocator, cwd_path, binding, spec_commit, detected_vcs) catch |err| {
                stderr_w.print("error checking {s}: {s}\n", .{ binding, @errorName(err) }) catch {};
                continue;
            };
            defer allocator.free(status.label);
            defer allocator.free(status.reason);

            if (!std.mem.eql(u8, status.label, "ok")) {
                has_issues = true;
                all_ok = false;
                if (status.reason.len > 0) {
                    stdout_w.print("  {s}   {s} ({s})\n", .{ status.label, status.display, status.reason }) catch {};
                } else {
                    stdout_w.print("  {s}   {s}\n", .{ status.label, status.display }) catch {};
                }
            }
        }

        if (all_ok) {
            stdout_w.print("  ok\n", .{}) catch {};
        }
    }

    if (specs.items.len == 0) {
        stdout_w.print("ok\n", .{}) catch {};
    }

    if (has_issues) {
        stdout_w.flush() catch {};
        stderr_w.flush() catch {};
        std.process.exit(1);
    }
}

const BindingStatus = struct {
    label: []const u8,
    display: []const u8,
    reason: []const u8,
};

fn checkBinding(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    binding: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
) !BindingStatus {
    // Split on # to check for symbol bindings
    const hash_pos = std.mem.indexOfScalar(u8, binding, '#');
    const file_path = if (hash_pos) |pos| binding[0..pos] else binding;
    const symbol_name = if (hash_pos) |pos| binding[pos + 1 ..] else null;

    // Check if the file exists
    const file_exists = blk: {
        std.fs.cwd().access(file_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!file_exists) {
        return .{
            .label = try allocator.dupe(u8, "STALE"),
            .display = binding,
            .reason = try allocator.dupe(u8, "file not found"),
        };
    }

    // If symbol binding, check if symbol exists in the file via tree-sitter
    if (symbol_name) |sym| {
        const file_content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch {
            return .{
                .label = try allocator.dupe(u8, "STALE"),
                .display = binding,
                .reason = try allocator.dupe(u8, "file not readable"),
            };
        };
        defer allocator.free(file_content);

        const ext = std.fs.path.extension(file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            if (!symbols.resolveSymbolWithTreeSitter(file_content, lang_query, sym)) {
                return .{
                    .label = try allocator.dupe(u8, "STALE"),
                    .display = binding,
                    .reason = try allocator.dupe(u8, "symbol not found"),
                };
            }
        } else {
            // Fallback to string search for unsupported languages
            if (std.mem.indexOf(u8, file_content, sym) == null) {
                return .{
                    .label = try allocator.dupe(u8, "STALE"),
                    .display = binding,
                    .reason = try allocator.dupe(u8, "symbol not found"),
                };
            }
        }
    }

    // Check staleness via VCS
    if (spec_commit) |commit| {
        const is_stale = vcs.checkStaleness(allocator, cwd_path, commit, file_path, detected_vcs) catch false;
        if (is_stale) {
            return .{
                .label = try allocator.dupe(u8, "STALE"),
                .display = binding,
                .reason = try allocator.dupe(u8, "changed after spec"),
            };
        }
    }

    return .{
        .label = try allocator.dupe(u8, "ok"),
        .display = binding,
        .reason = try allocator.dupe(u8, ""),
    };
}

fn runStatus(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse --format flag after "status" subcommand
    var format_json = false;
    var i: usize = 2; // skip binary path and "status"
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--format")) {
            if (i + 1 < args.len and std.mem.eql(u8, args[i + 1], "json")) {
                format_json = true;
                i += 1;
            }
        }
    }

    var specs: std.ArrayList(Spec) = .{};
    defer {
        for (specs.items) |*s| s.deinit(allocator);
        specs.deinit(allocator);
    }

    var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer root_dir.close();
    try scanner.walkForSpecs(allocator, root_dir, "", &specs);

    // Sort specs by path for deterministic output
    std.mem.sort(Spec, specs.items, {}, struct {
        fn lessThan(_: void, a: Spec, b: Spec) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    if (format_json) {
        writeSpecsJson(stdout_w, specs.items);
    } else {
        writeSpecsText(stdout_w, specs.items);
    }

    _ = stderr_w;
}

fn writeSpecsText(w: *std.io.Writer, specs: []const Spec) void {
    if (specs.len == 0) return;

    for (specs, 0..) |spec, idx| {
        w.print("{s} ({d} binding{s})\n", .{
            spec.path,
            spec.bindings.items.len,
            if (spec.bindings.items.len == 1) "" else "s",
        }) catch {};

        if (spec.bindings.items.len > 0) {
            w.print("  files:\n", .{}) catch {};
            for (spec.bindings.items) |binding| {
                w.print("    - {s}\n", .{binding}) catch {};
            }
        }

        if (idx < specs.len - 1) {
            w.print("\n", .{}) catch {};
        }
    }
}

fn writeSpecsJson(w: *std.io.Writer, specs: []const Spec) void {
    w.print("[", .{}) catch {};
    for (specs, 0..) |spec, idx| {
        if (idx > 0) w.print(",", .{}) catch {};
        w.print("{{\"spec\":\"{s}\",\"files\":[", .{spec.path}) catch {};
        for (spec.bindings.items, 0..) |binding, bidx| {
            if (bidx > 0) w.print(",", .{}) catch {};
            w.print("\"{s}\"", .{binding}) catch {};
        }
        w.print("]}}", .{}) catch {};
    }
    w.print("]\n", .{}) catch {};
}

fn runUnlink(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // args[0] = binary path, args[1] = "unlink", args[2] = spec-path, args[3] = binding
    if (args.len < 4) {
        stderr_w.print("usage: drift unlink <spec-path> <binding>\n", .{}) catch {};
        return error.MissingArguments;
    }

    const spec_path = args[2];
    const binding = args[3];

    const cwd = std.fs.cwd();
    const content = cwd.readFileAlloc(allocator, spec_path, 1024 * 1024) catch |err| {
        stderr_w.print("cannot read {s}: {s}\n", .{ spec_path, @errorName(err) }) catch {};
        return err;
    };
    defer allocator.free(content);

    const result = try frontmatter.unlinkBinding(allocator, content, binding);
    defer allocator.free(result.content);

    if (result.removed) {
        const file = cwd.openFile(spec_path, .{ .mode = .write_only }) catch |err| {
            stderr_w.print("cannot write {s}: {s}\n", .{ spec_path, @errorName(err) }) catch {};
            return err;
        };
        defer file.close();

        try file.writeAll(result.content);
        try file.setEndPos(result.content.len);

        stdout_w.print("removed {s} from {s}\n", .{ binding, spec_path }) catch {};
    }
}

// --- link command ---

fn runLink(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // args[0] = binary path, args[1] = "link", args[2] = spec-path, args[3] = binding
    if (args.len < 4) {
        stderr_w.print("usage: drift link <spec-path> <binding>\n", .{}) catch {};
        return error.MissingArguments;
    }

    const spec_path = args[2];
    const raw_binding = args[3];

    // Auto-provenance: if no @change suffix, detect VCS and append current change ID
    const binding = blk: {
        const identity = frontmatter.bindingFileIdentity(raw_binding);
        if (identity.len != raw_binding.len) {
            // Already has provenance (@... suffix)
            break :blk raw_binding;
        }
        // No provenance -- try to auto-detect
        const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch break :blk raw_binding;
        defer allocator.free(cwd_path);

        const detected_vcs = vcs.detectVcs();
        const change_id = vcs.getCurrentChangeId(allocator, cwd_path, detected_vcs) catch break :blk raw_binding;
        if (change_id) |cid| {
            defer allocator.free(cid);
            break :blk std.fmt.allocPrint(allocator, "{s}@{s}", .{ raw_binding, cid }) catch break :blk raw_binding;
        }
        break :blk raw_binding;
    };
    const binding_owned = binding.ptr != raw_binding.ptr;
    defer if (binding_owned) allocator.free(binding);

    const cwd = std.fs.cwd();
    const content = cwd.readFileAlloc(allocator, spec_path, 1024 * 1024) catch |err| {
        stderr_w.print("cannot read {s}: {s}\n", .{ spec_path, @errorName(err) }) catch {};
        return err;
    };
    defer allocator.free(content);

    const result = try frontmatter.linkBinding(allocator, content, binding);
    defer allocator.free(result);

    const file = cwd.openFile(spec_path, .{ .mode = .write_only }) catch |err| {
        stderr_w.print("cannot write {s}: {s}\n", .{ spec_path, @errorName(err) }) catch {};
        return err;
    };
    defer file.close();

    try file.writeAll(result);
    try file.setEndPos(result.len);

    stdout_w.print("added {s} to {s}\n", .{ binding, spec_path }) catch {};
}
