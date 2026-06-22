const std = @import("std");
const helpers = @import("helpers");

fn linkDoc(repo: *helpers.TempRepo, doc_path: []const u8, target: []const u8) !void {
    const allocator = std.testing.allocator;
    const result = try repo.runDrift(&.{ "link", doc_path, target });
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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add initial source and doc");

    try linkDoc(&repo, "docs/doc.md", file_path);
    try repo.commit("link doc to source file");

    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    try helpers.expectContains(check_result.stdout, "docs/doc.md");
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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add initial source and doc");

    try linkDoc(&repo, "docs/doc.md", symbol_anchor);
    try repo.commit("link doc to source symbol");

    try repo.writeFile(file_path, reformatted_source);
    try repo.commit("reformat source without syntax changes");

    const check_result = try repo.runDrift(&.{"check"});
    defer check_result.deinit(allocator);

    try helpers.expectExitCode(check_result.term, 0);
    try helpers.expectContains(check_result.stdout, "docs/doc.md");
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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "docs/doc.md");
    try helpers.expectContains(result.stdout, "ok");
}

test "lint reports stale when linked file changed after link" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("modify source");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "STALE");
    try helpers.expectContains(result.stdout, "src/main.ts");
    try helpers.expectContains(result.stdout, "changed after doc");
}

test "lint reports stale when linked file does not exist" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add doc");

    try repo.writeFile("drift.lock", "docs/doc.md -> src/missing.ts sig:deadbeefdeadbeef\n");
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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/lib.ts#doStuff");
    try repo.commit("link doc");

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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add initial source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/math.ts#add");
    try repo.commit("link doc");

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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

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
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        schema_version: []const u8,
        tool: []const u8,
        summary: struct {
            result: []const u8,
            docs_total: u32,
            docs_checked: u32,
            anchors_total: u32,
            anchors_fresh: u32,
        },
        docs: []const struct {
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
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_fresh);
    try std.testing.expectEqualStrings("docs/doc.md", parsed.value.docs[0].path);
    try std.testing.expectEqualStrings("fresh", parsed.value.docs[0].result);
    try std.testing.expectEqualStrings("src/main.ts", parsed.value.docs[0].anchors[0].identity);
    try std.testing.expectEqualStrings("file", parsed.value.docs[0].anchors[0].kind);
    try std.testing.expectEqualStrings("fresh", parsed.value.docs[0].anchors[0].result);
    try std.testing.expectEqualStrings("sig", parsed.value.docs[0].anchors[0].provenance.?.kind);
}

test "check --format json reports stale anchors with blame" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add source and doc");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    try repo.writeFile("src/main.ts", "export function main() { return 42; }\n");
    try repo.commit("refactor: tweak main return value");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        summary: struct { result: []const u8, docs_stale: u32, anchors_stale: u32 },
        docs: []const struct {
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
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_stale);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_stale);
    try std.testing.expectEqualStrings("stale", parsed.value.docs[0].result);
    try std.testing.expectEqualStrings("stale", parsed.value.docs[0].anchors[0].result);
    try std.testing.expectEqualStrings("changed_after_baseline", parsed.value.docs[0].anchors[0].reason.?.code);
    const blame = parsed.value.docs[0].anchors[0].blame orelse return error.MissingBlame;
    try std.testing.expect(blame.author.len > 0);
    try std.testing.expect(blame.commit.len >= 40);
    try std.testing.expect(std.mem.findScalar(u8, blame.date, 'T') != null);
    try helpers.expectContains(blame.subject, "refactor: tweak main return value");
}

test "check --format json reports missing file" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/missing.ts sig:deadbeefdeadbeef\n");
    try repo.commit("add missing binding");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        docs: []const struct {
            anchors: []const struct {
                result: []const u8,
                reason: ?struct { code: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("stale", parsed.value.docs[0].anchors[0].result);
    try std.testing.expectEqualStrings("file_not_found", parsed.value.docs[0].anchors[0].reason.?.code);
}

test "check --format json reports skip with origin_mismatch and verification_state none" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/main.ts", "export function main() {}\n");
    try repo.writeFile("drift.lock", "docs/doc.md -> src/main.ts sig:deadbeefdeadbeef origin:github:other/repo\n");
    try repo.commit("add foreign-origin binding");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        summary: struct {
            result: []const u8,
            verification_state: []const u8,
            docs_total: u32,
            docs_checked: u32,
            docs_skipped: u32,
            anchors_skipped: u32,
        },
        docs: []const struct {
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
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_total);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.summary.docs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_skipped);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.anchors_skipped);
    try std.testing.expectEqualStrings("skip", parsed.value.docs[0].result);
    try std.testing.expectEqualStrings("skip", parsed.value.docs[0].anchors[0].result);
    try std.testing.expectEqualStrings("origin_mismatch", parsed.value.docs[0].anchors[0].reason.?.code);
}

test "check --format json reports verification_state partial when one doc skips and one checks" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/ok.md", "# Ok\n");
    try repo.writeFile("docs/skip.md", "# Skip\n");
    try repo.writeFile("src/ok.ts", "export const x = 1;\n");
    try repo.writeFile("src/skip.ts", "export const y = 2;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/ok.md", "src/ok.ts");
    const existing_lock = try repo.readFile("drift.lock");
    defer allocator.free(existing_lock);
    const combined_lock = try std.fmt.allocPrint(
        allocator,
        "{s}\n[[bindings]]\n" ++
            "doc = \"docs/skip.md\"\n" ++
            "target = \"src/skip.ts\"\n" ++
            "origin = \"github:other/repo\"\n" ++
            "sig = \"deadbeefdeadbeef\"\n",
        .{std.mem.trim(u8, existing_lock, "\n")},
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
            docs_total: u32,
            docs_checked: u32,
            docs_skipped: u32,
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("partial", parsed.value.summary.verification_state);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.summary.docs_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_checked);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.docs_skipped);
}

test "check --format rejects unknown values" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add doc");

    const result = try repo.runDrift(&.{ "check", "--format", "yaml" });
    defer result.deinit(allocator);

    try std.testing.expect(result.exitCode() != 0);
    try helpers.expectContains(result.stderr, "unknown --format");
}

test "check --changed scopes checking to affected docs" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/auth.md", "# Auth\n");
    try repo.writeFile("docs/payments.md", "# Payments\n");
    try repo.writeFile("src/auth/login.ts", "export const login = true;\n");
    try repo.writeFile("src/payments/stripe.ts", "export const stripe = true;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/auth.md", "src/auth/login.ts");
    try linkDoc(&repo, "docs/payments.md", "src/payments/stripe.ts");
    try repo.commit("link both docs");

    try repo.writeFile("src/auth/login.ts", "export const login = false;\n");
    try repo.commit("modify auth source");

    const result = try repo.runDrift(&.{ "check", "--changed", "src/auth" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectNotContains(result.stdout, "docs/payments.md");
}

test "check --changed uses path segments not raw byte prefix (auth vs authz)" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/auth.md", "# Auth\n");
    try repo.writeFile("docs/authz.md", "# Authz\n");
    try repo.writeFile("src/auth/login.ts", "export const x = 1;\n");
    try repo.writeFile("src/authz/login.ts", "export const y = 1;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/auth.md", "src/auth/login.ts");
    try linkDoc(&repo, "docs/authz.md", "src/authz/login.ts");
    try repo.commit("link both docs");

    try repo.writeFile("src/auth/login.ts", "export const x = 2;\n");
    try repo.commit("modify auth only");

    const result = try repo.runDrift(&.{ "check", "--changed", "src/auth" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "docs/auth.md");
    try helpers.expectNotContains(result.stdout, "docs/authz.md");
}

test "check --changed returns ok when no bindings match the prefix" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/main.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    const result = try repo.runDrift(&.{ "check", "--changed", "src/other" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectContains(result.stdout, "ok");
}

test "check --changed includes broken-link-only docs when doc path matches" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/broken.md", "# Broken\n\nSee [missing](missing.md).\n");
    try repo.writeFile("docs/ok.md", "# Ok\n\nSee [self](ok.md).\n");
    try repo.commit("add docs");

    const result = try repo.runDrift(&.{ "check", "--changed", "docs/broken.md" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "docs/broken.md");
    try helpers.expectContains(result.stdout, "BROKEN  docs/missing.md (link target not found)");
    try helpers.expectNotContains(result.stdout, "docs/ok.md");
}

test "lint reports broken relative markdown links" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n\nSee [old](missing.md).\n");
    try repo.writeFile("src/main.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "BROKEN  docs/missing.md (link target not found)");
    try helpers.expectContains(result.stdout, "1 broken link");
}

test "lint checks broken links in discovered docs without drift bindings" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/plain.md", "# Plain\n\nSee [missing](missing.md).\n");
    try repo.commit("add plain doc");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "docs/plain.md");
    try helpers.expectContains(result.stdout, "BROKEN  docs/missing.md (link target not found)");
}

test "lint reports stale for markdown heading anchor when section changes" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n");
    try repo.writeFile("docs/auth.md", "# Auth\n\n## Authentication\n\nUse tokens.\n");
    try repo.commit("add docs");

    const link_result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Authentication" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);
    try repo.commit("link overview to auth heading");

    try repo.writeFile("docs/auth.md", "# Auth\n\n## Authentication\n\nUse signed tokens.\n");
    try repo.commit("update authentication docs");

    const result = try repo.runDrift(&.{"lint"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "STALE   docs/auth.md#authentication (changed after doc)");
}

test "lint resolves duplicate heading slugs to the first matching section" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n");
    try repo.writeFile(
        "docs/auth.md",
        "# Auth\n\n## Foo\n\nFirst body.\n\n## Foo\n\nSecond body.\n",
    );
    try repo.commit("add docs with duplicate headings");

    const link_result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Foo" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);
    try repo.commit("link duplicate heading");

    try repo.writeFile(
        "docs/auth.md",
        "# Auth\n\n## Foo\n\nFirst body.\n\n## Foo\n\nSecond body changed.\n",
    );
    try repo.commit("change second duplicate heading only");

    {
        const result = try repo.runDrift(&.{"lint"});
        defer result.deinit(allocator);
        try helpers.expectExitCode(result.term, 0);
        try helpers.expectContains(result.stdout, "docs/overview.md");
        try helpers.expectContains(result.stdout, "ok");
    }

    try repo.writeFile(
        "docs/auth.md",
        "# Auth\n\n## Foo\n\nFirst body changed.\n\n## Foo\n\nSecond body changed.\n",
    );
    try repo.commit("change first duplicate heading");

    {
        const result = try repo.runDrift(&.{"lint"});
        defer result.deinit(allocator);
        try helpers.expectExitCode(result.term, 1);
        try helpers.expectContains(result.stdout, "STALE   docs/auth.md#foo (changed after doc)");
    }
}

test "check --format json reports broken links and heading anchors" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/overview.md", "# Overview\n\nSee [auth](auth.md#Authentication) and [missing](missing.md).\n");
    try repo.writeFile("docs/auth.md", "# Auth\n\n## Authentication\n\nUse tokens.\n");
    try repo.commit("add docs");

    const link_result = try repo.runDrift(&.{ "link", "docs/overview.md", "docs/auth.md#Authentication" });
    defer link_result.deinit(allocator);
    try helpers.expectExitCode(link_result.term, 0);
    try repo.commit("link overview heading anchor");

    const result = try repo.runDrift(&.{ "check", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 1);
    try helpers.validateDriftCheckJson(allocator, result.stdout);

    const Payload = struct {
        summary: struct {
            result: []const u8,
            links_total: u32,
            links_broken: u32,
        },
        docs: []const struct {
            path: []const u8,
            result: []const u8,
            anchors: []const struct {
                kind: []const u8,
                result: []const u8,
            },
            links: []const struct {
                target: []const u8,
                result: []const u8,
                reason: ?struct { code: []const u8 },
            },
        },
    };

    var parsed = try std.json.parseFromSlice(Payload, allocator, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("fail", parsed.value.summary.result);
    try std.testing.expectEqual(@as(u32, 2), parsed.value.summary.links_total);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.summary.links_broken);

    var overview_index: ?usize = null;
    for (parsed.value.docs, 0..) |doc, idx| {
        if (std.mem.eql(u8, doc.path, "docs/overview.md")) {
            overview_index = idx;
            break;
        }
    }
    const overview = parsed.value.docs[overview_index orelse return error.TestUnexpectedResult];
    try std.testing.expectEqualStrings("broken", overview.result);
    try std.testing.expectEqualStrings("heading", overview.anchors[0].kind);
    try std.testing.expectEqualStrings("fresh", overview.anchors[0].result);
    try std.testing.expectEqualStrings("auth.md#Authentication", overview.links[0].target);
    try std.testing.expectEqualStrings("ok", overview.links[0].result);
    try std.testing.expectEqualStrings("missing.md", overview.links[1].target);
    try std.testing.expectEqualStrings("broken", overview.links[1].result);
    try std.testing.expectEqualStrings("link_target_not_found", overview.links[1].reason.?.code);
}

test "lint --format json works as alias" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.commit("add doc");

    const result = try repo.runDrift(&.{ "lint", "--format", "json" });
    defer result.deinit(allocator);
    try helpers.expectExitCode(result.term, 0);
    try helpers.validateDriftCheckJson(allocator, result.stdout);
    try helpers.expectContains(result.stdout, "drift.check.v1");
}

test "check from root skips docs in nested drift.lock scope" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    // Create root lockfile and a nested lockfile in nested/
    try repo.writeFile("drift.lock", "");
    try repo.writeFile("docs/root.md", "# Root\n");
    try repo.writeFile("nested/drift.lock", "");
    try repo.writeFile("nested/doc.md", "# Nested\n\nSee [missing](missing.md).\n");
    try repo.commit("add root and nested scope");

    // From root: should NOT report the broken link in nested/doc.md
    const result = try repo.runDrift(&.{"check"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try helpers.expectNotContains(result.stdout, "nested/doc.md");
    try helpers.expectNotContains(result.stdout, "BROKEN");
}

test "check from nested subdir with its own drift.lock only checks that scope" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("drift.lock", "");
    try repo.writeFile("docs/root.md", "# Root\n\nSee [missing](missing.md).\n");
    try repo.writeFile("nested/drift.lock", "");
    try repo.writeFile("nested/doc.md", "# Nested\n\nSee [also-missing](also-missing.md).\n");
    try repo.commit("add root and nested scope");

    // From nested/: should report the broken link in nested/doc.md
    const result = try repo.runDriftFromSubdir("nested", &.{"check"});
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try helpers.expectContains(result.stdout, "doc.md");
    try helpers.expectContains(result.stdout, "BROKEN");
    // Should NOT contain docs from root scope
    try helpers.expectNotContains(result.stdout, "docs/root.md");
}

test "check --silent suppresses passing output" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/doc.md", "# Doc\n");
    try repo.writeFile("src/main.ts", "export const value = 1;\n");
    try repo.commit("add doc and source");

    try linkDoc(&repo, "docs/doc.md", "src/main.ts");
    try repo.commit("link doc");

    const result = try repo.runDrift(&.{ "check", "--silent" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 0);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "check --silent prints only stale and broken docs on failure" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/stale.md", "# Stale\n");
    try repo.writeFile("docs/ok.md", "# Ok\n");
    try repo.writeFile("docs/broken.md", "# Broken\n\nSee [missing](missing.md).\n");
    try repo.writeFile("src/stale.ts", "export const stale = 1;\n");
    try repo.writeFile("src/ok.ts", "export const ok = 1;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/stale.md", "src/stale.ts");
    try linkDoc(&repo, "docs/ok.md", "src/ok.ts");
    try repo.commit("link docs");

    try repo.writeFile("src/stale.ts", "export const stale = 2;\n");
    try repo.commit("make stale doc stale");

    const result = try repo.runDrift(&.{ "check", "--silent" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try std.testing.expectEqualStrings("", result.stdout);
    try helpers.expectContains(result.stderr, "docs/stale.md");
    try helpers.expectContains(result.stderr, "STALE   src/stale.ts");
    try helpers.expectContains(result.stderr, "docs/broken.md");
    try helpers.expectContains(result.stderr, "BROKEN  docs/missing.md (link target not found)");
    try helpers.expectContains(result.stderr, "2 of 3 docs failed, 1 ok, 1 broken link");
    try helpers.expectNotContains(result.stderr, "docs/ok.md");
    try helpers.expectNotContains(result.stderr, "  ok\n");
}

test "check --silent composes with changed path filtering" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/auth.md", "# Auth\n");
    try repo.writeFile("docs/payments.md", "# Payments\n");
    try repo.writeFile("src/auth/login.ts", "export const login = true;\n");
    try repo.writeFile("src/payments/stripe.ts", "export const stripe = true;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/auth.md", "src/auth/login.ts");
    try linkDoc(&repo, "docs/payments.md", "src/payments/stripe.ts");
    try repo.commit("link both docs");

    try repo.writeFile("src/auth/login.ts", "export const login = false;\n");
    try repo.commit("modify auth source");

    const result = try repo.runDrift(&.{ "check", "--silent", "--changed", "src/auth" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try std.testing.expectEqualStrings("", result.stdout);
    try helpers.expectContains(result.stderr, "docs/auth.md");
    try helpers.expectContains(result.stderr, "1 of 1 doc failed");
    try helpers.expectNotContains(result.stderr, "docs/payments.md");
}

test "check --silent --format json keeps full payload on failure" {
    const allocator = std.testing.allocator;
    var repo = try helpers.TempRepo.init(allocator);
    defer repo.cleanup();

    try repo.writeFile("docs/stale.md", "# Stale\n");
    try repo.writeFile("docs/ok.md", "# Ok\n");
    try repo.writeFile("src/stale.ts", "export const stale = 1;\n");
    try repo.writeFile("src/ok.ts", "export const ok = 1;\n");
    try repo.commit("add docs and sources");

    try linkDoc(&repo, "docs/stale.md", "src/stale.ts");
    try linkDoc(&repo, "docs/ok.md", "src/ok.ts");
    try repo.commit("link docs");

    try repo.writeFile("src/stale.ts", "export const stale = 2;\n");
    try repo.commit("make stale doc stale");

    const result = try repo.runDrift(&.{ "check", "--silent", "--format", "json" });
    defer result.deinit(allocator);

    try helpers.expectExitCode(result.term, 1);
    try std.testing.expectEqualStrings("", result.stdout);
    try helpers.validateDriftCheckJson(allocator, result.stderr);
    try helpers.expectContains(result.stderr, "docs/stale.md");
    try helpers.expectContains(result.stderr, "docs/ok.md");
}
