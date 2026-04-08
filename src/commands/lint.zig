const std = @import("std");
const build_options = @import("build_options");
const drift_check_v1 = @import("payload");
const CommandContext = @import("../context.zig").CommandContext;
const lockfile = @import("../lockfile.zig");
const symbols = @import("../symbols.zig");
const vcs = @import("../vcs.zig");

pub const Format = enum { text, json };
pub const RunStatus = enum { pass, stale };
pub const RunError = error{LintCheckFailed};

/// Map from absolute path → current working-tree file bytes for one `lint` / `check` run.
///
/// Uses a child arena backed by `parent` so keys, values, and map metadata share one lifetime;
/// `deinit` tears down the map then resets the arena. Pass `CommandContext.run` as `parent`.
///
/// **Init:** call `init` on the address where the struct will live (`var c: FileCache = undefined; c.init(run);`).
/// Returning a new `FileCache` from a helper would leave `StringHashMap`'s allocator pointing at a
/// stack copy of `ArenaAllocator` (undefined behavior).
const FileCache = struct {
    arena: std.heap.ArenaAllocator,
    current: std.StringHashMap([]const u8),

    fn init(self: *FileCache, parent: std.mem.Allocator) void {
        self.arena = std.heap.ArenaAllocator.init(parent);
        self.current = std.StringHashMap([]const u8).init(self.arena.allocator());
    }

    fn deinit(self: *FileCache) void {
        self.current.deinit();
        self.arena.deinit();
    }

    fn getCurrent(self: *FileCache, absolute_path: []const u8) !?[]const u8 {
        if (self.current.get(absolute_path)) |content| return content;

        const file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const a = self.arena.allocator();
        const content = try file.readToEndAlloc(a, 1024 * 1024);
        const key = try a.dupe(u8, absolute_path);
        try self.current.put(key, content);
        return content;
    }
};

const AnchorResult = enum { fresh, stale, skip };

const ReasonCode = enum {
    none,
    changed_after_baseline,
    file_not_found,
    file_not_readable,
    symbol_not_found,
    fingerprint_unavailable,
    baseline_unavailable,
    origin_mismatch,
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
    };
}

fn anchorResultStr(r: AnchorResult) []const u8 {
    return switch (r) {
        .fresh => "fresh",
        .stale => "stale",
        .skip => "skip",
    };
}

const JsonAnchorRow = struct {
    blame_storage: ?vcs.BlameInfo,
    wire: drift_check_v1.Anchor,
};

const DocCheckResult = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: AnchorResult,
    anchors: std.ArrayList(JsonAnchorRow),
};

const CheckResult = struct {
    repo: ?[]const u8,
    checked_at_ms: i64,
    docs: std.ArrayList(DocCheckResult),
    summary_result: AnchorResult,
    docs_total: u32,
    docs_fresh: u32,
    docs_stale: u32,
    docs_skipped: u32,
    anchors_total: u32,
    anchors_fresh: u32,
    anchors_stale: u32,
    anchors_skipped: u32,

    fn specsChecked(self: *const CheckResult) u32 {
        return self.docs_fresh + self.docs_stale;
    }

    fn verificationState(self: *const CheckResult) []const u8 {
        const checked = self.specsChecked();
        if (self.docs_total > 0 and checked == 0) return "none";
        if (checked > 0 and self.docs_skipped > 0) return "partial";
        return "full";
    }
};

const TextSinkState = struct {
    writer: *std.io.Writer,
    summary_stale: bool = false,
};

const LintSink = union(enum) {
    text: *TextSinkState,
    json: *CheckResult,
};

const AnchorOutcome = struct {
    result: AnchorResult,
    reason_code: ReasonCode,
    blame: ?vcs.BlameInfo = null,
};

const ParsedTarget = struct {
    identity: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    provenance_kind: ?[]const u8,
    provenance_value: ?[]const u8,
};

fn parseTarget(target: []const u8, sig: ?[]const u8) ParsedTarget {
    const hash_pos = std.mem.indexOfScalar(u8, target, '#');
    const file_path = if (hash_pos) |pos| target[0..pos] else target;
    const symbol_name = if (hash_pos) |pos| target[pos + 1 ..] else null;

    return .{
        .identity = target,
        .file_path = file_path,
        .symbol_name = symbol_name,
        .provenance_kind = if (sig != null) "sig" else null,
        .provenance_value = sig,
    };
}

fn driftProvenance(parsed: ParsedTarget) ?drift_check_v1.Provenance {
    if (parsed.provenance_kind) |kind| {
        return .{ .kind = kind, .value = parsed.provenance_value.? };
    }
    return null;
}

fn driftReason(code: ReasonCode) ?drift_check_v1.Reason {
    if (code == .none) return null;
    return .{ .code = @tagName(code), .message = reasonMessage(code) };
}

fn jsonAnchorFromOutcome(target: []const u8, parsed: ParsedTarget, outcome: AnchorOutcome) JsonAnchorRow {
    const blame_storage = outcome.blame;
    return .{
        .blame_storage = blame_storage,
        .wire = .{
            .identity = parsed.identity,
            .raw = target,
            .kind = if (parsed.symbol_name != null) "symbol" else "file",
            .path = parsed.file_path,
            .symbol = parsed.symbol_name,
            .provenance = driftProvenance(parsed),
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

pub fn run(
    ctx: CommandContext,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    format: Format,
    changed_path: ?[]const u8,
) !RunStatus {
    const cwd_path = try std.fs.cwd().realpathAlloc(ctx.run_arena, ".");

    const lf = try lockfile.discover(ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    var doc_groups = try lockfile.groupByDoc(ctx.run_arena, lf.bindings.items);
    defer {
        for (doc_groups.items) |*doc| doc.bindings.deinit(ctx.run_arena);
        doc_groups.deinit(ctx.run_arena);
    }

    var parser_cache = symbols.ParserCache.init(ctx.run_arena);
    defer parser_cache.deinit();

    const detected_vcs = vcs.detectVcs();
    const repo_identity = vcs.getRepoIdentity(ctx.run_arena, ctx.scratch(), cwd_path);

    var file_cache: FileCache = undefined;
    file_cache.init(ctx.run_arena);
    defer file_cache.deinit();

    const normalized_changed = if (changed_path) |raw|
        try normalizeChangedPrefix(ctx, lf.root_path, cwd_path, raw)
    else
        null;

    var text_sink_state = TextSinkState{ .writer = stdout_w };

    var json_result: CheckResult = undefined;
    const json_result_init = format == .json;
    if (json_result_init) {
        json_result = .{
            .repo = repo_identity,
            .checked_at_ms = std.time.milliTimestamp(),
            .docs = .{},
            .summary_result = .fresh,
            .docs_total = 0,
            .docs_fresh = 0,
            .docs_stale = 0,
            .docs_skipped = 0,
            .anchors_total = 0,
            .anchors_fresh = 0,
            .anchors_stale = 0,
            .anchors_skipped = 0,
        };
    }

    const sink: LintSink = switch (format) {
        .text => .{ .text = &text_sink_state },
        .json => .{ .json = &json_result },
    };

    var checked_any = false;
    for (doc_groups.items) |doc| {
        if (normalized_changed) |prefix| {
            if (!docMatchesChangedPath(doc, prefix)) continue;
        }
        checked_any = true;
        switch (sink) {
            .text => |ts| ts.writer.print("{s}\n", .{doc.path}) catch {},
            .json => {},
        }

        var doc_result = DocCheckResult{
            .path = doc.path,
            .origin = null,
            .result = .fresh,
            .anchors = .{},
        };

        var fresh_count: usize = 0;
        var stale_count: usize = 0;
        var skip_count: usize = 0;

        for (doc.bindings.items) |binding| {
            ctx.resetScratch();

            const origin = binding.fieldValue("origin");
            const sig = binding.fieldValue("sig");
            const parsed = parseTarget(binding.target, sig);

            const outcome = blk: {
                if (origin) |o| {
                    const is_local = if (repo_identity) |ri| std.mem.eql(u8, o, ri) else false;
                    if (!is_local) break :blk AnchorOutcome{ .result = .skip, .reason_code = .origin_mismatch };
                }
                break :blk checkBinding(ctx, format, &parser_cache, lf.root_path, binding, &file_cache, detected_vcs) catch |err| {
                    stderr_w.print("error checking {s}: {s}\n", .{ binding.target, @errorName(err) }) catch {};
                    return error.LintCheckFailed;
                };
            };

            switch (sink) {
                .text => |ts| textEmitAnchor(ts.writer, origin, binding.target, outcome),
                .json => try doc_result.anchors.append(ctx.run_arena, jsonAnchorFromOutcome(binding.target, parsed, outcome)),
            }

            switch (outcome.result) {
                .fresh => fresh_count += 1,
                .stale => stale_count += 1,
                .skip => skip_count += 1,
            }
        }

        doc_result.result = if (stale_count > 0)
            .stale
        else if (skip_count > 0 and fresh_count == 0)
            .skip
        else
            .fresh;

        switch (sink) {
            .text => |ts| {
                if (stale_count == 0 and skip_count == 0) {
                    ts.writer.print("  ok\n", .{}) catch {};
                }
                if (stale_count > 0) ts.summary_stale = true;
            },
            .json => |r| {
                r.docs_total += 1;
                r.anchors_total += @intCast(doc.bindings.items.len);
                r.anchors_fresh += @intCast(fresh_count);
                r.anchors_stale += @intCast(stale_count);
                r.anchors_skipped += @intCast(skip_count);
                switch (doc_result.result) {
                    .fresh => r.docs_fresh += 1,
                    .stale => {
                        r.docs_stale += 1;
                        r.summary_result = .stale;
                    },
                    .skip => r.docs_skipped += 1,
                }
                try r.docs.append(ctx.run_arena, doc_result);
            },
        }
    }

    if (format == .text and !checked_any) {
        stdout_w.print("ok\n", .{}) catch {};
    }

    if (format == .json) {
        try writeResultsJson(ctx.run_arena, stdout_w, &json_result);
    }

    return switch (format) {
        .text => if (text_sink_state.summary_stale) .stale else .pass,
        .json => if (json_result.summary_result == .stale) .stale else .pass,
    };
}

/// True if `file_path` is exactly `prefix` or a proper subpath (next byte is a path separator). Avoids `src/auth` matching `src/authz`.
fn filePathMatchesChangedPrefix(file_path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, file_path, prefix)) return false;
    if (file_path.len == prefix.len) return true;
    return std.fs.path.isSep(file_path[prefix.len]);
}

fn docMatchesChangedPath(doc: lockfile.DocBindings, changed_prefix: []const u8) bool {
    for (doc.bindings.items) |binding| {
        const parsed = parseTarget(binding.target, null);
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
    if (std.fs.path.isAbsolute(raw_path)) {
        return try std.fs.path.relative(ctx.run_arena, root_path, raw_path);
    }

    const absolute = try std.fs.path.resolve(ctx.scratch(), &.{ cwd_path, raw_path });
    const relative = try std.fs.path.relative(ctx.run_arena, root_path, absolute);
    ctx.resetScratch();
    return relative;
}

fn checkBinding(
    ctx: CommandContext,
    format: Format,
    parser_cache: *symbols.ParserCache,
    root_path: []const u8,
    binding: *const lockfile.Binding,
    file_cache: *FileCache,
    detected_vcs: vcs.VcsKind,
) !AnchorOutcome {
    const sig_hex = binding.fieldValue("sig") orelse return .{ .result = .stale, .reason_code = .baseline_unavailable };

    const parsed = parseTarget(binding.target, sig_hex);
    const absolute_path = try std.fs.path.join(ctx.scratch(), &.{ root_path, parsed.file_path });

    const current_content = file_cache.getCurrent(absolute_path) catch {
        return .{ .result = .stale, .reason_code = .file_not_readable };
    } orelse {
        return .{ .result = .stale, .reason_code = .file_not_found };
    };

    if (parsed.symbol_name) |sym| {
        const ext = std.fs.path.extension(parsed.file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            if (!symbols.resolveSymbolWithTreeSitterCached(parser_cache, current_content, lang_query, sym)) {
                return .{ .result = .stale, .reason_code = .symbol_not_found };
            }
        }
    }

    const fingerprint = symbols.computeFingerprintCached(parser_cache, current_content, parsed.file_path, parsed.symbol_name) orelse {
        return .{ .result = .stale, .reason_code = .fingerprint_unavailable };
    };

    var hex_buf: [16]u8 = undefined;
    const current_hex = try std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{fingerprint});
    if (std.mem.eql(u8, current_hex, sig_hex)) {
        return .{ .result = .fresh, .reason_code = .none };
    }

    const blame_strings = if (format == .json) ctx.run_arena else ctx.scratch();
    const blame = try vcs.getLatestBlameInfo(blame_strings, ctx.scratch(), root_path, parsed.file_path, detected_vcs);
    return .{ .result = .stale, .reason_code = .changed_after_baseline, .blame = blame };
}

fn textEmitAnchor(
    stdout_w: *std.io.Writer,
    origin: ?[]const u8,
    target: []const u8,
    outcome: AnchorOutcome,
) void {
    switch (outcome.result) {
        .stale => {
            const msg = reasonMessage(outcome.reason_code);
            if (msg.len > 0) {
                stdout_w.print("  STALE   {s} ({s})\n", .{ target, msg }) catch {};
            } else {
                stdout_w.print("  STALE   {s}\n", .{target}) catch {};
            }
            if (outcome.blame) |blame| {
                stdout_w.print("          changed by {s} in {s} ({s})\n", .{ blame.author, blame.commit_hash, blame.date }) catch {};
                stdout_w.print("          \"{s}\"\n", .{blame.subject}) catch {};
            }
        },
        .skip => {
            if (origin) |o| {
                stdout_w.print("  SKIP   {s} (origin: {s})\n", .{ target, o }) catch {};
            } else {
                stdout_w.print("  SKIP   {s}\n", .{target}) catch {};
            }
        },
        .fresh => {},
    }
}

fn writeResultsJson(run_alloc: std.mem.Allocator, w: *std.io.Writer, result: *const CheckResult) !void {
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
        sp.* = .{
            .path = s.path,
            .origin = s.origin,
            .result = anchorResultStr(s.result),
            .anchors = anchors,
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
        .result = if (result.summary_result == .stale) "fail" else "pass",
        .verification_state = result.verificationState(),
        .docs_total = result.docs_total,
        .docs_checked = result.specsChecked(),
        .docs_skipped = result.docs_skipped,
        .docs_fresh = result.docs_fresh,
        .docs_stale = result.docs_stale,
        .anchors_total = result.anchors_total,
        .anchors_fresh = result.anchors_fresh,
        .anchors_stale = result.anchors_stale,
        .anchors_skipped = result.anchors_skipped,
    };
}
