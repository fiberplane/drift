const std = @import("std");
const build_options = @import("build_options");
const drift_check_v1 = @import("payload");
const lockfile = @import("../lockfile.zig");
const symbols = @import("../symbols.zig");
const vcs = @import("../vcs.zig");

pub const Format = enum { text, json };
pub const RunStatus = enum { pass, stale };

const FileCache = struct {
    allocator: std.mem.Allocator,
    current: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) FileCache {
        return .{
            .allocator = allocator,
            .current = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *FileCache) void {
        var it = self.current.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.current.deinit();
    }

    fn getCurrent(self: *FileCache, absolute_path: []const u8) !?[]const u8 {
        if (self.current.get(absolute_path)) |content| return content;

        const file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        errdefer self.allocator.free(content);

        const key = try self.allocator.dupe(u8, absolute_path);
        errdefer self.allocator.free(key);

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
        .changed_after_baseline => "changed after spec",
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

    fn deinit(self: *JsonAnchorRow, allocator: std.mem.Allocator) void {
        if (self.blame_storage) |b| b.deinit(allocator);
    }
};

const SpecCheckResult = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: AnchorResult,
    anchors: std.ArrayList(JsonAnchorRow),

    fn deinit(self: *SpecCheckResult, allocator: std.mem.Allocator) void {
        for (self.anchors.items) |*a| a.deinit(allocator);
        self.anchors.deinit(allocator);
    }
};

const CheckResult = struct {
    repo: ?[]const u8,
    checked_at_ms: i64,
    specs: std.ArrayList(SpecCheckResult),
    summary_result: AnchorResult,
    specs_total: u32,
    specs_fresh: u32,
    specs_stale: u32,
    specs_skipped: u32,
    anchors_total: u32,
    anchors_fresh: u32,
    anchors_stale: u32,
    anchors_skipped: u32,

    fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        for (self.specs.items) |*s| s.deinit(allocator);
        self.specs.deinit(allocator);
    }

    fn specsChecked(self: *const CheckResult) u32 {
        return self.specs_fresh + self.specs_stale;
    }

    fn verificationState(self: *const CheckResult) []const u8 {
        const checked = self.specsChecked();
        if (self.specs_total > 0 and checked == 0) return "none";
        if (checked > 0 and self.specs_skipped > 0) return "partial";
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
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    format: Format,
) !RunStatus {
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    var lf = try lockfile.discover(allocator, cwd_path);
    defer lf.deinit(allocator);

    var spec_groups = try lockfile.groupBySpec(allocator, lf.bindings.items);
    defer {
        for (spec_groups.items) |*spec| spec.deinit(allocator);
        spec_groups.deinit(allocator);
    }

    const detected_vcs = vcs.detectVcs();
    const repo_identity = vcs.getRepoIdentity(allocator, cwd_path);
    defer if (repo_identity) |ri| allocator.free(ri);

    var file_cache = FileCache.init(allocator);
    defer file_cache.deinit();

    var text_sink_state = TextSinkState{ .writer = stdout_w };

    var json_result: CheckResult = undefined;
    const json_result_init = format == .json;
    if (json_result_init) {
        json_result = .{
            .repo = repo_identity,
            .checked_at_ms = std.time.milliTimestamp(),
            .specs = .{},
            .summary_result = .fresh,
            .specs_total = 0,
            .specs_fresh = 0,
            .specs_stale = 0,
            .specs_skipped = 0,
            .anchors_total = 0,
            .anchors_fresh = 0,
            .anchors_stale = 0,
            .anchors_skipped = 0,
        };
    }
    defer if (json_result_init) json_result.deinit(allocator);

    const sink: LintSink = switch (format) {
        .text => .{ .text = &text_sink_state },
        .json => .{ .json = &json_result },
    };

    for (spec_groups.items) |spec| {
        switch (sink) {
            .text => |ts| ts.writer.print("{s}\n", .{spec.path}) catch {},
            .json => {},
        }

        var spec_result = SpecCheckResult{
            .path = spec.path,
            .origin = null,
            .result = .fresh,
            .anchors = .{},
        };
        errdefer spec_result.deinit(allocator);

        var fresh_count: usize = 0;
        var stale_count: usize = 0;
        var skip_count: usize = 0;

        for (spec.bindings.items) |binding| {
            const origin = binding.fieldValue("origin");
            const sig = binding.fieldValue("sig");
            const parsed = parseTarget(binding.target, sig);

            const outcome = blk: {
                if (origin) |o| {
                    const is_local = if (repo_identity) |ri| std.mem.eql(u8, o, ri) else false;
                    if (!is_local) break :blk AnchorOutcome{ .result = .skip, .reason_code = .origin_mismatch };
                }
                break :blk checkBinding(allocator, lf.root_path, binding, &file_cache, detected_vcs) catch |err| {
                    stderr_w.print("error checking {s}: {s}\n", .{ binding.target, @errorName(err) }) catch {};
                    return error.LintCheckFailed;
                };
            };

            switch (sink) {
                .text => |ts| textEmitAnchor(allocator, ts.writer, origin, binding.target, outcome),
                .json => try spec_result.anchors.append(allocator, jsonAnchorFromOutcome(binding.target, parsed, outcome)),
            }

            switch (outcome.result) {
                .fresh => fresh_count += 1,
                .stale => stale_count += 1,
                .skip => skip_count += 1,
            }
        }

        spec_result.result = if (stale_count > 0)
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
                r.specs_total += 1;
                r.anchors_total += @intCast(spec.bindings.items.len);
                r.anchors_fresh += @intCast(fresh_count);
                r.anchors_stale += @intCast(stale_count);
                r.anchors_skipped += @intCast(skip_count);
                switch (spec_result.result) {
                    .fresh => r.specs_fresh += 1,
                    .stale => {
                        r.specs_stale += 1;
                        r.summary_result = .stale;
                    },
                    .skip => r.specs_skipped += 1,
                }
                try r.specs.append(allocator, spec_result);
            },
        }
    }

    if (format == .text and spec_groups.items.len == 0) {
        stdout_w.print("ok\n", .{}) catch {};
    }

    if (format == .json) {
        try writeResultsJson(allocator, stdout_w, &json_result);
    }

    return switch (format) {
        .text => if (text_sink_state.summary_stale) .stale else .pass,
        .json => if (json_result.summary_result == .stale) .stale else .pass,
    };
}

fn checkBinding(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    binding: *const lockfile.Binding,
    file_cache: *FileCache,
    detected_vcs: vcs.VcsKind,
) !AnchorOutcome {
    const sig_hex = binding.fieldValue("sig") orelse return .{ .result = .stale, .reason_code = .baseline_unavailable };

    const parsed = parseTarget(binding.target, sig_hex);
    const absolute_path = try std.fs.path.join(allocator, &.{ root_path, parsed.file_path });
    defer allocator.free(absolute_path);

    const current_content = file_cache.getCurrent(absolute_path) catch {
        return .{ .result = .stale, .reason_code = .file_not_readable };
    } orelse {
        return .{ .result = .stale, .reason_code = .file_not_found };
    };

    if (parsed.symbol_name) |sym| {
        const ext = std.fs.path.extension(parsed.file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            if (!symbols.resolveSymbolWithTreeSitter(current_content, lang_query, sym)) {
                return .{ .result = .stale, .reason_code = .symbol_not_found };
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

    const blame = vcs.getLatestBlameInfo(allocator, root_path, parsed.file_path, detected_vcs) catch null;
    return .{ .result = .stale, .reason_code = .changed_after_baseline, .blame = blame };
}

fn textEmitAnchor(
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    origin: ?[]const u8,
    target: []const u8,
    outcome: AnchorOutcome,
) void {
    const blame_owned = outcome.blame;
    defer if (blame_owned) |b| b.deinit(allocator);

    switch (outcome.result) {
        .stale => {
            const msg = reasonMessage(outcome.reason_code);
            if (msg.len > 0) {
                stdout_w.print("  STALE   {s} ({s})\n", .{ target, msg }) catch {};
            } else {
                stdout_w.print("  STALE   {s}\n", .{target}) catch {};
            }
            if (blame_owned) |blame| {
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

fn writeResultsJson(allocator: std.mem.Allocator, w: *std.io.Writer, result: *const CheckResult) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const doc = try checkResultToDriftCheckV1(arena.allocator(), result);
    try drift_check_v1.writeJson(w, doc);
}

fn checkResultToDriftCheckV1(arena: std.mem.Allocator, result: *const CheckResult) !drift_check_v1.DriftCheckV1 {
    const specs = try arena.alloc(drift_check_v1.Spec, result.specs.items.len);
    for (result.specs.items, specs) |s, *sp| {
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
        .specs = specs,
    };
}

fn checkResultSummaryWire(result: *const CheckResult) drift_check_v1.Summary {
    return .{
        .result = if (result.summary_result == .stale) "fail" else "pass",
        .verification_state = result.verificationState(),
        .specs_total = result.specs_total,
        .specs_checked = result.specsChecked(),
        .specs_skipped = result.specs_skipped,
        .specs_fresh = result.specs_fresh,
        .specs_stale = result.specs_stale,
        .anchors_total = result.anchors_total,
        .anchors_fresh = result.anchors_fresh,
        .anchors_stale = result.anchors_stale,
        .anchors_skipped = result.anchors_skipped,
    };
}
