const std = @import("std");
const helpers = @import("helpers");

fn expectFormattingOnlyFileChangeIsFresh(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    initial_source: []const u8,
    reformatted_source: []const u8,
) !void {
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile(file_path, initial_source);
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add initial source and spec");

    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", file_path });
    defer link_result.deinit(allocator);

    try helpers.expectExitCode(link_result.term, 0);

    const linked_spec = try repo.readFile("docs/spec.md");
    defer allocator.free(linked_spec);

    const linked_anchor = try std.fmt.allocPrint(allocator, "{s}@", .{file_path});
    defer allocator.free(linked_anchor);
    try helpers.expectContains(linked_spec, linked_anchor);

    try repo.commit("link spec to source file");

    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    const output = if (check_result.stdout.len > 0) check_result.stdout else check_result.stderr;
    try helpers.expectContains(output, "docs/spec.md");
    try helpers.expectContains(output, "ok");
    try helpers.expectNotContains(output, "STALE");
}

fn expectFormattingOnlySymbolChangeIsFresh(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    symbol_anchor: []const u8,
    initial_source: []const u8,
    reformatted_source: []const u8,
) !void {
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile(file_path, initial_source);
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add initial source and spec");

    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", symbol_anchor });
    defer link_result.deinit(allocator);

    try helpers.expectExitCode(link_result.term, 0);

    const linked_spec = try repo.readFile("docs/spec.md");
    defer allocator.free(linked_spec);

    const linked_anchor = try std.fmt.allocPrint(allocator, "{s}@", .{symbol_anchor});
    defer allocator.free(linked_anchor);
    try helpers.expectContains(linked_spec, linked_anchor);

    try repo.commit("link spec to source symbol");

    // Reformat the bound symbol without changing its syntax or behavior.
    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    const output = if (check_result.stdout.len > 0) check_result.stdout else check_result.stderr;
    try helpers.expectContains(output, "docs/spec.md");
    try helpers.expectContains(output, "ok");
    try helpers.expectNotContains(output, "STALE");
}

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

test "check ignores typescript formatting-only file change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\function add(a: number, b: number): number {
        \\  return a + b;
        \\}
        \\
    ;
    const reformatted_source =
        \\function add(
        \\  a: number,
        \\  b: number
        \\): number {
        \\  return a + b;
        \\}
        \\
    ;

    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/math.ts",
        initial_source,
        reformatted_source,
    );
}

test "check ignores python formatting-only file change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\def greet(name: str, excited: bool = False) -> str:
        \\    return "Hello, " + name + ("!" if excited else ".")
        \\
    ;
    const reformatted_source =
        \\def greet(
        \\    name: str,
        \\    excited: bool = False
        \\) -> str:
        \\    return "Hello, " + name + ("!" if excited else ".")
        \\
    ;

    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/greet.py",
        initial_source,
        reformatted_source,
    );
}

test "check ignores rust formatting-only file change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\pub fn greet(name: &str, excited: bool) -> String {
        \\    format!("Hello, {}{}", name, if excited { "!" } else { "." })
        \\}
        \\
    ;
    const reformatted_source =
        \\pub fn greet(
        \\    name: &str,
        \\    excited: bool
        \\) -> String {
        \\    format!("Hello, {}{}", name, if excited { "!" } else { "." })
        \\}
        \\
    ;

    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/greet.rs",
        initial_source,
        reformatted_source,
    );
}

test "check ignores typescript formatting-only symbol change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\function add(a: number, b: number): number {
        \\  return a + b;
        \\}
        \\
    ;
    const reformatted_source =
        \\function add(
        \\  a: number,
        \\  b: number
        \\): number {
        \\  return a + b;
        \\}
        \\
    ;

    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/math.ts",
        "src/math.ts#add",
        initial_source,
        reformatted_source,
    );
}

test "check ignores python formatting-only symbol change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\def greet(name: str, excited: bool = False) -> str:
        \\    return "Hello, " + name + ("!" if excited else ".")
        \\
    ;
    const reformatted_source =
        \\def greet(
        \\    name: str,
        \\    excited: bool = False
        \\) -> str:
        \\    return "Hello, " + name + ("!" if excited else ".")
        \\
    ;

    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/greet.py",
        "src/greet.py#greet",
        initial_source,
        reformatted_source,
    );
}

test "check ignores rust formatting-only symbol change" {
    const allocator = std.testing.allocator;

    const initial_source =
        \\pub fn greet(name: &str, excited: bool) -> String {
        \\    format!("Hello, {}{}", name, if excited { "!" } else { "." })
        \\}
        \\
    ;
    const reformatted_source =
        \\pub fn greet(
        \\    name: &str,
        \\    excited: bool
        \\) -> String {
        \\    format!("Hello, {}{}", name, if excited { "!" } else { "." })
        \\}
        \\
    ;

    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/greet.rs",
        "src/greet.rs#greet",
        initial_source,
        reformatted_source,
    );
}

test "check still reports stale after typescript symbol token change" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile(
        "src/math.ts",
        "function add(a: number, b: number): number {\n  return a + b;\n}\n",
    );
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add initial source and spec");

    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/math.ts#add" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);

    try repo.commit("link spec to source symbol");

    try repo.writeFile(
        "src/math.ts",
        "function add(a: number, b: number): number {\n  return a - b;\n}\n",
    );
    try repo.commit("change symbol behavior");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 1);
    const output = if (check_result.stdout.len > 0) check_result.stdout else check_result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "src/math.ts#add");
    try helpers.expectContains(output, "changed after spec");
}

test "lint includes blame info when anchored file changed after spec" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    // Modify the anchored file with a descriptive commit message
    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("refactor: update main return value");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    const output = if (result.stdout.len > 0) result.stdout else result.stderr;
    try helpers.expectContains(output, "STALE");
    try helpers.expectContains(output, "changed after spec");
    // Blame enrichment lines
    try helpers.expectContains(output, "changed by");
    try helpers.expectContains(output, "refactor: update main return value");
}

test "check --format json produces valid JSON with correct structure" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec and source");

    // Link to get a sig provenance
    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/main.ts" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);
    try repo.commit("link spec");

    // Check with JSON format — should be fresh
    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);

    const CheckPayload = struct {
        schema_version: []const u8,
        tool: []const u8,
        summary: struct {
            result: []const u8,
            specs_total: u32,
            specs_fresh: u32,
            specs_stale: u32,
            anchors_total: u32,
            anchors_fresh: u32,
            anchors_stale: u32,
        },
        specs: []const struct {
            path: []const u8,
            result: []const u8,
            anchors: []const struct {
                identity: []const u8,
                kind: []const u8,
                path: []const u8,
                result: []const u8,
            },
        },
    };

    var parsed = try std.json.parseFromSlice(CheckPayload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("drift.check.v1", parsed.value.schema_version);
    try std.testing.expectEqualStrings("drift", parsed.value.tool);
    try std.testing.expectEqualStrings("pass", parsed.value.summary.result);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_fresh);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.summary.specs_stale);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.specs.len);
    try std.testing.expectEqualStrings("docs/spec.md", parsed.value.specs[0].path);
    try std.testing.expectEqualStrings("fresh", parsed.value.specs[0].result);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.specs[0].anchors.len);
    try std.testing.expectEqualStrings("src/main.ts", parsed.value.specs[0].anchors[0].identity);
    try std.testing.expectEqualStrings("file", parsed.value.specs[0].anchors[0].kind);
    try std.testing.expectEqualStrings("fresh", parsed.value.specs[0].anchors[0].result);
}

test "check --format json reports stale anchors with reason" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec and source");

    // Link, commit, then modify the file
    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/main.ts" });
    defer link_result.deinit(allocator);
    try repo.commit("link spec");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);

    const CheckPayload = struct {
        summary: struct { result: []const u8, specs_stale: u32, anchors_stale: u32 },
        specs: []const struct {
            result: []const u8,
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8, message: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(CheckPayload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("fail", parsed.value.summary.result);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_stale);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_stale);
    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].result);
    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("changed_after_baseline", parsed.value.specs[0].anchors[0].reason.?.code);
}

test "check --format json reports missing file" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/missing.ts"}, "# Spec\n");
    try repo.commit("add spec with missing anchor");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);

    const CheckPayload = struct {
        specs: []const struct {
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(CheckPayload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("file_not_found", parsed.value.specs[0].anchors[0].reason.?.code);
}

test "check --format json includes tool_version, checked_at_ms, and provenance shape" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.commit("add spec and source");

    // `drift link` writes a `@sig:` provenance, so the JSON should report a
    // provenance object with kind="sig".
    const link_result = try repo.runDrift(&.{ "link", "docs/spec.md", "src/main.ts" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);
    try repo.commit("link spec");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);

    const Payload = struct {
        tool_version: []const u8,
        checked_at_ms: i64,
        summary: struct { fully_skipped: bool },
        specs: []const struct {
            anchors: []const struct {
                provenance: ?struct { kind: []const u8, value: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.tool_version.len > 0);
    try std.testing.expect(parsed.value.checked_at_ms > 0);
    try std.testing.expect(!parsed.value.summary.fully_skipped);
    try std.testing.expect(parsed.value.specs[0].anchors[0].provenance != null);
    try std.testing.expectEqualStrings("sig", parsed.value.specs[0].anchors[0].provenance.?.kind);
    try std.testing.expect(parsed.value.specs[0].anchors[0].provenance.?.value.len > 0);
}

test "check --format json populates blame on stale anchor" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{"src/main.ts"}, "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add spec and source");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("refactor: tweak main return value");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);

    const Payload = struct {
        specs: []const struct {
            anchors: []const struct {
                blame: ?struct {
                    author: []const u8,
                    commit: []const u8,
                    date: []const u8,
                    subject: []const u8,
                },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const blame = parsed.value.specs[0].anchors[0].blame orelse return error.MissingBlame;
    try std.testing.expect(blame.author.len > 0);
    try std.testing.expect(blame.commit.len > 0);
    try std.testing.expect(blame.date.len > 0);
    try helpers.expectContains(blame.subject, "refactor: tweak main return value");
}

test "check --format json reports skip with origin_mismatch and fully_skipped summary" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    // Hand-write a spec with a foreign origin so origin-mismatch fires.
    try repo.writeFile(
        "docs/spec.md",
        "---\ndrift:\n  origin: github:other/repo\n  files:\n    - src/main.ts\n---\n# Spec\n",
    );
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.commit("add foreign-origin spec");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0); // skip is not a failure

    const Payload = struct {
        summary: struct {
            result: []const u8,
            fully_skipped: bool,
            specs_skipped: u32,
            anchors_skipped: u32,
        },
        specs: []const struct {
            result: []const u8,
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("pass", parsed.value.summary.result);
    try std.testing.expect(parsed.value.summary.fully_skipped);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_skipped);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_skipped);
    try std.testing.expectEqualStrings("skip", parsed.value.specs[0].result);
    try std.testing.expectEqualStrings("skip", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("origin_mismatch", parsed.value.specs[0].anchors[0].reason.?.code);
}

test "check --format rejects unknown values" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Empty\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "check", "--format", "yaml" });
    defer result.deinit(allocator);

    // Should NOT exit 0 — unknown format must be a hard error, not silent text fallthrough.
    try std.testing.expect(result.exitCode() != 0);
    try helpers.expectContains(result.stderr, "unknown --format");
}

test "lint --format json works as alias" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeSpec("docs/spec.md", &.{}, "# Spec\n");
    try repo.commit("add empty spec");

    const result = try repo.runDrift(&.{ "lint", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "drift.check.v1");
}

test "lint succeeds in repos with many tracked files (>50KB ls-files output)" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    // Generate enough tracked files to push `git ls-files -z` output past the
    // old 50KB default limit.  ~1200 files x ~45 bytes/path > 50 KiB.
    var name_buf: [64]u8 = undefined;
    for (0..1200) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "src/gen/mod_{d:0>4}/component.ts", .{i});
        try repo.writeFile(name, "export {};\n");
    }

    try repo.writeFile("src/target.ts", "export function target() {}\n");
    try repo.writeSpec("docs/spec.md", &.{"src/target.ts"}, "# Spec\n");
    try repo.commit("add many files and spec");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}
