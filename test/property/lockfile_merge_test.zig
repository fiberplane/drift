//! Property 2: disjoint-edit merge commutativity.
//!
//! Given a base lockfile and two edit scripts that touch *disjoint* bindings,
//! a textual 3-way merge (git merge-file) should either:
//!   - produce no conflict markers and parse to the semantic union of the two
//!     scripts, OR
//!   - produce conflict markers (a "spurious" textual conflict — semantically
//!     clean, but adjacent sorted lines collided under git's diff heuristic).
//!
//! The oracle FAILS on the mismatch case (clean merge with wrong semantics) and
//! MEASURES the spurious-conflict rate over all trials. The rate is the signal
//! for whether it's worth writing a semantic mergetool / `.gitattributes` merge
//! driver — the higher it is, the more spurious pain users take.

const std = @import("std");
const minish = @import("minish");
const lockfile = @import("../../src/lockfile.zig");
const helpers = @import("helpers");

const GenError = minish.GenError;
const TestCase = minish.TestCase;

// --- Raw-state vocabulary (duplicated from lockfile_reorder_test.zig for now;
//     refactor into a shared module if a third property test arrives). ---

const RawField = struct {
    key: []const u8,
    value: []const u8,
};

const RawEntry = struct {
    doc_path: []const u8,
    target: []const u8,
    fields: []const RawField,
};

/// Edit operations. `doc` + `target` jointly identify the binding an op
/// touches; disjointness between left and right scripts is enforced by the
/// generator (left-only `add`s use an "L_"/"R_" prefix and base bindings are
/// partitioned before ops are sampled).
const Op = union(enum) {
    add: struct {
        doc_path: []const u8,
        target: []const u8,
        fields: []const RawField,
    },
    remove: struct {
        doc_path: []const u8,
        target: []const u8,
    },
    set_field: struct {
        doc_path: []const u8,
        target: []const u8,
        key: []const u8,
        value: []const u8,
    },
    remove_field: struct {
        doc_path: []const u8,
        target: []const u8,
        key: []const u8,
    },
};

const MergeState = struct {
    base: []const RawEntry,
    left_ops: []const Op,
    right_ops: []const Op,
};

const KEY_POOL = [_][]const u8{ "sig", "origin", "lang", "ver", "ref", "hash" };
const MAX_BASE = 5;
const MAX_OPS_PER_SIDE = 3;

// --- Generator ---

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
    side_prefix: u8, // 'L' or 'R'
    add_counter: *usize,
) GenError!Op {
    // If this side has no base bindings to touch, force an `add`.
    const max_kind: u64 = if (side_entries.len == 0) 0 else 3;
    const kind = try tc.choice(max_kind);
    switch (kind) {
        0 => {
            const doc_path = try std.fmt.allocPrint(
                tc.allocator,
                "doc_{c}_{d}",
                .{ side_prefix, add_counter.* },
            );
            errdefer tc.allocator.free(doc_path);
            const target = try std.fmt.allocPrint(
                tc.allocator,
                "src_{c}_{d}",
                .{ side_prefix, add_counter.* },
            );
            errdefer tc.allocator.free(target);
            add_counter.* += 1;
            const fields = try genFields(tc);
            return .{ .add = .{
                .doc_path = doc_path,
                .target = target,
                .fields = fields,
            } };
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

fn freeOp(allocator: std.mem.Allocator, op: Op) void {
    switch (op) {
        .add => |a| {
            allocator.free(a.doc_path);
            allocator.free(a.target);
            for (a.fields) |f| {
                allocator.free(f.key);
                allocator.free(f.value);
            }
            allocator.free(a.fields);
        },
        .remove => |r| {
            allocator.free(r.doc_path);
            allocator.free(r.target);
        },
        .set_field => |s| {
            allocator.free(s.doc_path);
            allocator.free(s.target);
            allocator.free(s.key);
            allocator.free(s.value);
        },
        .remove_field => |r| {
            allocator.free(r.doc_path);
            allocator.free(r.target);
            allocator.free(r.key);
        },
    }
}

fn generateMergeState(tc: *TestCase) GenError!MergeState {
    // Base: 0..=MAX_BASE entries with unique indexed (doc, target).
    const num_base = try tc.choice(MAX_BASE);
    var base = try tc.allocator.alloc(RawEntry, num_base);
    errdefer {
        for (base) |e| freeEntry(tc.allocator, e);
        tc.allocator.free(base);
    }
    for (0..num_base) |i| {
        const doc_path = try std.fmt.allocPrint(tc.allocator, "doc_{d}", .{i});
        errdefer tc.allocator.free(doc_path);
        const target = try std.fmt.allocPrint(tc.allocator, "src_{d}", .{i});
        errdefer tc.allocator.free(target);
        const fields = try genFields(tc);
        base[i] = .{ .doc_path = doc_path, .target = target, .fields = fields };
    }

    // Partition base into left / right sides. Each entry picks a side; sides
    // never share bindings after this point.
    var left_entries: std.ArrayList(RawEntry) = .empty;
    errdefer left_entries.deinit(tc.allocator);
    var right_entries: std.ArrayList(RawEntry) = .empty;
    errdefer right_entries.deinit(tc.allocator);
    for (base) |e| {
        const is_left = (try tc.choice(1)) == 0;
        if (is_left) {
            try left_entries.append(tc.allocator, e);
        } else {
            try right_entries.append(tc.allocator, e);
        }
    }

    var left_add_counter: usize = 0;
    var right_add_counter: usize = 0;

    var left_ops: std.ArrayList(Op) = .empty;
    errdefer {
        for (left_ops.items) |op| freeOp(tc.allocator, op);
        left_ops.deinit(tc.allocator);
    }
    const num_left = try tc.choice(MAX_OPS_PER_SIDE);
    for (0..num_left) |_| {
        const op = try genOp(tc, left_entries.items, 'L', &left_add_counter);
        try left_ops.append(tc.allocator, op);
    }

    var right_ops: std.ArrayList(Op) = .empty;
    errdefer {
        for (right_ops.items) |op| freeOp(tc.allocator, op);
        right_ops.deinit(tc.allocator);
    }
    const num_right = try tc.choice(MAX_OPS_PER_SIDE);
    for (0..num_right) |_| {
        const op = try genOp(tc, right_entries.items, 'R', &right_add_counter);
        try right_ops.append(tc.allocator, op);
    }

    // Partition lists shared entries with `base` — drop the lists without
    // freeing their content.
    left_entries.deinit(tc.allocator);
    right_entries.deinit(tc.allocator);

    return .{
        .base = base,
        .left_ops = try left_ops.toOwnedSlice(tc.allocator),
        .right_ops = try right_ops.toOwnedSlice(tc.allocator),
    };
}

fn freeEntry(allocator: std.mem.Allocator, entry: RawEntry) void {
    allocator.free(entry.doc_path);
    allocator.free(entry.target);
    for (entry.fields) |f| {
        allocator.free(f.key);
        allocator.free(f.value);
    }
    allocator.free(entry.fields);
}

fn freeMergeState(allocator: std.mem.Allocator, state: MergeState) void {
    for (state.base) |e| freeEntry(allocator, e);
    allocator.free(state.base);
    for (state.left_ops) |op| freeOp(allocator, op);
    allocator.free(state.left_ops);
    for (state.right_ops) |op| freeOp(allocator, op);
    allocator.free(state.right_ops);
}

const merge_gen: minish.gen.Generator(MergeState) = .{
    .generateFn = generateMergeState,
    .shrinkFn = null,
    .freeFn = freeMergeState,
};

// --- Apply ops semantically ---

/// Apply `ops` to a copy of `base` and return the resulting `ArrayList(Binding)`
/// (allocated from `arena`). Mirrors `Binding.setField` / `Binding.removeField`
/// semantics for per-field ops.
fn applyOps(
    arena: std.mem.Allocator,
    base: []const RawEntry,
    ops: []const Op,
) !std.ArrayList(lockfile.Binding) {
    var bindings: std.ArrayList(lockfile.Binding) = .empty;
    for (base) |e| {
        var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
        for (e.fields) |f| {
            try metadata.append(arena, .{
                .key = try arena.dupe(u8, f.key),
                .value = try arena.dupe(u8, f.value),
            });
        }
        try bindings.append(arena, .{
            .doc_path = try arena.dupe(u8, e.doc_path),
            .target = try arena.dupe(u8, e.target),
            .metadata = metadata,
        });
    }

    for (ops) |op| try applyOp(arena, &bindings, op);
    return bindings;
}

fn findBinding(
    bindings: *std.ArrayList(lockfile.Binding),
    doc_path: []const u8,
    target: []const u8,
) ?usize {
    for (bindings.items, 0..) |b, i| {
        if (std.mem.eql(u8, b.doc_path, doc_path) and std.mem.eql(u8, b.target, target)) {
            return i;
        }
    }
    return null;
}

fn applyOp(arena: std.mem.Allocator, bindings: *std.ArrayList(lockfile.Binding), op: Op) !void {
    switch (op) {
        .add => |a| {
            var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
            for (a.fields) |f| {
                try metadata.append(arena, .{
                    .key = try arena.dupe(u8, f.key),
                    .value = try arena.dupe(u8, f.value),
                });
            }
            try bindings.append(arena, .{
                .doc_path = try arena.dupe(u8, a.doc_path),
                .target = try arena.dupe(u8, a.target),
                .metadata = metadata,
            });
        },
        .remove => |r| {
            if (findBinding(bindings, r.doc_path, r.target)) |idx| {
                _ = bindings.orderedRemove(idx);
            }
        },
        .set_field => |s| {
            if (findBinding(bindings, s.doc_path, s.target)) |idx| {
                try bindings.items[idx].setField(arena, s.key, s.value);
            }
        },
        .remove_field => |r| {
            if (findBinding(bindings, r.doc_path, r.target)) |idx| {
                bindings.items[idx].removeField(r.key);
            }
        },
    }
}

// --- Oracle: run git merge-file and inspect output ---

const MergeOutcome = struct {
    merged: []u8,
    had_conflict: bool,
};

fn gitMergeFile(
    allocator: std.mem.Allocator,
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

    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".zig-cache/tmp/" ++ &tmp.sub_path, allocator);
    defer allocator.free(cwd_path);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "merge-file", "-p", "--no-diff3", "left", "base", "right" },
        .cwd = .{ .path = cwd_path },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    const had_conflict = std.mem.indexOf(u8, result.stdout, "<<<<<<<") != null;
    return .{ .merged = result.stdout, .had_conflict = had_conflict };
}

// --- Telemetry: spurious-conflict rate across the whole property run ---

var trials_total: u32 = 0;
var spurious_conflicts: u32 = 0;
var semantic_mismatches: u32 = 0;

fn disjointMergeProperty(state: MergeState) !void {
    trials_total += 1;

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base_bindings = try applyOps(arena, state.base, &.{});
    const left_bindings = try applyOps(arena, state.base, state.left_ops);
    const right_bindings = try applyOps(arena, state.base, state.right_ops);
    const combined_bindings = blk: {
        // Disjoint ops → combined = base + all ops applied in any order.
        const all_ops = try arena.alloc(Op, state.left_ops.len + state.right_ops.len);
        @memcpy(all_ops[0..state.left_ops.len], state.left_ops);
        @memcpy(all_ops[state.left_ops.len..], state.right_ops);
        break :blk try applyOps(arena, state.base, all_ops);
    };

    const base_text = try lockfile.serialize(arena, base_bindings.items);
    const left_text = try lockfile.serialize(arena, left_bindings.items);
    const right_text = try lockfile.serialize(arena, right_bindings.items);
    const expected_text = try lockfile.serialize(arena, combined_bindings.items);

    const outcome = try gitMergeFile(arena, std.testing.io, base_text, left_text, right_text);

    if (outcome.had_conflict) {
        spurious_conflicts += 1;
        return; // measured, not a failure
    }

    if (!std.mem.eql(u8, outcome.merged, expected_text)) {
        semantic_mismatches += 1;
        std.debug.print(
            "\n--- base ---\n{s}\n--- left ---\n{s}\n--- right ---\n{s}\n" ++
                "--- merged (clean but semantically wrong) ---\n{s}" ++
                "--- expected ---\n{s}\n",
            .{ base_text, left_text, right_text, outcome.merged, expected_text },
        );
        return error.SemanticMergeMismatch;
    }
}

test "property: disjoint edits merge cleanly or conflict-but-never-corrupt" {
    trials_total = 0;
    spurious_conflicts = 0;
    semantic_mismatches = 0;

    const N = 100;
    try minish.check(
        std.testing.allocator,
        merge_gen,
        disjointMergeProperty,
        .{ .num_runs = N, .seed = helpers.minish_seed },
    );

    const rate: f32 = if (trials_total == 0) 0 else @as(f32, @floatFromInt(spurious_conflicts)) * 100.0 / @as(f32, @floatFromInt(trials_total));
    std.debug.print(
        "\n[property 2] spurious conflicts: {d}/{d} ({d:.1}%)  semantic mismatches: {d}\n",
        .{ spurious_conflicts, trials_total, rate, semantic_mismatches },
    );
    try std.testing.expectEqual(@as(u32, 0), semantic_mismatches);
}
