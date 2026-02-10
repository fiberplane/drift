import { describe, expect, test } from "bun:test";

import { Either } from "effect";

import {
  commitWithVcs,
  detectDrift,
  parseProjectVcsBackend,
  resolveVcsBackend,
  snapshotFileHashes,
  type VcsCommand,
  type VcsCommandResult,
  type VcsRuntime,
} from "./vcs.ts";

const createCommandHarness = (results: readonly VcsCommandResult[]) => {
  const calls: VcsCommand[] = [];
  let index = 0;

  const runCommand = (command: VcsCommand): VcsCommandResult => {
    calls.push({
      cwd: command.cwd,
      cmd: [...command.cmd],
    });

    const next = results[index];
    index += 1;

    if (next === undefined) {
      return {
        exitCode: 1,
        stdout: "",
        stderr: "missing mock command result",
      };
    }

    return next;
  };

  return {
    calls,
    runCommand,
  };
};

describe("vcs", () => {
  test("parseProjectVcsBackend reads backend from nested vcs config", () => {
    const configRaw = `agent: claude
vcs:
  backend: jj
`;

    expect(parseProjectVcsBackend(configRaw)).toBe("jj");
  });

  test("parseProjectVcsBackend falls back to auto for missing or invalid values", () => {
    expect(parseProjectVcsBackend("agent: claude\n")).toBe("auto");

    const invalidConfig = `vcs:
  backend: svn
`;
    expect(parseProjectVcsBackend(invalidConfig)).toBe("auto");
  });

  test("resolveVcsBackend auto-detects jj before git", () => {
    const backend = resolveVcsBackend({
      cwd: "/repo",
      backend: "auto",
      pathExists: (path) => path.endsWith(".jj") || path.endsWith(".git"),
    });

    expect(backend).toBe("jj");
  });

  test("commitWithVcs commits selected files with git and resolves commit ref", () => {
    const harness = createCommandHarness([
      {
        exitCode: 0,
        stdout: "",
        stderr: "",
      },
      {
        exitCode: 0,
        stdout: "[main 1234567] drift: cell\n",
        stderr: "",
      },
      {
        exitCode: 0,
        stdout: "abc123\n",
        stderr: "",
      },
    ]);

    const result = commitWithVcs(
      {
        cwd: "/repo",
        backend: "git",
        files: ["src/a.ts", "src/a.ts"],
        message: "drift: cell 1",
        cellIndices: [1],
      },
      {
        pathExists: () => false,
        runCommand: harness.runCommand,
      },
    );

    expect(Either.isRight(result)).toBe(true);
    if (Either.isRight(result)) {
      expect(result.right.backend).toBe("git");
      expect(result.right.ref).toBe("abc123");
    }

    expect(harness.calls.map((call) => call.cmd)).toEqual([
      ["git", "add", "--", "src/a.ts"],
      ["git", "commit", "-m", "drift: cell 1", "--only", "--", "src/a.ts"],
      ["git", "rev-parse", "--short", "HEAD"],
    ]);
  });

  test("commitWithVcs returns VcsCommitError when backend command fails", () => {
    const harness = createCommandHarness([
      {
        exitCode: 0,
        stdout: "",
        stderr: "",
      },
      {
        exitCode: 1,
        stdout: "",
        stderr: "nothing to commit",
      },
    ]);

    const result = commitWithVcs(
      {
        cwd: "/repo",
        backend: "git",
        files: ["src/a.ts"],
        message: "drift: cell 1",
        cellIndices: [1, 2],
      },
      {
        pathExists: () => false,
        runCommand: harness.runCommand,
      },
    );

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isLeft(result)) {
      expect(result.left._tag).toBe("VcsCommitError");
      expect(result.left.cellIndices).toEqual([1, 2]);
      expect(result.left.stderr).toBe("nothing to commit");
    }
  });

  test("detectDrift prefers VCS ref-based detection when ref diff succeeds", () => {
    const harness = createCommandHarness([
      {
        exitCode: 0,
        stdout: "src/a.ts\n",
        stderr: "",
      },
    ]);

    const runtime: VcsRuntime = {
      pathExists: () => false,
      runCommand: harness.runCommand,
      readTextFile: () => null,
    };

    const drift = detectDrift(
      {
        cwd: "/repo",
        backend: "git",
        files: ["src/a.ts", "src/b.ts"],
        ref: "abc123",
        previousHashes: {},
      },
      runtime,
    );

    expect(drift.method).toBe("ref");
    expect(drift.driftedFiles).toEqual(["src/a.ts"]);
    expect(harness.calls[0]?.cmd).toEqual([
      "git",
      "diff",
      "--name-only",
      "abc123",
      "--",
      "src/a.ts",
      "src/b.ts",
    ]);
  });

  test("detectDrift falls back to file hashes when ref diff fails", () => {
    const previousHashes = snapshotFileHashes(
      {
        cwd: "/repo",
        files: ["src/a.ts", "src/b.ts"],
      },
      {
        readTextFile: (path) => (path.endsWith("src/a.ts") ? "before-a" : "before-b"),
      },
    );

    const harness = createCommandHarness([
      {
        exitCode: 1,
        stdout: "",
        stderr: "unknown revision",
      },
    ]);

    const runtime: VcsRuntime = {
      pathExists: (path) => path.endsWith(".git"),
      runCommand: harness.runCommand,
      readTextFile: (path) => (path.endsWith("src/a.ts") ? "after-a" : "before-b"),
    };

    const drift = detectDrift(
      {
        cwd: "/repo",
        backend: "auto",
        files: ["src/a.ts", "src/b.ts"],
        ref: "deadbeef",
        previousHashes,
      },
      runtime,
    );

    expect(drift.backend).toBe("git");
    expect(drift.method).toBe("hash");
    expect(drift.driftedFiles).toEqual(["src/a.ts"]);
  });

  test("snapshotFileHashes stores null when files are missing", () => {
    const hashes = snapshotFileHashes(
      {
        cwd: "/repo",
        files: ["src/present.ts", "src/missing.ts"],
      },
      {
        readTextFile: (path) => (path.endsWith("present.ts") ? "content" : null),
      },
    );

    expect(typeof hashes["src/present.ts"]).toBe("string");
    expect(hashes["src/missing.ts"]).toBeNull();
  });
});
