const std = @import("std");
const build_options = @import("build_options");
const drift_check_v1 = @import("payload");
const CommandContext = @import("../context.zig").CommandContext;
const lockfile = @import("../lockfile.zig");
const markdown = @import("../markdown.zig");
const symbols = @import("../symbols.zig");
const target = @import("../target.zig");
const vcs = @import("../vcs.zig");

pub const Format = enum { text, json };
pub const RunStatus = enum { pass, fail };
pub const RunError = error{LintCheckFailed};

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
};

const CheckResult = struct {
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

    fn docsChecked(self: *const CheckResult) u32 {
        return self.docs_fresh + self.docs_stale;
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
    stdout_w: *std.io.Writer,
    stderr_w: *std.io.Writer,
    format: Format,
    changed_path: ?[]const u8,
) !RunStatus {
    const cwd_path = try std.fs.cwd().realpathAlloc(ctx.run_arena, ".");

    const lf = try lockfile.discover(ctx.run_arena, ctx.scratch(), cwd_path);
    ctx.resetScratch();

    var doc_groups = try discoverDocGroups(ctx.run_arena, lf.root_path, lf.bindings.items);
    defer {
        for (doc_groups.items) |*doc| doc.bindings.deinit(ctx.run_arena);
        doc_groups.deinit(ctx.run_arena);
    }

    const detected_vcs = vcs.detectVcs();
    const repo_identity = vcs.getRepoIdentity(ctx.run_arena, ctx.scratch(), cwd_path);

    var file_cache: FileCache = undefined;
    file_cache.init(ctx.run_arena);
    defer file_cache.deinit();

    const normalized_changed = if (changed_path) |raw|
        try normalizeChangedPrefix(ctx, lf.root_path, cwd_path, raw)
    else
        null;

    var result: CheckResult = .{
        .repo = repo_identity,
        .checked_at_ms = std.time.milliTimestamp(),
        .docs = .{},
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

    var checked_any = false;
    for (doc_groups.items) |doc| {
        if (normalized_changed) |prefix| {
            if (!docMatchesChangedPath(doc, prefix)) continue;
        }
        checked_any = true;

        var doc_result = DocCheckResult{
            .path = doc.path,
            .origin = commonOrigin(doc.bindings.items),
            .result = .fresh,
            .anchors = .{},
            .links = .{},
        };

        var fresh_count: usize = 0;
        var stale_count: usize = 0;
        var skip_count: usize = 0;

        for (doc.bindings.items) |binding| {
            ctx.resetScratch();
            const parsed = target.parse(binding.target);
            const origin = binding.fieldValue("origin");

            const outcome = blk: {
                if (origin) |o| {
                    const is_local = if (repo_identity) |ri| std.mem.eql(u8, o, ri) else false;
                    if (!is_local) break :blk AnchorOutcome{ .result = .skip, .reason_code = .origin_mismatch };
                }
                break :blk checkBinding(ctx, lf.root_path, binding, parsed, &file_cache, detected_vcs) catch |err| {
                    stderr_w.print("error checking {s}: {s}\n", .{ binding.target, @errorName(err) }) catch {};
                    return error.LintCheckFailed;
                };
            };

            try doc_result.anchors.append(ctx.run_arena, jsonAnchorFromOutcome(binding.target, binding.fieldValue("sig"), parsed, outcome));
            switch (outcome.result) {
                .fresh => fresh_count += 1,
                .stale => stale_count += 1,
                .skip => skip_count += 1,
            }
        }

        try checkDocLinks(ctx, lf.root_path, doc.path, &file_cache, &doc_result.links);

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

        result.docs_total += 1;
        result.anchors_total += @intCast(doc.bindings.items.len);
        result.anchors_fresh += @intCast(fresh_count);
        result.anchors_stale += @intCast(stale_count);
        result.anchors_skipped += @intCast(skip_count);
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

        try result.docs.append(ctx.run_arena, doc_result);
    }

    switch (format) {
        .text => try writeResultsText(stdout_w, &result, checked_any),
        .json => try writeResultsJson(ctx.run_arena, stdout_w, &result),
    }

    return if (result.failed) .fail else .pass;
}

fn discoverDocGroups(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    bindings: []lockfile.Binding,
) !std.ArrayList(DocGroup) {
    var docs: std.ArrayList(DocGroup) = .{};
    errdefer {
        for (docs.items) |*doc| doc.bindings.deinit(allocator);
        docs.deinit(allocator);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .cwd = root_path,
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var offset: usize = 0;
    while (offset < result.stdout.len) {
        const rest = result.stdout[offset..];
        const rel_end = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        const line = rest[0..rel_end];
        offset += rel_end + 1;

        if (!std.mem.endsWith(u8, line, ".md")) continue;
        if (hasNestedLockfile(root_path, line, allocator)) continue;
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
fn hasNestedLockfile(root_path: []const u8, rel_path: []const u8, allocator: std.mem.Allocator) bool {
    var dir: []const u8 = std.fs.path.dirname(rel_path) orelse return false;

    while (dir.len > 0) {
        const candidate = std.fs.path.join(allocator, &.{ root_path, dir, "drift.lock" }) catch return false;
        if (pathExists(candidate)) return true;
        dir = std.fs.path.dirname(dir) orelse break;
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
        .bindings = .{},
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
    const absolute_doc_path = try std.fs.path.join(ctx.scratch(), &.{ root_path, doc_path });
    const content = file_cache.getCurrent(absolute_doc_path) catch return orelse return;

    var parsed = (try markdown.parseDocument(ctx.run_arena, content)) orelse return;
    defer parsed.deinit();

    for (parsed.links.items) |link| {
        const checked = try classifyRelativeLink(ctx, root_path, doc_path, link.target) orelse continue;
        try out.append(ctx.run_arena, .{
            .display_target = checked.display_target,
            .wire = .{
                .target = link.target,
                .line = link.line,
                .result = linkResultStr(if (checked.exists) .ok else .broken),
                .reason = if (checked.exists) null else driftReason(.link_target_not_found),
            },
        });
    }
}

const CheckedLink = struct {
    display_target: []const u8,
    exists: bool,
};

fn classifyRelativeLink(
    ctx: CommandContext,
    root_path: []const u8,
    doc_path: []const u8,
    raw_target: []const u8,
) !?CheckedLink {
    const trimmed = std.mem.trim(u8, raw_target, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#') return null;
    if (std.fs.path.isAbsolute(trimmed)) return null;
    if (hasUriScheme(trimmed)) return null;

    const path_part = if (std.mem.indexOfScalar(u8, trimmed, '#')) |idx| trimmed[0..idx] else trimmed;
    if (path_part.len == 0) return null;

    // Resolve symlinks on the doc path so relative links are computed from the real location.
    const raw_absolute_doc = try std.fs.path.resolve(ctx.scratch(), &.{ root_path, doc_path });
    const real_doc_path = std.fs.cwd().realpathAlloc(ctx.scratch(), raw_absolute_doc) catch raw_absolute_doc;
    const doc_dir = std.fs.path.dirname(real_doc_path) orelse root_path;
    const absolute = try std.fs.path.resolve(ctx.scratch(), &.{ doc_dir, path_part });
    const relative = try std.fs.path.relative(ctx.run_arena, root_path, absolute);
    const exists = pathExists(absolute);
    ctx.resetScratch();

    return .{ .display_target = relative, .exists = exists };
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
    return std.fs.path.isSep(file_path[prefix.len]);
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
    root_path: []const u8,
    binding: *const lockfile.Binding,
    parsed: target.ParsedTarget,
    file_cache: *FileCache,
    detected_vcs: vcs.VcsKind,
) !AnchorOutcome {
    const sig_hex = binding.fieldValue("sig") orelse return .{ .result = .stale, .reason_code = .baseline_unavailable };

    const absolute_path = try std.fs.path.join(ctx.scratch(), &.{ root_path, parsed.file_path });
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
            const ext = std.fs.path.extension(parsed.file_path);
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

    const blame = try vcs.getLatestBlameInfo(ctx.run_arena, ctx.scratch(), root_path, parsed.file_path, detected_vcs);
    return .{ .result = .stale, .reason_code = .changed_after_baseline, .blame = blame };
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

fn jsonAnchorFromOutcome(raw_target: []const u8, sig: ?[]const u8, parsed: target.ParsedTarget, outcome: AnchorOutcome) JsonAnchorRow {
    const blame_storage = outcome.blame;
    return .{
        .blame_storage = blame_storage,
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

fn writeResultsText(w: *std.io.Writer, result: *const CheckResult, checked_any: bool) !void {
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

fn textEmitAnchor(w: *std.io.Writer, origin: ?[]const u8, row: drift_check_v1.Anchor, blame_storage: ?vcs.BlameInfo) void {
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
        if (origin) |o| {
            w.print("  SKIP   {s} (origin: {s})\n", .{ row.raw, o }) catch {};
        } else {
            w.print("  SKIP   {s}\n", .{row.raw}) catch {};
        }
    }
}

fn textEmitLink(w: *std.io.Writer, display_target: []const u8, row: drift_check_v1.Link) void {
    if (!std.mem.eql(u8, row.result, "broken")) return;
    w.print("  BROKEN  {s} ({s})\n", .{ display_target, row.reason.?.message }) catch {};
}

fn writeSummaryText(w: *std.io.Writer, result: *const CheckResult) !void {
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

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
