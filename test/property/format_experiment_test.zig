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

// ------------------------------------------------------------------
// Oracle (conflict-rate only — no semantic parse-back check, since
// variant formats don't have matching parsers yet).
// ------------------------------------------------------------------

const MergeOutcome = struct { had_conflict: bool, byte_size: usize };

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
    defer alloc.free(result.stdout);
    const had_conflict = std.mem.indexOf(u8, result.stdout, "<<<<<<<") != null;
    return .{ .had_conflict = had_conflict, .byte_size = base_text.len };
}

const VARIANTS = 4;
const VARIANT_NAMES = [_][]const u8{ "V0 baseline        ", "V1 multiline-block ", "V2 sectioned-single", "V3 sectioned-multi " };
const VARIANT_FNS = [_]SerializeFn{
    serializeV0Baseline,
    serializeV1MultilineBlocks,
    serializeV2SectionedSingle,
    serializeV3SectionedMultiline,
};

var variant_total: [VARIANTS]u32 = .{0} ** VARIANTS;
var variant_conflicts: [VARIANTS]u32 = .{0} ** VARIANTS;
var variant_bytes: [VARIANTS]u64 = .{0} ** VARIANTS; // total base-file bytes across trials

fn runVariant(variant_idx: usize, serialize_fn: SerializeFn, state: MergeState) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try applyOps(a, state.base, &.{});
    const left = try applyOps(a, state.base, state.left_ops);
    const right = try applyOps(a, state.base, state.right_ops);

    const base_text = try serialize_fn(a, base.items);
    const left_text = try serialize_fn(a, left.items);
    const right_text = try serialize_fn(a, right.items);

    const outcome = try gitMergeFile(a, std.testing.io, base_text, left_text, right_text);

    variant_total[variant_idx] += 1;
    variant_bytes[variant_idx] += outcome.byte_size;
    if (outcome.had_conflict) variant_conflicts[variant_idx] += 1;
}

fn allVariantsProperty(state: MergeState) !void {
    for (0..VARIANTS) |i| try runVariant(i, VARIANT_FNS[i], state);
}

test "experiment: conflict rate across lockfile format variants" {
    if (!helpers.run_format_experiment) return error.SkipZigTest;

    variant_total = .{0} ** VARIANTS;
    variant_conflicts = .{0} ** VARIANTS;
    variant_bytes = .{0} ** VARIANTS;

    const N = 100;
    try minish.check(
        std.testing.allocator,
        merge_gen,
        allVariantsProperty,
        .{ .num_runs = N, .seed = helpers.minish_seed },
    );

    std.debug.print("\n[format experiment] {d} trials (same seed across variants)\n", .{N});
    std.debug.print("  variant              |  conflict rate     | avg base bytes\n", .{});
    std.debug.print("  ---------------------|--------------------|----------------\n", .{});
    for (0..VARIANTS) |i| {
        const rate: f32 = if (variant_total[i] == 0) 0 else @as(f32, @floatFromInt(variant_conflicts[i])) * 100.0 / @as(f32, @floatFromInt(variant_total[i]));
        const avg_bytes: f32 = if (variant_total[i] == 0) 0 else @as(f32, @floatFromInt(variant_bytes[i])) / @as(f32, @floatFromInt(variant_total[i]));
        std.debug.print(
            "  {s} |  {d:>3}/{d:<3} ({d:>4.1}%)  |  {d:>8.1}\n",
            .{ VARIANT_NAMES[i], variant_conflicts[i], variant_total[i], rate, avg_bytes },
        );
    }
}
