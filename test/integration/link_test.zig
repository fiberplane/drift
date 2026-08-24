const std = @import("std");
const helpers = @import("helpers");

test "link exits non-zero when required arguments are missing" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    const result = try repo.runDrift(&.{"link"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "usage: drift link <doc-path>");
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
    try helpers.expectContains(lock_content, "doc = \"docs/doc.md\"\n");
    try helpers.expectContains(lock_content, "target = \"src/new.ts\"\n");
    try helpers.expectContains(lock_content, "sig = ");
    try helpers.expectNotContains(lock_content, "doc:");

    const doc_content = try repo.readFile("docs/doc.md");
    defer allocator.free(doc_content);
    try std.testing.expectEqualStrings("# Doc\n", doc_content);
}

test "link stores repo-relative paths with POSIX separators" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/new.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    // A Windows shell hands drift backslash-separated arguments, but the
    // lockfile is shared across platforms and is matched against `git ls-files`
    // output, which is POSIX everywhere. Degenerates to the plain form on POSIX
    // hosts, where a backslash is an ordinary filename byte.
    const sep = std.Io.Dir.path.sep_str;
    const result = try repo.runDrift(&.{ "link", "docs" ++ sep ++ "doc.md", "src" ++ sep ++ "new.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "added docs/doc.md -> src/new.ts sig:");

    const lock_content = try repo.readFile("drift.lock");
    defer allocator.free(lock_content);
    try helpers.expectContains(lock_content, "doc = \"docs/doc.md\"\n");
    try helpers.expectContains(lock_content, "target = \"src/new.ts\"\n");
    try helpers.expectNotContains(lock_content, "\\\\");
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
    try helpers.expectContains(lock_content, "doc = \"docs/doc.md\"\n");
    try helpers.expectContains(lock_content, "target = \"src/lib.ts#myFunction\"\n");
    try helpers.expectContains(lock_content, "sig = ");
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
    try helpers.expectContains(lock_content, "doc = \"docs/overview.md\"\n");
    try helpers.expectContains(lock_content, "target = \"docs/auth.md#token-validation\"\n");
    try helpers.expectContains(lock_content, "sig = ");
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

test "link blanket mode refuses relink when doc unchanged" {
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

    try repo.writeFile("src/main.ts", "export const value = 2;\n");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "refused:");
    try helpers.expectContains(result.stderr, "--doc-is-still-accurate");
}

test "link blanket mode refuses relink even when doc changed" {
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

    try repo.writeFile("src/main.ts", "export const value = 2;\n");
    try repo.writeFile("docs/doc.md", "# Doc\nUpdated content.\n");

    const result = try repo.runDrift(&.{ "link", "docs/doc.md" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stderr, "refused:");
    try helpers.expectContains(result.stderr, "--doc-is-still-accurate");
}

test "link blanket mode relinks with --doc-is-still-accurate override" {
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

    const result = try repo.runDrift(&.{ "link", "docs/doc.md", "--doc-is-still-accurate" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "relinked all anchors in docs/doc.md");

    const after = try repo.readFile("drift.lock");
    defer allocator.free(after);
    try std.testing.expect(!std.mem.eql(u8, before, after));
    try helpers.expectContains(after, "doc = \"docs/doc.md\"\n");
    try helpers.expectContains(after, "target = \"src/main.ts\"\n");
    try helpers.expectContains(after, "sig = ");
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

test "link uses nested drift.lock when doc is in nested scope" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "");
    try repo.writeFile("nested/drift.lock", "");
    try repo.writeFile("nested/doc.md", "# Nested\n");
    try repo.writeFile("nested/code.ts", "export const value = 1;\n");
    try repo.commit("add root and nested scope");

    // Run link from root, but doc is in nested/ — should write to nested/drift.lock
    const result = try repo.runDrift(&.{ "link", "nested/doc.md", "nested/code.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "added doc.md -> code.ts sig:");

    // Verify binding is in nested/drift.lock, NOT root drift.lock
    const nested_lock = try repo.readFile("nested/drift.lock");
    defer allocator.free(nested_lock);
    try helpers.expectContains(nested_lock, "doc = \"doc.md\"\n");
    try helpers.expectContains(nested_lock, "target = \"code.ts\"\n");
    try helpers.expectContains(nested_lock, "sig = ");

    const root_lock = try repo.readFile("drift.lock");
    defer allocator.free(root_lock);
    try std.testing.expectEqualStrings("", root_lock);
}

test "unlink uses nested drift.lock when doc is in nested scope" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "");
    try repo.writeFile("nested/drift.lock", "nested/doc.md -> nested/code.ts sig:deadbeefdeadbeef\n");

    // Wait, unlink normalizes paths relative to lockfile root.
    // Since nested/drift.lock root is nested/, the binding path is doc.md -> code.ts
    try repo.writeFile("nested/drift.lock", "doc.md -> code.ts sig:deadbeefdeadbeef\n");
    try repo.writeFile("nested/doc.md", "# Nested\n");
    try repo.writeFile("nested/code.ts", "export const value = 1;\n");
    try repo.commit("add root and nested scope with binding");

    // Run unlink from root, but doc is in nested/ — should use nested/drift.lock
    const result = try repo.runDrift(&.{ "unlink", "nested/doc.md", "nested/code.ts" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "removed doc.md -> code.ts from drift.lock");

    const nested_lock = try repo.readFile("nested/drift.lock");
    defer allocator.free(nested_lock);
    try helpers.expectNotContains(nested_lock, "code.ts");
}
