//! Property 1: semantic_eq(L1, L2) ⟹ serialize(L1) == serialize(L2)
//!
//! Two lockfiles whose bindings and metadata form the same multiset must
//! serialize to the same bytes, regardless of iteration order. This catches
//! the class of spurious merge conflicts where two branches converged on the
//! same semantic state through different `setField` sequences.

const std = @import("std");
const minish = @import("minish");
const lockfile = @import("../../src/lockfile.zig");
const helpers = @import("helpers");

const GenError = minish.GenError;
const TestCase = minish.TestCase;

/// Semantic description of a lockfile: a flat list of entries with no
/// assumption of order. Keys within each entry are unique by construction
/// (generator guarantees) so `semantic_eq` reduces to multiset equality.
const RawField = struct {
    key: []const u8,
    value: []const u8,
};

const RawEntry = struct {
    doc_path: []const u8,
    target: []const u8,
    fields: []const RawField,
};

const State = []const RawEntry;

/// Fixed key pool used by the generator. A small, fixed pool makes the
/// uniqueness guarantee cheap (subset of a known set) and keeps counterexamples
/// readable.
const KEY_POOL = [_][]const u8{ "sig", "origin", "lang", "ver", "ref", "hash" };
const MAX_ENTRIES = 6;

fn genShortString(tc: *TestCase, comptime prefix: []const u8) GenError![]const u8 {
    // 1–2 trailing chars from a small alphabet keeps paths short and
    // counterexamples easy to read; collisions between entries are intentional
    // (two bindings to the same (doc, target) is a real case).
    const CHARS = "abcd";
    const len = 1 + try tc.choice(1); // 1..2
    var buf = try tc.allocator.alloc(u8, prefix.len + len);
    errdefer tc.allocator.free(buf);
    @memcpy(buf[0..prefix.len], prefix);
    for (0..len) |i| {
        const idx = try tc.choice(CHARS.len - 1);
        buf[prefix.len + i] = CHARS[idx];
    }
    return buf;
}

fn genValue(tc: *TestCase) GenError![]const u8 {
    const CHARS = "0123456789abcdef";
    const len = 1 + try tc.choice(3); // 1..4
    var buf = try tc.allocator.alloc(u8, len);
    errdefer tc.allocator.free(buf);
    for (0..len) |i| {
        const idx = try tc.choice(CHARS.len - 1);
        buf[i] = CHARS[idx];
    }
    return buf;
}

fn genFields(tc: *TestCase) GenError![]const RawField {
    // Pick a random subset of KEY_POOL via Fisher–Yates on indices, then take
    // the first `num` elements. Guarantees unique keys per entry without any
    // post-hoc dedup logic.
    var indices: [KEY_POOL.len]usize = undefined;
    for (0..KEY_POOL.len) |i| indices[i] = i;
    var i: usize = KEY_POOL.len;
    while (i > 1) {
        i -= 1;
        const j = try tc.choice(@intCast(i));
        std.mem.swap(usize, &indices[i], &indices[j]);
    }

    const num = try tc.choice(KEY_POOL.len); // 0..KEY_POOL.len
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

fn freeFields(allocator: std.mem.Allocator, fields: []const RawField) void {
    for (fields) |f| {
        allocator.free(f.key);
        allocator.free(f.value);
    }
    allocator.free(fields);
}

fn genEntry(tc: *TestCase) GenError!RawEntry {
    const doc_path = try genShortString(tc, "doc_");
    errdefer tc.allocator.free(doc_path);
    const target = try genShortString(tc, "src_");
    errdefer tc.allocator.free(target);
    const fields = try genFields(tc);
    return .{ .doc_path = doc_path, .target = target, .fields = fields };
}

fn freeEntry(allocator: std.mem.Allocator, entry: RawEntry) void {
    allocator.free(entry.doc_path);
    allocator.free(entry.target);
    freeFields(allocator, entry.fields);
}

fn generateState(tc: *TestCase) GenError!State {
    const num = try tc.choice(MAX_ENTRIES); // 0..MAX_ENTRIES
    var entries = try tc.allocator.alloc(RawEntry, num);
    errdefer {
        for (entries) |e| freeEntry(tc.allocator, e);
        tc.allocator.free(entries);
    }
    for (0..num) |i| entries[i] = try genEntry(tc);
    return entries;
}

fn freeState(allocator: std.mem.Allocator, state: State) void {
    for (state) |e| freeEntry(allocator, e);
    allocator.free(state);
}

const state_gen: minish.gen.Generator(State) = .{
    .generateFn = generateState,
    .shrinkFn = null,
    .freeFn = freeState,
};

/// Build a `[]lockfile.Binding` from the raw state. Allocations come from the
/// caller-provided arena so the property function can free everything at once.
/// `reverse` swaps both binding order and within-binding field order — the
/// simplest permutation that, combined with a forward-order build, exercises
/// any order-sensitivity in serialization.
fn buildBindings(
    arena: std.mem.Allocator,
    state: State,
    reverse: bool,
) !std.ArrayList(lockfile.Binding) {
    var bindings: std.ArrayList(lockfile.Binding) = .empty;
    const n = state.len;
    for (0..n) |i| {
        const e_idx = if (reverse) n - 1 - i else i;
        const entry = state[e_idx];

        var metadata: std.ArrayList(lockfile.MetadataField) = .empty;
        const m = entry.fields.len;
        for (0..m) |j| {
            const f_idx = if (reverse) m - 1 - j else j;
            try metadata.append(arena, .{
                .key = try arena.dupe(u8, entry.fields[f_idx].key),
                .value = try arena.dupe(u8, entry.fields[f_idx].value),
            });
        }

        try bindings.append(arena, .{
            .doc_path = try arena.dupe(u8, entry.doc_path),
            .target = try arena.dupe(u8, entry.target),
            .metadata = metadata,
        });
    }
    return bindings;
}

fn canonicalSerializationProperty(state: State) !void {
    var arena_l1: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_l1.deinit();
    var arena_l2: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_l2.deinit();

    const l1 = try buildBindings(arena_l1.allocator(), state, false);
    const l2 = try buildBindings(arena_l2.allocator(), state, true);

    const s1 = try lockfile.serialize(arena_l1.allocator(), l1.items);
    const s2 = try lockfile.serialize(arena_l2.allocator(), l2.items);

    std.testing.expectEqualStrings(s1, s2) catch |err| {
        std.debug.print(
            "\n--- forward serialization ---\n{s}\n--- reverse serialization ---\n{s}\n",
            .{ s1, s2 },
        );
        return err;
    };
}

test "property: serialize is invariant under binding+field reorder" {
    try minish.check(
        std.testing.allocator,
        state_gen,
        canonicalSerializationProperty,
        .{ .num_runs = 200, .seed = helpers.minish_seed },
    );
}
