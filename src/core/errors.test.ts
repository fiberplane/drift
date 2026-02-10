import { describe, expect, test } from "bun:test";

import {
  AgentError,
  AncestorFailedError,
  DagCycleError,
  DiffApplyError,
  DriftDetectedError,
  ImportNotFoundError,
  InlineCommandError,
  InvalidDiffError,
  LoadProjectError,
  ParseMarkdownError,
  VcsCommitError,
} from "./errors.ts";

describe("errors", () => {
  test("all tagged errors expose stable tags", () => {
    const dagCycleError = new DagCycleError({ cells: [1, 2, 3] });
    const invalidDiffError = new InvalidDiffError({
      cellIndex: 3,
      rawOutput: "not-a-diff",
    });
    const diffApplyError = new DiffApplyError({
      cellIndex: 3,
      patch: "diff --git a/a.ts b/a.ts",
      stderr: "patch failed",
    });
    const agentError = new AgentError({
      cellIndex: 3,
      agent: "claude",
      exitCode: 1,
      stderr: "process failed",
    });
    const ancestorFailedError = new AncestorFailedError({
      targetCell: 4,
      failedCell: 3,
      cause: agentError,
    });
    const importNotFoundError = new ImportNotFoundError({
      cellIndex: 2,
      importRef: "@./missing.ts",
    });
    const inlineCommandError = new InlineCommandError({
      cellIndex: 2,
      command: "bun test",
      exitCode: 2,
      stderr: "test suite failed",
    });
    const vcsCommitError = new VcsCommitError({
      cellIndices: [1, 2],
      stderr: "nothing to commit",
    });
    const driftDetectedError = new DriftDetectedError({
      cellIndex: 5,
      files: ["src/core/schemas.ts"],
    });
    const loadProjectError = new LoadProjectError({
      path: ".drift/config.yaml",
      message: "Invalid config",
    });
    const parseMarkdownError = new ParseMarkdownError({
      message: "Missing frontmatter",
      cellIndex: null,
    });

    expect(dagCycleError._tag).toBe("DagCycleError");
    expect(invalidDiffError._tag).toBe("InvalidDiffError");
    expect(diffApplyError._tag).toBe("DiffApplyError");
    expect(agentError._tag).toBe("AgentError");
    expect(ancestorFailedError._tag).toBe("AncestorFailedError");
    expect(importNotFoundError._tag).toBe("ImportNotFoundError");
    expect(inlineCommandError._tag).toBe("InlineCommandError");
    expect(vcsCommitError._tag).toBe("VcsCommitError");
    expect(driftDetectedError._tag).toBe("DriftDetectedError");
    expect(loadProjectError._tag).toBe("LoadProjectError");
    expect(parseMarkdownError._tag).toBe("ParseMarkdownError");
    expect(ancestorFailedError.cause._tag).toBe("AgentError");
  });
});
