//! TOML-variant serde benchmark.
//!
//! Zooms in on three TOML arrangements of the same (doc, target) -> fields
//! data model:
//!
//!   A — flat array-of-tables, each binding is a [[bindings]] block
//!       doc and target are fields inside the block
//!   B — nested table keyed by (doc, target), block header carries the full
//!       binding identity (["doc"."target"])
//!   C — arrays-of-tables grouped by doc ([["doc"]]), target lives as a field
//!
//! Reports:
//!   - Serialized byte size
//!   - Serialize wall time (min of N runs)
//!   - Parse wall time (min of N runs)
//!   - Peak memory for serialize (output buffer) and parse (parsed tree)
//!   - Round-trip byte-equality check (parse then re-serialize)
//!
//! Gated on -Dformat-experiment=true. For merge-rate numbers, see
//! format_experiment_test.zig; the TOML variants there are measured via the
//! same disjoint-edit oracle.

const std = @import("std");
const lockfile = @import("../../src/lockfile.zig");
const helpers = @import("helpers");

const Binding = lockfile.Binding;
const MetadataField = lockfile.MetadataField;

// ----------------------------------------------------------------------
// Shared sort helpers
// ----------------------------------------------------------------------

fn compareBindings(_: void, a: Binding, b: Binding) bool {
    const doc_cmp = std.mem.order(u8, a.doc_path, b.doc_path);
    if (doc_cmp != .eq) return doc_cmp == .lt;
    return std.mem.order(u8, a.target, b.target) == .lt;
}

fn sortedMetadataCopy(alloc: std.mem.Allocator, fields: []const MetadataField) ![]MetadataField {
    const sorted = try alloc.dupe(MetadataField, fields);
    std.mem.sort(MetadataField, sorted, {}, struct {
        fn lt(_: void, a: MetadataField, b: MetadataField) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return sorted;
}

// ----------------------------------------------------------------------
// Serializers
// ----------------------------------------------------------------------

/// A: flat [[bindings]] blocks, each with doc/target as fields.
fn serializeA(alloc: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    const sorted = try alloc.dupe(Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(Binding, sorted, {}, compareBindings);

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

/// B: nested tables keyed by (doc, target). Block header carries full
/// binding identity.
pub fn serializeB(alloc: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    const sorted = try alloc.dupe(Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("[\"{s}\".\"{s}\"]\n", .{ b.doc_path, b.target });
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("{s} = \"{s}\"\n", .{ f.key, f.value });
    }
    return try out.toOwnedSlice();
}

/// C: arrays-of-tables grouped by doc. Target lives as a field.
pub fn serializeC(alloc: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    const sorted = try alloc.dupe(Binding, bindings);
    defer alloc.free(sorted);
    std.mem.sort(Binding, sorted, {}, compareBindings);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    for (sorted, 0..) |b, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("[[\"{s}\"]]\n", .{b.doc_path});
        try w.print("target = \"{s}\"\n", .{b.target});
        const fields = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(fields);
        for (fields) |f| try w.print("{s} = \"{s}\"\n", .{ f.key, f.value });
    }
    return try out.toOwnedSlice();
}

// ----------------------------------------------------------------------
// Parsers
//
// All variants share an "emit one binding" contract: each parser accumulates
// the current binding's fields and flushes into the output list on the next
// block header or at EOF.
//
// Scope: these are not general TOML parsers. They handle exactly the subset
// our serializers produce — `key = "value"` lines, ASCII-quoted strings, no
// escapes, no multi-line strings, no type coercion. That keeps parser cost
// comparable across variants (the work is the same shape, only the header
// syntax differs).
// ----------------------------------------------------------------------

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn parseQuotedString(raw: []const u8) ?[]const u8 {
    const trimmed = trimLine(raw);
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return null;
    return trimmed[1 .. trimmed.len - 1];
}

/// Parses `key = "value"`. Returns (key, value) or null.
fn parseKeyValue(line: []const u8) ?struct { []const u8, []const u8 } {
    const eq = std.mem.findScalar(u8, line, '=') orelse return null;
    const key = trimLine(line[0..eq]);
    const value = parseQuotedString(line[eq + 1 ..]) orelse return null;
    if (key.len == 0) return null;
    return .{ key, value };
}

fn finalizeBinding(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(Binding),
    doc_path: ?[]const u8,
    target: ?[]const u8,
    metadata: *std.ArrayList(MetadataField),
) !void {
    const dp = doc_path orelse return;
    const tg = target orelse return;
    const owned = metadata.*;
    metadata.* = .empty;
    try out.append(alloc, .{
        .doc_path = try alloc.dupe(u8, dp),
        .target = try alloc.dupe(u8, tg),
        .metadata = owned,
    });
}

fn appendField(
    alloc: std.mem.Allocator,
    metadata: *std.ArrayList(MetadataField),
    key: []const u8,
    value: []const u8,
) !void {
    try metadata.append(alloc, .{
        .key = try alloc.dupe(u8, key),
        .value = try alloc.dupe(u8, value),
    });
}

/// A: look for `[[bindings]]` headers, accumulate fields until next header.
pub fn parseA(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Binding) {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(alloc);

    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(MetadataField) = .empty;
    errdefer cur_meta.deinit(alloc);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[bindings]]")) {
            try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            cur_doc = null;
            cur_target = null;
            continue;
        }

        const kv = parseKeyValue(line) orelse continue;
        if (std.mem.eql(u8, kv[0], "doc")) {
            cur_doc = kv[1];
        } else if (std.mem.eql(u8, kv[0], "target")) {
            cur_target = kv[1];
        } else {
            try appendField(alloc, &cur_meta, kv[0], kv[1]);
        }
    }
    try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

/// B: headers like `["doc"."target"]` carry the full binding identity.
pub fn parseB(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Binding) {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(alloc);

    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(MetadataField) = .empty;
    errdefer cur_meta.deinit(alloc);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']' and line[1] != '[') {
            try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            const inner = line[1 .. line.len - 1];
            // Expect format: "doc"."target"
            var parts = std.mem.splitSequence(u8, inner, "\".\"");
            const first = parts.first();
            const second = parts.rest();
            if (first.len < 1 or first[0] != '"' or second.len < 1 or second[second.len - 1] != '"') {
                cur_doc = null;
                cur_target = null;
                continue;
            }
            cur_doc = first[1..];
            cur_target = second[0 .. second.len - 1];
            continue;
        }

        const kv = parseKeyValue(line) orelse continue;
        try appendField(alloc, &cur_meta, kv[0], kv[1]);
    }
    try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

/// C: headers like `[["doc"]]` set the current doc; target is a field.
pub fn parseC(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Binding) {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(alloc);

    var cur_doc: ?[]const u8 = null;
    var cur_target: ?[]const u8 = null;
    var cur_meta: std.ArrayList(MetadataField) = .empty;
    errdefer cur_meta.deinit(alloc);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        if (line.len >= 6 and std.mem.startsWith(u8, line, "[[\"") and std.mem.endsWith(u8, line, "\"]]")) {
            try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
            cur_doc = line[3 .. line.len - 3];
            cur_target = null;
            continue;
        }

        const kv = parseKeyValue(line) orelse continue;
        if (std.mem.eql(u8, kv[0], "target")) {
            cur_target = kv[1];
        } else {
            try appendField(alloc, &cur_meta, kv[0], kv[1]);
        }
    }
    try finalizeBinding(alloc, &out, cur_doc, cur_target, &cur_meta);
    return out;
}

/// V0 baseline: wrap the existing lockfile parser for apples-to-apples timing.
fn parseV0(alloc: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Binding) {
    var out: std.ArrayList(Binding) = .empty;
    errdefer out.deinit(alloc);
    try lockfile.parseInto(alloc, bytes, &out);
    return out;
}

fn serializeV0(alloc: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    return try lockfile.serialize(alloc, bindings);
}

// ----------------------------------------------------------------------
// Fixture builder
// ----------------------------------------------------------------------

/// Build a deterministic lockfile with `num_bindings` entries distributed
/// across `num_docs` docs. Each binding has 2–4 metadata fields. Arena-only
/// ownership.
fn buildFixture(
    arena: std.mem.Allocator,
    num_bindings: usize,
    num_docs: usize,
) !std.ArrayList(Binding) {
    var out: std.ArrayList(Binding) = .empty;
    const FIELD_KEYS = [_][]const u8{ "sig", "origin", "lang", "ver", "ref", "hash" };
    for (0..num_bindings) |i| {
        const doc_idx = i % num_docs;
        const doc_path = try std.fmt.allocPrint(arena, "docs/group_{d}/file_{d}.md", .{ doc_idx / 10, doc_idx });
        const target = try std.fmt.allocPrint(arena, "src/group_{d}/mod_{d}.ts", .{ i / 10, i });
        const num_fields = 2 + (i % 3); // 2..4
        var metadata: std.ArrayList(MetadataField) = .empty;
        for (0..num_fields) |f_idx| {
            const key = try arena.dupe(u8, FIELD_KEYS[f_idx]);
            const value = try std.fmt.allocPrint(arena, "val_{d}_{d}", .{ i, f_idx });
            try metadata.append(arena, .{ .key = key, .value = value });
        }
        try out.append(arena, .{ .doc_path = doc_path, .target = target, .metadata = metadata });
    }
    return out;
}

// ----------------------------------------------------------------------
// Round-trip correctness (must pass before benchmark is meaningful)
// ----------------------------------------------------------------------

fn normaliseBindings(alloc: std.mem.Allocator, bindings: []Binding) !void {
    std.mem.sort(Binding, bindings, {}, compareBindings);
    for (bindings) |*b| {
        const sorted_meta = try sortedMetadataCopy(alloc, b.metadata.items);
        defer alloc.free(sorted_meta);
        // replace in place
        b.metadata.clearRetainingCapacity();
        for (sorted_meta) |f| try b.metadata.append(alloc, f);
    }
}

fn bindingsEqual(a: []const Binding, b: []const Binding) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ba, i| {
        const bb = b[i];
        if (!std.mem.eql(u8, ba.doc_path, bb.doc_path)) return false;
        if (!std.mem.eql(u8, ba.target, bb.target)) return false;
        if (ba.metadata.items.len != bb.metadata.items.len) return false;
        for (ba.metadata.items, 0..) |fa, j| {
            const fb = bb.metadata.items[j];
            if (!std.mem.eql(u8, fa.key, fb.key)) return false;
            if (!std.mem.eql(u8, fa.value, fb.value)) return false;
        }
    }
    return true;
}

test "toml-variants: round-trip is stable (A, B, C, V0)" {
    if (!helpers.run_format_experiment) return error.SkipZigTest;

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = try buildFixture(arena, 50, 8);
    const expected = try arena.dupe(Binding, fixture.items);
    try normaliseBindings(arena, expected);

    const cases = .{
        .{ "A", serializeA, parseA },
        .{ "B", serializeB, parseB },
        .{ "C", serializeC, parseC },
        .{ "V0", serializeV0, parseV0 },
    };
    inline for (cases) |case| {
        const bytes = try case.@"1"(arena, fixture.items);
        const parsed = try case.@"2"(arena, bytes);
        try normaliseBindings(arena, parsed.items);
        if (!bindingsEqual(parsed.items, expected)) {
            std.debug.print("\nvariant {s}: round-trip mismatch\n", .{case.@"0"});
            return error.RoundTripMismatch;
        }
    }
}

// ----------------------------------------------------------------------
// Benchmark
// ----------------------------------------------------------------------

const Result = struct {
    name: []const u8,
    bytes: usize,
    ser_ns_min: u64,
    par_ns_min: u64,
    ser_peak_bytes: usize,
    par_peak_bytes: usize,
};

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) i96 {
    const clock: std.Io.Clock = .awake;
    const end = clock.now(io);
    return start.durationTo(end).nanoseconds;
}

fn benchmarkVariant(
    comptime name: []const u8,
    io: std.Io,
    backing: std.mem.Allocator,
    fixture: []const Binding,
    serialize_fn: *const fn (std.mem.Allocator, []const Binding) anyerror![]u8,
    parse_fn: *const fn (std.mem.Allocator, []const u8) anyerror!std.ArrayList(Binding),
    iterations: u32,
) !Result {
    const clock: std.Io.Clock = .awake;

    // Serialize once to get the canonical bytes + ser peak memory.
    var ser_arena: std.heap.ArenaAllocator = .init(backing);
    defer ser_arena.deinit();
    const bytes = try serialize_fn(ser_arena.allocator(), fixture);
    const ser_peak = ser_arena.queryCapacity();

    // Hot-loop serialize; measure min wall time across iterations.
    var ser_ns_min: i96 = std.math.maxInt(i96);
    for (0..iterations) |_| {
        var inner: std.heap.ArenaAllocator = .init(backing);
        defer inner.deinit();
        const start = clock.now(io);
        _ = try serialize_fn(inner.allocator(), fixture);
        const ns = elapsedNs(io, start);
        if (ns < ser_ns_min) ser_ns_min = ns;
    }

    // Parse once to get par peak memory.
    var par_arena: std.heap.ArenaAllocator = .init(backing);
    defer par_arena.deinit();
    _ = try parse_fn(par_arena.allocator(), bytes);
    const par_peak = par_arena.queryCapacity();

    // Hot-loop parse.
    var par_ns_min: i96 = std.math.maxInt(i96);
    for (0..iterations) |_| {
        var inner: std.heap.ArenaAllocator = .init(backing);
        defer inner.deinit();
        const start = clock.now(io);
        _ = try parse_fn(inner.allocator(), bytes);
        const ns = elapsedNs(io, start);
        if (ns < par_ns_min) par_ns_min = ns;
    }

    return .{
        .name = name,
        .bytes = bytes.len,
        .ser_ns_min = @intCast(ser_ns_min),
        .par_ns_min = @intCast(par_ns_min),
        .ser_peak_bytes = ser_peak,
        .par_peak_bytes = par_peak,
    };
}

test "toml-variants: serde latency + memory benchmark" {
    if (!helpers.run_format_experiment) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var fixture_arena: std.heap.ArenaAllocator = .init(gpa);
    defer fixture_arena.deinit();

    const NUM_BINDINGS = 200;
    const NUM_DOCS = 30;
    const ITERATIONS = 200;

    const fixture = try buildFixture(fixture_arena.allocator(), NUM_BINDINGS, NUM_DOCS);

    const io = std.testing.io;
    const v0 = try benchmarkVariant("V0 baseline       ", io, gpa, fixture.items, serializeV0, parseV0, ITERATIONS);
    const a = try benchmarkVariant("A  flat [[bindings]]", io, gpa, fixture.items, serializeA, parseA, ITERATIONS);
    const b = try benchmarkVariant("B  nested [d.t]   ", io, gpa, fixture.items, serializeB, parseB, ITERATIONS);
    const c = try benchmarkVariant("C  grouped [[d]]  ", io, gpa, fixture.items, serializeC, parseC, ITERATIONS);
    const results = [_]Result{ v0, a, b, c };

    std.debug.print(
        "\n[toml-variants benchmark] {d} bindings across {d} docs, min of {d} iterations\n",
        .{ NUM_BINDINGS, NUM_DOCS, ITERATIONS },
    );
    std.debug.print("  variant              |  bytes  | serialize    | parse       | ser peak | par peak\n", .{});
    std.debug.print("  ---------------------|---------|--------------|-------------|----------|----------\n", .{});
    for (results) |r| {
        std.debug.print(
            "  {s} | {d:>7} | {d:>8} us | {d:>7} us | {d:>7} B | {d:>7} B\n",
            .{
                r.name,
                r.bytes,
                r.ser_ns_min / 1_000,
                r.par_ns_min / 1_000,
                r.ser_peak_bytes,
                r.par_peak_bytes,
            },
        );
    }

    // Also dump the relative ratios vs V0 for quick scan.
    std.debug.print("\n  vs V0                |  bytes  | serialize    | parse       | ser peak | par peak\n", .{});
    std.debug.print("  ---------------------|---------|--------------|-------------|----------|----------\n", .{});
    for (results) |r| {
        const byte_ratio: f32 = @as(f32, @floatFromInt(r.bytes)) / @as(f32, @floatFromInt(v0.bytes));
        const ser_ratio: f32 = @as(f32, @floatFromInt(r.ser_ns_min)) / @as(f32, @floatFromInt(v0.ser_ns_min));
        const par_ratio: f32 = @as(f32, @floatFromInt(r.par_ns_min)) / @as(f32, @floatFromInt(v0.par_ns_min));
        const ser_mem_ratio: f32 = @as(f32, @floatFromInt(r.ser_peak_bytes)) / @as(f32, @floatFromInt(v0.ser_peak_bytes));
        const par_mem_ratio: f32 = @as(f32, @floatFromInt(r.par_peak_bytes)) / @as(f32, @floatFromInt(v0.par_peak_bytes));
        std.debug.print(
            "  {s} | {d:>5.2}x  | {d:>8.2}x   | {d:>7.2}x  | {d:>5.2}x   | {d:>5.2}x\n",
            .{ r.name, byte_ratio, ser_ratio, par_ratio, ser_mem_ratio, par_mem_ratio },
        );
    }
}
