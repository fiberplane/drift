import { describe, expect, test } from "bun:test";

import {
  createInitialNotebook,
  createToolbarState,
  isCellCommitReady,
  setCellOutput,
  setCellState,
  updateCellInput,
} from "./notebook.ts";
import type { UiCell } from "../types.ts";

const createCell = (index: number, overrides: Partial<UiCell> = {}): UiCell => ({
  index,
  title: overrides.title ?? `Cell ${index}`,
  dependencies: overrides.dependencies ?? [],
  state: overrides.state ?? "stale",
  input: overrides.input ?? `# Cell ${index}`,
  output: overrides.output ?? null,
});

describe("ui notebook state", () => {
  test("createInitialNotebook sets activeCell to the first cell", () => {
    const notebook = createInitialNotebook([createCell(0), createCell(1)]);

    expect(notebook.activeCell).toBe(0);
    expect(notebook.cells.map((cell) => cell.index)).toEqual([0, 1]);
  });

  test("updateCellInput updates markdown and marks cell stale", () => {
    const notebook = createInitialNotebook([
      createCell(0, {
        state: "clean",
        output: {
          summary: "already built",
          commitRef: null,
        },
      }),
    ]);

    const updated = updateCellInput(notebook, 0, "# Updated content");
    const cell = updated.cells[0];

    expect(cell?.input).toBe("# Updated content");
    expect(cell?.state).toBe("stale");
  });

  test("setCellOutput promotes cell to clean and stores summary", () => {
    const notebook = createInitialNotebook([createCell(2)]);
    const updated = setCellOutput(notebook, 2, {
      summary: "Build done",
      commitRef: null,
    });

    const cell = updated.cells[0];

    expect(cell?.state).toBe("clean");
    expect(cell?.output?.summary).toBe("Build done");
  });

  test("createToolbarState tracks stale and uncommitted counts", () => {
    const notebook = createInitialNotebook([
      createCell(0, {
        state: "clean",
        output: {
          summary: "committed",
          commitRef: "abc123",
        },
      }),
      createCell(1, {
        state: "stale",
      }),
      createCell(2, {
        state: "clean",
        output: {
          summary: "ready to commit",
          commitRef: null,
        },
      }),
    ]);

    const toolbar = createToolbarState(notebook);

    expect(toolbar.staleCount).toBe(1);
    expect(toolbar.uncommittedCount).toBe(1);
    expect(toolbar.canBuildAll).toBe(true);
    expect(toolbar.canCommitAll).toBe(true);
  });

  test("isCellCommitReady only allows clean cells with uncommitted output", () => {
    const eligible = createCell(4, {
      state: "clean",
      output: {
        summary: "summary",
        commitRef: null,
      },
    });

    const running = setCellState(createInitialNotebook([eligible]), 4, "running").cells[0];

    expect(isCellCommitReady(eligible)).toBe(true);
    expect(isCellCommitReady(createCell(5))).toBe(false);
    expect(isCellCommitReady(running ?? createCell(6))).toBe(false);
  });
});
