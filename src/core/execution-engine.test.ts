import { describe, expect, test } from "bun:test";

import { Either } from "effect";

import {
  runAllStaleBuild,
  runOneCellBuild,
  type BuildCallbacks,
  type ExecutionAttempt,
  type ExecutionCell,
} from "./execution-engine.ts";

const createCell = (args: {
  readonly index: number;
  readonly dependencies?: readonly number[];
  readonly dependents?: readonly number[];
  readonly state: "clean" | "stale" | "running" | "error";
}): ExecutionCell => ({
  index: args.index,
  dependencies: args.dependencies ?? [],
  dependents: args.dependents ?? [],
  state: args.state,
  artifact: null,
});

const createAlwaysSuccessfulCallbacks = (): BuildCallbacks => ({
  runBuild: ({ cell }) =>
    Either.right({
      files: [`src/${cell.index}.ts`],
      patch: `patch-${cell.index}`,
      timestamp: "2026-02-10T00:00:00Z",
    }),
  reviewBuild: ({ cell }) => Either.right(`summary-${cell.index}`),
});

describe("execution-engine", () => {
  test("runOneCellBuild resolves stale ancestors before running the target cell", () => {
    const calls: number[] = [];
    const callbacks: BuildCallbacks = {
      runBuild: ({ cell }) => {
        calls.push(cell.index);
        return Either.right({
          files: [`src/${cell.index}.ts`],
          patch: `patch-${cell.index}`,
          timestamp: "2026-02-10T00:00:00Z",
        });
      },
      reviewBuild: ({ cell }) => Either.right(`summary-${cell.index}`),
    };

    const result = runOneCellBuild({
      cells: [
        createCell({ index: 0, state: "clean" }),
        createCell({ index: 1, dependencies: [0], state: "stale" }),
        createCell({ index: 2, dependencies: [1], state: "stale" }),
        createCell({ index: 3, dependencies: [1], state: "stale" }),
        createCell({ index: 4, dependencies: [2, 3], state: "stale" }),
        createCell({ index: 5, dependencies: [4], state: "stale" }),
      ],
      targetCell: 4,
      callbacks,
    });

    expect(Either.isRight(result)).toBe(true);
    if (Either.isLeft(result)) {
      return;
    }

    expect(calls).toEqual([1, 2, 3, 4]);
    expect(result.right.executed).toEqual([1, 2, 3, 4]);
    expect(result.right.eligibleDescendants).toEqual([5]);

    const cellStates = result.right.cells.map((cell) => ({
      index: cell.index,
      state: cell.state,
    }));
    expect(cellStates).toEqual([
      { index: 0, state: "clean" },
      { index: 1, state: "clean" },
      { index: 2, state: "clean" },
      { index: 3, state: "clean" },
      { index: 4, state: "clean" },
      { index: 5, state: "stale" },
    ]);
  });

  test("runAllStaleBuild executes all stale cells in topological order", () => {
    const result = runAllStaleBuild({
      cells: [
        createCell({ index: 0, state: "clean" }),
        createCell({ index: 1, dependencies: [0], state: "stale" }),
        createCell({ index: 2, dependencies: [1], state: "stale" }),
        createCell({ index: 3, dependencies: [1], state: "stale" }),
        createCell({ index: 4, dependencies: [2, 3], state: "stale" }),
        createCell({ index: 5, dependencies: [4], state: "stale" }),
      ],
      callbacks: createAlwaysSuccessfulCallbacks(),
    });

    expect(Either.isRight(result)).toBe(true);
    if (Either.isLeft(result)) {
      return;
    }

    expect(result.right.executed).toEqual([1, 2, 3, 4, 5]);
    expect(result.right.eligibleDescendants).toEqual([]);
  });

  test("parallel mode retries diff-apply failures sequentially", () => {
    const attempts: string[] = [];
    const callbacks: BuildCallbacks = {
      runBuild: ({ cell, attempt }) => {
        attempts.push(`${cell.index}:${attempt}`);

        if (cell.index === 3 && attempt === "parallel") {
          return Either.left({
            tag: "diff-apply",
            cellIndex: 3,
            message: "conflict",
          });
        }

        return Either.right({
          files: [`src/${cell.index}.ts`],
          patch: `patch-${cell.index}`,
          timestamp: "2026-02-10T00:00:00Z",
        });
      },
      reviewBuild: ({ cell }) => Either.right(`summary-${cell.index}`),
    };

    const result = runOneCellBuild({
      cells: [
        createCell({ index: 0, state: "clean" }),
        createCell({ index: 1, dependencies: [0], state: "stale" }),
        createCell({ index: 2, dependencies: [1], state: "stale" }),
        createCell({ index: 3, dependencies: [1], state: "stale" }),
        createCell({ index: 4, dependencies: [2, 3], state: "stale" }),
      ],
      targetCell: 4,
      callbacks,
      config: { parallel: true },
    });

    expect(Either.isRight(result)).toBe(true);
    if (Either.isLeft(result)) {
      return;
    }

    expect(result.right.retried).toEqual([3]);
    expect(result.right.executed).toEqual([1, 2, 3, 4]);
    expect(attempts).toEqual([
      "1:parallel",
      "2:parallel",
      "3:parallel",
      "3:sequential-retry",
      "4:sequential",
    ]);
  });

  test("runOneCellBuild wraps ancestor failures and keeps target unexecuted", () => {
    const attempts: Array<{ readonly cellIndex: number; readonly attempt: ExecutionAttempt }> = [];

    const callbacks: BuildCallbacks = {
      runBuild: ({ cell, attempt }) => {
        attempts.push({ cellIndex: cell.index, attempt });

        if (cell.index === 2) {
          return Either.left({
            tag: "agent-error",
            cellIndex: 2,
            message: "agent crashed",
          });
        }

        return Either.right({
          files: [`src/${cell.index}.ts`],
          patch: `patch-${cell.index}`,
          timestamp: "2026-02-10T00:00:00Z",
        });
      },
      reviewBuild: ({ cell }) => Either.right(`summary-${cell.index}`),
    };

    const result = runOneCellBuild({
      cells: [
        createCell({ index: 0, state: "clean" }),
        createCell({ index: 1, dependencies: [0], state: "stale" }),
        createCell({ index: 2, dependencies: [1], state: "stale" }),
        createCell({ index: 3, dependencies: [1], state: "stale" }),
        createCell({ index: 4, dependencies: [2, 3], state: "stale" }),
      ],
      targetCell: 4,
      callbacks,
    });

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left.tag).toBe("ancestor-failed");
    if (result.left.tag !== "ancestor-failed") {
      return;
    }

    expect(result.left.failedCell).toBe(2);
    expect(result.left.targetCell).toBe(4);
    expect(attempts).toEqual([
      { cellIndex: 1, attempt: "sequential" },
      { cellIndex: 2, attempt: "sequential" },
    ]);
  });
});
