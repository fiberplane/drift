const std = @import("std");

pub const MetadataField = struct {
    key: []const u8,
    value: []const u8,

    fn deinit(self: MetadataField, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const Binding = struct {
    spec_path: []const u8,
    target: []const u8,
    metadata: std.ArrayList(MetadataField),

    pub fn deinit(self: *Binding, allocator: std.mem.Allocator) void {
        allocator.free(self.spec_path);
        allocator.free(self.target);
        for (self.metadata.items) |field| field.deinit(allocator);
        self.metadata.deinit(allocator);
    }

    pub fn fieldValue(self: *const Binding, key: []const u8) ?[]const u8 {
        for (self.metadata.items) |field| {
            if (std.mem.eql(u8, field.key, key)) return field.value;
        }
        return null;
    }

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

    pub fn deinit(self: *Lockfile, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.lockfile_path);
        for (self.bindings.items) |*binding| binding.deinit(allocator);
        self.bindings.deinit(allocator);
    }
};

pub const ParseError = error{
    InvalidBindingLine,
    InvalidMetadataField,
};

pub fn discover(allocator: std.mem.Allocator, start_path: []const u8) !Lockfile {
    const resolved_start = if (std.fs.path.isAbsolute(start_path))
        try allocator.dupe(u8, start_path)
    else
        try std.fs.cwd().realpathAlloc(allocator, start_path);
    defer allocator.free(resolved_start);

    var current = try allocator.dupe(u8, resolved_start);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "drift.lock" });
        errdefer allocator.free(candidate);

        if (fileExists(candidate)) {
            const lockfile = try readAtPath(allocator, current, candidate, true);
            allocator.free(candidate);
            return lockfile;
        }
        allocator.free(candidate);

        const parent = parentPath(current) orelse {
            return .{
                .root_path = try allocator.dupe(u8, resolved_start),
                .lockfile_path = try std.fs.path.join(allocator, &.{ resolved_start, "drift.lock" }),
                .exists = false,
                .bindings = .{},
            };
        };
        const next_current = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next_current;
    }
}

pub fn readAtPath(allocator: std.mem.Allocator, root_path: []const u8, lockfile_path: []const u8, exists: bool) !Lockfile {
    var bindings: std.ArrayList(Binding) = .{};
    errdefer {
        for (bindings.items) |*binding| binding.deinit(allocator);
        bindings.deinit(allocator);
    }

    if (exists) {
        const file = try openPath(lockfile_path);
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        try parseInto(allocator, content, &bindings);
    }

    return .{
        .root_path = try allocator.dupe(u8, root_path),
        .lockfile_path = try allocator.dupe(u8, lockfile_path),
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

pub fn serialize(allocator: std.mem.Allocator, bindings: []const Binding) ![]u8 {
    var lines: std.ArrayList([]const u8) = .{};
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    for (bindings) |binding| {
        try lines.append(allocator, try renderLine(allocator, binding));
    }

    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    for (lines.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    return try output.toOwnedSlice(allocator);
}

pub fn writeFile(lockfile: *const Lockfile, allocator: std.mem.Allocator) !void {
    const content = try serialize(allocator, lockfile.bindings.items);
    defer allocator.free(content);

    const file = try createPath(lockfile.lockfile_path);
    defer file.close();
    try file.writeAll(content);
}

fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Binding {
    const arrow = std.mem.indexOf(u8, line, " -> ") orelse return error.InvalidBindingLine;
    const spec_path = std.mem.trim(u8, line[0..arrow], " \t");
    const rest = std.mem.trim(u8, line[arrow + " -> ".len ..], " \t");
    if (spec_path.len == 0 or rest.len == 0) return error.InvalidBindingLine;

    var tokens = std.mem.tokenizeScalar(u8, rest, ' ');
    const target = tokens.next() orelse return error.InvalidBindingLine;

    var metadata: std.ArrayList(MetadataField) = .{};
    errdefer {
        for (metadata.items) |field| field.deinit(allocator);
        metadata.deinit(allocator);
    }

    while (tokens.next()) |token| {
        const colon = std.mem.indexOfScalar(u8, token, ':') orelse return error.InvalidMetadataField;
        if (colon == 0 or colon == token.len - 1) return error.InvalidMetadataField;
        try metadata.append(allocator, .{
            .key = try allocator.dupe(u8, token[0..colon]),
            .value = try allocator.dupe(u8, token[colon + 1 ..]),
        });
    }

    return .{
        .spec_path = try allocator.dupe(u8, spec_path),
        .target = try allocator.dupe(u8, target),
        .metadata = metadata,
    };
}

fn renderLine(allocator: std.mem.Allocator, binding: Binding) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.print("{s} -> {s}", .{ binding.spec_path, binding.target });
    for (binding.metadata.items) |field| {
        try writer.print(" {s}:{s}", .{ field.key, field.value });
    }

    return try output.toOwnedSlice(allocator);
}

fn fileExists(path: []const u8) bool {
    const file = openPath(path) catch return false;
    file.close();
    return true;
}

fn openPath(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn createPath(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{ .truncate = true });
    }
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}

fn parentPath(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/")) return null;
    const parent = std.fs.path.dirname(path) orelse return null;
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

    var bindings: std.ArrayList(Binding) = .{};
    defer {
        for (bindings.items) |*binding| binding.deinit(allocator);
        bindings.deinit(allocator);
    }

    try parseInto(allocator, content, &bindings);
    try std.testing.expectEqual(@as(usize, 2), bindings.items.len);
    try std.testing.expectEqualStrings("docs/auth.md", bindings.items[0].spec_path);
    try std.testing.expectEqualStrings("src/auth/login.ts", bindings.items[0].target);
    try std.testing.expectEqualStrings("a1b2c3d4e5f6a7b8", bindings.items[0].fieldValue("sig").?);
    try std.testing.expectEqualStrings("github:fiberplane/drift", bindings.items[1].fieldValue("origin").?);
}

test "serialize sorts lines and appends trailing newline" {
    const allocator = std.testing.allocator;

    var bindings: std.ArrayList(Binding) = .{};
    defer {
        for (bindings.items) |*binding| binding.deinit(allocator);
        bindings.deinit(allocator);
    }

    try bindings.append(allocator, .{
        .spec_path = try allocator.dupe(u8, "docs/z.md"),
        .target = try allocator.dupe(u8, "src/z.ts"),
        .metadata = .{},
    });
    try bindings.append(allocator, .{
        .spec_path = try allocator.dupe(u8, "docs/a.md"),
        .target = try allocator.dupe(u8, "src/a.ts"),
        .metadata = .{},
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo/nested/work");
    try tmp.dir.writeFile(.{
        .sub_path = "repo/drift.lock",
        .data = "docs/spec.md -> src/main.ts sig:abc123\n",
    });

    const start_path = try tmp.dir.realpathAlloc(allocator, "repo/nested/work");
    defer allocator.free(start_path);

    var discovered = try discover(allocator, start_path);
    defer discovered.deinit(allocator);

    try std.testing.expect(discovered.exists);
    try std.testing.expectEqual(@as(usize, 1), discovered.bindings.items.len);
    try std.testing.expect(std.mem.endsWith(u8, discovered.root_path, "/repo"));
    try std.testing.expect(std.mem.endsWith(u8, discovered.lockfile_path, "/repo/drift.lock"));
}

test "discover returns empty lockfile rooted at start path when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("repo");

    const start_path = try tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(start_path);

    var discovered = try discover(allocator, start_path);
    defer discovered.deinit(allocator);

    try std.testing.expect(!discovered.exists);
    try std.testing.expectEqual(@as(usize, 0), discovered.bindings.items.len);
    try std.testing.expectEqualStrings(start_path, discovered.root_path);
    try std.testing.expect(std.mem.endsWith(u8, discovered.lockfile_path, "/repo/drift.lock"));
}
