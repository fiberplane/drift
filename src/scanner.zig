const std = @import("std");
const frontmatter = @import("frontmatter.zig");

pub const Spec = struct {
    path: []const u8,
    bindings: std.ArrayList([]const u8),

    pub fn deinit(self: *Spec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.bindings.items) |b| allocator.free(b);
        self.bindings.deinit(allocator);
    }
};

pub const skip_dirs = [_][]const u8{ ".git", ".jj", "node_modules", "vendor", ".zig-cache" };

pub fn shouldSkipDir(name: []const u8) bool {
    // Skip hidden directories (starting with '.')
    if (name.len > 0 and name[0] == '.') return true;
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

pub fn walkForSpecs(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, specs: *std.ArrayList(Spec)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDir(entry.name)) continue;

            const sub_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
            defer allocator.free(sub_prefix);

            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkForSpecs(allocator, sub_dir, sub_prefix, specs);
        } else if (entry.kind == .file) {
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

            const file_path = if (prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

            const content = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
                allocator.free(file_path);
                continue;
            };
            defer allocator.free(content);

            if (frontmatter.parseDriftSpec(allocator, content)) |bindings| {
                try specs.append(allocator, .{
                    .path = file_path,
                    .bindings = bindings,
                });
            } else {
                allocator.free(file_path);
            }
        }
    }
}

/// Parse inline bindings (@./path references) from markdown content body.
pub fn parseInlineBindings(allocator: std.mem.Allocator, content: []const u8) std.ArrayList([]const u8) {
    var bindings: std.ArrayList([]const u8) = .{};

    // Find body: skip frontmatter if present
    const body = blk: {
        if (std.mem.startsWith(u8, content, "---\n")) {
            const after_open = content[4..];
            if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
                break :blk after_open[close_offset + 5 ..];
            }
            if (std.mem.indexOf(u8, after_open, "\n---")) |close_offset| {
                const end = close_offset + 4; // skip "\n---"
                if (end <= after_open.len) {
                    break :blk after_open[end..];
                }
            }
        }
        break :blk content;
    };

    // Scan for @./ references
    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOf(u8, body[pos..], "@./")) |offset| {
            const path_start = pos + offset + 3; // skip "@./"

            // Find end of path: next whitespace or end of body
            var path_end = path_start;
            while (path_end < body.len and !isPathTerminator(body[path_end])) {
                path_end += 1;
            }

            // Strip trailing punctuation
            while (path_end > path_start and isTrailingPunctuation(body[path_end - 1])) {
                path_end -= 1;
            }

            if (path_end > path_start) {
                const path = body[path_start..path_end];
                const duped = allocator.dupe(u8, path) catch {
                    pos = path_end;
                    continue;
                };
                bindings.append(allocator, duped) catch {
                    allocator.free(duped);
                    pos = path_end;
                    continue;
                };
            }

            pos = path_end;
        } else {
            break;
        }
    }

    return bindings;
}

pub fn isPathTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn isTrailingPunctuation(c: u8) bool {
    return c == '.' or c == ',' or c == ';' or c == ':' or c == ')' or c == ']' or c == '}' or c == '!' or c == '?';
}
