const std = @import("std");
const build_options = @import("build_options");

/// Result returned by runDrift.
pub const ExecResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    pub fn exitCode(self: ExecResult) u8 {
        return switch (self.term) {
            .Exited => |code| code,
            else => 255,
        };
    }

    pub fn deinit(self: ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// A temporary git repository for integration tests.
pub const TempRepo = struct {
    tmp: std.testing.TmpDir,
    abs_path: []const u8,
    allocator: std.mem.Allocator,

    /// Create a temp dir and run `git init` inside it.
    pub fn init(allocator: std.mem.Allocator) !TempRepo {
        const tmp = std.testing.tmpDir(.{});

        // Resolve the absolute path of the temp dir so we can pass it as cwd to child processes.
        const abs_path = try std.fs.cwd().realpathAlloc(allocator, ".zig-cache/tmp/" ++ &tmp.sub_path);

        // git init
        const git_init = try runProcess(allocator, &.{ "git", "init" }, abs_path);
        defer git_init.deinit(allocator);

        // Configure git user for commits
        const git_email = try runProcess(allocator, &.{ "git", "config", "user.email", "test@drift.dev" }, abs_path);
        defer git_email.deinit(allocator);

        const git_name = try runProcess(allocator, &.{ "git", "config", "user.name", "Test" }, abs_path);
        defer git_name.deinit(allocator);

        // Create initial commit so HEAD exists
        const allow_empty = try runProcess(allocator, &.{ "git", "commit", "--allow-empty", "-m", "initial" }, abs_path);
        defer allow_empty.deinit(allocator);

        return .{
            .tmp = tmp,
            .abs_path = abs_path,
            .allocator = allocator,
        };
    }

    /// Write a file at the given relative path, creating parent directories as needed.
    pub fn writeFile(self: *TempRepo, path: []const u8, content: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            try self.tmp.dir.makePath(parent);
        }
        try self.tmp.dir.writeFile(.{
            .sub_path = path,
            .data = content,
        });
    }

    /// Write a markdown spec file with drift frontmatter.
    /// `frontmatter_files` is the list of file bindings for the drift: files: section.
    /// `body` is the markdown body after the frontmatter.
    pub fn writeSpec(self: *TempRepo, path: []const u8, frontmatter_files: []const []const u8, body: []const u8) !void {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);
        try writer.writeAll("---\n");
        try writer.writeAll("drift:\n");
        try writer.writeAll("  files:\n");
        for (frontmatter_files) |file| {
            try writer.print("    - {s}\n", .{file});
        }
        try writer.writeAll("---\n");
        if (body.len > 0) {
            try writer.writeAll(body);
            if (body[body.len - 1] != '\n') {
                try writer.writeByte('\n');
            }
        }

        try self.writeFile(path, buf.items);
    }

    /// Stage all files and create a git commit.
    pub fn commit(self: *TempRepo, message: []const u8) !void {
        const add_result = try runProcess(self.allocator, &.{ "git", "add", "-A" }, self.abs_path);
        defer add_result.deinit(self.allocator);

        const commit_result = try runProcess(self.allocator, &.{ "git", "commit", "-m", message }, self.abs_path);
        defer commit_result.deinit(self.allocator);
    }

    /// Run the drift binary with given arguments, cwd set to the temp repo.
    pub fn runDrift(self: *TempRepo, args: []const []const u8) !ExecResult {
        const drift_bin = build_options.drift_bin;

        // Build argv: drift_bin + args (max 16 extra args)
        var argv_buf: [17][]const u8 = undefined;
        argv_buf[0] = drift_bin;
        for (args, 0..) |arg, i| {
            argv_buf[i + 1] = arg;
        }
        const argv = argv_buf[0 .. args.len + 1];

        return runProcess(self.allocator, argv, self.abs_path);
    }

    /// Read a file from the temp repo. Caller owns the returned memory.
    pub fn readFile(self: *TempRepo, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(self.allocator, path, 1024 * 1024);
    }

    /// Clean up the temp directory.
    pub fn cleanup(self: *TempRepo) void {
        self.allocator.free(self.abs_path);
        self.tmp.cleanup();
    }
};

/// Run a process and collect stdout/stderr. Caller owns result memory.
fn runProcess(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !ExecResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 256 * 1024,
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .term = result.term,
    };
}

// --- Assertion helpers ---

/// Assert that the process exited with the expected code.
pub fn expectExitCode(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .Exited => |code| {
            if (code != expected) {
                std.debug.print("\nExpected exit code {d}, got {d}\n", .{ expected, code });
                return error.TestUnexpectedResult;
            }
        },
        else => {
            std.debug.print("\nProcess did not exit normally\n", .{});
            return error.TestUnexpectedResult;
        },
    }
}

/// Assert that `haystack` contains `needle`.
pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\n--- Expected to find ---\n{s}\n--- in output ---\n{s}\n--- end ---\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// Assert that `haystack` does NOT contain `needle`.
pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\n--- Expected NOT to find ---\n{s}\n--- in output ---\n{s}\n--- end ---\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}
