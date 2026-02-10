import { describe, expect, test } from "bun:test";

import { applyServerEvent, createNotebookFromDag, syncNotebookFromDag } from "./ws.svelte.ts";

describe("ui websocket notebook integration", () => {
  test("createNotebookFromDag hydrates cells with output and versions", () => {
    const notebook = createNotebookFromDag([
      {
        index: 0,
        title: "Project",
        dependencies: [],
        dependents: [1],
        state: "clean",
        version: 2,
        content: "# Project\n\nCurrent",
        artifactRef: "abc1234",
        artifact: {
          summary: "Initial build complete",
          patch: "diff --git a/src/project.ts b/src/project.ts",
        },
        versions: [
          {
            version: 1,
            content: "# Project\n\nStart",
          },
          {
            version: 2,
            content: "# Project\n\nCurrent",
          },
        ],
      },
    ]);

    const cell = notebook.cells[0];

    expect(cell?.versions).toHaveLength(2);
    expect(cell?.output?.commitRef).toBe("abc1234");
    expect(cell?.output?.patch).toContain("diff --git");
  });

  test("applyServerEvent appends streaming tokens and final build artifact", () => {
    const notebook = createNotebookFromDag([
      {
        index: 2,
        title: "API",
        dependencies: [0],
        dependents: [],
        state: "stale",
        version: 1,
        content: "# API",
        artifactRef: null,
        artifact: null,
      },
    ]);

    const running = applyServerEvent(notebook, {
      type: "cell:state",
      cell: 2,
      state: "running",
    });

    const streamed = applyServerEvent(running, {
      type: "cell:token",
      cell: 2,
      token: "diff --git a/src/api.ts b/src/api.ts\n",
    });

    const completed = applyServerEvent(streamed, {
      type: "cell:complete",
      cell: 2,
      action: "build",
      artifact: {
        summary: "Implemented API handlers",
        patch: "diff --git a/src/api.ts b/src/api.ts\n+export const handler = () => {};",
      },
    });

    const cell = completed.cells[0];

    expect(cell?.liveOutput).toBeNull();
    expect(cell?.state).toBe("clean");
    expect(cell?.output?.summary).toBe("Implemented API handlers");
    expect(cell?.output?.patch).toContain("handler");
  });

  test("syncNotebookFromDag keeps local browsing state while refreshing dag snapshots", () => {
    const notebook = createNotebookFromDag([
      {
        index: 1,
        title: "Execution",
        dependencies: [0],
        dependents: [],
        state: "stale",
        version: 2,
        content: "# Execution\n\nDraft",
        artifactRef: null,
        artifact: null,
        versions: [
          {
            version: 1,
            content: "# Execution\n\nInitial",
          },
          {
            version: 2,
            content: "# Execution\n\nDraft",
          },
        ],
      },
    ]);

    const streamed = applyServerEvent(notebook, {
      type: "cell:token",
      cell: 1,
      token: "Planning token",
    });

    const synced = syncNotebookFromDag(streamed, [
      {
        index: 1,
        title: "Execution",
        dependencies: [0],
        dependents: [3],
        state: "running",
        version: 3,
        content: "# Execution\n\nExpanded",
        artifactRef: null,
        artifact: null,
      },
    ]);

    const cell = synced.cells[0];

    expect(cell?.dependents).toEqual([3]);
    expect(cell?.versions).toHaveLength(3);
    expect(cell?.liveOutput?.content).toContain("Planning token");
  });
});
