import { describe, expect, test } from "bun:test";

import { Either } from "effect";

import { applyDagToCells, buildDagGraph } from "./dag.ts";
import type { Cell } from "./schemas.ts";

const createCell = (index: number): Cell => ({
  index,
  content: `Cell ${index}`,
  explicitDeps: null,
  agent: null,
  imports: [],
  inlines: [],
  version: 1,
  dependencies: [],
  dependents: [],
  state: "stale",
  comments: [],
  artifact: null,
  lastInputHash: null,
});

describe("dag", () => {
  test("buildDagGraph computes normalized dependencies, dependents, and topological levels", () => {
    const dependencies = new Map<number, readonly number[]>([
      [0, []],
      [1, [0]],
      [2, [0]],
      [3, [2, 1, 2]],
      [4, [2]],
    ]);

    const result = buildDagGraph(dependencies);

    expect(Either.isRight(result)).toBe(true);
    if (Either.isLeft(result)) {
      return;
    }

    expect([...result.right.dependenciesByCell.entries()]).toEqual([
      [0, []],
      [1, [0]],
      [2, [0]],
      [3, [1, 2]],
      [4, [2]],
    ]);

    expect([...result.right.dependentsByCell.entries()]).toEqual([
      [0, [1, 2]],
      [1, [3]],
      [2, [3, 4]],
      [3, []],
      [4, []],
    ]);

    expect(result.right.levels).toEqual([[0], [1, 2], [3, 4]]);

    const hydratedCells = applyDagToCells({
      cells: [createCell(0), createCell(1), createCell(2), createCell(3), createCell(4)],
      dependenciesByCell: result.right.dependenciesByCell,
      dependentsByCell: result.right.dependentsByCell,
    });

    const cellThree = hydratedCells.find((cell) => cell.index === 3);
    const cellTwo = hydratedCells.find((cell) => cell.index === 2);

    expect(cellThree?.dependencies).toEqual([1, 2]);
    expect(cellTwo?.dependents).toEqual([3, 4]);
  });

  test("buildDagGraph returns DagCycleError when dependencies form a cycle", () => {
    const dependencies = new Map<number, readonly number[]>([
      [0, []],
      [1, [2]],
      [2, [1]],
    ]);

    const result = buildDagGraph(dependencies);

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left._tag).toBe("DagCycleError");
    expect(result.left.cells).toEqual([1, 2]);
  });
});
