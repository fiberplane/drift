import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runCli } from "./index.ts";
import type { CliContext, CliDependencies } from "./types.ts";

const FIXED_TIME = new Date("2026-02-10T00:00:00.000Z");

interface CliRunResult {
  readonly exitCode: number;
  readonly stdout: readonly string[];
  readonly stderr: readonly string[];
}

const runCliInDirectory = (
  args: readonly string[],
  cwd: string,
  dependencies?: Partial<CliDependencies>,
): CliRunResult => {
  const stdout: string[] = [];
  const stderr: string[] = [];

  const context: CliContext = {
    cwd,
    now: () => FIXED_TIME,
    writeLine: (line) => {
      stdout.push(line);
    },
    writeError: (line) => {
      stderr.push(line);
    },
    dependencies,
  };

  const exitCode = runCli(args, context);
  return {
    exitCode,
    stdout,
    stderr,
  };
};

const createTempDirectory = (): string => mkdtempSync(join(tmpdir(), "drift-cli-"));

const writeCell = (args: {
  readonly cwd: string;
  readonly index: number;
  readonly content: string;
}): void => {
  const cellDir = join(args.cwd, ".drift", "cells", String(args.index));
  mkdirSync(cellDir, { recursive: true });
  writeFileSync(join(cellDir, "v1.md"), `${args.content.trimEnd()}\n`);
};

describe("drift CLI", () => {
  test("new command scaffolds .drift structure", () => {
    const cwd = createTempDirectory();

    const result = runCliInDirectory(["new"], cwd);

    expect(result.exitCode).toBe(0);
    expect(existsSync(join(cwd, ".drift", "config.yaml"))).toBe(true);
    expect(existsSync(join(cwd, ".drift", "cells", "0", "v1.md"))).toBe(true);

    rmSync(cwd, { recursive: true, force: true });
  });

  test("run command builds stale cells and writes artifacts", () => {
    const cwd = createTempDirectory();

    const newResult = runCliInDirectory(["new"], cwd);
    expect(newResult.exitCode).toBe(0);

    writeCell({
      cwd,
      index: 1,
      content: "## Data Model <!-- depends: 0 -->\n\nCreate todo schema.",
    });

    const runResult = runCliInDirectory(["run", "--no-stream"], cwd);

    expect(runResult.exitCode).toBe(0);
    expect(existsSync(join(cwd, "src", "generated", "cell-1.md"))).toBe(true);
    expect(existsSync(join(cwd, ".drift", "cells", "1", "artifacts", "build.yaml"))).toBe(true);

    const summary = readFileSync(
      join(cwd, ".drift", "cells", "1", "artifacts", "summary.md"),
      "utf8",
    );
    const patch = readFileSync(
      join(cwd, ".drift", "cells", "1", "artifacts", "build.patch"),
      "utf8",
    );
    const buildYaml = readFileSync(
      join(cwd, ".drift", "cells", "1", "artifacts", "build.yaml"),
      "utf8",
    );

    expect(summary).toContain("Data Model");
    expect(patch).toContain("--- /dev/null");
    expect(buildYaml).toContain("  - src/generated/cell-1.md");
    expect(buildYaml).toContain(`timestamp: ${FIXED_TIME.toISOString()}`);

    rmSync(cwd, { recursive: true, force: true });
  });

  test("plan command creates the next version snapshot", () => {
    const cwd = createTempDirectory();

    expect(runCliInDirectory(["new"], cwd).exitCode).toBe(0);
    writeCell({
      cwd,
      index: 1,
      content: "## Routes <!-- depends: 0 -->\n\nDraft route requirements.",
    });

    const planResult = runCliInDirectory(["plan", "1"], cwd);

    expect(planResult.exitCode).toBe(0);
    expect(existsSync(join(cwd, ".drift", "cells", "1", "v2.md"))).toBe(true);

    const plannedContent = readFileSync(join(cwd, ".drift", "cells", "1", "v2.md"), "utf8");
    expect(plannedContent).toContain("<!-- drift:planned");

    rmSync(cwd, { recursive: true, force: true });
  });

  test("assemble and init roundtrip", () => {
    const source = createTempDirectory();

    expect(runCliInDirectory(["new"], source).exitCode).toBe(0);
    writeCell({
      cwd: source,
      index: 1,
      content: "## Routes <!-- depends: 0 -->\n\nDefine API routes.",
    });
    expect(runCliInDirectory(["run", "--no-stream"], source).exitCode).toBe(0);
    expect(runCliInDirectory(["assemble", "-o", "PLAN.md"], source).exitCode).toBe(0);

    const assembled = readFileSync(join(source, "PLAN.md"), "utf8");
    const target = createTempDirectory();
    writeFileSync(join(target, "PLAN.md"), assembled);

    const initResult = runCliInDirectory(["init", "PLAN.md"], target);

    expect(initResult.exitCode).toBe(0);
    expect(existsSync(join(target, ".drift", "cells", "0", "v1.md"))).toBe(true);
    expect(existsSync(join(target, ".drift", "cells", "1", "v1.md"))).toBe(true);

    rmSync(source, { recursive: true, force: true });
    rmSync(target, { recursive: true, force: true });
  });

  test("commit command stores commit ref from VCS service", () => {
    const cwd = createTempDirectory();

    expect(runCliInDirectory(["new"], cwd).exitCode).toBe(0);
    writeCell({
      cwd,
      index: 1,
      content: "## Database <!-- depends: 0 -->\n\nCreate database setup.",
    });
    expect(runCliInDirectory(["run", "--no-stream"], cwd).exitCode).toBe(0);

    const commitResult = runCliInDirectory(["commit", "1"], cwd, {
      commitFiles: () => ({
        ok: true,
        ref: "deadbeef",
      }),
    });

    expect(commitResult.exitCode).toBe(0);

    const buildYaml = readFileSync(
      join(cwd, ".drift", "cells", "1", "artifacts", "build.yaml"),
      "utf8",
    );

    expect(buildYaml).toContain("ref: deadbeef");

    rmSync(cwd, { recursive: true, force: true });
  });

  test("commit command surfaces VCS failure from dependency", () => {
    const cwd = createTempDirectory();

    expect(runCliInDirectory(["new"], cwd).exitCode).toBe(0);
    writeCell({
      cwd,
      index: 1,
      content: "## Database <!-- depends: 0 -->\n\nCreate database setup.",
    });
    expect(runCliInDirectory(["run", "--no-stream"], cwd).exitCode).toBe(0);

    const commitResult = runCliInDirectory(["commit", "1"], cwd, {
      commitFiles: () => ({
        ok: false,
        message: "simulated VCS failure",
      }),
    });

    expect(commitResult.exitCode).toBe(1);
    expect(commitResult.stderr).toEqual(["Commit failed: simulated VCS failure"]);

    rmSync(cwd, { recursive: true, force: true });
  });
});
