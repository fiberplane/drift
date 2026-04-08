const std = @import("std");
const helpers = @import("helpers");

fn linkSpec(repo: *helpers.TempRepo, spec_path: []const u8, target: []const u8) !void {
    const allocator = std.testing.allocator;
    const result = try repo.runDrift(&.{ "link", spec_path, target });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
}

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

    try linkSpec(&repo, "docs/spec.md", file_path);
    try repo.commit("link spec to source file");

    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    try helpers.expectContains(check_result.stdout, "docs/spec.md");
    try helpers.expectContains(check_result.stdout, "ok");
    try helpers.expectNotContains(check_result.stdout, "STALE");
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

    try linkSpec(&repo, "docs/spec.md", symbol_anchor);
    try repo.commit("link spec to source symbol");

    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    try helpers.expectContains(check_result.stdout, "docs/spec.md");
    try helpers.expectContains(check_result.stdout, "ok");
    try helpers.expectNotContains(check_result.stdout, "STALE");
}

test "lint reports ok when no lockfile exists" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("README.md", "# Hello\n");
    try repo.commit("add readme");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports ok when linked file has not changed" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "docs/spec.md");
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports stale when linked file changed after link" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "STALE");
    try helpers.expectContains(result.stdout, "src/main.ts");
    try helpers.expectContains(result.stdout, "changed after spec");
}

test "lint reports stale when linked file does not exist" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add spec");

    try repo.writeFile("drift.lock", "docs/spec.md -> src/missing.ts sig:deadbeefdeadbeef\n");
    try repo.commit("add missing binding");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "STALE");
    try helpers.expectContains(result.stdout, "file not found");
}

test "lint reports stale for missing symbol anchor" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/lib.ts", "export function doStuff() { return 1; }\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/lib.ts#doStuff");
    try repo.commit("link spec");

    try repo.writeFile("src/lib.ts", "export const value = 1;\n");
    try repo.commit("remove symbol");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "STALE");
    try helpers.expectContains(result.stdout, "src/lib.ts#doStuff");
    try helpers.expectContains(result.stdout, "symbol not found");
}

test "check ignores typescript formatting-only file change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/math.ts",
        "function add(a: number, b: number): number {\n  return a + b;\n}\n",
        "function add(\n  a: number,\n  b: number\n): number {\n  return a + b;\n}\n",
    );
}

test "check ignores python formatting-only file change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/greet.py",
        "def greet(name: str, excited: bool = False) -> str:\n    return \"Hello, \" + name + (\"!\" if excited else \".\")\n",
        "def greet(\n    name: str,\n    excited: bool = False\n) -> str:\n    return \"Hello, \" + name + (\"!\" if excited else \".\")\n",
    );
}

test "check ignores rust formatting-only file change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlyFileChangeIsFresh(
        allocator,
        "src/greet.rs",
        "pub fn greet(name: &str, excited: bool) -> String {\n    format!(\"Hello, {}{}\", name, if excited { \"!\" } else { \".\" })\n}\n",
        "pub fn greet(\n    name: &str,\n    excited: bool\n) -> String {\n    format!(\"Hello, {}{}\", name, if excited { \"!\" } else { \".\" })\n}\n",
    );
}

test "check ignores typescript formatting-only symbol change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/math.ts",
        "src/math.ts#add",
        "function add(a: number, b: number): number {\n  return a + b;\n}\n",
        "function add(\n  a: number,\n  b: number\n): number {\n  return a + b;\n}\n",
    );
}

test "check ignores python formatting-only symbol change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/greet.py",
        "src/greet.py#greet",
        "def greet(name: str, excited: bool = False) -> str:\n    return \"Hello, \" + name + (\"!\" if excited else \".\")\n",
        "def greet(\n    name: str,\n    excited: bool = False\n) -> str:\n    return \"Hello, \" + name + (\"!\" if excited else \".\")\n",
    );
}

test "check ignores rust formatting-only symbol change" {
    const allocator = std.testing.allocator;
    try expectFormattingOnlySymbolChangeIsFresh(
        allocator,
        "src/greet.rs",
        "src/greet.rs#greet",
        "pub fn greet(name: &str, excited: bool) -> String {\n    format!(\"Hello, {}{}\", name, if excited { \"!\" } else { \".\" })\n}\n",
        "pub fn greet(\n    name: &str,\n    excited: bool\n) -> String {\n    format!(\"Hello, {}{}\", name, if excited { \"!\" } else { \".\" })\n}\n",
    );
}

test "check still reports stale after typescript symbol token change" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/math.ts", "function add(a: number, b: number): number {\n  return a + b;\n}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add initial source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/math.ts#add");
    try repo.commit("link spec");

    try repo.writeFile("src/math.ts", "function add(a: number, b: number): number {\n  return a - b;\n}\n");
    try repo.commit("change symbol behavior");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 1);
    try helpers.expectContains(check_result.stdout, "STALE");
    try helpers.expectContains(check_result.stdout, "src/math.ts#add");
}

test "lint includes blame info when linked file changed after link" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("refactor: update main return value");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "changed by");
    try helpers.expectContains(result.stdout, "refactor: update main return value");
}

test "check --format json produces valid JSON with correct structure" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        schema_version: []const u8,
        tool: []const u8,
        summary: struct {
            result: []const u8,
            specs_total: u32,
            specs_checked: u32,
            anchors_total: u32,
            anchors_fresh: u32,
        },
        specs: []const struct {
            path: []const u8,
            result: []const u8,
            anchors: []const struct {
                identity: []const u8,
                kind: []const u8,
                path: []const u8,
                result: []const u8,
                provenance: ?struct { kind: []const u8, value: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("drift.check.v1", parsed.value.schema_version);
    try std.testing.expectEqualStrings("drift", parsed.value.tool);
    try std.testing.expectEqualStrings("pass", parsed.value.summary.result);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_fresh);
    try std.testing.expectEqualStrings("docs/spec.md", parsed.value.specs[0].path);
    try std.testing.expectEqualStrings("fresh", parsed.value.specs[0].result);
    try std.testing.expectEqualStrings("src/main.ts", parsed.value.specs[0].anchors[0].identity);
    try std.testing.expectEqualStrings("file", parsed.value.specs[0].anchors[0].kind);
    try std.testing.expectEqualStrings("fresh", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("sig", parsed.value.specs[0].anchors[0].provenance.?.kind);
}

test "check --format json reports stale anchors with blame" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add source and spec");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("refactor: tweak main return value");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        summary: struct { result: []const u8, specs_stale: u32, anchors_stale: u32 },
        specs: []const struct {
            result: []const u8,
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8 },
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

    try std.testing.expectEqualStrings("fail", parsed.value.summary.result);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_stale);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_stale);
    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].result);
    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("changed_after_baseline", parsed.value.specs[0].anchors[0].reason.?.code);
    const blame = parsed.value.specs[0].anchors[0].blame orelse return error.MissingBlame;
    try std.testing.expect(blame.author.len > 0);
    try std.testing.expect(blame.commit.len >= 40);
    try std.testing.expect(std.mem.indexOfScalar(u8, blame.date, 'T') != null);
    try helpers.expectContains(blame.subject, "refactor: tweak main return value");
}

test "check --format json reports missing file" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/missing.ts sig:deadbeefdeadbeef\n");
    try repo.commit("add missing binding");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        specs: []const struct {
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("stale", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("file_not_found", parsed.value.specs[0].anchors[0].reason.?.code);
}

test "check --format json reports skip with origin_mismatch and verification_state none" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("drift.lock", "docs/spec.md -> src/main.ts sig:deadbeefdeadbeef origin:github:other/repo\n");
    try repo.commit("add foreign-origin binding");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        summary: struct {
            result: []const u8,
            verification_state: []const u8,
            specs_total: u32,
            specs_checked: u32,
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
    try std.testing.expectEqualStrings("none", parsed.value.summary.verification_state);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_total);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.summary.specs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_skipped);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_skipped);
    try std.testing.expectEqualStrings("skip", parsed.value.specs[0].result);
    try std.testing.expectEqualStrings("skip", parsed.value.specs[0].anchors[0].result);
    try std.testing.expectEqualStrings("origin_mismatch", parsed.value.specs[0].anchors[0].reason.?.code);
}

test "check --format json reports verification_state partial when one spec skips and one checks" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/ok.md", "# Ok\n");
    try repo.writeFile("docs/skip.md", "# Skip\n");
    try repo.writeFile("src/ok.ts", "export const x = 1;\n");
    try repo.writeFile("src/skip.ts", "export const y = 2;\n");
    try repo.commit("add docs and sources");

    try linkSpec(&repo, "docs/ok.md", "src/ok.ts");
    const existing_lock = try repo.readFile("drift.lock");
    defer allocator.free(existing_lock);
    const combined_lock = try std.fmt.allocPrint(
        allocator,
        "{s}docs/skip.md -> src/skip.ts sig:deadbeefdeadbeef origin:github:other/repo\n",
        .{existing_lock},
    );
    defer allocator.free(combined_lock);
    try repo.writeFile("drift.lock", combined_lock);
    try repo.commit("add local and foreign bindings");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);

    const Payload = struct {
        summary: struct {
            verification_state: []const u8,
            specs_total: u32,
            specs_checked: u32,
            specs_skipped: u32,
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("partial", parsed.value.summary.verification_state);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.summary.specs_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.specs_skipped);
}

test "check --format rejects unknown values" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add spec");

    const result = try repo.runDrift(&.{ "check", "--format", "yaml" });
    defer result.deinit(allocator);

    try std.testing.expect(result.exitCode() != 0);
    try helpers.expectContains(result.stderr, "unknown --format");
}

test "check --changed scopes checking to affected specs" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/auth.md", "# Auth\n");
    try repo.writeFile("docs/payments.md", "# Payments\n");
    try repo.writeFile("src/auth/login.ts", "export const login = true;\n");
    try repo.writeFile("src/payments/stripe.ts", "export const stripe = true;\n");
    try repo.commit("add docs and sources");

    try linkSpec(&repo, "docs/auth.md", "src/auth/login.ts");
    try linkSpec(&repo, "docs/payments.md", "src/payments/stripe.ts");
    try repo.commit("link both specs");

    try repo.writeFile("src/auth/login.ts", "export const login = false;\n");
    try repo.commit("modify auth source");

    const result = try repo.runDrift(&.{ "check", "--changed", "src/auth" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectNotContains(result.stdout, "docs/payments.md");
}

test "check --changed returns ok when no bindings match the prefix" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.writeFile("src/main.ts", "export const value = 1;\n");
    try repo.commit("add spec and source");

    try linkSpec(&repo, "docs/spec.md", "src/main.ts");
    try repo.commit("link spec");

    const result = try repo.runDrift(&.{ "check", "--changed", "src/other" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "lint --format json works as alias" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/spec.md", "# Spec\n");
    try repo.commit("add spec");

    const result = try repo.runDrift(&.{ "lint", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);
    try helpers.expectContains(result.stdout, "drift.check.v1");
}
