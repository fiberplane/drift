const std = @import("std");
const CommandContext = @import("../context.zig").CommandContext;
const content_mod = @import("../content.zig");
const lockfile = @import("../lockfile.zig");
const markdown = @import("../markdown.zig");
const repo_path = @import("../repo_path.zig");
const symbols = @import("../symbols.zig");
const target = @import("../target.zig");

const stale_context_line_cap = 10;

pub const RunError = error{ DocReadFailed, NoBindingsForDoc, CannotComputeFingerprint, TargetNotFound, HeadingNotFound, DocUnchanged };

pub fn run(
    ctx: CommandContext,
    stdout_w: *std.Io.Writer,
    stderr_w: *std.Io.Writer,
    doc_path: []const u8,
    optional_anchor: ?[]const u8,
    doc_is_still_accurate: bool,
) !void {
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.run_arena);

    const abs_doc_path = try std.Io.Dir.path.resolve(ctx.run_arena, &.{ cwd_path, doc_path });
    const doc_dir = std.Io.Dir.path.dirname(abs_doc_path) orelse cwd_path;
    var lf = try lockfile.discover(ctx.io, ctx.run_arena, ctx.scratch(), doc_dir);
    ctx.resetScratch();

    const doc_content = content_mod.normalizeLineEndings(std.Io.Dir.cwd().readFileAlloc(ctx.io, doc_path, ctx.run_arena, .limited(1024 * 1024)) catch |err| {
        stderr_w.print("error: cannot read '{s}': {s}\n", .{ doc_path, @errorName(err) }) catch {};
        return error.DocReadFailed;
    });

    const normalized_doc_path = try normalizeDocPath(ctx, lf.root_path, cwd_path, doc_path);
    ctx.resetScratch();

    if (optional_anchor) |raw_anchor| {
        const normalized_target = normalizeTargetPath(ctx, lf.root_path, cwd_path, raw_anchor) catch |err| switch (err) {
            error.TargetNotFound => {
                stderr_w.print("error: target not found: {s}\n", .{raw_anchor}) catch {};
                return err;
            },
            error.HeadingNotFound => {
                stderr_w.print("error: heading not found in target doc: {s}\n", .{raw_anchor}) catch {};
                return err;
            },
            else => return err,
        };
        ctx.resetScratch();

        const existing_binding = findBinding(lf.bindings.items, normalized_doc_path, normalized_target);
        const old_sig = if (existing_binding) |b| try copySig(ctx, b) else null;

        upsertBinding(ctx, &lf, cwd_path, normalized_doc_path, normalized_target) catch |err| switch (err) {
            error.CannotComputeFingerprint => {
                stderr_w.print("error: cannot compute fingerprint for target: {s}\n", .{raw_anchor}) catch {};
                return err;
            },
            else => return err,
        };

        const binding = findBinding(lf.bindings.items, normalized_doc_path, normalized_target).?;
        if (isDocGateBlocked(binding, old_sig, doc_is_still_accurate)) {
            printStaleContext(ctx, stderr_w, lf.root_path, cwd_path, doc_path, doc_content, binding.target);
            if (!promptDocAccurate(ctx.io, stderr_w)) return error.DocUnchanged;
        }
        binding.removeField("doc");

        try lockfile.writeFile(ctx.io, &lf, ctx.scratch());

        stdout_w.print("added {s} -> {s}", .{ normalized_doc_path, binding.target }) catch {};
        if (binding.fieldValue("sig")) |sig| {
            stdout_w.print(" sig:{s}", .{sig}) catch {};
        }
        stdout_w.print("\n", .{}) catch {};
        return;
    }

    var relinked_any = false;
    var refused_count: usize = 0;
    for (lf.bindings.items) |*binding| {
        if (!std.mem.eql(u8, binding.doc_path, normalized_doc_path)) continue;
        const old_sig = try copySig(ctx, binding);
        refreshBindingSig(ctx, cwd_path, lf.root_path, binding) catch |err| switch (err) {
            error.CannotComputeFingerprint => {
                stderr_w.print("error: cannot compute fingerprint for target: {s}\n", .{binding.target}) catch {};
                return err;
            },
            else => return err,
        };

        if (isDocGateBlocked(binding, old_sig, doc_is_still_accurate)) {
            refused_count += 1;
        } else {
            binding.removeField("doc");
        }
        relinked_any = true;
    }

    if (!relinked_any) {
        stderr_w.print("no bindings found for {s}\n", .{normalized_doc_path}) catch {};
        return error.NoBindingsForDoc;
    }

    if (refused_count > 0) {
        printBlanketRefusal(ctx, stderr_w, lf.root_path, cwd_path, doc_path, doc_content, lf.bindings.items, normalized_doc_path, refused_count);
        if (!promptDocAccurate(ctx.io, stderr_w)) return error.DocUnchanged;
    }

    try lockfile.writeFile(ctx.io, &lf, ctx.scratch());
    stdout_w.print("relinked all anchors in {s}\n", .{normalized_doc_path}) catch {};
}

/// In TTY mode, prompt the user to confirm the doc is still accurate.
/// In non-TTY mode, print the refusal message and return false.
fn promptDocAccurate(io: std.Io, stderr_w: *std.Io.Writer) bool {
    const stdin = std.Io.File.stdin();
    const is_tty = stdin.isTty(io) catch false;
    if (!is_tty) {
        stderr_w.print("refused: target changed since last link.\nReview the doc, then relink with --doc-is-still-accurate.\n", .{}) catch {};
        return false;
    }
    stderr_w.print("Doc is still accurate? [y/N] ", .{}) catch {};
    stderr_w.flush() catch {};
    var buf: [16]u8 = undefined;
    var stdin_reader = stdin.readerStreaming(io, &buf);
    const slice = stdin_reader.interface.takeDelimiterExclusive('\n') catch return false;
    const answer = std.mem.trimEnd(u8, slice, "\r\n \t");
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

/// Copy a binding's current signature out before restamping it.
///
/// `Binding.setField` frees the previous value, so a slice held across
/// `refreshBindingSig` dangles and the gate below would compare against freed
/// memory — refusing or waving through a relink depending on what the allocator
/// happened to leave there.
fn copySig(ctx: CommandContext, binding: *const lockfile.Binding) !?[]const u8 {
    const sig = binding.fieldValue("sig") orelse return null;
    return try ctx.run_arena.dupe(u8, sig);
}

/// Returns true when a relink should be refused: target changed without review.
fn isDocGateBlocked(
    binding: *lockfile.Binding,
    old_sig: ?[]const u8,
    doc_is_still_accurate: bool,
) bool {
    if (doc_is_still_accurate) return false;
    const os = old_sig orelse return false;
    const ns = binding.fieldValue("sig") orelse return true;
    return !std.mem.eql(u8, os, ns);
}

/// Print a consolidated refusal for blanket relink: doc section once, then
/// each refused binding with its target context.
fn printBlanketRefusal(
    ctx: CommandContext,
    stderr_w: *std.Io.Writer,
    root_path: []const u8,
    cwd_path: []const u8,
    doc_path: []const u8,
    doc_content: []const u8,
    bindings: []lockfile.Binding,
    normalized_doc_path: []const u8,
    refused_count: usize,
) void {
    // Print the doc section once using the first binding for this doc
    const parsed_first = blk: {
        for (bindings) |*b| {
            if (std.mem.eql(u8, b.doc_path, normalized_doc_path)) break :blk target.parse(b.target);
        }
        return;
    };
    printDocSection(stderr_w, doc_path, doc_content, parsed_first.identity, parsed_first);

    // Print each binding's target context
    for (bindings) |*b| {
        if (!std.mem.eql(u8, b.doc_path, normalized_doc_path)) continue;

        const parsed = target.parse(b.target);
        if (parsed.isHeading()) {
            printHeadingTarget(ctx, stderr_w, root_path, cwd_path, parsed);
        } else if (parsed.symbol_name != null) {
            printSymbolTarget(ctx, stderr_w, root_path, cwd_path, parsed);
        }

        stderr_w.print("  STALE  {s}\n", .{b.target}) catch {};
    }

    stderr_w.print("\n{d} stale anchor{s} in {s}\n", .{
        refused_count,
        if (refused_count == 1) "" else "s",
        doc_path,
    }) catch {};
}

fn upsertBinding(
    ctx: CommandContext,
    lf: *lockfile.Lockfile,
    cwd_path: []const u8,
    normalized_doc_path: []const u8,
    normalized_target: []const u8,
) !void {
    if (findBinding(lf.bindings.items, normalized_doc_path, normalized_target)) |binding| {
        try refreshBindingSig(ctx, cwd_path, lf.root_path, binding);
        return;
    }

    var binding = lockfile.Binding{
        .doc_path = try ctx.run_arena.dupe(u8, normalized_doc_path),
        .target = try ctx.run_arena.dupe(u8, normalized_target),
        .metadata = .empty,
    };
    try refreshBindingSig(ctx, cwd_path, lf.root_path, &binding);
    try lf.bindings.append(ctx.run_arena, binding);
}

fn refreshBindingSig(
    ctx: CommandContext,
    cwd_path: []const u8,
    root_path: []const u8,
    binding: *lockfile.Binding,
) !void {
    var hex: [16]u8 = undefined;
    try computeTargetSigInto(ctx, cwd_path, root_path, binding.target, &hex);
    try binding.setField(ctx.run_arena, "sig", hex[0..16]);
}

fn computeTargetSigInto(
    ctx: CommandContext,
    cwd_path: []const u8,
    root_path: []const u8,
    raw_target: []const u8,
    hex_out: *[16]u8,
) !void {
    const parsed = target.parse(raw_target);
    const absolute_path = try resolveInputPath(ctx, root_path, cwd_path, parsed.file_path);
    const content = try readResolvedFile(ctx, absolute_path);
    if (!symbols.writeFingerprintHex(hex_out, content, parsed.file_path, parsed.symbol_name)) {
        ctx.resetScratch();
        return error.CannotComputeFingerprint;
    }
    ctx.resetScratch();
}

fn normalizeDocPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    doc_path: []const u8,
) ![]const u8 {
    const absolute = try resolveInputPath(ctx, root_path, cwd_path, doc_path);
    const relative = repo_path.normalize(try std.Io.Dir.path.relative(ctx.run_arena, "", null, root_path, absolute));
    ctx.resetScratch();
    return relative;
}

fn normalizeTargetPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    raw_target: []const u8,
) ![]const u8 {
    const parsed = target.parse(raw_target);
    const absolute = try resolveInputPath(ctx, root_path, cwd_path, parsed.file_path);
    if (!pathExists(ctx.io, absolute)) {
        ctx.resetScratch();
        return error.TargetNotFound;
    }

    const relative = repo_path.normalize(try std.Io.Dir.path.relative(ctx.run_arena, "", null, root_path, absolute));

    if (parsed.symbol_name) |symbol| {
        if (parsed.isHeading()) {
            const content = try readResolvedFile(ctx, absolute);
            const slug_buf = try ctx.scratch().alloc(u8, symbol.len);
            const slug = markdown.headingToSlug(slug_buf, symbol);
            if (!markdown.headingExists(content, slug)) {
                ctx.resetScratch();
                return error.HeadingNotFound;
            }
            const normalized = try std.fmt.allocPrint(ctx.run_arena, "{s}#{s}", .{ relative, slug });
            ctx.resetScratch();
            return normalized;
        }
        const normalized = try std.fmt.allocPrint(ctx.run_arena, "{s}#{s}", .{ relative, symbol });
        ctx.resetScratch();
        return normalized;
    }

    ctx.resetScratch();
    return relative;
}

fn resolveInputPath(
    ctx: CommandContext,
    root_path: []const u8,
    cwd_path: []const u8,
    path: []const u8,
) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(path)) {
        return try ctx.scratch().dupe(u8, path);
    }

    const cwd_candidate = try std.Io.Dir.path.resolve(ctx.scratch(), &.{ cwd_path, path });
    if (pathExists(ctx.io, cwd_candidate)) return cwd_candidate;

    return try std.Io.Dir.path.resolve(ctx.scratch(), &.{ root_path, path });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn readResolvedFile(ctx: CommandContext, path: []const u8) ![]const u8 {
    const file = if (std.Io.Dir.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(ctx.io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var file_reader = file.reader(ctx.io, &.{});
    return content_mod.normalizeLineEndings(try file_reader.interface.allocRemaining(ctx.scratch(), .limited(1024 * 1024)));
}

fn findBinding(bindings: []lockfile.Binding, doc_path: []const u8, normalized_target: []const u8) ?*lockfile.Binding {
    for (bindings) |*binding| {
        if (std.mem.eql(u8, binding.doc_path, doc_path) and std.mem.eql(u8, binding.target, normalized_target)) {
            return binding;
        }
    }
    return null;
}

/// Print context for a stale relink refusal: the doc section and the current
/// code/heading/commits depending on anchor type. Best-effort — failures are
/// silently ignored so the refusal message always follows.
fn printStaleContext(
    ctx: CommandContext,
    stderr_w: *std.Io.Writer,
    root_path: []const u8,
    cwd_path: []const u8,
    doc_path: []const u8,
    doc_content: []const u8,
    binding_target: []const u8,
) void {
    const parsed = target.parse(binding_target);

    // Header line: doc_path -> binding_target  STALE
    stderr_w.print("\n{s} -> {s}  STALE\n", .{ doc_path, binding_target }) catch {};

    // --- doc section ---
    printDocSection(stderr_w, doc_path, doc_content, binding_target, parsed);

    // --- target section (symbol or heading anchors only) ---
    if (parsed.isHeading()) {
        printHeadingTarget(ctx, stderr_w, root_path, cwd_path, parsed);
    } else if (parsed.symbol_name != null) {
        printSymbolTarget(ctx, stderr_w, root_path, cwd_path, parsed);
    }

    stderr_w.print("\n", .{}) catch {};
}

fn printDocSection(
    stderr_w: *std.Io.Writer,
    doc_path: []const u8,
    doc_content: []const u8,
    binding_target: []const u8,
    parsed: target.ParsedTarget,
) void {
    const section_text = findDocSectionForTarget(doc_content, binding_target, parsed);
    const heading_label = findNearestHeadingAbove(doc_content, section_text);

    if (heading_label) |label| {
        stderr_w.print("\n── doc ── {s} ##{s} ──\n", .{ doc_path, label }) catch {};
    } else {
        stderr_w.print("\n── doc ── {s} ──\n", .{doc_path}) catch {};
    }

    printCappedLines(stderr_w, section_text);
}

/// Search doc_content for a line referencing the target. Extract the enclosing
/// heading section. Falls back to the first stale_context_line_cap lines.
fn findDocSectionForTarget(
    doc_content: []const u8,
    binding_target: []const u8,
    parsed: target.ParsedTarget,
) []const u8 {
    // Try to find a line referencing the target file path or symbol name
    const search_terms = [_][]const u8{
        binding_target,
        parsed.file_path,
        if (parsed.symbol_name) |s| s else "",
    };

    var lines = std.mem.splitScalar(u8, doc_content, '\n');
    var line_start: usize = 0;
    var match_offset: ?usize = null;

    while (lines.next()) |line| {
        for (search_terms) |term| {
            if (term.len > 0 and std.mem.find(u8, line, term) != null) {
                match_offset = line_start;
                break;
            }
        }
        if (match_offset != null) break;
        line_start += line.len + 1;
    }

    if (match_offset) |offset| {
        return extractSectionAroundOffset(doc_content, offset);
    }

    // Fallback: return the beginning of the doc
    return firstNLines(doc_content, stale_context_line_cap);
}

/// Walk backwards from offset to find the nearest heading, then forward to the
/// next heading of equal or higher level (or EOF).
fn extractSectionAroundOffset(content: []const u8, offset: usize) []const u8 {
    // Find nearest heading above offset
    var heading_start: usize = 0;
    var heading_level: usize = 0;
    var pos: usize = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            const level = countLeadingChar(trimmed, '#');
            if (level > 0 and level <= 6 and pos <= offset) {
                heading_start = pos;
                heading_level = level;
            }
        }
        if (pos > offset and heading_level > 0) {
            // We've passed the match; now find the end of the section
            break;
        }
        pos += line.len + 1;
    }

    if (heading_level == 0) {
        return firstNLines(content, stale_context_line_cap);
    }

    // Find the end: next heading of equal or higher level
    var section_end: usize = content.len;
    pos = heading_start;
    var past_heading = false;
    var iter2 = std.mem.splitScalar(u8, content[heading_start..], '\n');

    while (iter2.next()) |line| {
        if (past_heading) {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '#') {
                const level = countLeadingChar(trimmed, '#');
                if (level > 0 and level <= heading_level) {
                    section_end = pos;
                    break;
                }
            }
        } else {
            past_heading = true;
        }
        pos += line.len + 1;
    }

    const section = content[heading_start..@min(section_end, content.len)];
    return std.mem.trimEnd(u8, section, "\n\r ");
}

fn countLeadingChar(s: []const u8, c: u8) usize {
    var count: usize = 0;
    for (s) |ch| {
        if (ch == c) count += 1 else break;
    }
    return count;
}

/// Find the heading text for the section containing `section_text` within `doc_content`.
fn findNearestHeadingAbove(doc_content: []const u8, section_text: []const u8) ?[]const u8 {
    // section_text is a slice of doc_content, so we can compute the offset
    if (@intFromPtr(section_text.ptr) < @intFromPtr(doc_content.ptr)) return null;
    const offset = @intFromPtr(section_text.ptr) - @intFromPtr(doc_content.ptr);
    if (offset > doc_content.len) return null;

    const prefix = doc_content[0..offset];
    // Find the last heading line in prefix
    var last_heading: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, prefix, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            const hashes = countLeadingChar(trimmed, '#');
            if (hashes > 0 and hashes <= 6 and trimmed.len > hashes) {
                last_heading = std.mem.trim(u8, trimmed[hashes..], " \t");
            }
        }
    }

    // Also check if section_text itself starts with a heading
    const first_line_end = std.mem.findScalar(u8, section_text, '\n') orelse section_text.len;
    const first_line = std.mem.trimStart(u8, section_text[0..first_line_end], " \t");
    if (first_line.len > 0 and first_line[0] == '#') {
        const hashes = countLeadingChar(first_line, '#');
        if (hashes > 0 and hashes <= 6 and first_line.len > hashes) {
            return std.mem.trim(u8, first_line[hashes..], " \t");
        }
    }

    return last_heading;
}

fn printHeadingTarget(
    ctx: CommandContext,
    stderr_w: *std.Io.Writer,
    root_path: []const u8,
    cwd_path: []const u8,
    parsed: target.ParsedTarget,
) void {
    const absolute_path = resolveInputPath(ctx, root_path, cwd_path, parsed.file_path) catch return;
    const content = readResolvedFile(ctx, absolute_path) catch return;
    defer ctx.resetScratch();

    const symbol = parsed.symbol_name orelse return;
    const range = markdown.extractHeadingSectionContent(content, symbol) orelse return;
    const section = content[range[0]..range[1]];
    const line_count = countLines(section);

    stderr_w.print("\n── target ── {s} ({d} lines) ──\n", .{ parsed.identity, line_count }) catch {};
    printCappedLines(stderr_w, section);
}

fn printSymbolTarget(
    ctx: CommandContext,
    stderr_w: *std.Io.Writer,
    root_path: []const u8,
    cwd_path: []const u8,
    parsed: target.ParsedTarget,
) void {
    const absolute_path = resolveInputPath(ctx, root_path, cwd_path, parsed.file_path) catch return;
    const content = readResolvedFile(ctx, absolute_path) catch return;
    defer ctx.resetScratch();

    const symbol = parsed.symbol_name orelse return;
    const ext = std.Io.Dir.path.extension(parsed.file_path);
    const lang_query = symbols.languageForExtension(ext) orelse return;
    const range = symbols.extractSymbolContent(content, lang_query, symbol) orelse return;
    const source = content[range[0]..range[1]];
    const line_count = countLines(source);

    stderr_w.print("\n── code ── {s} ({d} lines) ──\n", .{ parsed.identity, line_count }) catch {};
    printCappedLines(stderr_w, source);
}

fn printCappedLines(stderr_w: *std.Io.Writer, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var printed: usize = 0;

    while (lines.next()) |line| {
        if (printed >= stale_context_line_cap) {
            stderr_w.print("  ... ({d} more lines)\n", .{countLines(lines.rest()) + 1}) catch {};
            return;
        }
        stderr_w.print("{s}\n", .{line}) catch {};
        printed += 1;
    }
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    // Don't count a trailing newline as an extra line
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

fn firstNLines(content: []const u8, n: usize) []const u8 {
    var end: usize = 0;
    var line_count: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            line_count += 1;
            if (line_count >= n) {
                end = i;
                break;
            }
        }
        end = i + 1;
    }
    return content[0..end];
}
