const std = @import("std");
const build_options = @import("build_options");
const drift_check_v1 = @import("payload");
const CommandContext = @import("../context.zig").CommandContext;
const Config = @import("../Config.zig");
const lockfile = @import("../lockfile.zig");
const markdown = @import("../markdown.zig");
const repo_map = @import("../repo_map.zig");
const symbols = @import("../symbols.zig");
const target = @import("../target.zig");
const vcs = @import("../vcs.zig");

pub const Format = enum { text, json };
pub const RunStatus = enum { pass, fail };
pub const RunError = error{LintCheckFailed};

const FileCache = struct {
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    current: std.StringHashMap([]const u8),

    fn init(self: *FileCache, io: std.Io, parent: std.mem.Allocator) void {
        self.io = io;
        self.arena = std.heap.ArenaAllocator.init(parent);
        self.current = std.StringHashMap([]const u8).init(self.arena.allocator());
    }

    fn deinit(self: *FileCache) void {
        self.current.deinit();
        self.arena.deinit();
    }

    fn getCurrent(self: *FileCache, absolute_path: []const u8) !?[]const u8 {
        if (self.current.get(absolute_path)) |content| return content;

        const file = std.Io.Dir.openFileAbsolute(self.io, absolute_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(self.io);

        const a = self.arena.allocator();
        var file_reader = file.reader(self.io, &.{});
        const content = try file_reader.interface.allocRemaining(a, .limited(1024 * 1024));
        const key = try a.dupe(u8, absolute_path);
        try self.current.put(key, content);
        return content;
    }
};

const AnchorResult = enum { fresh, stale, skip };
const LinkResult = enum { ok, broken };
const DocResult = enum { fresh, stale, skip, broken };

const ReasonCode = enum {
    none,
    changed_after_baseline,
    file_not_found,
    file_not_readable,
    symbol_not_found,
    fingerprint_unavailable,
    baseline_unavailable,
    origin_mismatch,
    mapped_repo_missing,
    link_target_not_found,
};

fn reasonMessage(code: ReasonCode) []const u8 {
    return switch (code) {
        .none => "",
        .changed_after_baseline => "changed after doc",
        .file_not_found => "file not found",
        .file_not_readable => "file not readable",
        .symbol_not_found => "symbol not found",
        .fingerprint_unavailable => "cannot compute fingerprint",
        .baseline_unavailable => "baseline unavailable",
        .origin_mismatch => "origin mismatch",
        .mapped_repo_missing => "mapped repo missing",
        .link_target_not_found => "link target not found",
    };
}

fn anchorResultStr(r: AnchorResult) []const u8 {
    return switch (r) {
        .fresh => "fresh",
        .stale => "stale",
        .skip => "skip",
    };
}

fn docResultStr(r: DocResult) []const u8 {
    return switch (r) {
        .fresh => "fresh",
        .stale => "stale",
        .skip => "skip",
        .broken => "broken",
    };
}

fn linkResultStr(r: LinkResult) []const u8 {
    return switch (r) {
        .ok => "ok",
        .broken => "broken",
    };
}

const JsonAnchorRow = struct {
    blame_storage: ?vcs.BlameInfo,
    /// Root the anchor was checked against: the scope root, or the mapped
    /// sibling checkout when the binding's origin was resolved via `--repo`.
    /// Blame queries in phase 2 run with this directory as cwd.
    effective_root: []const u8,
    wire: drift_check_v1.Anchor,
};

const JsonLinkRow = struct {
    display_target: []const u8,
    wire: drift_check_v1.Link,
};

const DocCheckResult = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: DocResult,
    anchors: std.ArrayList(JsonAnchorRow),
    links: std.ArrayList(JsonLinkRow),
    /// Populated when `checkBinding` fails for a binding in this doc. The main
    /// thread re-raises this as `error.LintCheckFailed` during the merge step,
    /// since `Io.Group.async` cannot propagate errors out of tasks.
    error_message: ?[]const u8 = null,
};

pub const CheckResult = struct {
    repo: ?[]const u8,
    checked_at_ms: i64,
    docs: std.ArrayList(DocCheckResult),
    failed: bool,
    docs_total: u32,
    docs_fresh: u32,
    docs_stale: u32,
    docs_skipped: u32,
    anchors_total: u32,
    anchors_fresh: u32,
    anchors_stale: u32,
    anchors_skipped: u32,
    links_total: u32,
    links_broken: u32,

    pub fn status(self: *const CheckResult) RunStatus {
        return if (self.failed) .fail else .pass;
    }

    fn docsChecked(self: *const CheckResult) u32 {
        return self.docs_fresh + self.docs_stale;
    }

    fn checkedAny(self: *const CheckResult) bool {
        return self.docs.items.len > 0;
    }

    fn verificationState(self: *const CheckResult) []const u8 {
        const checked = self.docsChecked();
        if (self.docs_total > 0 and checked == 0) return "none";
        if (checked > 0 and self.docs_skipped > 0) return "partial";
        return "full";
    }
};

const AnchorOutcome = struct {
    result: AnchorResult,
    reason_code: ReasonCode,
    blame: ?vcs.BlameInfo = null,
};

const DocGroup = struct {
    path: []const u8,
    bindings: std.ArrayList(*lockfile.Binding),
};

pub fn run(
    ctx: CommandContext,
    stdout_w: *std.Io.Writer,
    stderr_w: *std.Io.Writer,
    format: Format,
    changed_path: ?[]const u8,
    repo_entries: []const repo_map.Entry,
) !RunStatus {
    const result = try compute(ctx, stderr_w, changed_path, repo_entries);
    switch (format) {
        .text => try renderText(stdout_w, &result),
        .json => try renderJson(ctx.run_arena, stdout_w, &result),
    }
    return result.status();
}

/// Run the lint check and return the computed result. Rendering is a separate
/// step so callers (e.g. `--silent` mode in `main`) can choose where — and
/// whether — to print the report based on the exit status.
///
/// All allocations live in `ctx.run_arena`; the caller is responsible for the
/// arena's lifetime.
pub fn compute(
    ctx: CommandContext,
    stderr_w: *std.Io.Writer,
    changed_path: ?[]const u8,
    repo_entries: []const repo_map.Entry,
) !CheckResult {
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.run_arena);

    const lf = try lockfile.discover(ctx.io, ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    // Kick off the `git remote get-url origin` query and the config read
    // concurrently with the `git ls-files` run inside `discoverDocGroups`.
    // All three are independent, so the subprocesses and the file read overlap.
    var identity_future = ctx.io.async(vcs.getRepoIdentity, .{ ctx.io, ctx.run_arena, ctx.run_arena, cwd_path });
    defer _ = identity_future.cancel(ctx.io);

    var config_diagnostics: Config.Diagnostics = .{};
    var config_future = ctx.io.async(Config.load, .{ ctx.io, ctx.run_arena, lf.root_path, &config_diagnostics });
    defer if (config_future.cancel(ctx.io)) |_| {} else |_| {};

    var doc_groups = try discoverDocGroups(ctx.io, ctx.run_arena, lf.root_path, lf.bindings.items);
    defer {
        for (doc_groups.items) |*doc| doc.bindings.deinit(ctx.run_arena);
        doc_groups.deinit(ctx.run_arena);
    }

    const config = config_future.await(ctx.io) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reportConfigError(stderr_w, err, config_diagnostics.line_number);
            return error.LintCheckFailed;
        },
    };

    // Built once and shared read-only across the per-doc tasks below. Flag
    // entries win over config entries on duplicate origins; flag paths resolve
    // against cwd, config paths against the lockfile root (docs/CLI.md).
    const mapped_repos = try repo_map.RepoMap.buildMerged(ctx.run_arena, repo_entries, cwd_path, config.repos, lf.root_path);

    const detected_vcs = vcs.detectVcs();
    const repo_identity = identity_future.await(ctx.io);

    const normalized_changed = if (changed_path) |raw|
        try normalizeChangedPrefix(ctx, lf.root_path, cwd_path, raw)
    else
        null;

    var result: CheckResult = .{
        .repo = repo_identity,
        .checked_at_ms = std.Io.Timestamp.now(ctx.io, .real).toMilliseconds(),
        .docs = .empty,
        .failed = false,
        .docs_total = 0,
        .docs_fresh = 0,
        .docs_stale = 0,
        .docs_skipped = 0,
        .anchors_total = 0,
        .anchors_fresh = 0,
        .anchors_stale = 0,
        .anchors_skipped = 0,
        .links_total = 0,
        .links_broken = 0,
    };

    // Pre-allocate one result slot per doc so each task writes into disjoint
    // memory. Tasks produce results independently; we merge in doc-order on
    // the main thread below to preserve deterministic output.
    const results = try ctx.run_arena.alloc(?DocCheckResult, doc_groups.items.len);
    @memset(results, null);

    var group: std.Io.Group = .init;
    defer group.cancel(ctx.io);

    for (doc_groups.items, 0..) |doc, i| {
        if (normalized_changed) |prefix| {
            if (!docMatchesChangedPath(doc, prefix)) continue;
        }
        group.async(ctx.io, checkOneDoc, .{
            ctx.io,
            ctx.run_arena,
            lf.root_path,
            doc,
            detected_vcs,
            repo_identity,
            &mapped_repos,
            &results[i],
        });
    }
    try group.await(ctx.io);

    for (results) |maybe| {
        const doc_result = maybe orelse continue;
        if (doc_result.error_message) |msg| {
            stderr_w.print("{s}", .{msg}) catch {};
            return error.LintCheckFailed;
        }
        mergeDocResult(ctx.run_arena, &result, doc_result) catch |err| return err;
    }

    return result;
}

/// Prints a human-readable diagnostic for a `.drift/config.toml` load failure.
/// The caller turns the failure into `error.LintCheckFailed` so `main` exits 1
/// without printing a second, less specific message.
fn reportConfigError(stderr_w: *std.Io.Writer, err: Config.LoadError, line_number: usize) void {
    const detail: []const u8 = switch (err) {
        error.ConfigRepoInvalid => "invalid [[repos]] entry: need origin = \"github:owner/repo\" and a non-empty path",
        error.ConfigSyntax => "syntax error",
        error.ConfigUnknownKey => "unknown key",
        error.ConfigUnknownTable => "unknown table",
        error.ConfigUnreadable => "file not readable",
        error.ConfigVersionMissing => "missing 'version = 1' header",
        error.ConfigVersionUnsupported => "unsupported config version",
        error.OutOfMemory => "out of memory",
    };
    if (line_number > 0) {
        stderr_w.print("error: .drift/config.toml:{d}: {s}\n", .{ line_number, detail }) catch {};
    } else {
        stderr_w.print("error: .drift/config.toml: {s}\n", .{detail}) catch {};
    }
}

/// Write the text report for an already-computed result. Safe to call more
/// than once (e.g. to stdout under normal conditions and to stderr when
/// `--silent` runs fail).
pub fn renderText(w: *std.Io.Writer, result: *const CheckResult) !void {
    try writeResultsText(w, result, result.checkedAny());
}

/// Write the JSON report for an already-computed result.
pub fn renderJson(run_alloc: std.mem.Allocator, w: *std.Io.Writer, result: *const CheckResult) !void {
    try writeResultsJson(run_alloc, w, result);
}

/// Per-doc check task, spawned once per `DocGroup` inside `Io.Group`.
///
/// Creates a task-local scratch arena and task-local `FileCache` so tasks do
/// not contend on shared state. The `run_arena` allocator is threadsafe (see
/// `std.heap.ArenaAllocator`), so persistent allocations (anchor rows, link
/// rows, strings) go there. Errors from `checkBinding` are stored on `out`
/// (via `error_message`) and re-raised by the main thread during merge —
/// `Io.Group.async` cannot propagate errors back out of a task.
fn checkOneDoc(
    io: std.Io,
    run_arena: std.mem.Allocator,
    root_path: []const u8,
    doc: DocGroup,
    detected_vcs: vcs.VcsKind,
    repo_identity: ?[]const u8,
    mapped_repos: *const repo_map.RepoMap,
    out: *?DocCheckResult,
) void {
    checkOneDocInner(io, run_arena, root_path, doc, detected_vcs, repo_identity, mapped_repos, out) catch |err| {
        // Persist the failure into the result slot so the main thread can
        // surface it as `error.LintCheckFailed` after `group.await`.
        const msg = std.fmt.allocPrint(run_arena, "error checking doc {s}: {s}\n", .{ doc.path, @errorName(err) }) catch "error checking doc (out of memory)\n";
        out.* = DocCheckResult{
            .path = doc.path,
            .origin = null,
            .result = .broken,
            .anchors = .empty,
            .links = .empty,
            .error_message = msg,
        };
    };
}

fn checkOneDocInner(
    io: std.Io,
    run_arena: std.mem.Allocator,
    root_path: []const u8,
    doc: DocGroup,
    detected_vcs: vcs.VcsKind,
    repo_identity: ?[]const u8,
    mapped_repos: *const repo_map.RepoMap,
    out: *?DocCheckResult,
) !void {
    var task_scratch = std.heap.ArenaAllocator.init(run_arena);
    defer task_scratch.deinit();

    const task_ctx = CommandContext{
        .io = io,
        .run_arena = run_arena,
        .scratch_arena = &task_scratch,
    };

    var file_cache: FileCache = undefined;
    file_cache.init(io, run_arena);
    defer file_cache.deinit();

    var doc_result = DocCheckResult{
        .path = doc.path,
        .origin = commonOrigin(doc.bindings.items),
        .result = .fresh,
        .anchors = .empty,
        .links = .empty,
    };

    var fresh_count: usize = 0;
    var stale_count: usize = 0;
    var skip_count: usize = 0;

    // Phase 1: determine staleness per binding. CPU-bound (tree-sitter parse +
    // fingerprint). `checkBinding` no longer fetches blame — that's phase 2.
    for (doc.bindings.items) |binding| {
        task_ctx.resetScratch();
        const parsed = target.parse(binding.target);
        const origin = binding.fieldValue("origin");

        var effective_root = root_path;
        const outcome = blk: {
            if (origin) |o| {
                const is_local = if (repo_identity) |ri| std.mem.eql(u8, o, ri) else false;
                if (!is_local) {
                    // A foreign origin is checkable when `--repo` maps it to a
                    // local sibling checkout that exists on disk. Fingerprints
                    // (and phase-2 blame) then compute against that checkout.
                    const mapped_root = mapped_repos.resolve(o) orelse
                        break :blk AnchorOutcome{ .result = .skip, .reason_code = .origin_mismatch };
                    if (!pathExists(io, mapped_root)) {
                        // Mapped but absent (e.g. a teammate without the
                        // checkout): skip instead of reporting stale.
                        break :blk AnchorOutcome{ .result = .skip, .reason_code = .mapped_repo_missing };
                    }
                    effective_root = mapped_root;
                }
            }
            break :blk checkBinding(task_ctx, effective_root, binding, parsed, &file_cache) catch |err| {
                const msg = try std.fmt.allocPrint(run_arena, "error checking {s}: {s}\n", .{ binding.target, @errorName(err) });
                doc_result.error_message = msg;
                out.* = doc_result;
                return;
            };
        };

        try doc_result.anchors.append(run_arena, jsonAnchorFromOutcome(binding.target, binding.fieldValue("sig"), parsed, outcome, effective_root));
        switch (outcome.result) {
            .fresh => fresh_count += 1,
            .stale => stale_count += 1,
            .skip => skip_count += 1,
        }
    }

    // Phase 2: fetch blame in parallel for every `changed_after_baseline` stale
    // anchor. Each call shells out to `git log`; running them concurrently cuts
    // doc check time on docs with multiple stale anchors from N× to ~1×.
    // Previously these were serialized inside `checkBinding`.
    const BlameReturn = @typeInfo(@TypeOf(vcs.getLatestBlameInfo)).@"fn".return_type.?;
    const BlameJob = struct {
        row_index: usize,
        future: std.Io.Future(BlameReturn),
    };
    var blame_jobs: std.ArrayList(BlameJob) = .empty;
    defer blame_jobs.deinit(run_arena);

    for (doc_result.anchors.items, 0..) |row, i| {
        if (!std.mem.eql(u8, row.wire.result, "stale")) continue;
        const reason = row.wire.reason orelse continue;
        if (!std.mem.eql(u8, reason.code, @tagName(ReasonCode.changed_after_baseline))) continue;

        const future = io.async(vcs.getLatestBlameInfo, .{
            io, run_arena, run_arena, row.effective_root, row.wire.path, detected_vcs,
        });
        blame_jobs.append(run_arena, .{ .row_index = i, .future = future }) catch {
            // If we can't record the future, at least drain it so it doesn't leak.
            var drop = future;
            _ = drop.cancel(io) catch null;
            continue;
        };
    }
    for (blame_jobs.items) |*job| {
        const blame = (job.future.await(io)) catch null;
        if (blame) |b| {
            const row = &doc_result.anchors.items[job.row_index];
            row.blame_storage = b;
            row.wire.blame = .{
                .author = b.author,
                .commit = b.commit_hash,
                .date = b.date,
                .subject = b.subject,
            };
        }
    }

    try checkDocLinks(task_ctx, root_path, doc.path, &file_cache, &doc_result.links);

    var broken_links: usize = 0;
    for (doc_result.links.items) |link| {
        if (std.mem.eql(u8, link.wire.result, "broken")) broken_links += 1;
    }

    doc_result.result = if (broken_links > 0)
        .broken
    else if (stale_count > 0)
        .stale
    else if (fresh_count == 0 and skip_count > 0)
        .skip
    else
        .fresh;

    out.* = doc_result;
}

fn mergeDocResult(run_arena: std.mem.Allocator, result: *CheckResult, doc_result: DocCheckResult) !void {
    var broken_links: usize = 0;
    for (doc_result.links.items) |link| {
        if (std.mem.eql(u8, link.wire.result, "broken")) broken_links += 1;
    }
    var fresh_anchors: usize = 0;
    var stale_anchors: usize = 0;
    var skip_anchors: usize = 0;
    for (doc_result.anchors.items) |row| {
        const r = row.wire.result;
        if (std.mem.eql(u8, r, "fresh")) fresh_anchors += 1 //
        else if (std.mem.eql(u8, r, "stale")) stale_anchors += 1 //
        else if (std.mem.eql(u8, r, "skip")) skip_anchors += 1;
    }

    result.docs_total += 1;
    result.anchors_total += @intCast(doc_result.anchors.items.len);
    result.anchors_fresh += @intCast(fresh_anchors);
    result.anchors_stale += @intCast(stale_anchors);
    result.anchors_skipped += @intCast(skip_anchors);
    result.links_total += @intCast(doc_result.links.items.len);
    result.links_broken += @intCast(broken_links);

    switch (doc_result.result) {
        .fresh => result.docs_fresh += 1,
        .skip => result.docs_skipped += 1,
        .stale, .broken => {
            result.docs_stale += 1;
            result.failed = true;
        },
    }
    if (broken_links > 0) result.failed = true;

    try result.docs.append(run_arena, doc_result);
}

fn discoverDocGroups(
    io: std.Io,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    bindings: []lockfile.Binding,
) !std.ArrayList(DocGroup) {
    var docs: std.ArrayList(DocGroup) = .empty;
    errdefer {
        for (docs.items) |*doc| doc.bindings.deinit(allocator);
        docs.deinit(allocator);
    }

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .cwd = .{ .path = root_path },
        .stdout_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var offset: usize = 0;
    while (offset < result.stdout.len) {
        const rest = result.stdout[offset..];
        const rel_end = std.mem.findScalar(u8, rest, 0) orelse break;
        const line = rest[0..rel_end];
        offset += rel_end + 1;

        if (!std.mem.endsWith(u8, line, ".md")) continue;
        if (hasNestedLockfile(io, root_path, line, allocator)) continue;
        _ = try ensureDocGroup(allocator, &docs, line);
    }

    for (bindings) |*binding| {
        const doc = try ensureDocGroup(allocator, &docs, binding.doc_path);
        try doc.bindings.append(allocator, binding);
    }

    std.mem.sort(DocGroup, docs.items, {}, struct {
        fn lessThan(_: void, a: DocGroup, b: DocGroup) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    for (docs.items) |*doc| {
        std.mem.sort(*lockfile.Binding, doc.bindings.items, {}, struct {
            fn lessThan(_: void, a: *lockfile.Binding, b: *lockfile.Binding) bool {
                return std.mem.order(u8, a.target, b.target) == .lt;
            }
        }.lessThan);
    }

    return docs;
}

/// Check if a relative path has a closer drift.lock than root_path.
/// Returns true if there's an intermediate drift.lock (the file belongs to a nested scope).
fn hasNestedLockfile(io: std.Io, root_path: []const u8, rel_path: []const u8, allocator: std.mem.Allocator) bool {
    var dir: []const u8 = std.Io.Dir.path.dirname(rel_path) orelse return false;

    while (dir.len > 0) {
        const candidate = std.Io.Dir.path.join(allocator, &.{ root_path, dir, "drift.lock" }) catch return false;
        if (pathExists(io, candidate)) return true;
        dir = std.Io.Dir.path.dirname(dir) orelse break;
    }
    return false;
}

fn ensureDocGroup(
    allocator: std.mem.Allocator,
    docs: *std.ArrayList(DocGroup),
    path: []const u8,
) !*DocGroup {
    for (docs.items) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }

    try docs.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .bindings = .empty,
    });
    return &docs.items[docs.items.len - 1];
}

fn commonOrigin(bindings: []const *lockfile.Binding) ?[]const u8 {
    if (bindings.len == 0) return null;
    const first = bindings[0].fieldValue("origin") orelse return null;
    for (bindings[1..]) |binding| {
        const origin = binding.fieldValue("origin") orelse return null;
        if (!std.mem.eql(u8, origin, first)) return null;
    }
    return first;
}

fn checkDocLinks(
    ctx: CommandContext,
    root_path: []const u8,
    doc_path: []const u8,
    file_cache: *FileCache,
    out: *std.ArrayList(JsonLinkRow),
) !void {
    const absolute_doc_path = try std.Io.Dir.path.join(ctx.scratch(), &.{ root_path, doc_path });
    const content = file_cache.getCurrent(absolute_doc_path) catch return orelse return;

    var parsed = (try markdown.parseDocument(ctx.run_arena, content)) orelse return;
    defer parsed.deinit();

    if (parsed.links.items.len == 0) return;

    // Resolve the doc's real path once; every link check needs the same dir.
    const raw_absolute_doc = try std.Io.Dir.path.resolve(ctx.run_arena, &.{ root_path, doc_path });
    const real_doc_path = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, raw_absolute_doc, ctx.run_arena) catch raw_absolute_doc;
    const doc_dir = std.Io.Dir.path.dirname(real_doc_path) orelse root_path;

    // Parallelize link-existence checks. Each task is a `statFile` syscall
    // wrapped in `pathExists`. On docs with many cross-doc links this
    // collapses N sequential stats into a single pool round-trip.
    const slots = try ctx.run_arena.alloc(?JsonLinkRow, parsed.links.items.len);
    @memset(slots, null);

    var group: std.Io.Group = .init;
    defer group.cancel(ctx.io);

    for (parsed.links.items, slots) |link, *slot| {
        group.async(ctx.io, classifyLinkTask, .{
            ctx.io, ctx.run_arena, root_path, doc_dir, link, slot,
        });
    }
    try group.await(ctx.io);

    for (slots) |maybe_row| {
        const row = maybe_row orelse continue;
        try out.append(ctx.run_arena, row);
    }
}

fn classifyLinkTask(
    io: std.Io,
    run_arena: std.mem.Allocator,
    root_path: []const u8,
    doc_dir: []const u8,
    link: markdown.Link,
    slot: *?JsonLinkRow,
) void {
    const trimmed = std.mem.trim(u8, link.target, " \t\r\n");
    if (trimmed.len == 0) return;
    if (trimmed[0] == '#') return;
    if (std.Io.Dir.path.isAbsolute(trimmed)) return;
    if (hasUriScheme(trimmed)) return;

    const path_part = if (std.mem.findScalar(u8, trimmed, '#')) |idx| trimmed[0..idx] else trimmed;
    if (path_part.len == 0) return;

    const absolute = std.Io.Dir.path.resolve(run_arena, &.{ doc_dir, path_part }) catch return;
    const relative = std.Io.Dir.path.relative(run_arena, "", null, root_path, absolute) catch return;
    const exists = pathExists(io, absolute);

    slot.* = .{
        .display_target = relative,
        .wire = .{
            .target = link.target,
            .line = link.line,
            .result = linkResultStr(if (exists) .ok else .broken),
            .reason = if (exists) null else driftReason(.link_target_not_found),
        },
    };
}

fn hasUriScheme(target_text: []const u8) bool {
    var i: usize = 0;
    while (i < target_text.len) : (i += 1) {
        const c = target_text[i];
        if (c == '/' or c == '?' or c == '#') return false;
        if (c == ':') return i > 0;
    }
    return false;
}

fn filePathMatchesChangedPrefix(file_path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, file_path, prefix)) return false;
    if (file_path.len == prefix.len) return true;
    return std.Io.Dir.path.isSep(file_path[prefix.len]);
}

fn docMatchesChangedPath(doc: DocGroup, changed_prefix: []const u8) bool {
    if (filePathMatchesChangedPrefix(doc.path, changed_prefix)) return true;
    for (doc.bindings.items) |binding| {
        const parsed = target.parse(binding.target);
        if (filePathMatchesChangedPrefix(parsed.file_path, changed_prefix)) return true;
    }
    return false;
}

fn normalizeChangedPrefix(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    raw_path: []const u8,
) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(raw_path)) {
        return try std.Io.Dir.path.relative(ctx.run_arena, "", null, root_path, raw_path);
    }

    const absolute = try std.Io.Dir.path.resolve(ctx.scratch(), &.{ cwd_path, raw_path });
    const relative = try std.Io.Dir.path.relative(ctx.run_arena, "", null, root_path, absolute);
    ctx.resetScratch();
    return relative;
}

fn checkBinding(
    ctx: CommandContext,
    root_path: []const u8,
    binding: *const lockfile.Binding,
    parsed: target.ParsedTarget,
    file_cache: *FileCache,
) !AnchorOutcome {
    const sig_hex = binding.fieldValue("sig") orelse return .{ .result = .stale, .reason_code = .baseline_unavailable };

    const absolute_path = try std.Io.Dir.path.join(ctx.scratch(), &.{ root_path, parsed.file_path });
    const current_content = file_cache.getCurrent(absolute_path) catch {
        return .{ .result = .stale, .reason_code = .file_not_readable };
    } orelse {
        return .{ .result = .stale, .reason_code = .file_not_found };
    };

    if (parsed.symbol_name) |sym| {
        if (parsed.isHeading()) {
            if (!markdown.headingExists(current_content, sym)) {
                return .{ .result = .stale, .reason_code = .symbol_not_found };
            }
        } else {
            const ext = std.Io.Dir.path.extension(parsed.file_path);
            if (symbols.languageForExtension(ext)) |lang_query| {
                if (!symbols.resolveSymbolWithTreeSitter(current_content, lang_query, sym)) {
                    return .{ .result = .stale, .reason_code = .symbol_not_found };
                }
            }
        }
    }

    const fingerprint = symbols.computeFingerprint(current_content, parsed.file_path, parsed.symbol_name) orelse {
        return .{ .result = .stale, .reason_code = .fingerprint_unavailable };
    };

    var hex_buf: [16]u8 = undefined;
    const current_hex = try std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{fingerprint});
    if (std.mem.eql(u8, current_hex, sig_hex)) {
        return .{ .result = .fresh, .reason_code = .none };
    }

    // Blame lookup happens in a second parallel phase in `checkOneDocInner`.
    // Leaving it unset here so multiple stale anchors in the same doc don't
    // serialize on one-at-a-time `git log` invocations.
    return .{ .result = .stale, .reason_code = .changed_after_baseline };
}

fn driftProvenance(sig: ?[]const u8) ?drift_check_v1.Provenance {
    if (sig) |value| {
        return .{ .kind = "sig", .value = value };
    }
    return null;
}

fn driftReason(code: ReasonCode) ?drift_check_v1.Reason {
    if (code == .none) return null;
    return .{ .code = @tagName(code), .message = reasonMessage(code) };
}

fn jsonAnchorFromOutcome(raw_target: []const u8, sig: ?[]const u8, parsed: target.ParsedTarget, outcome: AnchorOutcome, effective_root: []const u8) JsonAnchorRow {
    const blame_storage = outcome.blame;
    return .{
        .blame_storage = blame_storage,
        .effective_root = effective_root,
        .wire = .{
            .identity = parsed.identity,
            .raw = raw_target,
            .kind = parsed.kind(),
            .path = parsed.file_path,
            .symbol = parsed.symbol_name,
            .provenance = driftProvenance(sig),
            .result = anchorResultStr(outcome.result),
            .reason = driftReason(outcome.reason_code),
            .blame = if (blame_storage) |b| drift_check_v1.Blame{
                .author = b.author,
                .commit = b.commit_hash,
                .date = b.date,
                .subject = b.subject,
            } else null,
        },
    };
}

fn writeResultsText(w: *std.Io.Writer, result: *const CheckResult, checked_any: bool) !void {
    if (!checked_any) {
        try w.writeAll("ok\n");
        return;
    }

    for (result.docs.items, 0..) |doc, doc_index| {
        try w.print("{s}\n", .{doc.path});

        for (doc.anchors.items) |row| {
            textEmitAnchor(w, doc.origin, row.wire, row.blame_storage);
        }
        for (doc.links.items) |row| {
            textEmitLink(w, row.display_target, row.wire);
        }

        if (doc.result == .fresh) {
            try w.writeAll("  ok\n");
        }

        if (doc_index + 1 < result.docs.items.len) {
            try w.writeByte('\n');
        }
    }

    if (result.docs_stale > 0 or result.docs_fresh > 0 or result.links_broken > 0) {
        if (result.docs.items.len > 0) try w.writeByte('\n');
        try writeSummaryText(w, result);
        try w.writeByte('\n');
    }
}

fn textEmitAnchor(w: *std.Io.Writer, origin: ?[]const u8, row: drift_check_v1.Anchor, blame_storage: ?vcs.BlameInfo) void {
    if (std.mem.eql(u8, row.result, "stale")) {
        const msg = row.reason.?.message;
        if (msg.len > 0) {
            w.print("  STALE   {s} ({s})\n", .{ row.raw, msg }) catch {};
        } else {
            w.print("  STALE   {s}\n", .{row.raw}) catch {};
        }
        if (blame_storage) |blame| {
            w.print("          changed by {s} in {s} ({s})\n", .{ blame.author, blame.commit_hash, blame.date }) catch {};
            w.print("          \"{s}\"\n", .{blame.subject}) catch {};
        }
        return;
    }

    if (std.mem.eql(u8, row.result, "skip")) {
        const is_origin_mismatch = if (row.reason) |reason|
            std.mem.eql(u8, reason.code, @tagName(ReasonCode.origin_mismatch))
        else
            true;
        if (!is_origin_mismatch) {
            w.print("  SKIP   {s} ({s})\n", .{ row.raw, row.reason.?.message }) catch {};
        } else if (origin) |o| {
            w.print("  SKIP   {s} (origin: {s})\n", .{ row.raw, o }) catch {};
        } else {
            w.print("  SKIP   {s}\n", .{row.raw}) catch {};
        }
    }
}

fn textEmitLink(w: *std.Io.Writer, display_target: []const u8, row: drift_check_v1.Link) void {
    if (!std.mem.eql(u8, row.result, "broken")) return;
    w.print("  BROKEN  {s} ({s})\n", .{ display_target, row.reason.?.message }) catch {};
}

fn writeSummaryText(w: *std.Io.Writer, result: *const CheckResult) !void {
    var wrote_any = false;

    if (result.docs_stale > 0) {
        try w.print("{d} doc{s} stale", .{ result.docs_stale, if (result.docs_stale == 1) "" else "s" });
        wrote_any = true;
    }
    if (result.docs_fresh > 0) {
        if (wrote_any) try w.writeAll(", ");
        try w.print("{d} ok", .{result.docs_fresh});
        wrote_any = true;
    }
    if (result.links_broken > 0) {
        if (wrote_any) try w.writeAll(", ");
        try w.print("{d} broken link{s}", .{ result.links_broken, if (result.links_broken == 1) "" else "s" });
    }
}

fn writeResultsJson(run_alloc: std.mem.Allocator, w: *std.Io.Writer, result: *const CheckResult) !void {
    const doc = try checkResultToDriftCheckV1(run_alloc, result);
    try drift_check_v1.writeJson(w, doc);
}

fn checkResultToDriftCheckV1(arena: std.mem.Allocator, result: *const CheckResult) !drift_check_v1.DriftCheckV1 {
    const docs = try arena.alloc(drift_check_v1.Doc, result.docs.items.len);
    for (result.docs.items, docs) |s, *sp| {
        const anchors = try arena.alloc(drift_check_v1.Anchor, s.anchors.items.len);
        for (s.anchors.items, anchors) |row, *ap| {
            ap.* = row.wire;
        }
        const links = try arena.alloc(drift_check_v1.Link, s.links.items.len);
        for (s.links.items, links) |row, *lp| {
            lp.* = row.wire;
        }
        sp.* = .{
            .path = s.path,
            .origin = s.origin,
            .result = docResultStr(s.result),
            .anchors = anchors,
            .links = links,
        };
    }
    return .{
        .schema_version = "drift.check.v1",
        .tool = "drift",
        .tool_version = build_options.version,
        .repo = result.repo,
        .checked_at_ms = result.checked_at_ms,
        .summary = checkResultSummaryWire(result),
        .docs = docs,
    };
}

fn checkResultSummaryWire(result: *const CheckResult) drift_check_v1.Summary {
    return .{
        .result = if (result.failed) "fail" else "pass",
        .verification_state = result.verificationState(),
        .docs_total = result.docs_total,
        .docs_checked = result.docsChecked(),
        .docs_skipped = result.docs_skipped,
        .docs_fresh = result.docs_fresh,
        .docs_stale = result.docs_stale,
        .anchors_total = result.anchors_total,
        .anchors_fresh = result.anchors_fresh,
        .anchors_stale = result.anchors_stale,
        .anchors_skipped = result.anchors_skipped,
        .links_total = result.links_total,
        .links_broken = result.links_broken,
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
