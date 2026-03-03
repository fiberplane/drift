const std = @import("std");
const helpers = @import("helpers");

test "lint reports ok for spec with no anchors" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Empty spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports ok when anchored file has not changed since spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source file");

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec anchored to main.ts");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports stale when anchored file changed after spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    // Modify the anchored file without touching the spec
    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source file");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/main.ts");
}

test "lint reports stale when anchored file does not exist" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/missing.ts"}, "# Spec\n");
    try repo.commit("add spec with missing anchor");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/missing.ts");
    try helpers.expectContains(output, "file not found");
}

test "lint exits 1 on stale by default" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source file");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
}

test "lint exits 0 when all ok" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source file");

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec anchored to main.ts");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
}

test "lint detects inline anchors from content" {
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
    try repo.commit("add spec with inline anchor and source");

    // Modify the inline-anchored file
    try repo.writeFile("src/helper.ts", "export function help() { return true; }\n");
    try repo.commit("modify helper");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/helper.ts");
}

test "lint ok when provenance content matches current file" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source");

    // Get the current commit hash for provenance
    const rev = try repo.getHeadRevision(allocator);
    defer allocator.free(rev);

    // Create spec with anchor pointing to that revision
    const anchor = try std.fmt.allocPrint(allocator, "src/main.ts@{s}", .{rev});
    defer allocator.free(anchor);
    try repo.writeSpec("docs/spec.md", &.{anchor}, "# Spec\n");
    try repo.commit("add spec");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint stale when provenance content differs" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source");

    const rev = try repo.getHeadRevision(allocator);
    defer allocator.free(rev);

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source");

    const anchor = try std.fmt.allocPrint(allocator, "src/main.ts@{s}", .{rev});
    defer allocator.free(anchor);
    try repo.writeSpec("docs/spec.md", &.{anchor}, "# Spec\n");
    try repo.commit("add spec");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "changed after spec");
}

test "lint detects stale comment-based anchors" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source");

    // Write spec with comment-based anchor (no frontmatter)
    try repo.writeFile("docs/spec.md", "# Spec\n\n<!-- drift:\n  files:\n    - src/main.ts\n-->\n\nSome docs.\n");
    try repo.commit("add spec with comment anchor");

    // Modify the anchored file
    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/main.ts");
}

test "lint reports stale for missing symbol anchor" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/lib.ts", "export function doStuff() { return 1; }\n");
    try repo.writeSpec("docs/spec.md", &.{"src/lib.ts#MissingSymbol"}, "# Spec\n");
    try repo.commit("add spec with missing symbol anchor");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/lib.ts#MissingSymbol");
    try helpers.expectContains(output, "symbol not found");
}
