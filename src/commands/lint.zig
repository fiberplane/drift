const std = @import("std");
const build_options = @import("build_options");
const frontmatter = @import("../frontmatter.zig");
const scanner = @import("../scanner.zig");
const symbols = @import("../symbols.zig");
const vcs = @import("../vcs.zig");

const Spec = scanner.Spec;

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
    reason_message: []const u8,
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
    checked_at: i64, // unix timestamp ms
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
};

// Legacy struct used internally by checkAnchor — maps to AnchorCheckResult.
const AnchorStatus = struct {
    label: []const u8,
    display: []const u8,
    reason: []const u8,
    blame: ?vcs.BlameInfo = null,

    fn deinit(self: AnchorStatus, allocator: std.mem.Allocator) void {
        if (self.blame) |blame| blame.deinit(allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, stdout_w: *std.io.Writer, stderr_w: *std.io.Writer, format_json: bool) !void {
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
        .checked_at = std.time.milliTimestamp(),
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
                    const parsed = parseAnchorParts(anchor);
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
                        .reason_message = "origin mismatch",
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
            const status = checkAnchor(allocator, cwd_path, anchor, spec_commit, detected_vcs, &cat_file, &file_cache) catch |err| {
                stderr_w.print("error checking {s}: {s}\n", .{ anchor, @errorName(err) }) catch {};
                return error.LintCheckFailed;
            };

            const parsed = parseAnchorParts(anchor);
            const anchor_result: AnchorResult = if (std.mem.eql(u8, status.label, "ok")) .fresh else .stale;
            const reason_code = reasonCodeFromMessage(status.reason);

            try spec_result.anchors.append(allocator, .{
                .anchor = anchor,
                .identity = parsed.identity,
                .path = parsed.file_path,
                .symbol = parsed.symbol_name,
                .anchor_kind = if (parsed.symbol_name != null) "symbol" else "file",
                .provenance_kind = parsed.provenance_kind,
                .provenance_value = parsed.provenance_value,
                .result = anchor_result,
                .reason_code = reason_code,
                .reason_message = status.reason,
                .blame = status.blame,
            });

            result.anchors_total += 1;
            switch (anchor_result) {
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

    // Render output
    if (format_json) {
        writeResultsJson(stdout_w, &result);
    } else {
        writeResultsText(stdout_w, &result);
    }

    if (result.summary_result == .stale) {
        stdout_w.flush() catch {};
        stderr_w.flush() catch {};
        std.process.exit(1);
    }
}

fn parseAnchorParts(anchor: []const u8) struct {
    identity: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    provenance_kind: ?[]const u8,
    provenance_value: ?[]const u8,
} {
    const identity = frontmatter.anchorFileIdentity(anchor);
    const provenance_raw: ?[]const u8 = if (identity.len < anchor.len)
        anchor[identity.len + 1 ..]
    else
        null;
    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_path = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    var provenance_kind: ?[]const u8 = null;
    var provenance_value: ?[]const u8 = null;
    if (provenance_raw) |prov| {
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
        .provenance_kind = provenance_kind,
        .provenance_value = provenance_value,
    };
}

fn reasonCodeFromMessage(reason: []const u8) ReasonCode {
    if (reason.len == 0) return .none;
    if (std.mem.eql(u8, reason, "changed after spec")) return .changed_after_baseline;
    if (std.mem.eql(u8, reason, "file not found")) return .file_not_found;
    if (std.mem.eql(u8, reason, "file not readable")) return .file_not_readable;
    if (std.mem.eql(u8, reason, "symbol not found")) return .symbol_not_found;
    if (std.mem.eql(u8, reason, "cannot compute fingerprint")) return .fingerprint_unavailable;
    return .changed_after_baseline;
}

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
                    if (a.reason_message.len > 0) {
                        stdout_w.print("  STALE   {s} ({s})\n", .{ a.anchor, a.reason_message }) catch {};
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

fn writeResultsJson(w: *std.io.Writer, result: *const CheckResult) void {
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    jw.beginObject() catch return;

    jw.objectField("schema_version") catch return;
    jw.write("drift.check.v1") catch return;
    jw.objectField("tool") catch return;
    jw.write("drift") catch return;
    jw.objectField("tool_version") catch return;
    jw.write(build_options.version) catch return;

    jw.objectField("repo") catch return;
    jw.write(result.repo) catch return;

    jw.objectField("checked_at") catch return;
    jw.write(result.checked_at) catch return;

    // Summary
    jw.objectField("summary") catch return;
    jw.write(.{
        .result = if (result.summary_result == .stale) "fail" else "pass",
        .specs_total = result.specs_total,
        .specs_fresh = result.specs_fresh,
        .specs_stale = result.specs_stale,
        .specs_skipped = result.specs_skipped,
        .anchors_total = result.anchors_total,
        .anchors_fresh = result.anchors_fresh,
        .anchors_stale = result.anchors_stale,
        .anchors_skipped = result.anchors_skipped,
    }) catch return;

    // Specs array
    jw.objectField("specs") catch return;
    jw.beginArray() catch return;
    for (result.specs.items) |spec| {
        jw.beginObject() catch return;

        jw.objectField("path") catch return;
        jw.write(spec.path) catch return;
        jw.objectField("origin") catch return;
        jw.write(spec.origin) catch return;
        jw.objectField("result") catch return;
        jw.write(anchorResultStr(spec.result)) catch return;

        jw.objectField("anchors") catch return;
        jw.beginArray() catch return;
        for (spec.anchors.items) |a| {
            jw.beginObject() catch return;

            jw.objectField("identity") catch return;
            jw.write(a.identity) catch return;
            jw.objectField("raw") catch return;
            jw.write(a.anchor) catch return;
            jw.objectField("kind") catch return;
            jw.write(a.anchor_kind) catch return;
            jw.objectField("path") catch return;
            jw.write(a.path) catch return;
            jw.objectField("symbol") catch return;
            jw.write(a.symbol) catch return;

            jw.objectField("provenance") catch return;
            if (a.provenance_kind) |pk| {
                jw.write(.{ .kind = pk, .value = a.provenance_value }) catch return;
            } else {
                jw.write(null) catch return;
            }

            jw.objectField("result") catch return;
            jw.write(anchorResultStr(a.result)) catch return;

            jw.objectField("reason") catch return;
            if (a.reason_code != .none) {
                jw.write(.{
                    .code = @tagName(a.reason_code),
                    .message = a.reason_message,
                }) catch return;
            } else {
                jw.write(null) catch return;
            }

            jw.objectField("blame") catch return;
            if (a.blame) |blame| {
                jw.write(.{
                    .author = blame.author,
                    .commit = blame.commit_hash,
                    .date = blame.date,
                    .subject = blame.subject,
                }) catch return;
            } else {
                jw.write(null) catch return;
            }

            jw.endObject() catch return;
        }
        jw.endArray() catch return;

        jw.endObject() catch return;
    }
    jw.endArray() catch return;

    jw.endObject() catch return;
    w.writeByte('\n') catch {};
}

fn anchorResultStr(r: AnchorResult) []const u8 {
    return switch (r) {
        .fresh => "fresh",
        .stale => "stale",
        .skip => "skip",
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
) !AnchorStatus {
    const identity = frontmatter.anchorFileIdentity(anchor);
    const provenance: ?[]const u8 = if (identity.len < anchor.len)
        anchor[identity.len + 1 ..]
    else
        null;

    const hash_pos = std.mem.indexOfScalar(u8, identity, '#');
    const file_path = if (hash_pos) |pos| identity[0..pos] else identity;
    const symbol_name = if (hash_pos) |pos| identity[pos + 1 ..] else null;

    const file_exists = blk: {
        std.fs.cwd().access(file_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!file_exists) {
        return .{
            .label = "STALE",
            .display = anchor,
            .reason = "file not found",
        };
    }

    const needs_current_content = symbol_name != null or provenance != null or spec_commit != null;
    const file_content: ?[]const u8 = if (needs_current_content) blk: {
        break :blk file_cache.getCurrent(file_path) orelse {
            return .{
                .label = "STALE",
                .display = anchor,
                .reason = "file not readable",
            };
        };
    } else null;

    if (symbol_name) |sym| {
        const content = file_content.?;

        const ext = std.fs.path.extension(file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            if (!symbols.resolveSymbolWithTreeSitter(content, lang_query, sym)) {
                return .{
                    .label = "STALE",
                    .display = anchor,
                    .reason = "symbol not found",
                };
            }
        } else {
            if (std.mem.indexOf(u8, content, sym) == null) {
                return .{
                    .label = "STALE",
                    .display = anchor,
                    .reason = "symbol not found",
                };
            }
        }
    }

    if (provenance) |prov| {
        if (std.mem.startsWith(u8, prov, "sig:")) {
            return checkAnchorBySig(allocator, cwd_path, anchor, file_path, symbol_name, prov["sig:".len..], spec_commit, detected_vcs, file_content.?);
        }
        return checkAnchorByContent(allocator, cwd_path, anchor, file_path, symbol_name, prov, spec_commit, detected_vcs, file_content.?, cat_file, file_cache);
    }
    if (spec_commit) |commit| {
        return checkAnchorByContent(allocator, cwd_path, anchor, file_path, symbol_name, commit, spec_commit, detected_vcs, file_content.?, cat_file, file_cache);
    }

    return .{
        .label = "ok",
        .display = anchor,
        .reason = "",
    };
}

fn checkAnchorByContent(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    anchor: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    provenance: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
    current_content: []const u8,
    cat_file: *vcs.GitCatFile,
    file_cache: *FileCache,
) !AnchorStatus {
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
        return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
    }

    if (symbol_name) |sym| {
        const ext = std.fs.path.extension(file_path);
        const lang_query = symbols.languageForExtension(ext) orelse {
            if (!std.mem.eql(u8, historical_content.?, current_content)) {
                return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
            }
            return .{
                .label = "ok",
                .display = anchor,
                .reason = "",
            };
        };

        const current_fingerprint = symbols.fingerprintSymbolSyntax(current_content, lang_query, sym);
        if (current_fingerprint == null) {
            return .{
                .label = "STALE",
                .display = anchor,
                .reason = "symbol not found",
            };
        }

        const historical_fingerprint = symbols.fingerprintSymbolSyntax(historical_content.?, lang_query, sym);
        if (historical_fingerprint == null) {
            return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
        }

        if (current_fingerprint.? != historical_fingerprint.?) {
            return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
        }
    } else {
        const ext = std.fs.path.extension(file_path);
        if (symbols.languageForExtension(ext)) |lang_query| {
            const current_fingerprint = symbols.fingerprintFileSyntax(current_content, lang_query);
            const historical_fingerprint = symbols.fingerprintFileSyntax(historical_content.?, lang_query);

            if (current_fingerprint == null or historical_fingerprint == null) {
                if (!std.mem.eql(u8, historical_content.?, current_content)) {
                    return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
                }
            } else if (current_fingerprint.? != historical_fingerprint.?) {
                return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
            }
        } else {
            if (!std.mem.eql(u8, historical_content.?, current_content)) {
                return staleChangedAfterSpec(allocator, cwd_path, anchor, file_path, provenance, detected_vcs);
            }
        }
    }

    return .{
        .label = "ok",
        .display = anchor,
        .reason = "",
    };
}

fn checkAnchorBySig(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    anchor: []const u8,
    file_path: []const u8,
    symbol_name: ?[]const u8,
    sig_hex: []const u8,
    spec_commit: ?[]const u8,
    detected_vcs: vcs.VcsKind,
    current_content: []const u8,
) !AnchorStatus {
    const fingerprint = symbols.computeFingerprint(current_content, file_path, symbol_name) orelse {
        return .{
            .label = "STALE",
            .display = anchor,
            .reason = "cannot compute fingerprint",
        };
    };

    var hex_buf: [16]u8 = undefined;
    const current_hex = std.fmt.bufPrint(&hex_buf, "{x:0>16}", .{fingerprint}) catch unreachable;

    if (std.mem.eql(u8, current_hex, sig_hex)) {
        return .{
            .label = "ok",
            .display = anchor,
            .reason = "",
        };
    }

    const blame_rev = spec_commit orelse sig_hex;
    const blame = vcs.getBlameInfo(allocator, cwd_path, file_path, blame_rev, detected_vcs) catch null;
    errdefer if (blame) |b| b.deinit(allocator);

    return .{
        .label = "STALE",
        .display = anchor,
        .reason = "changed after spec",
        .blame = blame,
    };
}

fn staleChangedAfterSpec(
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    anchor: []const u8,
    file_path: []const u8,
    provenance: []const u8,
    detected_vcs: vcs.VcsKind,
) !AnchorStatus {
    const blame = vcs.getBlameInfo(allocator, cwd_path, file_path, provenance, detected_vcs) catch null;
    errdefer if (blame) |b| b.deinit(allocator);

    return .{
        .label = "STALE",
        .display = anchor,
        .reason = "changed after spec",
        .blame = blame,
    };
}
