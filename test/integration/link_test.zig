const std = @import("std");
const helpers = @import("helpers");

test "link exits non-zero when required arguments are missing" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    const result = try repo.runDrift(&.{"link"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "usage: drift link <doc-path> [anchor]");
}

test "link adds new file binding to drift.lock" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/new.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md", "src/new.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "added docs/doc.md -> src/new.ts sig:");

    const lock_content = try repo.readFile("drift.lock");
    defer allocator.free(lock_content);
    try helpers.expectContains(lock_content, "docs/doc.md -> src/new.ts sig:");

    const doc_content = try repo.readFile("docs/doc.md");
    defer allocator.free(doc_content);
    try std.testing.expectEqualStrings("# Doc\n", doc_content);
}

test "link adds symbol binding to drift.lock" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/lib.ts", "export function myFunction() { return 1; }\n");
    try repo.commit("add doc and source");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md", "src/lib.ts#myFunction" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);

    const lock_content = try repo.readFile("drift.lock");
    defer allocator.free(lock_content);
    try helpers.expectContains(lock_content, "docs/doc.md -> src/lib.ts#myFunction sig:");
}

test "link stores markdown heading bindings using slug fragments" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n");
    try repo.writeFile("docs/auth.md", "# Auth\n\n## Token Validation\n\nUse tokens.\n");
    try repo.commit("add docs");

    const result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Token Validation" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "added docs/overview.md -> docs/auth.md#token-validation sig:");

    const lock_content = try repo.readFile("drift.lock");
    defer allocator.free(lock_content);
    try helpers.expectContains(lock_content, "docs/overview.md -> docs/auth.md#token-validation sig:");
}


test "link rejects missing markdown heading target" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n");
    try repo.writeFile("docs/auth.md", "# Auth\n\n## Authentication\n\nUse tokens.\n");
    try repo.commit("add docs");

    const result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Missing Heading" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "heading not found in target doc");
}

test "link round-trips slugged markdown heading bindings through lint" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n");
    try repo.writeFile("docs/auth.md", "# Auth\n\n## Token Validation\n\nUse tokens.\n");
    try repo.commit("add docs");

    const link_result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Token Validation" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);

    const lint_result = try repo.runDrift(&.{"lint"});
    defer lint_result.deinit(allocator);
    try helpers.expectExitCode(lint_result.term, 0);
    try helpers.expectContains(lint_result.stdout, "docs/overview.md");
    try helpers.expectContains(lint_result.stdout, "ok");
}

test "link blanket mode refreshes sigs for existing bindings" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/main.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    const first_link = try repo.runDrift(&.{ "link", "docs/doc.md", "src/main.ts" });
    defer first_link.deinit(allocator);
    try helpers.expectExitCode(first_link.term, 0);
    try repo.commit("create lockfile binding");

    const before = try repo.readFile("drift.lock");
    defer allocator.free(before);

    try repo.writeFile("src/main.ts", "export const value = 2;\n");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "relinked all anchors in docs/doc.md");

    const after = try repo.readFile("drift.lock");
    defer allocator.free(after);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try helpers.expectContains(after, "docs/doc.md -> src/main.ts sig:");
}

test "link no longer migrates legacy frontmatter anchors" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeDoc("docs/doc.md", &.{"src/main.ts"}, "# Doc\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add legacy doc and source");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "no bindings found for docs/doc.md");
}
