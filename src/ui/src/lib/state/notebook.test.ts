import { describe, expect, test } from "bun:test";

import {
  appendCellLiveToken,
  createInitialNotebook,
  createToolbarState,
  getCellDisplayedInput,
  isCellCommitReady,
  restoreCellVersion,
  setCellOutput,
  setCellState,
  startCellLiveOutput,
  stepCellVersion,
  updateCellInput,
} from "./notebook.ts";
import type { UiCell } from "../types.ts";

const createCell = (index: number, overrides: Partial<UiCell> = {}): UiCell => {
  const input = overrides.input ?? `# Cell ${index}`;

  return {
    index,
    title: overrides.title ?? `Cell ${index}`,
    dependencies: overrides.dependencies ?? [],
    dependents: overrides.dependents ?? [],
    state: overrides.state ?? "stale",
    input,
    output: overrides.output ?? null,
    liveOutput: overrides.liveOutput ?? null,
    versions: overrides.versions ?? [
      {
        version: 1,
        content: input,
      },
    ],
    selectedVersion: overrides.selectedVersion ?? null,
  };
};

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
          patch: "diff --git a/a.ts b/a.ts",
          commitRef: null,
        },
      }),
    ]);

    const updated = updateCellInput(notebook, 0, "# Updated content");
    const cell = updated.cells[0];

    expect(cell?.input).toBe("# Updated content");
    expect(cell?.state).toBe("stale");
    expect(cell?.output).toBeNull();
  });

  test("setCellOutput promotes cell to clean and stores summary", () => {
    const notebook = createInitialNotebook([createCell(2)]);
    const updated = setCellOutput(notebook, 2, {
      summary: "Build done",
      patch: "diff --git a/a.ts b/a.ts",
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
          patch: "",
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
          patch: "",
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
        patch: "",
        commitRef: null,
      },
    });

    const running = setCellState(createInitialNotebook([eligible]), 4, "running").cells[0];

    expect(isCellCommitReady(eligible)).toBe(true);
    expect(isCellCommitReady(createCell(5))).toBe(false);
    expect(isCellCommitReady(running ?? createCell(6))).toBe(false);
  });

  test("startCellLiveOutput and appendCellLiveToken build a streaming transcript", () => {
    const notebook = createInitialNotebook([createCell(0)]);

    const withStream = startCellLiveOutput(notebook, 0, "build");
    const withFirstToken = appendCellLiveToken(withStream, 0, "diff --git ");
    const withSecondToken = appendCellLiveToken(withFirstToken, 0, "a/src/app.ts b/src/app.ts\n");

    expect(withSecondToken.cells[0]?.state).toBe("running");
    expect(withSecondToken.cells[0]?.liveOutput?.content).toBe(
      "diff --git a/src/app.ts b/src/app.ts\n",
    );
  });

  test("stepCellVersion browses history and restoreCellVersion creates rollback snapshots", () => {
    const notebook = createInitialNotebook([
      createCell(1, {
        input: "# Current",
        versions: [
          {
            version: 1,
            content: "# v1",
          },
          {
            version: 2,
            content: "# v2",
          },
          {
            version: 3,
            content: "# Current",
          },
        ],
      }),
    ]);

    const browsing = stepCellVersion(notebook, 1, -1);
    expect(browsing.cells[0]?.selectedVersion).toBe(2);
    expect(getCellDisplayedInput(browsing.cells[0] ?? createCell(1))).toBe("# v2");

    const restored = restoreCellVersion(browsing, 1, 2);
    const cell = restored.cells[0];

    expect(cell?.selectedVersion).toBeNull();
    expect(cell?.input).toBe("# v2");
    expect(cell?.state).toBe("stale");
    expect(cell?.versions.map((version) => version.version)).toEqual([1, 2, 3, 4, 5]);
    expect(cell?.versions[3]?.content).toBe("# Current");
    expect(cell?.versions[4]?.content).toBe("# v2");
  });
});
