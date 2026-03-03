const std = @import("std");
const helpers = @import("helpers");

test "unlink removes file anchor" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{ "src/a.ts", "src/b.ts" }, "# Spec\n");
    try repo.commit("add spec with two anchors");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/a.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/a.ts");
    try helpers.expectContains(content, "src/b.ts");
}

test "unlink removes anchor regardless of provenance" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/file.ts@abc123"}, "# Spec\n");
    try repo.commit("add spec with provenance anchor");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/file.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/file.ts");
}

test "unlink on non-existent anchor is a no-op" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/a.ts"}, "# Spec\n");
    try repo.commit("add spec with one anchor");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/missing.ts" });
    defer result.deinit(allocator);

    // Should handle gracefully — exit 0 or informative message
    try helpers.expectExitCode(result.term, 0);

    // Original anchor should be untouched
    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/a.ts");
}

test "unlink removes symbol anchor" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/lib.ts#Foo"}, "# Spec\n");
    try repo.commit("add spec with symbol anchor");

    const result = try repo.runDrift(&.{ "unlink", "docs/spec.md", "src/lib.ts#Foo" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectNotContains(content, "src/lib.ts#Foo");
}
