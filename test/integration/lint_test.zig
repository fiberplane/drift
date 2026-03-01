const std = @import("std");
const helpers = @import("helpers");

test "lint reports ok for spec with no bindings" {
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

test "lint reports ok when bound file has not changed since spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add source file");

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec binding to main.ts");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports stale when bound file changed after spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    // Modify the bound file without touching the spec
    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source file");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/main.ts");
}

test "lint reports stale when bound file does not exist" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/missing.ts"}, "# Spec\n");
    try repo.commit("add spec with missing binding");

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
    try repo.commit("add spec binding to main.ts");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
}

test "lint detects inline bindings from content" {
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
    try repo.commit("add spec with inline binding and source");

    // Modify the inline-bound file
    try repo.writeFile("src/helper.ts", "export function help() { return true; }\n");
    try repo.commit("modify helper");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/helper.ts");
}

test "lint reports stale for missing symbol binding" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/lib.ts", "export function doStuff() { return 1; }\n");
    try repo.writeSpec("docs/spec.md", &.{"src/lib.ts#MissingSymbol"}, "# Spec\n");
    try repo.commit("add spec with missing symbol binding");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/lib.ts#MissingSymbol");
    try helpers.expectContains(output, "symbol not found");
}
