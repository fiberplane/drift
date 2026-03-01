const std = @import("std");

/// Extract the file identity from a binding string: strip `@change` suffix but keep `#Symbol`.
/// E.g. "src/file.ts@abc" -> "src/file.ts", "src/lib.ts#Foo@abc" -> "src/lib.ts#Foo"
pub fn bindingFileIdentity(binding: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, binding, '@')) |at_pos| {
        return binding[0..at_pos];
    }
    return binding;
}

/// Parse drift frontmatter from file content. Returns bindings list if this is a drift spec, null otherwise.
pub fn parseDriftSpec(allocator: std.mem.Allocator, content: []const u8) ?std.ArrayList([]const u8) {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse
        std.mem.indexOf(u8, after_open, "\n---") orelse return null;
    const frontmatter = after_open[0..close_offset];

    // Check for "drift:" line
    var has_drift = false;
    var in_files_section = false;
    var bindings: std.ArrayList([]const u8) = .{};

    var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.eql(u8, line, "drift:") or std.mem.startsWith(u8, line, "drift:")) {
            has_drift = true;
            continue;
        }

        if (has_drift and std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const binding_text = line["    - ".len..];
            const duped = allocator.dupe(u8, binding_text) catch continue;
            bindings.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
            continue;
        }

        // Non-list-item line ends the files section
        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }
    }

    if (!has_drift) {
        for (bindings.items) |b| allocator.free(b);
        bindings.deinit(allocator);
        return null;
    }

    return bindings;
}

/// Core logic: given file content and a binding, produce new file content with the binding added/updated.
pub fn linkBinding(allocator: std.mem.Allocator, content: []const u8, binding: []const u8) ![]const u8 {
    const new_identity = bindingFileIdentity(binding);

    // Check if file has YAML frontmatter (starts with "---\n")
    if (std.mem.startsWith(u8, content, "---\n")) {
        // Find the closing "---\n"
        const after_open = content[4..];
        if (std.mem.indexOf(u8, after_open, "\n---\n")) |close_offset| {
            // close_offset is index in after_open where "\n---\n" starts
            const frontmatter = after_open[0..close_offset]; // text between the two ---
            const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

            // Process the frontmatter lines
            var output: std.ArrayList(u8) = .{};
            defer output.deinit(allocator);
            const writer = output.writer(allocator);

            try writer.writeAll("---\n");

            var found_existing = false;
            var in_files_section = false;
            var wrote_binding = false;
            var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

            while (lines_iter.next()) |line| {
                if (std.mem.startsWith(u8, line, "  files:")) {
                    in_files_section = true;
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
                    const existing_binding = line["    - ".len..];
                    const existing_identity = bindingFileIdentity(existing_binding);

                    if (std.mem.eql(u8, existing_identity, new_identity)) {
                        // Replace this line with the new binding
                        try writer.print("    - {s}\n", .{binding});
                        found_existing = true;
                        wrote_binding = true;
                        continue;
                    }
                    // Keep the existing line
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    continue;
                }

                // If we were in files section and hit a non-list line, we left it
                if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
                    // Before leaving files section, append new binding if not found
                    if (!found_existing and !wrote_binding) {
                        try writer.print("    - {s}\n", .{binding});
                        wrote_binding = true;
                    }
                    in_files_section = false;
                }

                try writer.writeAll(line);
                try writer.writeByte('\n');
            }

            // If we were still in files section at end of frontmatter, append
            if (!wrote_binding) {
                try writer.print("    - {s}\n", .{binding});
            }

            try writer.writeAll("---\n");

            // Append the body
            if (body_start <= content.len) {
                try writer.writeAll(content[body_start..]);
            }

            return try allocator.dupe(u8, output.items);
        }
    }

    // No frontmatter found: prepend a complete frontmatter block
    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");
    try writer.writeAll("drift:\n");
    try writer.writeAll("  files:\n");
    try writer.print("    - {s}\n", .{binding});
    try writer.writeAll("---\n");
    try writer.writeAll(content);

    return try allocator.dupe(u8, output.items);
}

pub const UnlinkResult = struct {
    content: []const u8,
    removed: bool,
};

/// Core logic: given file content and a binding, produce new file content with the binding removed.
/// Matches on file identity (stripping @provenance from both the existing binding and the argument).
pub fn unlinkBinding(allocator: std.mem.Allocator, content: []const u8, binding: []const u8) !UnlinkResult {
    const target_identity = bindingFileIdentity(binding);

    // Must have YAML frontmatter to contain bindings
    if (!std.mem.startsWith(u8, content, "---\n")) {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    }

    const after_open = content[4..];
    const close_offset = std.mem.indexOf(u8, after_open, "\n---\n") orelse {
        return .{ .content = try allocator.dupe(u8, content), .removed = false };
    };

    const frontmatter = after_open[0..close_offset];
    const body_start = 4 + close_offset + 5; // skip opening "---\n" + frontmatter + "\n---\n"

    var output: std.ArrayList(u8) = .{};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    try writer.writeAll("---\n");

    var removed = false;
    var in_files_section = false;
    var lines_iter = std.mem.splitScalar(u8, frontmatter, '\n');

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "  files:")) {
            in_files_section = true;
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (in_files_section and std.mem.startsWith(u8, line, "    - ")) {
            const existing_binding = line["    - ".len..];
            const existing_identity = bindingFileIdentity(existing_binding);

            if (std.mem.eql(u8, existing_identity, target_identity)) {
                // Skip this line (remove the binding)
                removed = true;
                continue;
            }
        }

        // Non-list-item line ends the files section
        if (in_files_section and !std.mem.startsWith(u8, line, "    - ")) {
            in_files_section = false;
        }

        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    try writer.writeAll("---\n");

    // Append the body
    if (body_start <= content.len) {
        try writer.writeAll(content[body_start..]);
    }

    return .{ .content = try allocator.dupe(u8, output.items), .removed = removed };
}

// --- unit tests for unlinkBinding ---

test "unlinkBinding removes matching binding" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n    - src/b.ts\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/a.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/b.ts") != null);
}

test "unlinkBinding matches by file identity ignoring provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@abc123\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/file.ts");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/file.ts") == null);
}

test "unlinkBinding returns removed=false when binding not found" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/a.ts\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/missing.ts");
    defer allocator.free(result.content);
    try std.testing.expect(!result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/a.ts") != null);
}

test "unlinkBinding removes symbol binding" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/lib.ts#Foo\n---\n# Spec\n";
    const result = try unlinkBinding(allocator, content, "src/lib.ts#Foo");
    defer allocator.free(result.content);
    try std.testing.expect(result.removed);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "src/lib.ts#Foo") == null);
}

// --- unit tests for linkBinding ---

test "linkBinding adds binding to empty files list" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n---\n# Spec\n";
    const result = try linkBinding(allocator, content, "src/new.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/new.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Spec") != null);
}

test "linkBinding updates existing binding provenance" {
    const allocator = std.testing.allocator;
    const content = "---\ndrift:\n  files:\n    - src/file.ts@old\n---\n# Spec\n";
    const result = try linkBinding(allocator, content, "src/file.ts@new");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@new") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/file.ts@old") == null);
}

test "linkBinding adds frontmatter to plain markdown" {
    const allocator = std.testing.allocator;
    const content = "# Just a plain markdown file\n\nSome content.\n";
    const result = try linkBinding(allocator, content, "src/target.ts");
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, "---\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "drift:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src/target.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "# Just a plain markdown file") != null);
}
