//! Mapping from foreign binding origins (`github:owner/repo`) to local
//! sibling checkouts, populated from repeated `--repo <origin>=<path>` flags
//! and `[[repos]]` entries in `.drift/config.toml`. Lets `drift check` verify
//! anchors whose origin does not match the current repo identity by computing
//! fingerprints against the mapped checkout.

const std = @import("std");

pub const Entry = struct {
    origin: []const u8,
    path: []const u8,
};

pub const ValidateError = error{
    EmptyOrigin,
    EmptyPath,
    InvalidOrigin,
};

pub const ParseSpecError = ValidateError || error{MissingSeparator};

/// Shared shape validation for repo mappings, regardless of source (`--repo`
/// flag specs and `[[repos]]` config entries). The origin must already be in
/// the normalized `github:owner/repo` shape produced by
/// `vcs.normalizeGitHubUrl` / `vcs.getRepoIdentity`.
pub fn validate(entry: Entry) ValidateError!void {
    if (entry.origin.len == 0) return error.EmptyOrigin;
    if (entry.path.len == 0) return error.EmptyPath;
    if (!isNormalizedOrigin(entry.origin)) return error.InvalidOrigin;
}

/// Parses a `--repo` spec of the form `github:owner/repo=../server`. The
/// first '=' is the separator — origins never contain '=', paths may.
pub fn parseSpec(spec: []const u8) ParseSpecError!Entry {
    const separator = std.mem.findScalar(u8, spec, '=') orelse return error.MissingSeparator;
    const entry: Entry = .{
        .origin = spec[0..separator],
        .path = spec[separator + 1 ..],
    };
    try validate(entry);
    return entry;
}

/// True when `origin` matches the normalized repo identity shape
/// (`github:owner/repo`): non-empty owner and repo, exactly one '/', no
/// `.git` suffix and no trailing slash — mirroring `vcs.normalizeGitHubUrl`.
fn isNormalizedOrigin(origin: []const u8) bool {
    const prefix = "github:";
    if (!std.mem.startsWith(u8, origin, prefix)) return false;

    const rest = origin[prefix.len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse return false;
    const owner = rest[0..slash];
    const repo = rest[slash + 1 ..];

    if (owner.len == 0 or repo.len == 0) return false;
    if (std.mem.findScalar(u8, repo, '/') != null) return false;
    if (std.mem.endsWith(u8, repo, ".git")) return false;
    return true;
}

/// Immutable origin → local-checkout map, built once per run and shared
/// (read-only) across the per-doc check tasks.
pub const RepoMap = struct {
    entries: []const Entry,

    pub const empty: RepoMap = .{ .entries = &.{} };

    /// Copies `source_entries` into `arena_allocator`-backed storage,
    /// normalizing each path to absolute. Relative paths resolve against
    /// `base_path` (the caller's cwd for flag-provided specs).
    pub fn build(
        arena_allocator: std.mem.Allocator,
        source_entries: []const Entry,
        base_path: []const u8,
    ) error{OutOfMemory}!RepoMap {
        const entries = try arena_allocator.alloc(Entry, source_entries.len);
        for (source_entries, entries) |source, *entry| {
            entry.* = try buildEntry(arena_allocator, source, base_path);
        }
        return .{ .entries = entries };
    }

    /// Combines flag entries and config entries into one map with CLI-wins
    /// precedence: a config entry whose origin is already mapped by a flag is
    /// dropped. Flag paths resolve against `flag_base_path` (the caller's
    /// cwd); config paths resolve against `config_base_path` (the lockfile
    /// root), so config mappings are checkout-location-independent.
    pub fn buildMerged(
        arena_allocator: std.mem.Allocator,
        flag_entries: []const Entry,
        flag_base_path: []const u8,
        config_entries: []const Entry,
        config_base_path: []const u8,
    ) error{OutOfMemory}!RepoMap {
        var entries = try std.ArrayList(Entry).initCapacity(arena_allocator, flag_entries.len + config_entries.len);
        for (flag_entries) |source| {
            entries.appendAssumeCapacity(try buildEntry(arena_allocator, source, flag_base_path));
        }
        for (config_entries) |source| {
            if (buildMergedContainsOrigin(entries.items, source.origin)) continue;
            entries.appendAssumeCapacity(try buildEntry(arena_allocator, source, config_base_path));
        }
        return .{ .entries = entries.items };
    }

    fn buildMergedContainsOrigin(entries: []const Entry, origin: []const u8) bool {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.origin, origin)) return true;
        }
        return false;
    }

    fn buildEntry(
        arena_allocator: std.mem.Allocator,
        source: Entry,
        base_path: []const u8,
    ) error{OutOfMemory}!Entry {
        return .{
            .origin = try arena_allocator.dupe(u8, source.origin),
            .path = try std.Io.Dir.path.resolve(arena_allocator, &.{ base_path, source.path }),
        };
    }

    /// Returns the mapped absolute checkout path for `origin`, or null when
    /// the origin is unmapped. Linear scan — maps hold a handful of entries.
    pub fn resolve(self: *const RepoMap, origin: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.origin, origin)) return entry.path;
        }
        return null;
    }
};

// --- unit tests ---

test "parseSpec splits at the first equals" {
    const entry = try parseSpec("github:acme/server=../server");
    try std.testing.expectEqualStrings("github:acme/server", entry.origin);
    try std.testing.expectEqualStrings("../server", entry.path);
}

test "parseSpec keeps equals signs inside the path" {
    const entry = try parseSpec("github:acme/server=/tmp/check=outs/server");
    try std.testing.expectEqualStrings("github:acme/server", entry.origin);
    try std.testing.expectEqualStrings("/tmp/check=outs/server", entry.path);
}

test "parseSpec rejects specs without a separator" {
    try std.testing.expectError(error.MissingSeparator, parseSpec("github:acme/server"));
    try std.testing.expectError(error.MissingSeparator, parseSpec(""));
}

test "parseSpec rejects empty origin and empty path" {
    try std.testing.expectError(error.EmptyOrigin, parseSpec("=../server"));
    try std.testing.expectError(error.EmptyPath, parseSpec("github:acme/server="));
}

test "parseSpec rejects origins outside the normalized shape" {
    const invalid_origins = [_][]const u8{
        "acme/server=../server", // missing github: prefix
        "github:acme=../server", // no owner/repo split
        "github:/server=../server", // empty owner
        "github:acme/=../server", // empty repo
        "github:acme/server/extra=../server", // extra path segment
        "github:acme/server.git=../server", // .git suffix never survives normalization
        "gitlab:acme/server=../server", // unsupported forge
    };
    for (invalid_origins) |spec| {
        try std.testing.expectError(error.InvalidOrigin, parseSpec(spec));
    }
}

test "RepoMap.build normalizes relative paths against the base directory" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "../server" },
        .{ .origin = "github:acme/client", .path = "/checkouts/client" },
    };
    const map = try RepoMap.build(arena.allocator(), &source_entries, "/work/drift");

    try std.testing.expectEqualStrings("/work/server", map.resolve("github:acme/server").?);
    try std.testing.expectEqualStrings("/checkouts/client", map.resolve("github:acme/client").?);
}

test "RepoMap.buildMerged prefers flag entries over config entries for the same origin" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const flag_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "../server" },
    };
    const config_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "checkouts/wrong-server" },
        .{ .origin = "github:acme/client", .path = "../client" },
    };
    const map = try RepoMap.buildMerged(arena.allocator(), &flag_entries, "/cwd/drift", &config_entries, "/root/drift");

    try std.testing.expectEqual(@as(usize, 2), map.entries.len);
    try std.testing.expectEqualStrings("/cwd/server", map.resolve("github:acme/server").?);
    try std.testing.expectEqualStrings("/root/client", map.resolve("github:acme/client").?);
}

test "RepoMap.buildMerged resolves config paths against the config base, flag paths against the flag base" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const flag_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "../server" },
    };
    const config_entries = [_]Entry{
        .{ .origin = "github:acme/client", .path = "../client" },
    };
    // The caller's cwd is a subdirectory of the lockfile root: flag paths
    // follow the cwd, config paths stay anchored to the root.
    const map = try RepoMap.buildMerged(arena.allocator(), &flag_entries, "/work/drift/sub", &config_entries, "/work/drift");

    try std.testing.expectEqualStrings("/work/drift/server", map.resolve("github:acme/server").?);
    try std.testing.expectEqualStrings("/work/client", map.resolve("github:acme/client").?);
}

test "RepoMap.buildMerged with no flag entries keeps all config entries" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const config_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "/checkouts/server" },
    };
    const map = try RepoMap.buildMerged(arena.allocator(), &.{}, "/cwd", &config_entries, "/root");

    try std.testing.expectEqual(@as(usize, 1), map.entries.len);
    try std.testing.expectEqualStrings("/checkouts/server", map.resolve("github:acme/server").?);
}

test "validate accepts normalized entries and rejects malformed ones" {
    try validate(.{ .origin = "github:acme/server", .path = "../server" });
    try std.testing.expectError(error.EmptyOrigin, validate(.{ .origin = "", .path = "../server" }));
    try std.testing.expectError(error.EmptyPath, validate(.{ .origin = "github:acme/server", .path = "" }));
    try std.testing.expectError(error.InvalidOrigin, validate(.{ .origin = "gitlab:acme/server", .path = "../server" }));
}

test "RepoMap.resolve returns null for unmapped origins" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source_entries = [_]Entry{
        .{ .origin = "github:acme/server", .path = "../server" },
    };
    const map = try RepoMap.build(arena.allocator(), &source_entries, "/work/drift");

    try std.testing.expect(map.resolve("github:acme/other") == null);
    try std.testing.expect(RepoMap.empty.resolve("github:acme/server") == null);
}
