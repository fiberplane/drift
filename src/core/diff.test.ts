import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { Either } from "effect";

import { applyUnifiedDiff, summarizeUnifiedDiff } from "./diff.ts";

const createTempDirectory = (): string => mkdtempSync(join(tmpdir(), "drift-diff-"));

describe("diff", () => {
  test("summarizeUnifiedDiff counts additions and deletions", () => {
    const patch = `--- a/src/example.ts
+++ b/src/example.ts
@@ -1,2 +1,2 @@
-const oldValue = 1;
+const newValue = 2;
 const untouched = true;
`;

    expect(summarizeUnifiedDiff(patch)).toEqual({
      additions: 1,
      deletions: 1,
    });
  });

  test("applyUnifiedDiff supports /dev/null new-file patches", () => {
    const cwd = createTempDirectory();
    const patch = `--- /dev/null
+++ b/src/generated/new-file.ts
@@ -0,0 +1,1 @@
+export const generated = true;
`;

    const result = applyUnifiedDiff({
      cwd,
      cellIndex: 3,
      rawOutput: patch,
    });

    expect(Either.isRight(result)).toBe(true);
    if (Either.isRight(result)) {
      expect(result.right.files).toEqual(["src/generated/new-file.ts"]);
      expect(result.right.patch).toContain("--- /dev/null");
    }

    const written = readFileSync(join(cwd, "src", "generated", "new-file.ts"), "utf8");
    expect(written).toBe("export const generated = true;\n");

    rmSync(cwd, { recursive: true, force: true });
  });

  test("applyUnifiedDiff returns InvalidDiffError for non-diff output", () => {
    const result = applyUnifiedDiff({
      cwd: "/tmp",
      cellIndex: 7,
      rawOutput: "This is not a patch",
    });

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isLeft(result)) {
      expect(result.left._tag).toBe("InvalidDiffError");
      expect(result.left.cellIndex).toBe(7);
    }
  });

  test("applyUnifiedDiff returns DiffApplyError when a hunk does not match", () => {
    const cwd = createTempDirectory();
    const targetDir = join(cwd, "src");
    mkdirSync(targetDir, { recursive: true });
    writeFileSync(join(targetDir, "example.ts"), "export const value = 1;\n");

    const patch = `--- a/src/example.ts
+++ b/src/example.ts
@@ -1,1 +1,1 @@
-export const value = 2;
+export const value = 3;
`;

    const result = applyUnifiedDiff({
      cwd,
      cellIndex: 4,
      rawOutput: patch,
    });

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isLeft(result)) {
      expect(result.left._tag).toBe("DiffApplyError");
      expect(result.left.cellIndex).toBe(4);
      if (result.left._tag === "DiffApplyError") {
        expect(result.left.stderr).toContain("Hunk does not match");
      }
    }

    const unchanged = readFileSync(join(targetDir, "example.ts"), "utf8");
    expect(unchanged).toBe("export const value = 1;\n");

    rmSync(cwd, { recursive: true, force: true });
  });
});
