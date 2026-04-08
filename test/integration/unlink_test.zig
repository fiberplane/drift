const std = @import("std");
const helpers = @import("helpers");

test "unlink removes file binding from drift.lock" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/a.ts sig:aaaa\ndocs/spec.md -> src/b.ts sig:bbbb\n");
    try repo.commit("add lockfile bindings");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/a.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "removed docs/spec.md -> src/a.ts from drift.lock");

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/a.ts");
    try helpers.expectContains(content, "src/b.ts");
}

test "unlink removes binding regardless of provenance in input" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/file.ts sig:aaaa\n");
    try repo.commit("add lockfile binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/file.ts@sig:old" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/file.ts");
}

test "unlink on non-existent binding is a no-op" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/a.ts sig:aaaa\n");
    try repo.commit("add lockfile binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/missing.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/a.ts");
}

test "unlink removes symbol binding" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/lib.ts#Foo sig:aaaa\n");
    try repo.commit("add symbol binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/lib.ts#Foo" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/lib.ts#Foo");
}

test "unlink leaves spec markdown untouched" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n\nBody.\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/a.ts sig:aaaa\n");
    try repo.commit("add spec and binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/a.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const spec_content = try repo.readFile("docs/spec.md");
    defer allocator.free(spec_content);
    try std.testing.expectEqualStrings("# Spec\n\nBody.\n", spec_content);
}
