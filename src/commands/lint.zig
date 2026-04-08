const std = @import("std");
const build_options = @import("build_options");
const drift_check_v1 = @import("payload");
const frontmatter = @import("../frontmatter.zig");
const scanner = @import("../scanner.zig");
const symbols = @import("../symbols.zig");
const vcs = @import("../vcs.zig");

const Spec = scanner.Spec;

/// Output format for `drift check` / `drift lint`.
///
/// Defined here (rather than in main.zig) so the lint command owns its own surface
/// and other call sites (status.zig, future commands) can import the same enum.
/// Replaces the previous `format_json: bool` boolean trap — adding sarif/junit/etc.
/// later only requires extending this enum.
pub const Format = enum { text, json };

/// Result of a single `run` invocation. The command exits 1 on `.stale` and 0 on `.pass`.
///
/// We return this from `run` instead of calling `std.process.exit` directly so that
/// `defer`-based cleanup (FileCache, CheckResult, GitCatFile, repo_identity) actually
/// runs before the process dies. `std.process.exit` calls libc `exit`, which does not
/// unwind Zig defers — previously this leaked allocations on the stale path and tripped
/// DebugAllocator in test/CI builds.
pub const RunStatus = enum { pass, stale };

/// Caches current and historical file bytes for one lint run (path -> bytes, rev+path -> bytes).
const FileCache = struct {
    allocator: std.mem.Allocator,
    current: std.StringHashMap([]const u8),
    historical: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) FileCache {
        return .{
            .allocator = allocator,
            .current = std.StringHashMap([]const u8).init(allocator),
            .historical = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *FileCache) void {
        var c_it = self.current.iterator();
        while (c_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.current.deinit();
        var h_it = self.historical.iterator();
        while (h_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.historical.deinit();
    }

    fn getCurrent(self: *FileCache, path: []const u8) ?[]const u8 {
        if (self.current.get(path)) |c| return c;
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch return null;
        const key = self.allocator.dupe(u8, path) catch {
            self.allocator.free(content);
            return null;
        };
        self.current.put(key, content) catch {
            self.allocator.free(key);
            self.allocator.free(content);
            return null;
        };
        return content;
    }

    fn getHistorical(self: *FileCache, cat_file: *vcs.GitCatFile, revision: []const u8, file_path: []const u8) !?[]const u8 {
        const key_str = try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}", .{ revision, file_path });
        defer self.allocator.free(key_str);

        if (self.historical.get(key_str)) |c| return c;

        const content_opt = try cat_file.getContent(self.allocator, revision, file_path);
        if (content_opt == null) return null;
        const content = content_opt.?;

        const key_owned = try self.allocator.dupe(u8, key_str);
        errdefer self.allocator.free(key_owned);
        errdefer self.allocator.free(content);
        try self.historical.put(key_owned, content);
        return content;
    }
};

// --- Result model (shared by text and JSON output) ---

const AnchorResult = enum { fresh, stale, skip };

/// Why an anchor is stale or skipped. The wire format emits `@tagName(code)` so the
/// JSON consumer never sees a free-form English string for the code itself.
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

/// Stable, human-readable message for a reason code. This is the *only* mapping from
/// code → string in the codebase: the text renderer and the `reason.message` JSON field
/// both call this. Tests assert these exact strings, so changing one is a wire-format
/// change and should bump `drift.check.v1`, update `docs/schemas/`, and `src/payload/drift_check_v1.zig`.
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

/// One JSON anchor row: wire payload plus owned blame storage when `wire.blame` is non-null.
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
    result: AnchorResult, // worst of all anchors: stale > skip > fresh
    anchors: std.ArrayList(JsonAnchorRow),

    fn deinit(self: *SpecCheckResult, allocator: std.mem.Allocator) void {
        for (self.anchors.items) |*a| a.deinit(allocator);
        self.anchors.deinit(allocator);
    }
};

const CheckResult = struct {
    repo: ?[]const u8,
    /// Unix timestamp in milliseconds. Wire field name is `checked_at_ms` so the unit
    /// is unambiguous to JSON consumers (a bare `checked_at` integer could be s/ms/us/ns).
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

    /// `specs_fresh + specs_stale` — specs that were actually verified (not skipped).
    fn specsChecked(self: *const CheckResult) u32 {
        return self.specs_fresh + self.specs_stale;
    }

    /// Coverage of verification across discovered specs. See `docs/check-json-schema.md`.
    fn verificationState(self: *const CheckResult) []const u8 {
        const checked = self.specsChecked();
        if (self.specs_total > 0 and checked == 0) return "none";
        if (checked > 0 and self.specs_skipped > 0) return "partial";
        return "full";
    }
};

/// Human-readable output streams one spec at a time; `summary_stale` drives exit status.
const TextSinkState = struct {
    writer: *std.io.Writer,
    summary_stale: bool = false,
};

/// Where anchor rows go: text prints immediately (bounded memory); JSON buffers `CheckResult`.
const LintSink = union(enum) {
    text: *TextSinkState,
    json: *CheckResult,
};

/// Outcome of checking a single anchor. Returned by `checkAnchor` and merged into the
/// model in `run`. Replaces the old `AnchorStatus` struct that carried English label
/// strings (`"ok"`, `"STALE"`) which `run` then re-parsed via `std.mem.eql` — fragile,
/// and a future label tweak would silently flip JSON results.
const AnchorOutcome = struct {
    result: AnchorResult,
    reason_code: ReasonCode,
    blame: ?vcs.BlameInfo = null,
};

const ParsedAnchor = struct {
    identity: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    /// Raw provenance suffix (everything after the first `@`), or null when no `@` is present.
    provenance: ?[]const u8,
    provenance_kind: ?[]const u8,
    provenance_value: ?[]const u8,
};

/// Single source of truth for splitting an anchor string into its parts. Both
/// `checkAnchor` (for staleness logic) and `run` (for building the JSON model) call this,
/// so the parsing rules can never drift between the two paths.
fn parseAnchor(anchor: []const u8) ParsedAnchor {
    const identity = frontmatter.anchorFileIdentity(anchor);
    const provenance: ?[]const u8 = if (identity.len < anchor.len)
        anchor[identity.len + 1 ..] // skip the `@` separator that anchorFileIdentity stopped at
    else
        null;

    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_path = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    var provenance_kind: ?[]const u8 = null;
    var provenance_value: ?[]const u8 = null;
    if (provenance) |prov| {
        if (std.mem.startsWith(u8, prov, "sig:")) {
            provenance_kind = "sig";
            provenance_value = prov["sig:".len..];
        } else {
            provenance_kind = "vcs";
            provenance_value = prov;
        }
    }

    return .{
        .identity = identity,
        .file_path = file_path,
        .symbol_name = symbol_name,
        .provenance = provenance,
        .provenance_kind = provenance_kind,
        .provenance_value = provenance_value,
    };
}

fn driftProvenance(parsed: ParsedAnchor) ?drift_check_v1.Provenance {
    if (parsed.provenance_kind) |pk| {
        return .{ .kind = pk, .value = parsed.provenance_value.? };
    }
    return null;
}

fn driftReason(code: ReasonCode) ?drift_check_v1.Reason {
    if (code == .none) return null;
    return .{ .code = @tagName(code), .message = reasonMessage(code) };
}

fn jsonAnchorFromOutcome(anchor: []const u8, parsed: ParsedAnchor, outcome: AnchorOutcome) JsonAnchorRow {
    const blame_storage = outcome.blame;
    return .{
        .blame_storage = blame_storage,
        .wire = .{
            .identity = parsed.identity,
            .raw = anchor,
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

fn jsonAnchorOriginMismatch(anchor: []const u8, parsed: ParsedAnchor) JsonAnchorRow {
    return .{
        .blame_storage = null,
        .wire = .{
            .identity = parsed.identity,
            .raw = anchor,
            .kind = if (parsed.symbol_name != null) "symbol" else "file",
            .path = parsed.file_path,
            .symbol = parsed.symbol_name,
            .provenance = driftProvenance(parsed),
            .result = "skip",
            .reason = driftReason(.origin_mismatch),
            .blame = null,
        },
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    format: Format,
) !RunStatus {
    var specs: std.ArrayList(Spec) = .{};
    defer {
        for (specs.items) |*s| s.deinit(allocator);
        specs.deinit(allocator);
    }

    try scanner.findAndSortSpecs(allocator, &specs);

    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const detected_vcs = vcs.detectVcs();

    var file_cache = FileCache.init(allocator);
    defer file_cache.deinit();

    var cat_file = try vcs.GitCatFile.init(allocator, cwd_path);
    defer cat_file.deinit();

    const repo_identity = vcs.getRepoIdentity(allocator, cwd_path);
    defer if (repo_identity) |ri| allocator.free(ri);

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

    for (specs.items) |spec| {
        switch (sink) {
            .text => |ts| ts.writer.print("{s}\n", .{spec.path}) catch {},
            .json => {},
        }

        if (spec.anchors.items.len == 0) {
            switch (sink) {
                .text => |ts| ts.writer.print("  ok\n", .{}) catch {},
                .json => |r| {
                    try r.specs.append(allocator, .{
                        .path = spec.path,
                        .origin = spec.origin,
                        .result = .fresh,
                        .anchors = .{},
                    });
                    r.specs_total += 1;
                    r.specs_fresh += 1;
                },
            }
            continue;
        }

        if (spec.origin) |origin| {
            const is_local = if (repo_identity) |ri| std.mem.eql(u8, origin, ri) else false;
            if (!is_local) {
                switch (sink) {
                    .text => {
                        for (spec.anchors.items) |anchor| {
                            text_sink_state.writer.print("  SKIP   {s} (origin: {s})\n", .{ anchor, origin }) catch {};
                        }
                    },
                    .json => |r| {
                        var spec_result = SpecCheckResult{
                            .path = spec.path,
                            .origin = spec.origin,
                            .result = .fresh,
                            .anchors = .{},
                        };
                        for (spec.anchors.items) |anchor| {
                            const parsed = parseAnchor(anchor);
                            try spec_result.anchors.append(allocator, jsonAnchorOriginMismatch(anchor, parsed));
                            r.anchors_total += 1;
                            r.anchors_skipped += 1;
                        }
                        spec_result.result = .skip;
                        try r.specs.append(allocator, spec_result);
                        r.specs_total += 1;
                        r.specs_skipped += 1;
                    },
                }
                continue;
            }
        }

        const spec_commit = vcs.getLastCommit(allocator, cwd_path, spec.path, detected_vcs) catch |err| {
            stderr_w.print("vcs error for {s}: {s}\n", .{ spec.path, @errorName(err) }) catch {};
            return error.LintCheckFailed;
        };
        defer if (spec_commit) |c| allocator.free(c);

        switch (sink) {
            .text => {
                var any_problem = false;
                for (spec.anchors.items) |anchor| {
                    const outcome = checkAnchor(allocator, cwd_path, anchor, spec_commit, detected_vcs, &cat_file, &file_cache) catch |err| {
                        stderr_w.print("error checking {s}: {s}\n", .{ anchor, @errorName(err) }) catch {};
                        return error.LintCheckFailed;
                    };
                    textEmitAnchor(allocator, text_sink_state.writer, spec.origin, anchor, outcome);
                    switch (outcome.result) {
                        .fresh => {},
                        .stale => {
                            any_problem = true;
                            text_sink_state.summary_stale = true;
                        },
                        .skip => any_problem = true,
                    }
                }
                if (!any_problem) {
                    text_sink_state.writer.print("  ok\n", .{}) catch {};
                }
            },
            .json => |r| {
                var spec_result = SpecCheckResult{
                    .path = spec.path,
                    .origin = spec.origin,
                    .result = .fresh,
                    .anchors = .{},
                };
                for (spec.anchors.items) |anchor| {
                    const outcome = checkAnchor(allocator, cwd_path, anchor, spec_commit, detected_vcs, &cat_file, &file_cache) catch |err| {
                        stderr_w.print("error checking {s}: {s}\n", .{ anchor, @errorName(err) }) catch {};
                        return error.LintCheckFailed;
                    };

                    const parsed = parseAnchor(anchor);
                    try spec_result.anchors.append(allocator, jsonAnchorFromOutcome(anchor, parsed, outcome));

                    r.anchors_total += 1;
                    switch (outcome.result) {
                        .fresh => r.anchors_fresh += 1,
                        .stale => {
                            r.anchors_stale += 1;
                            spec_result.result = .stale;
                        },
                        .skip => r.anchors_skipped += 1,
                    }
                }

                r.specs_total += 1;
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

    switch (sink) {
        .text => |ts| {
            if (specs.items.len == 0) {
                ts.writer.print("ok\n", .{}) catch {};
            }
        },
        .json => {},
    }

    // JSON write errors propagate so a truncated/corrupt payload becomes a non-zero exit.
    if (format == .json) {
        try writeResultsJson(allocator, stdout_w, &json_result);
    }

    return switch (format) {
        .text => if (text_sink_state.summary_stale) .stale else .pass,
        .json => if (json_result.summary_result == .stale) .stale else .pass,
    };
}

fn checkAnchor(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    anchor: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
    cat_file: *vcs.GitCatFile,
    file_cache: *FileCache,
) !AnchorOutcome {
    const parsed = parseAnchor(anchor);
    const file_path = parsed.file_path;
    const symbol_name = parsed.symbol_name;
    const provenance = parsed.provenance;

    const file_exists = blk: {
        std.fs.cwd().access(file_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!file_exists) {
        return .{ .result = .stale, .reason_code = .file_not_found };
    }

    const needs_current_content = symbol_name != null or provenance != null or spec_commit != null;
    const file_content: ?[]const u8 = if (needs_current_content) blk: {
        break :blk file_cache.getCurrent(file_path) orelse {
            return .{ .result = .stale, .reason_code = .file_not_readable };
        };
    } else null;

    if (symbol_name) |sym| {
        const content = file_content.?;

        const ext = std.fs.path.extension(file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            if (!symbols.resolveSymbolWithTreeSitter(content, lang_query, sym)) {
                return .{ .result = .stale, .reason_code = .symbol_not_found };
            }
        } else {
            if (std.mem.indexOf(u8, content, sym) == null) {
                return .{ .result = .stale, .reason_code = .symbol_not_found };
            }
        }
    }

    if (provenance) |prov| {
        if (std.mem.startsWith(u8, prov, "sig:")) {
            return checkAnchorBySig(allocator, cwd_path, file_path, symbol_name, prov["sig:".len..], spec_commit, detected_vcs, file_content.?);
        }
        return checkAnchorByContent(allocator, cwd_path, file_path, symbol_name, prov, spec_commit, detected_vcs, file_content.?, cat_file, file_cache);
    }
    if (spec_commit) |commit| {
        return checkAnchorByContent(allocator, cwd_path, file_path, symbol_name, commit, spec_commit, detected_vcs, file_content.?, cat_file, file_cache);
    }

    return .{ .result = .fresh, .reason_code = .none };
}

fn checkAnchorByContent(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    provenance: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
    current_content: []const u8,
    cat_file: *vcs.GitCatFile,
    file_cache: *FileCache,
) !AnchorOutcome {
    const historical_content = blk: {
        const from_prov = file_cache.getHistorical(cat_file, provenance, file_path) catch break :blk null;
        if (from_prov) |content| break :blk content;
        if (spec_commit) |sc| {
            const from_spec = file_cache.getHistorical(cat_file, sc, file_path) catch break :blk null;
            if (from_spec) |content| break :blk content;
        }
        break :blk null;
    };

    if (historical_content == null) {
        return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
    }

    if (symbol_name) |sym| {
        const ext = std.fs.path.extension(file_path);
        const lang_query = symbols.languageForExtension(ext) orelse {
            if (!std.mem.eql(u8, historical_content.?, current_content)) {
                return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
            }
            return .{ .result = .fresh, .reason_code = .none };
        };

        const current_fingerprint = symbols.fingerprintSymbolSyntax(current_content, lang_query, sym);
        if (current_fingerprint == null) {
            return .{ .result = .stale, .reason_code = .symbol_not_found };
        }

        const historical_fingerprint = symbols.fingerprintSymbolSyntax(historical_content.?, lang_query, sym);
        if (historical_fingerprint == null) {
            return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
        }

        if (current_fingerprint.? != historical_fingerprint.?) {
            return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
        }
    } else {
        const ext = std.fs.path.extension(file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            const current_fingerprint = symbols.fingerprintFileSyntax(current_content, lang_query);
            const historical_fingerprint = symbols.fingerprintFileSyntax(historical_content.?, lang_query);

            if (current_fingerprint == null or historical_fingerprint == null) {
                if (!std.mem.eql(u8, historical_content.?, current_content)) {
                    return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
                }
            } else if (current_fingerprint.? != historical_fingerprint.?) {
                return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
            }
        } else {
            if (!std.mem.eql(u8, historical_content.?, current_content)) {
                return staleChangedAfterSpec(allocator, cwd_path, file_path, provenance, detected_vcs);
            }
        }
    }

    return .{ .result = .fresh, .reason_code = .none };
}

fn checkAnchorBySig(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    sig_hex: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
    current_content: []const u8,
) !AnchorOutcome {
    const fingerprint = symbols.computeFingerprint(current_content, file_path, symbol_name) orelse {
        return .{ .result = .stale, .reason_code = .fingerprint_unavailable };
    };

    var hex_buf: [16]u8 = undefined;
    const current_hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{fingerprint}) catch unreachable;

    if (std.mem.eql(u8, current_hex, sig_hex)) {
        return .{ .result = .fresh, .reason_code = .none };
    }

    const blame_rev = spec_commit orelse sig_hex;
    const blame = vcs.getBlameInfo(allocator, cwd_path, file_path, blame_rev, detected_vcs) catch null;
    return .{ .result = .stale, .reason_code = .changed_after_baseline, .blame = blame };
}

fn staleChangedAfterSpec(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    file_path: []const u8,
    provenance: []const u8,
    detected_vcs: vcs.VcsKind,
) !AnchorOutcome {
    const blame = vcs.getBlameInfo(allocator, cwd_path, file_path, provenance, detected_vcs) catch null;
    return .{ .result = .stale, .reason_code = .changed_after_baseline, .blame = blame };
}

// --- Renderers ---

/// Prints one anchor for text mode and frees `outcome.blame` when present (bounded memory).
fn textEmitAnchor(
    allocator: std.mem.Allocator,
    stdout_w: *std.io.Writer,
    spec_origin: ?[]const u8,
    anchor: []const u8,
    outcome: AnchorOutcome,
) void {
    const blame_owned = outcome.blame;
    defer if (blame_owned) |b| b.deinit(allocator);

    switch (outcome.result) {
        .stale => {
            const msg = reasonMessage(outcome.reason_code);
            if (msg.len > 0) {
                stdout_w.print("  STALE   {s} ({s})\n", .{ anchor, msg }) catch {};
            } else {
                stdout_w.print("  STALE   {s}\n", .{anchor}) catch {};
            }
            if (blame_owned) |blame| {
                stdout_w.print("          changed by {s} in {s} ({s})\n", .{ blame.author, blame.commit_hash, blame.date }) catch {};
                stdout_w.print("          \"{s}\"\n", .{blame.subject}) catch {};
            }
        },
        .skip => {
            if (spec_origin) |origin| {
                stdout_w.print("  SKIP   {s} (origin: {s})\n", .{ anchor, origin }) catch {};
            } else {
                stdout_w.print("  SKIP   {s}\n", .{anchor}) catch {};
            }
        },
        .fresh => {},
    }
}

/// Emit the `drift.check.v1` document from `src/payload/drift_check_v1.zig`. See
/// `docs/check-json-schema.md` and `docs/schemas/drift.check.v1.json`.
///
/// Errors propagate (broken pipe, OOM in encoder, full disk) so a truncated payload
/// becomes a non-zero exit. Do *not* swallow these — a JSON consumer that gets a
/// half-written document has no way to distinguish "drift exited cleanly with this
/// content" from "drift died mid-write."
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
