const std = @import("std");
const build_options = @import("build_options");
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
/// change and should bump `drift.check.v1`.
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

const AnchorCheckResult = struct {
    anchor: []const u8,
    identity: []const u8,
    path: []const u8,
    symbol: ?[]const u8,
    anchor_kind: []const u8, // "file" or "symbol"
    provenance_kind: ?[]const u8,
    provenance_value: ?[]const u8,
    result: AnchorResult,
    reason_code: ReasonCode,
    blame: ?vcs.BlameInfo,
};

const SpecCheckResult = struct {
    path: []const u8,
    origin: ?[]const u8,
    result: AnchorResult, // worst of all anchors: stale > skip > fresh
    anchors: std.ArrayList(AnchorCheckResult),

    fn deinit(self: *SpecCheckResult, allocator: std.mem.Allocator) void {
        for (self.anchors.items) |*a| {
            if (a.blame) |b| b.deinit(allocator);
        }
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

    /// True when there are specs but every one was skipped (e.g. all origin mismatches).
    /// Distinct from "pass" because the user got zero verification — the dashboard should
    /// surface this rather than report a green check.
    fn fullySkipped(self: *const CheckResult) bool {
        return self.specs_total > 0 and self.specs_total == self.specs_skipped;
    }
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

    // Build result model
    var result = CheckResult{
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
    defer result.deinit(allocator);

    for (specs.items) |spec| {
        var spec_result = SpecCheckResult{
            .path = spec.path,
            .origin = spec.origin,
            .result = .fresh,
            .anchors = .{},
        };

        if (spec.anchors.items.len == 0) {
            // No anchors — fresh by default
            try result.specs.append(allocator, spec_result);
            result.specs_total += 1;
            result.specs_fresh += 1;
            continue;
        }

        // Check origin
        if (spec.origin) |origin| {
            const is_local = if (repo_identity) |ri| std.mem.eql(u8, origin, ri) else false;
            if (!is_local) {
                for (spec.anchors.items) |anchor| {
                    const parsed = parseAnchor(anchor);
                    try spec_result.anchors.append(allocator, .{
                        .anchor = anchor,
                        .identity = parsed.identity,
                        .path = parsed.file_path,
                        .symbol = parsed.symbol_name,
                        .anchor_kind = if (parsed.symbol_name != null) "symbol" else "file",
                        .provenance_kind = parsed.provenance_kind,
                        .provenance_value = parsed.provenance_value,
                        .result = .skip,
                        .reason_code = .origin_mismatch,
                        .blame = null,
                    });
                    result.anchors_total += 1;
                    result.anchors_skipped += 1;
                }
                spec_result.result = .skip;
                try result.specs.append(allocator, spec_result);
                result.specs_total += 1;
                result.specs_skipped += 1;
                continue;
            }
        }

        const spec_commit = vcs.getLastCommit(allocator, cwd_path, spec.path, detected_vcs) catch |err| {
            stderr_w.print("vcs error for {s}: {s}\n", .{ spec.path, @errorName(err) }) catch {};
            return error.LintCheckFailed;
        };
        defer if (spec_commit) |c| allocator.free(c);

        for (spec.anchors.items) |anchor| {
            const outcome = checkAnchor(allocator, cwd_path, anchor, spec_commit, detected_vcs, &cat_file, &file_cache) catch |err| {
                stderr_w.print("error checking {s}: {s}\n", .{ anchor, @errorName(err) }) catch {};
                return error.LintCheckFailed;
            };

            const parsed = parseAnchor(anchor);
            try spec_result.anchors.append(allocator, .{
                .anchor = anchor,
                .identity = parsed.identity,
                .path = parsed.file_path,
                .symbol = parsed.symbol_name,
                .anchor_kind = if (parsed.symbol_name != null) "symbol" else "file",
                .provenance_kind = parsed.provenance_kind,
                .provenance_value = parsed.provenance_value,
                .result = outcome.result,
                .reason_code = outcome.reason_code,
                .blame = outcome.blame,
            });

            result.anchors_total += 1;
            switch (outcome.result) {
                .fresh => result.anchors_fresh += 1,
                .stale => {
                    result.anchors_stale += 1;
                    spec_result.result = .stale;
                },
                .skip => result.anchors_skipped += 1,
            }
        }

        result.specs_total += 1;
        switch (spec_result.result) {
            .fresh => result.specs_fresh += 1,
            .stale => {
                result.specs_stale += 1;
                result.summary_result = .stale;
            },
            .skip => result.specs_skipped += 1,
        }
        try result.specs.append(allocator, spec_result);
    }

    // Render output. JSON write errors propagate so a truncated/corrupt payload becomes
    // a non-zero exit instead of silently emitting an unparseable document — the previous
    // implementation used `catch return` on every json call and could leave a half-written
    // object on stdout while still exiting 0.
    switch (format) {
        .json => try writeResultsJson(stdout_w, &result),
        .text => writeResultsText(stdout_w, &result),
    }

    return if (result.summary_result == .stale) .stale else .pass;
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

fn writeResultsText(stdout_w: *std.io.Writer, result: *const CheckResult) void {
    if (result.specs.items.len == 0) {
        stdout_w.print("ok\n", .{}) catch {};
        return;
    }

    for (result.specs.items) |spec| {
        stdout_w.print("{s}\n", .{spec.path}) catch {};

        if (spec.anchors.items.len == 0) {
            stdout_w.print("  ok\n", .{}) catch {};
            continue;
        }

        var all_ok = true;
        for (spec.anchors.items) |a| {
            switch (a.result) {
                .stale => {
                    all_ok = false;
                    const msg = reasonMessage(a.reason_code);
                    if (msg.len > 0) {
                        stdout_w.print("  STALE   {s} ({s})\n", .{ a.anchor, msg }) catch {};
                    } else {
                        stdout_w.print("  STALE   {s}\n", .{a.anchor}) catch {};
                    }
                    if (a.blame) |blame| {
                        stdout_w.print("          changed by {s} in {s} ({s})\n", .{ blame.author, blame.commit_hash, blame.date }) catch {};
                        stdout_w.print("          \"{s}\"\n", .{blame.subject}) catch {};
                    }
                },
                .skip => {
                    all_ok = false;
                    if (spec.origin) |origin| {
                        stdout_w.print("  SKIP   {s} (origin: {s})\n", .{ a.anchor, origin }) catch {};
                    } else {
                        stdout_w.print("  SKIP   {s}\n", .{a.anchor}) catch {};
                    }
                },
                .fresh => {},
            }
        }

        if (all_ok) {
            stdout_w.print("  ok\n", .{}) catch {};
        }
    }
}

/// Emit the `drift.check.v1` schema. See `docs/check-json-schema.md` for the wire contract.
///
/// Errors propagate (broken pipe, OOM in encoder, full disk) so a truncated payload
/// becomes a non-zero exit. Do *not* swallow these — a JSON consumer that gets a
/// half-written document has no way to distinguish "drift exited cleanly with this
/// content" from "drift died mid-write."
fn writeResultsJson(w: *std.io.Writer, result: *const CheckResult) !void {
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    try jw.objectField("schema_version");
    try jw.write("drift.check.v1");
    try jw.objectField("tool");
    try jw.write("drift");
    try jw.objectField("tool_version");
    try jw.write(build_options.version);

    try jw.objectField("repo");
    try jw.write(result.repo);

    // Unit-suffixed name (`_ms`) so consumers don't have to guess s/ms/us/ns from
    // digit counts. Renaming this is a wire-format break — bump schema_version.
    try jw.objectField("checked_at_ms");
    try jw.write(result.checked_at_ms);

    // Summary
    try jw.objectField("summary");
    try jw.write(.{
        .result = if (result.summary_result == .stale) "fail" else "pass",
        // Distinguishes "all specs passed" from "all specs were skipped (zero verification)".
        // Consumers that gate on the build should treat fully_skipped as a yellow signal.
        .fully_skipped = result.fullySkipped(),
        .specs_total = result.specs_total,
        .specs_fresh = result.specs_fresh,
        .specs_stale = result.specs_stale,
        .specs_skipped = result.specs_skipped,
        .anchors_total = result.anchors_total,
        .anchors_fresh = result.anchors_fresh,
        .anchors_stale = result.anchors_stale,
        .anchors_skipped = result.anchors_skipped,
    });

    // Specs array
    try jw.objectField("specs");
    try jw.beginArray();
    for (result.specs.items) |spec| {
        try jw.beginObject();

        try jw.objectField("path");
        try jw.write(spec.path);
        try jw.objectField("origin");
        try jw.write(spec.origin);
        try jw.objectField("result");
        try jw.write(anchorResultStr(spec.result));

        try jw.objectField("anchors");
        try jw.beginArray();
        for (spec.anchors.items) |a| {
            try jw.beginObject();

            try jw.objectField("identity");
            try jw.write(a.identity);
            try jw.objectField("raw");
            try jw.write(a.anchor);
            try jw.objectField("kind");
            try jw.write(a.anchor_kind);
            try jw.objectField("path");
            try jw.write(a.path);
            try jw.objectField("symbol");
            try jw.write(a.symbol);

            try jw.objectField("provenance");
            if (a.provenance_kind) |pk| {
                try jw.write(.{ .kind = pk, .value = a.provenance_value });
            } else {
                try jw.write(null);
            }

            try jw.objectField("result");
            try jw.write(anchorResultStr(a.result));

            try jw.objectField("reason");
            if (a.reason_code != .none) {
                try jw.write(.{
                    .code = @tagName(a.reason_code),
                    .message = reasonMessage(a.reason_code),
                });
            } else {
                try jw.write(null);
            }

            try jw.objectField("blame");
            if (a.blame) |blame| {
                try jw.write(.{
                    .author = blame.author,
                    .commit = blame.commit_hash,
                    .date = blame.date,
                    .subject = blame.subject,
                });
            } else {
                try jw.write(null);
            }

            try jw.endObject();
        }
        try jw.endArray();

        try jw.endObject();
    }
    try jw.endArray();

    try jw.endObject();
    try w.writeByte('\n');
}

fn anchorResultStr(r: AnchorResult) []const u8 {
    return switch (r) {
        .fresh => "fresh",
        .stale => "stale",
        .skip => "skip",
    };
}
