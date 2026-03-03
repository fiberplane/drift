const std = @import("std");
const helpers = @import("helpers");

test "link adds new file anchor to spec" {
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

test "link adds anchor with provenance" {
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

test "link updates provenance on existing anchor" {
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

test "link updates inline references with provenance" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    const body =
        \\# Spec
        \\
        \\This references @./src/helper.ts in the content.
        \\
    ;
    try repo.writeSpec("docs/spec.md", &.{}, body);
    try repo.writeFile("src/helper.ts", "export function help() {}\n");
    try repo.commit("add spec and source");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/helper.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    // Read spec and verify inline ref got provenance
    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    // Should contain @./src/helper.ts@ followed by some change id
    try helpers.expectContains(content, "@./src/helper.ts@");
}

test "link blanket mode updates all anchors" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    const body =
        \\# Spec
        \\
        \\References @./src/a.ts and @./src/b.ts inline.
        \\
    ;
    try repo.writeSpec("docs/spec.md", &.{"src/a.ts"}, body);
    try repo.writeFile("src/a.ts", "export const a = 1;\n");
    try repo.writeFile("src/b.ts", "export const b = 2;\n");
    try repo.commit("add spec and sources");

    const result = try repo.runDrift(&.{ "link", "docs/spec.md" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    // Verify all anchors got provenance
    const content = try repo.readFile("docs/spec.md");
    defer allocator.free(content);
    try helpers.expectContains(content, "@./src/a.ts@");
    try helpers.expectContains(content, "@./src/b.ts@");
    // Frontmatter anchor should also have provenance
    try helpers.expectContains(content, "src/a.ts@");
}

test "link adds symbol anchor" {
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
