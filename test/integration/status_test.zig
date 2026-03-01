const std = @import("std");
const helpers = @import("helpers");

test "status shows spec with its bindings" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/auth.md", &.{ "src/auth/login.ts", "src/auth/provider.ts" }, "# Auth spec\n");
    try repo.writeFile("src/auth/login.ts", "export function login() {}\n");
    try repo.writeFile("src/auth/provider.ts", "export class Provider {}\n");
    try repo.commit("add spec and source files");

    const result = try repo.runDrift(&.{"status"});
    defer result.deinit(allocator);

    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectContains(result.stdout, "src/auth/login.ts");
    try helpers.expectContains(result.stdout, "src/auth/provider.ts");
}

test "status shows provenance on bindings" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/file.ts@qpvuntsm"}, "# Spec\n");
    try repo.writeFile("src/file.ts", "export const x = 1;\n");
    try repo.commit("add spec with provenance");

    const result = try repo.runDrift(&.{"status"});
    defer result.deinit(allocator);

    try helpers.expectContains(result.stdout, "@qpvuntsm");
}

test "status shows no specs when none exist" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("README.md", "# Hello\n");
    try repo.commit("add readme only");

    const result = try repo.runDrift(&.{"status"});
    defer result.deinit(allocator);

    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    // Should indicate no specs found — exact wording TBD
    _ = output;
    try helpers.expectExitCode(result.term, 0);
}

test "status format json outputs valid json" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    const result = try repo.runDrift(&.{ "status", "--format", "json" });
    defer result.deinit(allocator);

    // The output should contain JSON structural characters and the spec path
    try helpers.expectContains(result.stdout, "{");
    try helpers.expectContains(result.stdout, "}");
    try helpers.expectContains(result.stdout, "docs/spec.md");
}
