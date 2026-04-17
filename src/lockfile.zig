const std = @import("std");

pub const MetadataField = struct {
    key: []const u8,
    value: []const u8,
};

pub const Binding = struct {
    doc_path: []const u8,
    target: []const u8,
    metadata: std.ArrayList(MetadataField),

    pub fn fieldValue(self: *const Binding, key: []const u8) ?[]const u8 {
        for (self.metadata.items) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
        }
        return null;
    }

    /// Removes a metadata field by key, if present.
    pub fn removeField(self: *Binding, key: []const u8) void {
        var i: usize = 0;
        while (i < self.metadata.items.len) {
            if (std.mem.eql(u8, self.metadata.items[i].key, key)) {
                _ = self.metadata.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// Updates or appends a metadata field. On replace, frees the old value with `allocator` before allocating the new slice.
    pub fn setField(self: *Binding, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.metadata.items) |*field| {
            if (std.mem.eql(u8, field.key, key)) {
                allocator.free(field.value);
                field.value = try allocator.dupe(u8, value);
                return;
            }
        }
        try self.metadata.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }
};

pub const Lockfile = struct {
    root_path: []const u8,
    lockfile_path: []const u8,
    exists: bool,
    bindings: std.ArrayList(Binding),
};

pub const DocBindings = struct {
    path: []const u8,
    bindings: std.ArrayList(*Binding),
};

pub const ParseError = error{
    InvalidBindingLine,
    InvalidMetadataField,
};

/// `run` holds durable lockfile state; `scratch` holds walk temporaries and the lockfile file buffer (reset by caller).
pub fn discover(io: std.Io, run: std.mem.Allocator, scratch: std.mem.Allocator, start_path: []const u8) !Lockfile {
    const resolved_run = if (std.Io.Dir.path.isAbsolute(start_path))
        try run.dupe(u8, start_path)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, start_path, run);
    defer run.free(resolved_run);

    var current = try scratch.dupe(u8, resolved_run);

    while (true) {
        const candidate = try std.Io.Dir.path.join(scratch, &.{ current, "drift.lock" });

        if (fileExists(io, candidate)) {
            return try readAtPath(io, run, scratch, current, candidate, true);
        }

        // Stop at VCS root — don't climb out of the current repository.
        const has_git = fileExists(io, try std.Io.Dir.path.join(scratch, &.{ current, ".git" }));
        const has_jj = fileExists(io, try std.Io.Dir.path.join(scratch, &.{ current, ".jj" }));
        if (has_git or has_jj) {
            return .{
                .root_path = try run.dupe(u8, current),
                .lockfile_path = try std.Io.Dir.path.join(run, &.{ current, "drift.lock" }),
                .exists = false,
                .bindings = .empty,
            };
        }

        const parent = parentPath(current) orelse {
            return .{
                .root_path = try run.dupe(u8, resolved_run),
                .lockfile_path = try std.Io.Dir.path.join(run, &.{ resolved_run, "drift.lock" }),
                .exists = false,
                .bindings = .empty,
            };
        };
        current = try scratch.dupe(u8, parent);
    }
}

pub fn readAtPath(io: std.Io, run: std.mem.Allocator, scratch: std.mem.Allocator, root_path: []const u8, lockfile_path: []const u8, exists: bool) !Lockfile {
    var bindings: std.ArrayList(Binding) = .empty;
    errdefer {
        for (bindings.items) |*binding| {
            run.free(binding.doc_path);
            run.free(binding.target);
            for (binding.metadata.items) |field| {
                run.free(field.key);
                run.free(field.value);
            }
            binding.metadata.deinit(run);
        }
        bindings.deinit(run);
    }

    if (exists) {
        const content = try readFileAt(io, scratch, lockfile_path, 1024 * 1024);
        defer scratch.free(content);
        try parseInto(run, content, &bindings);
    }

    return .{
        .root_path = try run.dupe(u8, root_path),
        .lockfile_path = try run.dupe(u8, lockfile_path),
        .exists = exists,
        .bindings = bindings,
    };
}

pub fn parseInto(allocator: std.mem.Allocator, content: []const u8, bindings: *std.ArrayList(Binding)) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try bindings.append(allocator, try parseLine(allocator, trimmed));
    }
}

pub fn groupByDoc(allocator: std.mem.Allocator, bindings: []Binding) !std.ArrayList(DocBindings) {
    var docs: std.ArrayList(DocBindings) = .empty;
    errdefer {
        for (docs.items) |*doc| doc.bindings.deinit(allocator);
        docs.deinit(allocator);
    }

    for (bindings) |*binding| {
        var found: ?*DocBindings = null;
        for (docs.items) |*doc| {
            if (std.mem.eql(u8, doc.path, binding.doc_path)) {
                found = doc;
                break;
            }
        }

        if (found) |doc| {
            try doc.bindings.append(allocator, binding);
        } else {
            var doc = DocBindings{
                .path = binding.doc_path,
                .bindings = .empty,
            };
            errdefer doc.bindings.deinit(allocator);
            try doc.bindings.append(allocator, binding);
            try docs.append(allocator, doc);
        }
    }

    std.mem.sort(DocBindings, docs.items, {}, struct {
        fn lessThan(_: void, a: DocBindings, b: DocBindings) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    for (docs.items) |*doc| {
        std.mem.sort(*Binding, doc.bindings.items, {}, struct {
            fn lessThan(_: void, a: *Binding, b: *Binding) bool {
                return std.mem.order(u8, a.target, b.target) == .lt;
            }
        }.lessThan);
    }

    return docs;
}

fn renderLineToWriter(writer: *std.Io.Writer, binding: Binding) !void {
    try writer.print("{s} -> {s}", .{ binding.doc_path, binding.target });
    for (binding.metadata.items) |field| {
        try writer.print(" {s}:{s}", .{ field.key, field.value });
    }
}

/// Writes sorted lockfile lines to `writer`. Uses `scratch` for sort temporaries.
pub fn serializeToWriter(scratch: std.mem.Allocator, writer: *std.Io.Writer, bindings: []const Binding) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |line| scratch.free(line);
        lines.deinit(scratch);
    }

    for (bindings) |binding| {
        var row: std.Io.Writer.Allocating = .init(scratch);
        errdefer row.deinit();
        try renderLineToWriter(&row.writer, binding);
        try lines.append(scratch, try row.toOwnedSlice());
    }

    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (lines.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

pub fn serialize(allocator: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try serializeToWriter(allocator, &output.writer, bindings);
    return try output.toOwnedSlice();
}

pub fn writeFile(io: std.Io, lockfile: *const Lockfile, scratch: std.mem.Allocator) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, lockfile.lockfile_path, .{ .truncate = true });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    defer fw.interface.flush() catch {};
    try serializeToWriter(scratch, &fw.interface, lockfile.bindings.items);
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Binding {
    const arrow = std.mem.find(u8, line, " -> ") orelse return error.InvalidBindingLine;
    const doc_path = std.mem.trim(u8, line[0..arrow], " \t");
    const rest = std.mem.trim(u8, line[arrow + " -> ".len ..], " \t");
    if (doc_path.len == 0 or rest.len == 0) return error.InvalidBindingLine;

    var tokens = std.mem.tokenizeScalar(u8, rest, ' ');
    const target = tokens.next() orelse return error.InvalidBindingLine;

    var metadata: std.ArrayList(MetadataField) = .empty;
    errdefer metadata.deinit(allocator);

    while (tokens.next()) |token| {
        const colon = std.mem.findScalar(u8, token, ':') orelse return error.InvalidMetadataField;
        if (colon == 0 or colon == token.len - 1) return error.InvalidMetadataField;
        try metadata.append(allocator, .{
            .key = try allocator.dupe(u8, token[0..colon]),
            .value = try allocator.dupe(u8, token[colon + 1 ..]),
        });
    }

    return .{
        .doc_path = try allocator.dupe(u8, doc_path),
        .target = try allocator.dupe(u8, target),
        .metadata = metadata,
    };
}

fn fileExists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

/// Read a file at `path` (absolute or cwd-relative) fully into memory via `allocator`.
fn readFileAt(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = if (std.Io.Dir.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

fn parentPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return null;
    const parent = std.Io.Dir.path.dirname(path) orelse return null;
    if (parent.len == 0) return "/";
    if (std.mem.eql(u8, parent, path)) return null;
    return parent;
}

test "parseInto reads bindings and metadata" {
    const allocator = std.testing.allocator;
    const content =
        "# drift.lock\n" ++
        "docs/auth.md -> src/auth/login.ts sig:a1b2c3d4e5f6a7b8\n" ++
        "docs/auth.md -> src/auth/provider.ts#AuthConfig sig:1a2b3c4d5e6f7890 origin:github:fiberplane/drift\n";

    var bindings: std.ArrayList(Binding) = .empty;
    defer {
        for (bindings.items) |*binding| {
            allocator.free(binding.doc_path);
            allocator.free(binding.target);
            for (binding.metadata.items) |field| {
                allocator.free(field.key);
                allocator.free(field.value);
            }
            binding.metadata.deinit(allocator);
        }
        bindings.deinit(allocator);
    }

    try parseInto(allocator, content, &bindings);
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expectEqualStrings("docs/auth.md", bindings.items[0].doc_path);
    try std.testing.expectEqualStrings("src/auth/login.ts", bindings.items[0].target);
    try std.testing.expectEqualStrings("a1b2c3d4e5f6a7b8", bindings.items[0].fieldValue("sig").?);
    try std.testing.expectEqualStrings("github:fiberplane/drift", bindings.items[1].fieldValue("origin").?);
}

test "serialize sorts lines and appends trailing newline" {
    const allocator = std.testing.allocator;

    var bindings: std.ArrayList(Binding) = .empty;
    defer {
        for (bindings.items) |*binding| {
            allocator.free(binding.doc_path);
            allocator.free(binding.target);
            for (binding.metadata.items) |field| {
                allocator.free(field.key);
                allocator.free(field.value);
            }
            binding.metadata.deinit(allocator);
        }
        bindings.deinit(allocator);
    }

    try bindings.append(allocator, .{
        .doc_path = try allocator.dupe(u8, "docs/z.md"),
        .target = try allocator.dupe(u8, "src/z.ts"),
        .metadata = .empty,
    });
    try bindings.append(allocator, .{
        .doc_path = try allocator.dupe(u8, "docs/a.md"),
        .target = try allocator.dupe(u8, "src/a.ts"),
        .metadata = .empty,
    });

    const content = try serialize(allocator, bindings.items);
    defer allocator.free(content);

    try std.testing.expectEqualStrings(
        "docs/a.md -> src/a.ts\ndocs/z.md -> src/z.ts\n",
        content,
    );
}

test "discover walks up to find drift.lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/nested/work");
    try tmp.dir.writeFile(io, .{
        .sub_path = "repo/drift.lock",
        .data = "docs/doc.md -> src/main.ts sig:abc123\n",
    });

    const start_path = try tmp.dir.realPathFileAlloc(io, "repo/nested/work", allocator);
    defer allocator.free(start_path);

    var discovered = try discover(io, allocator, scratch_arena.allocator(), start_path);
    defer {
        for (discovered.bindings.items) |*b| {
            allocator.free(b.doc_path);
            allocator.free(b.target);
            for (b.metadata.items) |field| {
                allocator.free(field.key);
                allocator.free(field.value);
            }
            b.metadata.deinit(allocator);
        }
        discovered.bindings.deinit(allocator);
        allocator.free(discovered.root_path);
        allocator.free(discovered.lockfile_path);
    }

    try std.testing.expect(discovered.exists);
    try std.testing.expectEqual(@as(usize, 1), discovered.bindings.items.len);
    try std.testing.expect(std.mem.endsWith(u8, discovered.root_path, "/repo"));
    try std.testing.expect(std.mem.endsWith(u8, discovered.lockfile_path, "/repo/drift.lock"));
}

test "discover returns empty lockfile rooted at start path when missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/.git");

    const start_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(start_path);

    var discovered = try discover(io, allocator, scratch_arena.allocator(), start_path);
    defer {
        discovered.bindings.deinit(allocator);
        allocator.free(discovered.root_path);
        allocator.free(discovered.lockfile_path);
    }

    try std.testing.expect(!discovered.exists);
    try std.testing.expectEqual(@as(usize, 0), discovered.bindings.items.len);
    try std.testing.expectEqualStrings(start_path, discovered.root_path);
    try std.testing.expect(std.mem.endsWith(u8, discovered.lockfile_path, "/repo/drift.lock"));
}
