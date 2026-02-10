import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { writeBuildArtifacts } from "./build-artifacts.ts";

const createTempDirectory = (): string => mkdtempSync(join(tmpdir(), "drift-artifacts-"));

describe("build-artifacts", () => {
  test("writeBuildArtifacts writes build.patch, summary.md, and build.yaml", () => {
    const cwd = createTempDirectory();
    const cellDir = join(cwd, "cells", "2");

    writeBuildArtifacts({
      cellDir,
      artifact: {
        files: ["src/generated/cell-2.md"],
        patch: `--- /dev/null
+++ b/src/generated/cell-2.md
@@ -0,0 +1,1 @@
+# cell 2
`,
        summary: "Generated scaffold for cell 2.",
        timestamp: "2026-02-10T00:00:00.000Z",
      },
      ref: null,
    });

    const buildYaml = readFileSync(join(cellDir, "artifacts", "build.yaml"), "utf8");
    const patch = readFileSync(join(cellDir, "artifacts", "build.patch"), "utf8");
    const summary = readFileSync(join(cellDir, "artifacts", "summary.md"), "utf8");

    expect(buildYaml).toContain("files:");
    expect(buildYaml).toContain("  - src/generated/cell-2.md");
    expect(buildYaml).toContain("ref: null");
    expect(buildYaml).toContain("timestamp: 2026-02-10T00:00:00.000Z");
    expect(patch).toContain("+++ b/src/generated/cell-2.md");
    expect(summary).toBe("Generated scaffold for cell 2.");

    rmSync(cwd, { recursive: true, force: true });
  });

  test("writeBuildArtifacts renders empty file list with a commit ref", () => {
    const cwd = createTempDirectory();
    const cellDir = join(cwd, "cells", "3");

    writeBuildArtifacts({
      cellDir,
      artifact: {
        files: [],
        patch: "",
        summary: "No changes.",
        timestamp: "2026-02-10T01:00:00.000Z",
      },
      ref: "abc123",
    });

    const buildYaml = readFileSync(join(cellDir, "artifacts", "build.yaml"), "utf8");

    expect(buildYaml).toContain("files: []");
    expect(buildYaml).toContain("ref: abc123");
    expect(buildYaml).toContain("timestamp: 2026-02-10T01:00:00.000Z");

    rmSync(cwd, { recursive: true, force: true });
  });
});
