const std = @import("std");
const helpers = @import("helpers");

test "unlink removes file binding from drift.lock" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/a.ts sig:aaaa\ndocs/doc.md -> src/b.ts sig:bbbb\n");
    try repo.commit("add lockfile bindings");

    const result = try repo.runDrift(&.{ "unlink", "docs/doc.md", "src/a.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "removed docs/doc.md -> src/a.ts from drift.lock");

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/a.ts");
    try helpers.expectContains(content, "src/b.ts");
}

test "unlink removes binding regardless of provenance in input" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/file.ts sig:aaaa\n");
    try repo.commit("add lockfile binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/doc.md", "src/file.ts@sig:old" });
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

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/a.ts sig:aaaa\n");
    try repo.commit("add lockfile binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/doc.md", "src/missing.ts" });
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

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/lib.ts#Foo sig:aaaa\n");
    try repo.commit("add symbol binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/doc.md", "src/lib.ts#Foo" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("drift.lock");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/lib.ts#Foo");
}

test "unlink leaves doc markdown untouched" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n\nBody.\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/a.ts sig:aaaa\n");
    try repo.commit("add doc and binding");

    const result = try repo.runDrift(&.{ "unlink", "docs/doc.md", "src/a.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const spec_content = try repo.readFile("docs/doc.md");
    defer allocator.free(spec_content);
    try std.testing.expectEqualStrings("# Doc\n\nBody.\n", spec_content);
}
