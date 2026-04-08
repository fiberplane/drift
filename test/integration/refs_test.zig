const std = @import("std");
const helpers = @import("helpers");

test "refs prints docs that reference a file target" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile(
        "drift.lock",
        "docs/auth.md -> src/auth/login.ts sig:aaaa\ndocs/onboarding.md -> src/auth/login.ts sig:bbbb\n",
    );
    try repo.commit("add lockfile");

    const result = try repo.runDrift(&.{ "refs", "src/auth/login.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectContains(result.stdout, "docs/onboarding.md");
}

test "refs prints docs that reference a symbol target" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "docs/auth.md -> src/auth/provider.ts#AuthConfig sig:aaaa\n");
    try repo.commit("add lockfile");

    const result = try repo.runDrift(&.{ "refs", "src/auth/provider.ts#AuthConfig" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "docs/auth.md");
}

test "refs exits 0 and prints nothing when there are no matches" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "docs/auth.md -> src/auth/login.ts sig:aaaa\n");
    try repo.commit("add lockfile");

    const result = try repo.runDrift(&.{ "refs", "src/other.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try std.testing.expectEqual(@as(usize, 0), result.stdout.len);
}
