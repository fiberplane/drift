const std = @import("std");
const helpers = @import("helpers");

test "link adds new file binding to spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/new.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/new.ts");
}

test "link adds binding with provenance" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/new.ts@abc123" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/new.ts@abc123");
}

test "link updates provenance on existing binding" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/file.ts@old"}, "# Spec\n");
    try repo.commit("add spec with old provenance");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/file.ts@new" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/file.ts@new");
    try helpers.expectNotContains(content, "src/file.ts@old");
}

test "link adds frontmatter to plain markdown" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/plain.md", "# Just a plain markdown file\n\nSome content.\n");
    try repo.commit("add plain markdown");

    const result = try repo.runDrift(&.{ "link", "docs/plain.md", "src/target.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/plain.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "---");
    try helpers.expectContains(content, "drift:");
    try helpers.expectContains(content, "src/target.ts");
}

test "link auto-appends provenance from git" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/new.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    // Should contain the file path with an @ provenance suffix
    try helpers.expectContains(content, "src/new.ts@");
}

test "link adds symbol binding" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/lib.ts#MyFunction" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "src/lib.ts#MyFunction");
}
