const std = @import("std");
const helpers = @import("helpers");

test "status shows doc with its bindings from drift.lock" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "docs/auth.md -> src/auth/login.ts sig:aaaa\ndocs/auth.md -> src/auth/provider.ts#Provider sig:bbbb\n");
    try repo.commit("add lockfile");

    const result = try repo.runDrift(&.{"status"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectContains(result.stdout, "src/auth/login.ts");
    try helpers.expectContains(result.stdout, "src/auth/provider.ts#Provider");
}

test "status shows no docs when lockfile is missing" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("README.md", "# Hello\n");
    try repo.commit("add readme only");

    const result = try repo.runDrift(&.{"status"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}

test "status format json outputs valid escaped json" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "docs/doc\"name.md -> src/main\"file.ts sig:aaaa\n");
    try repo.commit("add lockfile with quoted paths");

    const result = try repo.runDrift(&.{ "status", "--format", "json" });
    defer result.deinit(allocator);

    const StatusEntry = struct {
        doc: []const u8,
        files: []const []const u8,
    };

    var parsed = try std.json.parseFromSlice([]StatusEntry, allocator, result.stdout, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("docs/doc\"name.md", parsed.value[0].doc);
    try std.testing.expectEqual(@as(usize, 1), parsed.value[0].files.len);
    try std.testing.expectEqualStrings("src/main\"file.ts", parsed.value[0].files[0]);
}
