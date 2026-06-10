//! Mapping from foreign binding origins (`github:owner/repo`) to local
//! sibling checkouts, populated from repeated `--repo <origin>=<path>` flags.
//! Lets `drift check` verify anchors whose origin does not match the current
//! repo identity by computing fingerprints against the mapped checkout.

const std = @import("std");

pub const Entry = struct {
    origin: []const u8,
    path: []const u8,
};

pub const ParseSpecError = error{
    MissingSeparator,
    EmptyOrigin,
    EmptyPath,
    InvalidOrigin,
};

/// Parses a `--repo` spec of the form `github:owner/repo=../server`. The
/// first '=' is the separator — origins never contain '=', paths may.
/// The origin must already be in the normalized `github:owner/repo` shape
/// produced by `vcs.normalizeGitHubUrl` / `vcs.getRepoIdentity`.
pub fn parseSpec(spec: []const u8) ParseSpecError!Entry {
    const separator = std.mem.findScalar(u8, spec, '=') orelse return error.MissingSeparator;
    const origin = spec[0..separator];
    const path = spec[separator + 1 ..];

    if (origin.len == 0) return error.EmptyOrigin;
    if (path.len == 0) return error.EmptyPath;
    if (!isNormalizedOrigin(origin)) return error.InvalidOrigin;

    return .{ .origin = origin, .path = path };
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
            entry.* = .{
                .origin = try arena_allocator.dupe(u8, source.origin),
                .path = try std.Io.Dir.path.resolve(arena_allocator, &.{ base_path, source.path }),
            };
        }
        return .{ .entries = entries };
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
