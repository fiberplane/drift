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
    UnsupportedLockfileVersion,
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
    if (containsTomlSyntax(content)) {
        try parseTomlInto(allocator, content, bindings);
        return;
    }

    // Compatibility reader for pre-TOML lockfiles. All writes use V1 TOML, so
    // old files are upgraded on the next mutation.
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

fn lessThanMetadataByKey(_: void, a: MetadataField, b: MetadataField) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn hasInvalidTomlBasicStringByte(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\"\\\n\r") != null;
}

fn writeTomlString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    try writer.writeAll(value);
    try writer.writeByte('"');
}

fn renderTomlBindingToWriter(scratch: std.mem.Allocator, writer: *std.Io.Writer, binding: Binding) !void {
    if (hasInvalidTomlBasicStringByte(binding.doc_path) or hasInvalidTomlBasicStringByte(binding.target)) return error.InvalidBindingLine;

    try writer.writeAll("[[bindings]]\n");
    try writer.writeAll("doc = ");
    try writeTomlString(writer, binding.doc_path);
    try writer.writeByte('\n');
    try writer.writeAll("target = ");
    try writeTomlString(writer, binding.target);
    try writer.writeByte('\n');

    const sorted = try scratch.dupe(MetadataField, binding.metadata.items);
    defer scratch.free(sorted);
    std.mem.sort(MetadataField, sorted, {}, lessThanMetadataByKey);
    for (sorted) |field| {
        if (field.key.len == 0 or hasInvalidTomlBasicStringByte(field.key) or hasInvalidTomlBasicStringByte(field.value)) return error.InvalidMetadataField;
        try writer.print("{s} = ", .{field.key});
        try writeTomlString(writer, field.value);
        try writer.writeByte('\n');
    }
}

/// Writes sorted V1 TOML lockfile tables to `writer`. Uses `scratch` for sort temporaries.
pub fn serializeToWriter(scratch: std.mem.Allocator, writer: *std.Io.Writer, bindings: []const Binding) !void {
    try writer.writeAll("version = 1\n");
    if (bindings.len != 0) try writer.writeByte('\n');

    var blocks: std.ArrayList([]const u8) = .empty;
    defer {
        for (blocks.items) |block| scratch.free(block);
        blocks.deinit(scratch);
    }

    for (bindings) |binding| {
        var block: std.Io.Writer.Allocating = .init(scratch);
        errdefer block.deinit();
        try renderTomlBindingToWriter(scratch, &block.writer, binding);
        try blocks.append(scratch, try block.toOwnedSlice());
    }

    std.mem.sort([]const u8, blocks.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (blocks.items, 0..) |block, i| {
        if (i != 0) try writer.writeByte('\n');
        try writer.writeAll(block);
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

fn containsTomlSyntax(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "[[bindings]]") or isTopLevelVersionLine(trimmed)) return true;
    }
    return false;
}

fn isTopLevelVersionLine(line: []const u8) bool {
    const equals = std.mem.findScalar(u8, line, '=') orelse return false;
    const key = std.mem.trim(u8, line[0..equals], " \t");
    return std.mem.eql(u8, key, "version");
}

const PendingBinding = struct {
    doc_path: ?[]const u8 = null,
    target: ?[]const u8 = null,
    metadata: std.ArrayList(MetadataField) = .empty,

    fn deinit(self: *PendingBinding, allocator: std.mem.Allocator) void {
        if (self.doc_path) |doc_path| allocator.free(doc_path);
        if (self.target) |target| allocator.free(target);
        for (self.metadata.items) |field| {
            allocator.free(field.key);
            allocator.free(field.value);
        }
        self.metadata.deinit(allocator);
        self.* = .{};
    }

    fn finish(self: *PendingBinding) !Binding {
        const doc_path = self.doc_path orelse return error.InvalidBindingLine;
        const target = self.target orelse return error.InvalidBindingLine;
        const metadata = self.metadata;
        self.* = .{};
        return .{ .doc_path = doc_path, .target = target, .metadata = metadata };
    }
};

fn parseTomlInto(allocator: std.mem.Allocator, content: []const u8, bindings: *std.ArrayList(Binding)) !void {
    var pending: ?PendingBinding = null;
    errdefer if (pending) |*p| p.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.eql(u8, trimmed, "[[bindings]]")) {
            if (pending) |*p| try bindings.append(allocator, try p.finish());
            pending = .{};
            continue;
        }

        if (pending == null) {
            if (isTopLevelVersionLine(trimmed)) {
                try parseLockfileVersion(trimmed);
                continue;
            }
            return error.InvalidBindingLine;
        }
        try parseTomlFieldInto(allocator, trimmed, &pending.?);
    }

    if (pending) |*p| try bindings.append(allocator, try p.finish());
}

fn parseLockfileVersion(line: []const u8) !void {
    const equals = std.mem.findScalar(u8, line, '=') orelse return error.InvalidBindingLine;
    const raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t");
    const value = if (raw_value.len >= 2 and raw_value[0] == '"' and raw_value[raw_value.len - 1] == '"')
        raw_value[1 .. raw_value.len - 1]
    else
        raw_value;
    const version = std.fmt.parseUnsigned(u32, value, 10) catch return error.InvalidBindingLine;
    if (version != 1) return error.UnsupportedLockfileVersion;
}

fn parseTomlFieldInto(allocator: std.mem.Allocator, line: []const u8, pending: *PendingBinding) !void {
    const equals = std.mem.findScalar(u8, line, '=') orelse return error.InvalidMetadataField;
    const key = std.mem.trim(u8, line[0..equals], " \t");
    const raw_value = std.mem.trim(u8, line[equals + 1 ..], " \t");
    if (key.len == 0) return error.InvalidMetadataField;

    const value = try parseTomlString(allocator, raw_value);
    errdefer allocator.free(value);

    if (std.mem.eql(u8, key, "doc")) {
        if (pending.doc_path) |old| allocator.free(old);
        pending.doc_path = value;
    } else if (std.mem.eql(u8, key, "target")) {
        if (pending.target) |old| allocator.free(old);
        pending.target = value;
    } else {
        try pending.metadata.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = value,
        });
    }
}

fn parseTomlString(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidMetadataField;
    const value = raw[1 .. raw.len - 1];
    if (hasInvalidTomlBasicStringByte(value)) return error.InvalidMetadataField;
    return try allocator.dupe(u8, value);
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

test "parseInto reads V1 TOML tables, comments, and unordered metadata" {
    const allocator = std.testing.allocator;
    const content =
        "version = 1\n" ++
        "# 00\n" ++
        "[[bindings]]\n" ++
        "target = \"src/auth/provider.ts#AuthConfig\"\n" ++
        "origin = \"github:fiberplane/drift\"\n" ++
        "doc = \"docs/auth.md\"\n" ++
        "sig = \"1a2b3c4d5e6f7890\"\n" ++
        "\n" ++
        "# arbitrary V17 bucket/header-compatible comment\n" ++
        "[[bindings]]\n" ++
        "doc = \"docs/auth.md\"\n" ++
        "target = \"src/auth/login.ts\"\n" ++
        "sig = \"a1b2c3d4e5f6a7b8\"\n";

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
    try std.testing.expectEqualStrings("src/auth/provider.ts#AuthConfig", bindings.items[0].target);
    try std.testing.expectEqualStrings("github:fiberplane/drift", bindings.items[0].fieldValue("origin").?);
    try std.testing.expectEqualStrings("a1b2c3d4e5f6a7b8", bindings.items[1].fieldValue("sig").?);
}

test "parseInto accepts empty V1 TOML lockfile" {
    const allocator = std.testing.allocator;
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(allocator);

    try parseInto(allocator, "version = 1\n# comment only\n", &bindings);
    try std.testing.expectEqual(@as(usize, 0), bindings.items.len);
}

test "serialize sorts tables and appends trailing newline" {
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
        "version = 1\n" ++
            "\n" ++
            "[[bindings]]\n" ++
            "doc = \"docs/a.md\"\n" ++
            "target = \"src/a.ts\"\n" ++
            "\n" ++
            "[[bindings]]\n" ++
            "doc = \"docs/z.md\"\n" ++
            "target = \"src/z.ts\"\n",
        content,
    );
}

test "serialize emits metadata sorted by key regardless of insertion order" {
    const allocator = std.testing.allocator;

    const mkBinding = struct {
        fn f(alloc: std.mem.Allocator, field_pairs: []const [2][]const u8) !Binding {
            var metadata: std.ArrayList(MetadataField) = .empty;
            errdefer {
                for (metadata.items) |field| {
                    alloc.free(field.key);
                    alloc.free(field.value);
                }
                metadata.deinit(alloc);
            }
            for (field_pairs) |pair| {
                try metadata.append(alloc, .{
                    .key = try alloc.dupe(u8, pair[0]),
                    .value = try alloc.dupe(u8, pair[1]),
                });
            }
            return .{
                .doc_path = try alloc.dupe(u8, "docs/x.md"),
                .target = try alloc.dupe(u8, "src/x.ts"),
                .metadata = metadata,
            };
        }
    }.f;

    const freeBinding = struct {
        fn f(alloc: std.mem.Allocator, b: *Binding) void {
            alloc.free(b.doc_path);
            alloc.free(b.target);
            for (b.metadata.items) |field| {
                alloc.free(field.key);
                alloc.free(field.value);
            }
            b.metadata.deinit(alloc);
        }
    }.f;

    var forward = [_]Binding{try mkBinding(allocator, &.{
        .{ "sig", "abc" },
        .{ "origin", "x" },
        .{ "lang", "ts" },
    })};
    defer freeBinding(allocator, &forward[0]);

    var reverse = [_]Binding{try mkBinding(allocator, &.{
        .{ "lang", "ts" },
        .{ "origin", "x" },
        .{ "sig", "abc" },
    })};
    defer freeBinding(allocator, &reverse[0]);

    const out_forward = try serialize(allocator, &forward);
    defer allocator.free(out_forward);
    const out_reverse = try serialize(allocator, &reverse);
    defer allocator.free(out_reverse);

    try std.testing.expectEqualStrings(out_forward, out_reverse);
    try std.testing.expectEqualStrings(
        "version = 1\n" ++
            "\n" ++
            "[[bindings]]\n" ++
            "doc = \"docs/x.md\"\n" ++
            "target = \"src/x.ts\"\n" ++
            "lang = \"ts\"\n" ++
            "origin = \"x\"\n" ++
            "sig = \"abc\"\n",
        out_forward,
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
