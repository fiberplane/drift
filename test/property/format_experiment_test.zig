//! Format experiment: measure the spurious-conflict rate of the `git merge-file`
//! default 3-way merge against several lockfile layout variants.
//!
//! Property 2 established that the current single-line sorted format produces
//! spurious textual conflicts on ~40% of disjoint-edit trials, with 0 semantic
//! mismatches. The experiment here asks: can a format tweak alone (no custom
//! merge driver, no `.gitattributes`) push that rate down?
//!
//! Mechanism: git's unified diff uses a 3-line context window. Two adjacent
//! line-edits fall into the same hunk and conflict. If bindings are laid out so
//! there's >= 3 lines of untouched context between any two of them, their hunks
//! don't overlap and the merge is clean.
//!
//! Variants measured:
//!   V0 baseline            — one sorted line per binding (current format)
//!   V1 multiline-blocks    — header + indented fields + 3 blank lines between
//!   V2 sectioned-single    — `# doc` section headers, single-line bindings
//!   V3 sectioned-multiline — sections + multi-line blocks within
//!
//! The generator clusters bindings into a small doc pool (so sectioning has
//! something to group by) and is otherwise identical to Property 2's.

const std = @import("std");
const minish = @import("minish");
const lockfile = @import("../../src/lockfile.zig");
const helpers = @import("helpers");
const toml_variants = @import("toml_variants_test.zig");

const GenError = minish.GenError;
const TestCase = minish.TestCase;

// ------------------------------------------------------------------
// Raw state + op vocabulary (duplicated from lockfile_merge_test.zig;
// scoped to this experiment — refactor if a fourth consumer appears).
// ------------------------------------------------------------------

const RawField = struct {
    key: []const u8,
    value: []const u8,
};

const RawEntry = struct {
    doc_path: []const u8,
    target: []const u8,
    fields: []const RawField,
};

const Op = union(enum) {
    add: struct { doc_path: []const u8, target: []const u8, fields: []const RawField },
    remove: struct { doc_path: []const u8, target: []const u8 },
    set_field: struct { doc_path: []const u8, target: []const u8, key: []const u8, value: []const u8 },
    remove_field: struct { doc_path: []const u8, target: []const u8, key: []const u8 },
};

const MergeState = struct {
    base: []const RawEntry,
    left_ops: []const Op,
    right_ops: []const Op,
};

const KEY_POOL = [_][]const u8{ "sig", "origin", "lang", "ver", "ref", "hash" };
const DOC_POOL = [_][]const u8{ "doc_a", "doc_b", "doc_c" }; // <= more bindings / doc
const MAX_BASE = 6;
const MAX_OPS_PER_SIDE = 3;

fn genValue(tc: *TestCase) GenError![]const u8 {
    const CHARS = "0123456789abcdef";
    const len = 1 + try tc.choice(3);
    var buf = try tc.allocator.alloc(u8, len);
    errdefer tc.allocator.free(buf);
    for (0..len) |i| {
        const idx = try tc.choice(CHARS.len - 1);
        buf[i] = CHARS[idx];
    }
    return buf;
}

fn genFields(tc: *TestCase) GenError![]const RawField {
    var indices: [KEY_POOL.len]usize = undefined;
    for (0..KEY_POOL.len) |i| indices[i] = i;
    var i: usize = KEY_POOL.len;
    while (i > 1) {
        i -= 1;
        const j = try tc.choice(@intCast(i));
        std.mem.swap(usize, &indices[i], &indices[j]);
    }
    const num = try tc.choice(KEY_POOL.len);
    var fields = try tc.allocator.alloc(RawField, num);
    errdefer {
        for (fields) |f| {
            tc.allocator.free(f.key);
            tc.allocator.free(f.value);
        }
        tc.allocator.free(fields);
    }
    for (0..num) |f_idx| {
        const key = try tc.allocator.dupe(u8, KEY_POOL[indices[f_idx]]);
        errdefer tc.allocator.free(key);
        const value = try genValue(tc);
        fields[f_idx] = .{ .key = key, .value = value };
    }
    return fields;
}

fn genOp(
    tc: *TestCase,
    side_entries: []const RawEntry,
    side_prefix: u8,
    add_counter: *usize,
) GenError!Op {
    const max_kind: u64 = if (side_entries.len == 0) 0 else 3;
    const kind = try tc.choice(max_kind);
    switch (kind) {
        0 => {
            // Adds share a doc with base entries ~half the time — models the
            // "add a new binding for an existing markdown file" case.
            const use_existing = side_entries.len > 0 and (try tc.choice(1)) == 0;
            const doc_path = if (use_existing) blk: {
                const idx = try tc.choice(side_entries.len - 1);
                break :blk try tc.allocator.dupe(u8, side_entries[idx].doc_path);
            } else try std.fmt.allocPrint(tc.allocator, "doc_{c}_{d}", .{ side_prefix, add_counter.* });
            errdefer tc.allocator.free(doc_path);
            const target = try std.fmt.allocPrint(tc.allocator, "src_{c}_{d}", .{ side_prefix, add_counter.* });
            errdefer tc.allocator.free(target);
            add_counter.* += 1;
            const fields = try genFields(tc);
            return .{ .add = .{ .doc_path = doc_path, .target = target, .fields = fields } };
        },
        1 => {
            const idx = try tc.choice(side_entries.len - 1);
            return .{ .remove = .{
                .doc_path = try tc.allocator.dupe(u8, side_entries[idx].doc_path),
                .target = try tc.allocator.dupe(u8, side_entries[idx].target),
            } };
        },
        2 => {
            const idx = try tc.choice(side_entries.len - 1);
            const key_idx = try tc.choice(KEY_POOL.len - 1);
            return .{ .set_field = .{
                .doc_path = try tc.allocator.dupe(u8, side_entries[idx].doc_path),
                .target = try tc.allocator.dupe(u8, side_entries[idx].target),
                .key = try tc.allocator.dupe(u8, KEY_POOL[key_idx]),
                .value = try genValue(tc),
            } };
        },
        3 => {
            const idx = try tc.choice(side_entries.len - 1);
            const key_idx = try tc.choice(KEY_POOL.len - 1);
            return .{ .remove_field = .{
                .doc_path = try tc.allocator.dupe(u8, side_entries[idx].doc_path),
                .target = try tc.allocator.dupe(u8, side_entries[idx].target),
                .key = try tc.allocator.dupe(u8, KEY_POOL[key_idx]),
            } };
        },
        else => unreachable,
    }
}

fn freeEntry(alloc: std.mem.Allocator, e: RawEntry) void {
    alloc.free(e.doc_path);
    alloc.free(e.target);
    for (e.fields) |f| {
        alloc.free(f.key);
        alloc.free(f.value);
    }
    alloc.free(e.fields);
}

fn freeOp(alloc: std.mem.Allocator, op: Op) void {
    switch (op) {
        .add => |a| {
            alloc.free(a.doc_path);
            alloc.free(a.target);
            for (a.fields) |f| {
                alloc.free(f.key);
                alloc.free(f.value);
            }
            alloc.free(a.fields);
        },
        .remove => |r| {
            alloc.free(r.doc_path);
            alloc.free(r.target);
        },
        .set_field => |s| {
            alloc.free(s.doc_path);
            alloc.free(s.target);
            alloc.free(s.key);
            alloc.free(s.value);
        },
        .remove_field => |r| {
            alloc.free(r.doc_path);
            alloc.free(r.target);
            alloc.free(r.key);
        },
    }
}

fn generateMergeState(tc: *TestCase) GenError!MergeState {
    const num_base = try tc.choice(MAX_BASE);
    var base = try tc.allocator.alloc(RawEntry, num_base);
    errdefer {
        for (base) |e| freeEntry(tc.allocator, e);
        tc.allocator.free(base);
    }
    for (0..num_base) |i| {
        const doc_idx = try tc.choice(DOC_POOL.len - 1);
        const doc_path = try tc.allocator.dupe(u8, DOC_POOL[doc_idx]);
        errdefer tc.allocator.free(doc_path);
        const target = try std.fmt.allocPrint(tc.allocator, "src_{d}", .{i});
        errdefer tc.allocator.free(target);
        const fields = try genFields(tc);
        base[i] = .{ .doc_path = doc_path, .target = target, .fields = fields };
    }

    var left_entries: std.ArrayList(RawEntry) = .empty;
    errdefer left_entries.deinit(tc.allocator);
    var right_entries: std.ArrayList(RawEntry) = .empty;
    errdefer right_entries.deinit(tc.allocator);
    for (base) |e| {
        const is_left = (try tc.choice(1)) == 0;
        if (is_left) try left_entries.append(tc.allocator, e) else try right_entries.append(tc.allocator, e);
    }

    var left_add_counter: usize = 0;
    var right_add_counter: usize = 0;

    var left_ops: std.ArrayList(Op) = .empty;
    errdefer {
        for (left_ops.items) |op| freeOp(tc.allocator, op);
        left_ops.deinit(tc.allocator);
    }
    const num_left = try tc.choice(MAX_OPS_PER_SIDE);
    for (0..num_left) |_| try left_ops.append(tc.allocator, try genOp(tc, left_entries.items, 'L', &left_add_counter));

    var right_ops: std.ArrayList(Op) = .empty;
    errdefer {
        for (right_ops.items) |op| freeOp(tc.allocator, op);
        right_ops.deinit(tc.allocator);
    }
    const num_right = try tc.choice(MAX_OPS_PER_SIDE);
    for (0..num_right) |_| try right_ops.append(tc.allocator, try genOp(tc, right_entries.items, 'R', &right_add_counter));

    left_entries.deinit(tc.allocator);
    right_entries.deinit(tc.allocator);

    return .{
        .base = base,
        .left_ops = try left_ops.toOwnedSlice(tc.allocator),
        .right_ops = try right_ops.toOwnedSlice(tc.allocator),
    };
}

fn freeMergeState(alloc: std.mem.Allocator, state: MergeState) void {
    for (state.base) |e| freeEntry(alloc, e);
    alloc.free(state.base);
    for (state.left_ops) |op| freeOp(alloc, op);
    alloc.free(state.left_ops);
    for (state.right_ops) |op| freeOp(alloc, op);
    alloc.free(state.right_ops);
}

const merge_gen: minish.gen.Generator(MergeState) = .{
    .generateFn = generateMergeState,
    .shrinkFn = null,
    .freeFn = freeMergeState,
};

// ------------------------------------------------------------------
// Apply ops to base → ArrayList(lockfile.Binding)
// ------------------------------------------------------------------

fn findBinding(bindings: *std.ArrayList(lockfile.Binding), doc_path: []const u8, target: []const u8) ?usize {
    for (bindings.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.doc_path, doc_path) and std.mem.eql(u8, b.target, target)) return i;
    }
    return null;
}

fn applyOp(arena: std.mem.Allocator, bindings: *std.ArrayList(lockfile.Binding), op: Op) !void {
    switch (op) {
        .add => |a| {
            var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
            for (a.fields) |f| try metadata.append(arena, .{
                .key = try arena.dupe(u8, f.key),
                .value = try arena.dupe(u8, f.value),
            });
            try bindings.append(arena, .{
                .doc_path = try arena.dupe(u8, a.doc_path),
                .target = try arena.dupe(u8, a.target),
                .metadata = metadata,
            });
        },
        .remove => |r| {
            if (findBinding(bindings, r.doc_path, r.target)) |idx| _ = bindings.orderedRemove(idx);
        },
        .set_field => |s| {
            if (findBinding(bindings, s.doc_path, s.target)) |idx| try bindings.items[idx].setField(arena, s.key, s.value);
        },
        .remove_field => |r| {
            if (findBinding(bindings, r.doc_path, r.target)) |idx| bindings.items[idx].removeField(r.key);
        },
    }
}

fn applyOps(arena: std.mem.Allocator, base: []const RawEntry, ops: []const Op) !std.ArrayList(lockfile.Binding) {
    var bindings: std.ArrayList(lockfile.Binding) = .empty;
    for (base) |e| {
        var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
        for (e.fields) |f| try metadata.append(arena, .{
            .key = try arena.dupe(u8, f.key),
            .value = try arena.dupe(u8, f.value),
        });
        try bindings.append(arena, .{
            .doc_path = try arena.dupe(u8, e.doc_path),
            .target = try arena.dupe(u8, e.target),
            .metadata = metadata,
        });
    }
    for (ops) |op| try applyOp(arena, &bindings, op);
    return bindings;
}

// ------------------------------------------------------------------
// Format variants. Each takes an arena and a slice of Bindings, returns
// serialized bytes. All variants produce a deterministic byte string given
// the same semantic state.
// ------------------------------------------------------------------

const SerializeFn = *const fn (std.mem.Allocator, []const lockfile.Binding) anyerror![]u8;
const ParseFn = *const fn (std.mem.Allocator, []const u8) anyerror!std.ArrayList(lockfile.Binding);

fn serializeV0Baseline(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    return try lockfile.serialize(alloc, bindings);
}

fn compareBindings(_: void, a: lockfile.Binding, b: lockfile.Binding) bool {
    const doc_cmp = std.mem.order(u8, a.doc_path, b.doc_path);
    if (doc_cmp != .eq) return doc_cmp == .lt;
    return std.mem.order(u8, a.target, b.target) == .lt;
}

fn sortedMetadataCopy(alloc: std.mem.Allocator, fields: []const lockfile.MetadataField) ![]lockfile.MetadataField {
    const sorted = try alloc.dupe(lockfile.MetadataField, fields);
    std.mem.sort(lockfile.MetadataField, sorted, {}, struct {
        fn lt(_: void, a: lockfile.MetadataField, b: lockfile.MetadataField) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return sorted;
}

/// V1: `doc -> target` header, indented fields, 3 blank lines between blocks.
/// 3 blank lines guarantees git's default 3-line unified-diff context can't
/// span a binding boundary.
fn serializeV1MultilineBlocks(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        try w.print("{s} -> {s}\n", .{ b.doc_path, b.target });
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("  {s}: {s}\n", .{ f.key, f.value });
        if (i + 1 < sorted.len) try w.writeAll("\n\n\n");
    }
    return try out.toOwnedSlice();
}

/// V2: `# <doc>` section headers, single-line bindings within the section,
/// sections separated by a blank line. Cross-doc edits are separated by at
/// least 3 non-changing lines (blank + header + blank/content) so they
/// typically land in different hunks; within a section, bindings remain
/// adjacent and can still collide.
fn serializeV2SectionedSingle(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    var i: usize = 0;
    while (i < sorted.len) {
        const section_doc = sorted[i].doc_path;
        if (i > 0) try w.writeAll("\n\n");
        try w.print("# {s}\n", .{section_doc});
        while (i < sorted.len and std.mem.eql(u8, sorted[i].doc_path, section_doc)) : (i += 1) {
            try w.print("{s} -> {s}", .{ sorted[i].doc_path, sorted[i].target });
            const fields = try sortedMetadataCopy(alloc, sorted[i].metadata.items);
            defer alloc.free(fields);
            for (fields) |f| try w.print(" {s}:{s}", .{ f.key, f.value });
            try w.writeByte('\n');
        }
    }
    return try out.toOwnedSlice();
}

/// V3: sectioned headers AND multi-line blocks within each section. Maximum
/// separation both across docs and across bindings within a doc.
fn serializeV3SectionedMultiline(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    var i: usize = 0;
    while (i < sorted.len) {
        const section_doc = sorted[i].doc_path;
        if (i > 0) try w.writeAll("\n\n\n");
        try w.print("# {s}\n", .{section_doc});
        var first_in_section = true;
        while (i < sorted.len and std.mem.eql(u8, sorted[i].doc_path, section_doc)) : (i += 1) {
            if (!first_in_section) try w.writeAll("\n\n\n");
            first_in_section = false;
            try w.print("{s} -> {s}\n", .{ sorted[i].doc_path, sorted[i].target });
            const fields = try sortedMetadataCopy(alloc, sorted[i].metadata.items);
            defer alloc.free(fields);
            for (fields) |f| try w.print("  {s}: {s}\n", .{ f.key, f.value });
        }
    }
    return try out.toOwnedSlice();
}

/// V4: TOML array-of-tables. `[[bindings]]` header is a highly distinctive
/// anchor (unlike blank lines); blocks separated by a single blank line per
/// TOML convention, so the anchor line is doing the alignment work, not padding.
fn serializeV4TomlTables(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        if (i > 0) try w.writeAll("\n");
        try w.writeAll("[[bindings]]\n");
        try w.print("doc = \"{s}\"\n", .{b.doc_path});
        try w.print("target = \"{s}\"\n", .{b.target});
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("{s} = \"{s}\"\n", .{ f.key, f.value });
    }
    return try out.toOwnedSlice();
}

/// V5: YAML-ish doc-keyed nested map. Indentation implies grouping, no repeated
/// doc_path on every line, no explicit separators. Tests whether structural
/// hierarchy alone produces enough context for git's merge.
fn serializeV5YamlNested(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    var i: usize = 0;
    while (i < sorted.len) {
        const section_doc = sorted[i].doc_path;
        try w.print("\"{s}\":\n", .{section_doc});
        while (i < sorted.len and std.mem.eql(u8, sorted[i].doc_path, section_doc)) : (i += 1) {
            try w.print("  \"{s}\":\n", .{sorted[i].target});
            const fields = try sortedMetadataCopy(alloc, sorted[i].metadata.items);
            defer alloc.free(fields);
            for (fields) |f| try w.print("    {s}: \"{s}\"\n", .{ f.key, f.value });
        }
    }
    return try out.toOwnedSlice();
}

/// V6: multi-line blocks separated by a single `---` line — no blank padding.
/// Tests whether a distinctive anchor line compensates for lack of physical
/// separation.
fn serializeV6HrSeparator(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        if (i > 0) try w.writeAll("---\n");
        try w.print("{s} -> {s}\n", .{ b.doc_path, b.target });
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("  {s}: {s}\n", .{ f.key, f.value });
    }
    return try out.toOwnedSlice();
}

/// V7: single-line per binding but with `doc_path` and `target` padded to the
/// max widths across the whole file. Tests whether column alignment alone
/// helps git's diff match corresponding fields across branches — no multi-line
/// spreading, no separators.
fn serializeV7AlignedColumns(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var max_doc: usize = 0;
    var max_target: usize = 0;
    for (sorted) |b| {
        if (b.doc_path.len > max_doc) max_doc = b.doc_path.len;
        if (b.target.len > max_target) max_target = b.target.len;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted) |b| {
        try w.writeAll(b.doc_path);
        for (0..max_doc - b.doc_path.len) |_| try w.writeByte(' ');
        try w.writeAll(" -> ");
        try w.writeAll(b.target);
        for (0..max_target - b.target.len) |_| try w.writeByte(' ');
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print(" {s}:{s}", .{ f.key, f.value });
        try w.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

fn shardBucket(comptime n: u32, b: lockfile.Binding) usize {
    var hasher = std.hash.XxHash3.init(0);
    hasher.update(b.doc_path);
    hasher.update("\x00");
    hasher.update(b.target);
    return @as(usize, @intCast(hasher.final() & (n - 1)));
}

/// Sharded single-line (sharded V0) factory. `n` is the bucket count (must be
/// power of two). All `n` bucket headers are emitted unconditionally — empty
/// buckets included — so each bucket has a stable line offset in base. Adds
/// with different hashes go to different anchor regions, breaking the "both
/// branches insert at the same line" pattern that kills V0–V10's add/add bucket.
fn makeShardedSingle(comptime n: u32) SerializeFn {
    return struct {
        fn serialize(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
            var buckets: [n]std.ArrayList(lockfile.Binding) = undefined;
            for (&buckets) |*b| b.* = .empty;
            defer for (&buckets) |*b| b.deinit(alloc);
            for (bindings) |b| try buckets[shardBucket(n, b)].append(alloc, b);

            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            const w = &out.writer;
            for (buckets, 0..) |bucket, idx| {
                try w.print("# {x:0>2}\n", .{idx});
                try lockfile.serializeToWriter(alloc, w, bucket.items);
            }
            return try out.toOwnedSlice();
        }
    }.serialize;
}

fn semanticBucket(b: lockfile.Binding) usize {
    var basename_start: usize = 0;
    for (b.doc_path, 0..) |c, i| {
        if (c == '/') basename_start = i + 1;
    }
    if (basename_start >= b.doc_path.len) return 26;
    const c = b.doc_path[basename_start];
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c >= 'A' and c <= 'Z') return c - 'A';
    return 26;
}

/// V19 (the "V21" from conversation): semantic bucketing of V4 by first letter
/// of doc basename. Bucket header is the letter itself (`# a` ... `# z`, plus
/// `# _` catch-all). All 27 headers are emitted unconditionally for merge-stable
/// anchors. Unlike hash sharding, dilution is data-dependent: works well when
/// doc paths are alphabetically diverse, degenerates if they share a prefix.
fn serializeV19SemToml(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const N = 27;
    var buckets: [N]std.ArrayList(lockfile.Binding) = undefined;
    for (&buckets) |*b| b.* = .empty;
    defer for (&buckets) |*b| b.deinit(alloc);
    for (bindings) |b| try buckets[semanticBucket(b)].append(alloc, b);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (buckets, 0..) |bucket, idx| {
        if (idx < 26) {
            try w.print("# {c}\n", .{@as(u8, 'a') + @as(u8, @intCast(idx))});
        } else {
            try w.writeAll("# _\n");
        }
        const sorted = try alloc.dupe(lockfile.Binding, bucket.items);
        defer alloc.free(sorted);
        std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);
        for (sorted, 0..) |b, i| {
            if (i > 0) try w.writeAll("\n");
            try w.writeAll("[[bindings]]\n");
            try w.print("doc = \"{s}\"\n", .{b.doc_path});
            try w.print("target = \"{s}\"\n", .{b.target});
            const fields = try sortedMetadataCopy(alloc, b.metadata.items);
            defer alloc.free(fields);
            for (fields) |f| try w.print("{s} = \"{s}\"\n", .{ f.key, f.value });
        }
    }
    return try out.toOwnedSlice();
}

/// Sharded `[[bindings]]` (sharded V4) factory. Same scheme as `makeShardedSingle`
/// but each bucket emits V4-style multi-line TOML blocks separated by blank lines.
fn makeShardedToml(comptime n: u32) SerializeFn {
    return struct {
        fn serialize(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
            var buckets: [n]std.ArrayList(lockfile.Binding) = undefined;
            for (&buckets) |*b| b.* = .empty;
            defer for (&buckets) |*b| b.deinit(alloc);
            for (bindings) |b| try buckets[shardBucket(n, b)].append(alloc, b);

            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            const w = &out.writer;
            for (buckets, 0..) |bucket, idx| {
                try w.print("# {x:0>2}\n", .{idx});
                const sorted = try alloc.dupe(lockfile.Binding, bucket.items);
                defer alloc.free(sorted);
                std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);
                for (sorted, 0..) |b, i| {
                    if (i > 0) try w.writeAll("\n");
                    try w.writeAll("[[bindings]]\n");
                    try w.print("doc = \"{s}\"\n", .{b.doc_path});
                    try w.print("target = \"{s}\"\n", .{b.target});
                    const fields = try sortedMetadataCopy(alloc, b.metadata.items);
                    defer alloc.free(fields);
                    for (fields) |f| try w.print("{s} = \"{s}\"\n", .{ f.key, f.value });
                }
            }
            return try out.toOwnedSlice();
        }
    }.serialize;
}

/// V8: INI-style `[doc -> target]` header, `key = value` fields, blank between.
/// The bracketed header is highly distinctive — arguably the strongest context
/// anchor of all the variants. Comparable in spirit to V4 but with the full
/// binding identity in the header line rather than split across `doc`+`target`.
fn serializeV8IniBlocks(alloc: std.mem.Allocator, bindings: []const lockfile.Binding) ![]u8 {
    const sorted = try alloc.dupe(lockfile.Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(lockfile.Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("[{s} -> {s}]\n", .{ b.doc_path, b.target });
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("{s} = {s}\n", .{ f.key, f.value });
    }
    return try out.toOwnedSlice();
}

// ------------------------------------------------------------------
// Exact-subset parsers for semantic merge oracle. These intentionally parse
// only bytes produced by the serializers above; they are experiment fixtures,
// not proposed production parsers.
// ------------------------------------------------------------------

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn unquote(raw: []const u8) []const u8 {
    const t = trimLine(raw);
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

fn appendMeta(alloc: std.mem.Allocator, meta: *std.ArrayList(lockfile.MetadataField), key: []const u8, value: []const u8) !void {
    try meta.append(alloc, .{
        .key = try alloc.dupe(u8, trimLine(key)),
        .value = try alloc.dupe(u8, unquote(value)),
    });
}

fn flushBinding(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(lockfile.Binding),
    doc: ?[]const u8,
    target: ?[]const u8,
    meta: *std.ArrayList(lockfile.MetadataField),
) !void {
    const d = doc orelse return;
    const t = target orelse return;
    const owned = meta.*;
    meta.* = .empty;
    try out.append(alloc, .{
        .doc_path = try alloc.dupe(u8, d),
        .target = try alloc.dupe(u8, t),
        .metadata = owned,
    });
}

fn parseArrowHeader(line: []const u8) ?struct { []const u8, []const u8 } {
    const arrow = std.mem.find(u8, line, " -> ") orelse return null;
    const doc = trimLine(line[0..arrow]);
    const target = trimLine(line[arrow + " -> ".len ..]);
    if (doc.len == 0 or target.len == 0) return null;
    return .{ doc, target };
}

fn parseV0Like(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(lockfile.Binding) {
    var out: std.ArrayList(lockfile.Binding) = .empty;
    try lockfile.parseInto(alloc, bytes, &out);
    return out;
}

fn parseMultilineBlocks(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(lockfile.Binding) {
    var out: std.ArrayList(lockfile.Binding) = .empty;
    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(lockfile.MetadataField) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or line[0] == '#' or std.mem.eql(u8, line, "---")) continue;

        if (parseArrowHeader(line)) |h| {
            try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            cur_doc = h[0];
            cur_target = h[1];
            continue;
        }

        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        try appendMeta(alloc, &cur_meta, line[0..colon], line[colon + 1 ..]);
    }
    try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

fn parseYamlNested(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(lockfile.Binding) {
    var out: std.ArrayList(lockfile.Binding) = .empty;
    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(lockfile.MetadataField) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        if (trimLine(raw).len == 0) continue;
        const line = trimLine(raw);
        if (!std.mem.startsWith(u8, raw, " ")) {
            try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            cur_doc = unquote(line[0 .. line.len - 1]);
            cur_target = null;
        } else if (std.mem.startsWith(u8, raw, "  ") and !std.mem.startsWith(u8, raw, "    ")) {
            try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            cur_target = unquote(line[0 .. line.len - 1]);
        } else if (std.mem.startsWith(u8, raw, "    ")) {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            try appendMeta(alloc, &cur_meta, line[0..colon], line[colon + 1 ..]);
        }
    }
    try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

fn parseIniBlocks(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(lockfile.Binding) {
    var out: std.ArrayList(lockfile.Binding) = .empty;
    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(lockfile.MetadataField) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            const h = parseArrowHeader(line[1 .. line.len - 1]) orelse continue;
            cur_doc = h[0];
            cur_target = h[1];
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        try appendMeta(alloc, &cur_meta, line[0..eq], line[eq + 1 ..]);
    }
    try flushBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

// ------------------------------------------------------------------
// Oracle: merge-file conflict rate plus semantic parse-back check for clean
// merges. A variant only gets credit for a clean merge if parsing the merged
// bytes canonicalizes to the expected semantic union.
// ------------------------------------------------------------------

const MergeOutcome = struct { merged: []u8, had_conflict: bool, byte_size: usize };

fn gitMergeFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    base_text: []const u8,
    left_text: []const u8,
    right_text: []const u8,
) !MergeOutcome {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "base", .data = base_text });
    try tmp.dir.writeFile(io, .{ .sub_path = "left", .data = left_text });
    try tmp.dir.writeFile(io, .{ .sub_path = "right", .data = right_text });
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp/" ++ &tmp.sub_path, alloc);
    defer alloc.free(cwd);
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "git", "merge-file", "-p", "--no-diff3", "left", "base", "right" },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    const had_conflict = std.mem.indexOf(u8, result.stdout, "<<<<<<<") != null;
    return .{ .merged = result.stdout, .had_conflict = had_conflict, .byte_size = base_text.len };
}

const VARIANTS = 20;
const VARIANT_NAMES = [_][]const u8{
    "V0 baseline        ",
    "V1 multiline-block ",
    "V2 sectioned-single",
    "V3 sectioned-multi ",
    "V4 toml (A) flat   ",
    "V5 yaml-nested     ",
    "V6 hr-separator    ",
    "V7 aligned-cols    ",
    "V8 ini-blocks      ",
    "V9 toml (B) nested ",
    "V10 toml(C) grouped",
    "V11 hash-V0  b=8   ",
    "V12 hash-V0  b=16  ",
    "V13 hash-V0  b=32  ",
    "V14 hash-V0  b=64  ",
    "V15 hash-V4  b=8   ",
    "V16 hash-V4  b=16  ",
    "V17 hash-V4  b=32  ",
    "V18 hash-V4  b=64  ",
    "V19 sem-V4 a-z     ",
};
pub const VARIANT_FNS = [_]SerializeFn{
    serializeV0Baseline,
    serializeV1MultilineBlocks,
    serializeV2SectionedSingle,
    serializeV3SectionedMultiline,
    serializeV4TomlTables,
    serializeV5YamlNested,
    serializeV6HrSeparator,
    serializeV7AlignedColumns,
    serializeV8IniBlocks,
    toml_variants.serializeB,
    toml_variants.serializeC,
    makeShardedSingle(8),
    makeShardedSingle(16),
    makeShardedSingle(32),
    makeShardedSingle(64),
    makeShardedToml(8),
    makeShardedToml(16),
    makeShardedToml(32),
    makeShardedToml(64),
    serializeV19SemToml,
};

const VARIANT_PARSE_FNS = [_]ParseFn{
    parseV0Like,
    parseMultilineBlocks,
    parseV0Like,
    parseMultilineBlocks,
    toml_variants.parseA,
    parseYamlNested,
    parseMultilineBlocks,
    parseV0Like,
    parseIniBlocks,
    toml_variants.parseB,
    toml_variants.parseC,
    parseV0Like,
    parseV0Like,
    parseV0Like,
    parseV0Like,
    toml_variants.parseA,
    toml_variants.parseA,
    toml_variants.parseA,
    toml_variants.parseA,
    toml_variants.parseA,
};

var variant_total: [VARIANTS]u32 = .{0} ** VARIANTS;
var variant_conflicts: [VARIANTS]u32 = .{0} ** VARIANTS;
var variant_mismatches: [VARIANTS]u32 = .{0} ** VARIANTS;
var variant_bytes: [VARIANTS]u64 = .{0} ** VARIANTS; // total base-file bytes across trials

const Bucket = enum(usize) {
    any,
    same_doc,
    different_doc,
    adjacent_base_rank,
    add_add,
    field_field,
    remove_any,
    mixed_ops,
};
const BUCKETS = @typeInfo(Bucket).@"enum".fields.len;
const BUCKET_NAMES = [_][]const u8{
    "any               ",
    "same doc          ",
    "different doc     ",
    "adjacent base rank",
    "add/add           ",
    "field/field       ",
    "remove involved   ",
    "mixed ops         ",
};
const SELECTED_BUCKET_VARIANTS = [_]usize{ 0, 3, 4, 13, 14, 17, 18, 19 };

var bucket_total: [VARIANTS * BUCKETS]u32 = .{0} ** (VARIANTS * BUCKETS);
var bucket_conflicts: [VARIANTS * BUCKETS]u32 = .{0} ** (VARIANTS * BUCKETS);

fn bucketIdx(variant_idx: usize, bucket: Bucket) usize {
    return variant_idx * BUCKETS + @intFromEnum(bucket);
}

const OpSummary = struct {
    add: bool = false,
    field: bool = false,
    remove: bool = false,
    docs: [MAX_OPS_PER_SIDE][]const u8 = undefined,
    docs_len: usize = 0,
    base_ranks: [MAX_OPS_PER_SIDE]usize = undefined,
    base_ranks_len: usize = 0,

    fn kinds(self: OpSummary) u8 {
        return @as(u8, @intFromBool(self.add)) + @as(u8, @intFromBool(self.field)) + @as(u8, @intFromBool(self.remove));
    }
};

fn rawBindingLess(a: RawEntry, b: RawEntry) bool {
    const doc_cmp = std.mem.order(u8, a.doc_path, b.doc_path);
    if (doc_cmp != .eq) return doc_cmp == .lt;
    return std.mem.order(u8, a.target, b.target) == .lt;
}

fn baseRank(base: []const RawEntry, doc_path: []const u8, target: []const u8) ?usize {
    var found = false;
    var rank: usize = 0;
    const needle: RawEntry = .{ .doc_path = doc_path, .target = target, .fields = &.{} };
    for (base) |e| {
        if (std.mem.eql(u8, e.doc_path, doc_path) and std.mem.eql(u8, e.target, target)) found = true;
        if (rawBindingLess(e, needle)) rank += 1;
    }
    return if (found) rank else null;
}

fn summarizeOps(base: []const RawEntry, ops: []const Op) OpSummary {
    var s: OpSummary = .{};
    for (ops) |op| {
        const doc_path, const target = switch (op) {
            .add => |a| blk: {
                s.add = true;
                break :blk .{ a.doc_path, a.target };
            },
            .remove => |r| blk: {
                s.remove = true;
                break :blk .{ r.doc_path, r.target };
            },
            .set_field => |f| blk: {
                s.field = true;
                break :blk .{ f.doc_path, f.target };
            },
            .remove_field => |f| blk: {
                s.field = true;
                break :blk .{ f.doc_path, f.target };
            },
        };
        if (s.docs_len < s.docs.len) {
            s.docs[s.docs_len] = doc_path;
            s.docs_len += 1;
        }
        if (baseRank(base, doc_path, target)) |rank| {
            if (s.base_ranks_len < s.base_ranks.len) {
                s.base_ranks[s.base_ranks_len] = rank;
                s.base_ranks_len += 1;
            }
        }
    }
    return s;
}

fn classifyState(state: MergeState) [BUCKETS]bool {
    const left = summarizeOps(state.base, state.left_ops);
    const right = summarizeOps(state.base, state.right_ops);
    var out: [BUCKETS]bool = .{false} ** BUCKETS;
    out[@intFromEnum(Bucket.any)] = true;
    out[@intFromEnum(Bucket.add_add)] = left.add and right.add;
    out[@intFromEnum(Bucket.field_field)] = left.field and right.field;
    out[@intFromEnum(Bucket.remove_any)] = left.remove or right.remove;
    out[@intFromEnum(Bucket.mixed_ops)] = left.kinds() + right.kinds() > 2;

    var has_doc_pair = false;
    for (left.docs[0..left.docs_len]) |ldoc| {
        for (right.docs[0..right.docs_len]) |rdoc| {
            has_doc_pair = true;
            if (std.mem.eql(u8, ldoc, rdoc)) out[@intFromEnum(Bucket.same_doc)] = true;
        }
    }
    out[@intFromEnum(Bucket.different_doc)] = has_doc_pair and !out[@intFromEnum(Bucket.same_doc)];

    for (left.base_ranks[0..left.base_ranks_len]) |lrank| {
        for (right.base_ranks[0..right.base_ranks_len]) |rrank| {
            const hi = @max(lrank, rrank);
            const lo = @min(lrank, rrank);
            if (hi - lo <= 1) out[@intFromEnum(Bucket.adjacent_base_rank)] = true;
        }
    }
    return out;
}

fn runVariant(variant_idx: usize, serialize_fn: SerializeFn, parse_fn: ParseFn, state: MergeState) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try applyOps(a, state.base, &.{});
    const left = try applyOps(a, state.base, state.left_ops);
    const right = try applyOps(a, state.base, state.right_ops);
    const combined = blk: {
        const all_ops = try a.alloc(Op, state.left_ops.len + state.right_ops.len);
        @memcpy(all_ops[0..state.left_ops.len], state.left_ops);
        @memcpy(all_ops[state.left_ops.len..], state.right_ops);
        break :blk try applyOps(a, state.base, all_ops);
    };

    const base_text = try serialize_fn(a, base.items);
    const left_text = try serialize_fn(a, left.items);
    const right_text = try serialize_fn(a, right.items);
    const expected_canonical = try lockfile.serialize(a, combined.items);

    const outcome = try gitMergeFile(a, std.testing.io, base_text, left_text, right_text);

    const buckets = classifyState(state);

    variant_total[variant_idx] += 1;
    variant_bytes[variant_idx] += outcome.byte_size;
    for (0..BUCKETS) |bucket_i| {
        if (buckets[bucket_i]) bucket_total[bucketIdx(variant_idx, @enumFromInt(bucket_i))] += 1;
    }
    if (outcome.had_conflict) {
        variant_conflicts[variant_idx] += 1;
        for (0..BUCKETS) |bucket_i| {
            if (buckets[bucket_i]) bucket_conflicts[bucketIdx(variant_idx, @enumFromInt(bucket_i))] += 1;
        }
        return;
    }

    const parsed = try parse_fn(a, outcome.merged);
    const actual_canonical = try lockfile.serialize(a, parsed.items);
    if (!std.mem.eql(u8, actual_canonical, expected_canonical)) {
        variant_mismatches[variant_idx] += 1;
        std.debug.print(
            "\n[format experiment] semantic mismatch in {s}\n" ++
                "--- base ---\n{s}\n--- left ---\n{s}\n--- right ---\n{s}\n" ++
                "--- merged clean ---\n{s}\n--- actual canonical ---\n{s}" ++
                "--- expected canonical ---\n{s}\n",
            .{ VARIANT_NAMES[variant_idx], base_text, left_text, right_text, outcome.merged, actual_canonical, expected_canonical },
        );
        return error.SemanticMergeMismatch;
    }
}

fn allVariantsProperty(state: MergeState) !void {
    for (0..VARIANTS) |i| try runVariant(i, VARIANT_FNS[i], VARIANT_PARSE_FNS[i], state);
}

test "experiment: conflict rate across lockfile format variants" {
    if (!helpers.run_format_experiment) return error.SkipZigTest;

    variant_total = .{0} ** VARIANTS;
    variant_conflicts = .{0} ** VARIANTS;
    variant_mismatches = .{0} ** VARIANTS;
    variant_bytes = .{0} ** VARIANTS;
    bucket_total = .{0} ** (VARIANTS * BUCKETS);
    bucket_conflicts = .{0} ** (VARIANTS * BUCKETS);

    const N = 100;
    try minish.check(
        std.testing.allocator,
        merge_gen,
        allVariantsProperty,
        .{ .num_runs = N, .seed = helpers.minish_seed },
    );

    std.debug.print("\n[format experiment] {d} trials (same seed across variants)\n", .{N});
    std.debug.print("  variant              |  conflict rate     | clean mismatches | avg base bytes\n", .{});
    std.debug.print("  ---------------------|--------------------|------------------|----------------\n", .{});
    for (0..VARIANTS) |i| {
        const rate: f32 = if (variant_total[i] == 0) 0 else @as(f32, @floatFromInt(variant_conflicts[i])) * 100.0 / @as(f32, @floatFromInt(variant_total[i]));
        const avg_bytes: f32 = if (variant_total[i] == 0) 0 else @as(f32, @floatFromInt(variant_bytes[i])) / @as(f32, @floatFromInt(variant_total[i]));
        std.debug.print(
            "  {s} |  {d:>3}/{d:<3} ({d:>4.1}%)  |  {d:>3}             |  {d:>8.1}\n",
            .{ VARIANT_NAMES[i], variant_conflicts[i], variant_total[i], rate, variant_mismatches[i], avg_bytes },
        );
    }
    std.debug.print("\n[format experiment] conflict rate by workload bucket\n", .{});
    std.debug.print("  bucket             ", .{});
    for (SELECTED_BUCKET_VARIANTS) |variant_idx| std.debug.print(" | {s}", .{VARIANT_NAMES[variant_idx]});
    std.debug.print("\n  -------------------", .{});
    for (SELECTED_BUCKET_VARIANTS) |_| std.debug.print("-|--------------------", .{});
    std.debug.print("\n", .{});
    for (0..BUCKETS) |bucket_i| {
        const bucket: Bucket = @enumFromInt(bucket_i);
        std.debug.print("  {s}", .{BUCKET_NAMES[bucket_i]});
        for (SELECTED_BUCKET_VARIANTS) |variant_idx| {
            const total = bucket_total[bucketIdx(variant_idx, bucket)];
            const conflicts = bucket_conflicts[bucketIdx(variant_idx, bucket)];
            const rate: f32 = if (total == 0) 0 else @as(f32, @floatFromInt(conflicts)) * 100.0 / @as(f32, @floatFromInt(total));
            std.debug.print(" | {d:>3}/{d:<3} ({d:>4.1}%)", .{ conflicts, total, rate });
        }
        std.debug.print("\n", .{});
    }

    for (0..VARIANTS) |i| try std.testing.expectEqual(@as(u32, 0), variant_mismatches[i]);
}
