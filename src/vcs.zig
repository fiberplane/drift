const std = @import("std");

pub const VcsKind = enum { git, jj };

/// Detect whether the current working directory uses jj or git.
/// Always returns git for now — jj change IDs don't resolve in git-only CI,
/// and colocated repos have git underneath anyway. Re-enable when jj-native
/// forges exist and CI can resolve change IDs natively.
pub fn detectVcs() VcsKind {
    // TODO: re-enable jj detection when jj-native forges exist
    // std.fs.cwd().access(".jj", .{}) catch {
    //     return .git;
    // };
    // return .jj;
    return .git;
}

fn runGit(
    io: std.Io,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd_path: []const u8,
    stdout_limit: std.Io.Limit,
) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
        .stdout_limit = stdout_limit,
        .stderr_limit = stdout_limit,
    });
}

/// Get the last commit/change ID that touched a given file path.
pub fn getLastCommit(io: std.Io, allocator: std.mem.Allocator, cwd_path: []const u8, file_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try runGit(
            io,
            allocator,
            &.{ "git", "log", "-1", "--format=%H", "--", file_path },
            cwd_path,
            .limited(256 * 1024),
        ),
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "latest(::@ & file(\"{s}\"))", .{file_path});
            defer allocator.free(revset);
            break :blk try runGit(
                io,
                allocator,
                &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                cwd_path,
                .limited(256 * 1024),
            );
        },
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    // Trim trailing newline
    const trimmed = std.mem.trimEnd(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const commit = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return commit;
}

/// Check if a bound file was modified after the given commit/change.
pub fn checkStaleness(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    doc_commit: []const u8,
    bound_file: []const u8,
    vcs: VcsKind,
) !bool {
    const result = switch (vcs) {
        .git => blk: {
            const range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{doc_commit});
            defer allocator.free(range);
            break :blk try runGit(
                io,
                allocator,
                &.{ "git", "log", "--oneline", range, "--", bound_file },
                cwd_path,
                .limited(256 * 1024),
            );
        },
        .jj => blk: {
            const revset = try std.fmt.allocPrint(allocator, "{s}..@ & file(\"{s}\")", .{ doc_commit, bound_file });
            defer allocator.free(revset);
            break :blk try runGit(
                io,
                allocator,
                &.{ "jj", "log", "-r", revset, "--no-graph", "-T", "change_id ++ \"\\n\"", "--color=never" },
                cwd_path,
                .limited(256 * 1024),
            );
        },
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    return trimmed.len > 0;
}

/// Get file content at a specific revision. Returns null if the file didn't exist at that revision.
/// Caller owns returned memory.
pub fn getFileAtRevision(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    revision: []const u8,
    file_path: []const u8,
    vcs_kind: VcsKind,
) !?[]const u8 {
    const rev_path = switch (vcs_kind) {
        .git => try std.fmt.allocPrint(allocator, "{s}:{s}", .{ revision, file_path }),
        .jj => null,
    };
    defer if (rev_path) |rp| allocator.free(rp);

    const argv: []const []const u8 = switch (vcs_kind) {
        .git => &.{ "git", "show", rev_path.? },
        .jj => &.{ "jj", "file", "show", "-r", revision, file_path },
    };

    const result = runGit(io, allocator, argv, cwd_path, .limited(1024 * 1024)) catch return null;
    defer allocator.free(result.stderr);

    // Non-zero exit means the file didn't exist at that revision
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    return result.stdout;
}

/// Information about the most recent commit that changed a file after a given revision.
pub const BlameInfo = struct {
    author: []const u8,
    /// Full object name (`git log` `%H`), not abbreviated.
    commit_hash: []const u8,
    /// Committer date as ISO 8601 strict (`git --date=iso-strict`), locale-independent.
    date: []const u8,
    subject: []const u8,

    pub fn deinit(self: BlameInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.author);
        allocator.free(self.commit_hash);
        allocator.free(self.date);
        allocator.free(self.subject);
    }
};

fn parseBlameInfoOutput(allocator: std.mem.Allocator, stdout: []const u8) !?BlameInfo {
    const trimmed = std.mem.trimEnd(u8, stdout, "\n\r ");
    if (trimmed.len == 0) return null;

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    const author_raw = lines.next() orelse return null;
    const hash_raw = lines.next() orelse return null;
    const date_raw = lines.next() orelse return null;
    const subject_raw = lines.rest();
    if (subject_raw.len == 0) return null;

    const author = try allocator.dupe(u8, author_raw);
    errdefer allocator.free(author);
    const commit_hash = try allocator.dupe(u8, hash_raw);
    errdefer allocator.free(commit_hash);
    const date = try allocator.dupe(u8, date_raw);
    errdefer allocator.free(date);
    const subject = try allocator.dupe(u8, subject_raw);

    return .{
        .author = author,
        .commit_hash = commit_hash,
        .date = date,
        .subject = subject,
    };
}

/// Get blame info for the most recent commit that changed a file after a given revision.
/// Returns null if no commits changed the file after the revision.
/// String fields are allocated with `result_allocator`. Subprocess I/O buffers use `subprocess_allocator`.
pub fn getBlameInfo(
    io: std.Io,
    result_allocator: std.mem.Allocator,
    subprocess_allocator: std.mem.Allocator,
    cwd_path: []const u8,
    file_path: []const u8,
    after_revision: []const u8,
    vcs_kind: VcsKind,
) !?BlameInfo {
    switch (vcs_kind) {
        .git => {
            const range = try std.fmt.allocPrint(subprocess_allocator, "{s}..HEAD", .{after_revision});
            defer subprocess_allocator.free(range);

            const result = runGit(
                io,
                subprocess_allocator,
                &.{ "git", "log", "-1", "--format=%an%n%H%n%cd%n%s", "--date=iso-strict", range, "--", file_path },
                cwd_path,
                .limited(256 * 1024),
            ) catch return null;
            defer subprocess_allocator.free(result.stderr);
            defer subprocess_allocator.free(result.stdout);

            return try parseBlameInfoOutput(result_allocator, result.stdout);
        },
        .jj => return null, // jj support disabled
    }
}

/// Get blame info for the most recent commit that touched a file, regardless of baseline.
/// String fields are allocated with `result_allocator`. Subprocess I/O buffers use `subprocess_allocator`.
pub fn getLatestBlameInfo(
    io: std.Io,
    result_allocator: std.mem.Allocator,
    subprocess_allocator: std.mem.Allocator,
    cwd_path: []const u8,
    file_path: []const u8,
    vcs_kind: VcsKind,
) !?BlameInfo {
    switch (vcs_kind) {
        .git => {
            const result = runGit(
                io,
                subprocess_allocator,
                &.{ "git", "log", "-1", "--format=%an%n%H%n%cd%n%s", "--date=iso-strict", "--", file_path },
                cwd_path,
                .limited(256 * 1024),
            ) catch return null;
            defer subprocess_allocator.free(result.stderr);
            defer subprocess_allocator.free(result.stdout);

            return try parseBlameInfoOutput(result_allocator, result.stdout);
        },
        .jj => return null,
    }
}

/// Normalize a GitHub remote URL to `github:owner/repo` format.
/// Handles SSH (`git@github.com:owner/repo`), HTTPS (`https://github.com/owner/repo`),
/// and SSH URL (`ssh://git@github.com/owner/repo`) formats.
/// Strips `.git` suffix and trailing slashes. Returns null for non-GitHub URLs.
pub fn normalizeGitHubUrl(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, url, " \t\n\r/");

    // Extract the owner/repo path from the URL
    const path = blk: {
        // SSH: git@github.com:owner/repo
        if (std.mem.startsWith(u8, trimmed, "git@github.com:")) {
            break :blk trimmed["git@github.com:".len..];
        }
        // HTTPS: https://github.com/owner/repo
        if (std.mem.startsWith(u8, trimmed, "https://github.com/")) {
            break :blk trimmed["https://github.com/".len..];
        }
        // SSH URL: ssh://git@github.com/owner/repo
        if (std.mem.startsWith(u8, trimmed, "ssh://git@github.com/")) {
            break :blk trimmed["ssh://git@github.com/".len..];
        }
        return null;
    };

    // Strip .git suffix
    const clean = if (std.mem.endsWith(u8, path, ".git"))
        path[0 .. path.len - 4]
    else
        path;

    if (clean.len == 0) return null;

    return std.fmt.allocPrint(allocator, "github:{s}", .{clean}) catch null;
}

/// Get the normalized repo identity by querying `git remote get-url origin`.
/// Returns `github:owner/repo` or null if not a GitHub remote.
/// Result string is allocated with `result_allocator`; subprocess buffers use `subprocess_allocator`.
pub fn getRepoIdentity(io: std.Io, result_allocator: std.mem.Allocator, subprocess_allocator: std.mem.Allocator, cwd_path: []const u8) ?[]const u8 {
    const result = runGit(
        io,
        subprocess_allocator,
        &.{ "git", "remote", "get-url", "origin" },
        cwd_path,
        .limited(4096),
    ) catch return null;
    defer subprocess_allocator.free(result.stderr);
    defer subprocess_allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\n\r ");
    if (trimmed.len == 0) return null;

    return normalizeGitHubUrl(result_allocator, trimmed);
}

/// Get the current change/commit ID (short form) for auto-provenance.
pub fn getCurrentChangeId(io: std.Io, allocator: std.mem.Allocator, cwd_path: []const u8, vcs: VcsKind) !?[]const u8 {
    const result = switch (vcs) {
        .git => try runGit(
            io,
            allocator,
            &.{ "git", "rev-parse", "--short", "HEAD" },
            cwd_path,
            .limited(256 * 1024),
        ),
        .jj => try runGit(
            io,
            allocator,
            &.{ "jj", "log", "-r", "@", "--no-graph", "-T", "change_id.shortest(8)", "--color=never" },
            cwd_path,
            .limited(256 * 1024),
        ),
    };
    defer allocator.free(result.stderr);

    const stdout = result.stdout;
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const trimmed = std.mem.trimEnd(u8, stdout, "\n\r ");
    if (trimmed.len == 0) {
        allocator.free(stdout);
        return null;
    }

    const id = try allocator.dupe(u8, trimmed);
    allocator.free(stdout);
    return id;
}

/// Persistent `git cat-file --batch` process for fetching historical file
/// content without spawning a new process per query.
pub const GitCatFile = struct {
    io: std.Io,
    child: std.process.Child,
    read_buf: []u8,
    stdout_reader: std.Io.File.Reader,
    allocator: std.mem.Allocator,

    const read_buf_size = 8192;

    pub fn init(io: std.Io, allocator: std.mem.Allocator, cwd_path: []const u8) !GitCatFile {
        const read_buf = try allocator.alloc(u8, read_buf_size);
        errdefer allocator.free(read_buf);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "git", "cat-file", "--batch" },
            .cwd = .{ .path = cwd_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer {
            child.kill(io);
        }

        var result: GitCatFile = .{
            .io = io,
            .child = child,
            .read_buf = read_buf,
            .stdout_reader = undefined,
            .allocator = allocator,
        };
        result.stdout_reader = result.child.stdout.?.readerStreaming(io, result.read_buf);
        return result;
    }

    /// Fetch a blob from git's object store. Returns file content at the given
    /// revision, or null if the object doesn't exist.
    pub fn getContent(self: *GitCatFile, allocator: std.mem.Allocator, revision: []const u8, file_path: []const u8) !?[]const u8 {
        const stdin = self.child.stdin orelse return error.BrokenPipe;

        stdin.writeStreamingAll(self.io, revision) catch return null;
        stdin.writeStreamingAll(self.io, ":") catch return null;
        stdin.writeStreamingAll(self.io, file_path) catch return null;
        stdin.writeStreamingAll(self.io, "\n") catch return null;

        const header = self.stdout_reader.interface.takeDelimiterExclusive('\n') catch return null;

        if (std.mem.endsWith(u8, header, " missing")) {
            return null;
        }

        const last_space = std.mem.lastIndexOfScalar(u8, header, ' ') orelse return null;
        const size = std.fmt.parseInt(usize, header[last_space + 1 ..], 10) catch return null;

        const content = try allocator.alloc(u8, size);
        errdefer allocator.free(content);

        self.stdout_reader.interface.readSliceAll(content) catch {
            allocator.free(content);
            return null;
        };

        // Consume trailing newline after blob content
        _ = self.stdout_reader.interface.takeByte() catch {};

        return content;
    }

    pub fn deinit(self: *GitCatFile) void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
        }
        _ = self.child.wait(self.io) catch {};
        self.allocator.free(self.read_buf);
    }
};

// --- unit tests ---

test "normalizeGitHubUrl handles SSH format" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "git@github.com:fiberplane/drift.git") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("github:fiberplane/drift", result);
}

test "normalizeGitHubUrl handles HTTPS format" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "https://github.com/fiberplane/drift.git") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("github:fiberplane/drift", result);
}

test "normalizeGitHubUrl handles SSH URL format" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "ssh://git@github.com/fiberplane/drift") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("github:fiberplane/drift", result);
}

test "normalizeGitHubUrl strips trailing slash" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "https://github.com/owner/repo/") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("github:owner/repo", result);
}

test "normalizeGitHubUrl without .git suffix" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "https://github.com/owner/repo") orelse
        return error.TestUnexpectedResult;
    defer allocator.free(result);
    try std.testing.expectEqualStrings("github:owner/repo", result);
}

test "normalizeGitHubUrl returns null for non-GitHub URL" {
    const allocator = std.testing.allocator;
    const result = normalizeGitHubUrl(allocator, "https://gitlab.com/owner/repo.git");
    try std.testing.expect(result == null);
}
