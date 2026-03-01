const std = @import("std");
const clap = @import("clap");
const ts = @import("tree_sitter");

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
    try walkForSpecs(allocator, root_dir, "", &specs);

    // Also parse inline bindings from body content of each spec
    for (specs.items) |*spec| {
        const content = std.fs.cwd().readFileAlloc(allocator, spec.path, 1024 * 1024) catch continue;
        defer allocator.free(content);

        var inline_bindings = parseInlineBindings(allocator, content);
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

    const vcs = detectVcs();
    var has_issues = false;

    for (specs.items) |spec| {
        stdout_w.print("{s}\n", .{spec.path}) catch {};

        if (spec.bindings.items.len == 0) {
            stdout_w.print("  ok\n", .{}) catch {};
            continue;
        }

        // Get last commit/change that touched the spec file
        const spec_commit = getLastCommit(allocator, cwd_path, spec.path, vcs) catch |err| {
            stderr_w.print("vcs error for {s}: {s}\n", .{ spec.path, @errorName(err) }) catch {};
            continue;
        };
        defer if (spec_commit) |c| allocator.free(c);

        var all_ok = true;

        for (spec.bindings.items) |binding| {
            const status = checkBinding(allocator, cwd_path, binding, spec_commit, vcs) catch |err| {
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
    vcs: VcsKind,
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
        if (languageForExtension(ext)) |lang_query| {
            if (!resolveSymbolWithTreeSitter(file_content, lang_query, sym)) {
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
        const is_stale = checkStaleness(allocator, cwd_path, commit, file_path, vcs) catch false;
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

/// Get the last commit/change ID that touched a given file path.
fn getLastCommit(allocator: std.mem.Allocator, cwd_path: []const u8, file_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "log", "-1", "--format=%H", "--", file_path },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "latest(::@ & file(\"{s}\"))", .{file_path});
            defer allocator.free(revset);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    // Trim trailing newline
    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const commit = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return commit;
}

/// Check if a bound file was modified after the given commit/change.
fn checkStaleness(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    spec_commit: []const u8,
    bound_file: []const u8,
    vcs: VcsKind,
) !bool {
    const result = switch (vcs) {
        .git => blk: {
            const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{spec_commit});
            defer allocator.free(range);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "log", "--oneline", range, "--", bound_file },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "{s}..@ & file(\"{s}\")", .{ spec_commit, bound_file });
            defer allocator.free(revset);
            break :blk try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                .cwd = cwd_path,
                .max_output_bytes = 256 * 1024,
            });
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
    return trimmed.len > 0;
}

/// Get the current change/commit ID (short form) for auto-provenance.
fn getCurrentChangeId(allocator: std.mem.Allocator, cwd_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
        .jj => try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.shortest(8)", "--color=never" },
            .cwd = cwd_path,
            .max_output_bytes = 256 * 1024,
        }),
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const id = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return id;
}

/// Parse inline bindings (@./path references) from markdown content body.
fn parseInlineBindings(allocator: std.mem.Allocator, content: []const u8) std.ArrayList([]const u8) {
    var bindings: std.ArrayList([]const u8) = .{};

    // Find body: skip frontmatter if present
    const body = blk: {
        if (std.mem.startsWith(u8, content, "---\n")) {
            const after_open = content[4..];
            if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
                break :blk after_open[close_offset + 5 ..];
            }
            if (std.mem.indexOf(u8, after_open, "\n---")) |close_offset| {
                const end = close_offset + 4; // skip "\n---"
                if (end <= after_open.len) {
                    break :blk after_open[end..];
                }
            }
        }
        break :blk content;
    };

    // Scan for @./ references
    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOf(u8, body[pos..], "@./")) |offset| {
            const path_start = pos + offset + 3; // skip "@./"

            // Find end of path: next whitespace or end of body
            var path_end = path_start;
            while (path_end < body.len and !isPathTerminator(body[path_end])) {
                path_end += 1;
            }

            // Strip trailing punctuation
            while (path_end > path_start and isTrailingPunctuation(body[path_end - 1])) {
                path_end -= 1;
            }

            if (path_end > path_start) {
                const path = body[path_start..path_end];
                const duped = allocator.dupe(u8, path) catch {
                    pos = path_end;
                    continue;
                };
                bindings.append(allocator, duped) catch {
                    allocator.free(duped);
                    pos = path_end;
                    continue;
                };
            }

            pos = path_end;
        } else {
            break;
        }
    }

    return bindings;
}

fn isPathTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isTrailingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == ')' or c == ']' or c == '}' or c == '!' or c == '?';
}

// --- tree-sitter language externs ---

extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;
extern fn tree_sitter_rust() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_java() callconv(.c) *const ts.Language;

const LanguageQuery = struct {
    language: *const ts.Language,
    query_source: []const u8,
};

// Tree-sitter query sources for symbol extraction, embedded as string literals.
// These match the @name captures in the query patterns to resolve symbol bindings.
const ts_query_typescript =
    \\[
    \\  (function_declaration
    \\    name: (identifier) @name) @definition
    \\  (class_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (type_alias_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (interface_declaration
    \\    name: (type_identifier) @name) @definition
    \\  (enum_declaration
    \\    name: (identifier) @name) @definition
    \\  (lexical_declaration
    \\    (variable_declarator
    \\      name: (identifier) @name)) @definition
    \\]
;

const ts_query_python =
    \\[
    \\  (function_definition
    \\    name: (identifier) @name) @definition
    \\  (class_definition
    \\    name: (identifier) @name) @definition
    \\]
;

const ts_query_rust =
    \\[
    \\  (function_item
    \\    name: (identifier) @name) @definition
    \\  (struct_item
    \\    name: (type_identifier) @name) @definition
    \\  (enum_item
    \\    name: (type_identifier) @name) @definition
    \\  (trait_item
    \\    name: (type_identifier) @name) @definition
    \\  (type_item
    \\    name: (type_identifier) @name) @definition
    \\  (impl_item
    \\    type: (type_identifier) @name) @definition
    \\  (const_item
    \\    name: (identifier) @name) @definition
    \\  (static_item
    \\    name: (identifier) @name) @definition
    \\]
;

const ts_query_go =
    \\[
    \\  (function_declaration
    \\    name: (identifier) @name) @definition
    \\  (method_declaration
    \\    name: (field_identifier) @name) @definition
    \\  (type_declaration
    \\    (type_spec
    \\      name: (type_identifier) @name)) @definition
    \\  (const_declaration
    \\    (const_spec
    \\      name: (identifier) @name)) @definition
    \\  (var_declaration
    \\    (var_spec
    \\      name: (identifier) @name)) @definition
    \\]
;

const ts_query_zig_lang =
    \\[
    \\  (TopLevelDecl
    \\    (FnDecl
    \\      (IDENTIFIER) @name)) @definition
    \\  (VarDecl
    \\    (IDENTIFIER) @name) @definition
    \\]
;

const ts_query_java =
    \\[
    \\  (class_declaration
    \\    name: (identifier) @name) @definition
    \\  (interface_declaration
    \\    name: (identifier) @name) @definition
    \\  (method_declaration
    \\    name: (identifier) @name) @definition
    \\  (enum_declaration
    \\    name: (identifier) @name) @definition
    \\  (record_declaration
    \\    name: (identifier) @name) @definition
    \\]
;

/// Map a file extension to a tree-sitter language and query source.
fn languageForExtension(ext: []const u8) ?LanguageQuery {
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx"))
    {
        return .{ .language = tree_sitter_typescript(), .query_source = ts_query_typescript };
    }
    if (std.mem.eql(u8, ext, ".py")) {
        return .{ .language = tree_sitter_python(), .query_source = ts_query_python };
    }
    if (std.mem.eql(u8, ext, ".rs")) {
        return .{ .language = tree_sitter_rust(), .query_source = ts_query_rust };
    }
    if (std.mem.eql(u8, ext, ".go")) {
        return .{ .language = tree_sitter_go(), .query_source = ts_query_go };
    }
    if (std.mem.eql(u8, ext, ".zig")) {
        return .{ .language = tree_sitter_zig(), .query_source = ts_query_zig_lang };
    }
    if (std.mem.eql(u8, ext, ".java")) {
        return .{ .language = tree_sitter_java(), .query_source = ts_query_java };
    }
    return null;
}

/// Check if a named symbol exists in the given source file using tree-sitter.
/// Returns true if the symbol is found, false otherwise.
fn resolveSymbolWithTreeSitter(source: []const u8, lang_query: LanguageQuery, target_symbol: []const u8) bool {
    const parser = ts.Parser.create();
    defer parser.destroy();

    parser.setLanguage(lang_query.language) catch return false;

    const tree = parser.parseString(source, null) orelse return false;
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang_query.language, lang_query.query_source, &error_offset) catch return false;
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    while (cursor.nextMatch()) |match| {
        for (match.captures) |capture| {
            const capture_name = query.captureNameForId(capture.index) orelse continue;
            if (std.mem.eql(u8, capture_name, "name")) {
                const node_text = source[capture.node.startByte()..capture.node.endByte()];
                if (std.mem.eql(u8, node_text, target_symbol)) {
                    return true;
                }
            }
        }
    }

    return false;
}

const Spec = struct {
    path: []const u8,
    bindings: std.ArrayList([]const u8),

    fn deinit(self: *Spec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.bindings.items) |b| allocator.free(b);
        self.bindings.deinit(allocator);
    }
};

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
    try walkForSpecs(allocator, root_dir, "", &specs);

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

const VcsKind = enum { git, jj };

/// Detect whether the current working directory uses jj or git.
/// Prefers jj (checks `.jj/` first), falls back to git.
fn detectVcs() VcsKind {
    std.fs.cwd().access(".jj", .{}) catch {
        return .git;
    };
    return .jj;
}

const skip_dirs = [_][]const u8{ ".git", ".jj", "node_modules", "vendor", ".zig-cache" };

fn shouldSkipDir(name: []const u8) bool {
    // Skip hidden directories (starting with '.')
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

fn walkForSpecs(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, specs: *std.ArrayList(Spec)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.name)) continue;

            const sub_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(sub_prefix);

            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkForSpecs(allocator, sub_dir, sub_prefix, specs);
        } else if (entry.kind == .file) {
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const file_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

            const content = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
                allocator.free(file_path);
                continue;
            };
            defer allocator.free(content);

            if (parseDriftSpec(allocator, content)) |bindings| {
                try specs.append(allocator, .{
                    .path = file_path,
                    .bindings = bindings,
                });
            } else {
                allocator.free(file_path);
            }
        }
    }
}

/// Parse drift frontmatter from file content. Returns bindings list if this is a drift spec, null otherwise.
fn parseDriftSpec(allocator: std.mem.Allocator, content: []const u8) ?std.ArrayList([]const u8) {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse
        std.mem.indexOf(u8, after_open, "\n---") orelse return null;
    const frontmatter = after_open[0..close_offset];

    // Check for "drift:" line
    var has_drift = false;
    var in_files_section = false;
    var bindings: std.ArrayList([]const u8) = .{};

    var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.eql(u8, line, "drift:") or std.mem.startsWith(u8, line, "drift:")) {
            has_drift = true;
            continue;
        }

        if (has_drift and std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const binding_text = line["    - ".len..];
            const duped = allocator.dupe(u8, binding_text) catch continue;
            bindings.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            continue;
        }

        // Non-list-item line ends the files section
        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }
    }

    if (!has_drift) {
        for (bindings.items) |b| allocator.free(b);
        bindings.deinit(allocator);
        return null;
    }

    return bindings;
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

    const result = try unlinkBinding(allocator, content, binding);
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
        const identity = bindingFileIdentity(raw_binding);
        if (identity.len != raw_binding.len) {
            // Already has provenance (@... suffix)
            break :blk raw_binding;
        }
        // No provenance — try to auto-detect
        const cwd_path = std.fs.cwd().realpathAlloc(allocator, ".") catch break :blk raw_binding;
        defer allocator.free(cwd_path);

        const vcs = detectVcs();
        const change_id = getCurrentChangeId(allocator, cwd_path, vcs) catch break :blk raw_binding;
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

    const result = try linkBinding(allocator, content, binding);
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

/// Extract the file identity from a binding string: strip `@change` suffix but keep `#Symbol`.
/// E.g. "src/file.ts@abc" -> "src/file.ts", "src/lib.ts#Foo@abc" -> "src/lib.ts#Foo"
fn bindingFileIdentity(binding: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, binding, '@')) |at_pos| {
        return binding[0..at_pos];
    }
    return binding;
}

/// Core logic: given file content and a binding, produce new file content with the binding added/updated.
fn linkBinding(allocator: std.mem.Allocator, content: []const u8, binding: []const u8) ![]const u8 {
    const new_identity = bindingFileIdentity(binding);

    // Check if file has YAML frontmatter (starts with "---\n")
    if (std.mem.startsWith(u8, content, "---\n")) {
        // Find the closing "---\n"
        const after_open = content[4..];
        if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
            // close_offset is index in after_open where "\n---\n" starts
            const frontmatter = after_open[0..close_offset]; // text between the two ---
            const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

            // Process the frontmatter lines
            var output: std.ArrayList(u8) = .{};
            defer output.deinit(allocator);
            const writer = output.writer(allocator);

            try writer.writeAll("---\n");

            var found_existing = false;
            var in_files_section = false;
            var wrote_binding = false;
            var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

            while (lines_iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "  files:")) {
                    in_files_section = true;
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
                    const existing_binding = line["    - ".len..];
                    const existing_identity = bindingFileIdentity(existing_binding);

                    if (std.mem.eql(u8, existing_identity, new_identity)) {
                        // Replace this line with the new binding
                        try writer.print("    - {s}\n", .{binding});
                        found_existing = true;
                        wrote_binding = true;
                        continue;
                    }
                    // Keep the existing line
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                // If we were in files section and hit a non-list line, we left it
                if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
                    // Before leaving files section, append new binding if not found
                    if (!found_existing and !wrote_binding) {
                        try writer.print("    - {s}\n", .{binding});
                        wrote_binding = true;
                    }
                    in_files_section = false;
                }

                try writer.writeAll(line);
                try writer.writeByte('\n');
            }

            // If we were still in files section at end of frontmatter, append
            if (!wrote_binding) {
                try writer.print("    - {s}\n", .{binding});
            }

            try writer.writeAll("---\n");

            // Append the body
            if (body_start <= content.len) {
                try writer.writeAll(content[body_start..]);
            }

            return try allocator.dupe(u8, output.items);
        }
    }

    // No frontmatter found: prepend a complete frontmatter block
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    try writer.writeAll("drift:\n");
    try writer.writeAll("  files:\n");
    try writer.print("    - {s}\n", .{binding});
    try writer.writeAll("---\n");
    try writer.writeAll(content);

    return try allocator.dupe(u8, output.items);
}

// --- unlink command ---

const UnlinkResult = struct {
    content: []const u8,
    removed: bool,
};

/// Core logic: given file content and a binding, produce new file content with the binding removed.
/// Matches on file identity (stripping @provenance from both the existing binding and the argument).
fn unlinkBinding(allocator: std.mem.Allocator, content: []const u8, binding: []const u8) !UnlinkResult {
    const target_identity = bindingFileIdentity(binding);

    // Must have YAML frontmatter to contain bindings
    if (!std.mem.startsWith(u8, content, "---\n")) {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    }

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    };

    const frontmatter = after_open[0..close_offset];
    const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");

    var removed = false;
    var in_files_section = false;
    var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const existing_binding = line["    - ".len..];
            const existing_identity = bindingFileIdentity(existing_binding);

            if (std.mem.eql(u8, existing_identity, target_identity)) {
                // Skip this line (remove the binding)
                removed = true;
                continue;
            }
        }

        // Non-list-item line ends the files section
        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }

        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    try writer.writeAll("---\n");

    // Append the body
    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }

    return .{ .content = try allocator.dupe(u8, output.items), .removed = removed };
}

// --- unit tests for unlinkBinding ---

test "unlinkBinding removes matching binding" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n    - src/b.ts\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/a.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/b.ts") != null);
}

test "unlinkBinding matches by file identity ignoring provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@abc123\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/file.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/file.ts") == null);
}

test "unlinkBinding returns removed=false when binding not found" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/missing.ts");
    defer allocator.free(result.content);
    try std.testing.expect(!result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") != null);
}

test "unlinkBinding removes symbol binding" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/lib.ts#Foo\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/lib.ts#Foo");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/lib.ts#Foo") == null);
}

// --- unit tests for linkBinding ---

test "linkBinding adds binding to empty files list" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n---\n# Spec\n";
    const result = try linkBinding(allocator, content, "src/new.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Spec") != null);
}

test "linkBinding updates existing binding provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@old\n---\n# Spec\n";
    const result = try linkBinding(allocator, content, "src/file.ts@new");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@new") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@old") == null);
}

test "linkBinding adds frontmatter to plain markdown" {
    const allocator = std.testing.allocator;
    const content = "# Just a plain markdown file\n\nSome content.\n";
    const result = try linkBinding(allocator, content, "src/target.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "drift:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/target.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Just a plain markdown file") != null);
}
