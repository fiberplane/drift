import {
  appendCellLiveToken,
  appendCellVersion,
  clearCellLiveOutput,
  createInitialNotebook,
  replaceNotebookCells,
  setCellCommitRef,
  setCellOutput,
  setCellState,
  startCellLiveOutput,
} from "./notebook.ts";
import type { NotebookViewModel, UiCell, UiCellState, UiCellVersion } from "../types.ts";

export interface WsDagCellVersionSnapshot {
  readonly version: number;
  readonly content: string;
}

export interface WsBuildArtifactSnapshot {
  readonly summary: string;
  readonly patch: string;
}

export interface WsDagCellSnapshot {
  readonly index: number;
  readonly title: string;
  readonly dependencies: ReadonlyArray<number>;
  readonly dependents: ReadonlyArray<number>;
  readonly state: UiCellState;
  readonly version: number;
  readonly content?: string;
  readonly artifactRef: string | null;
  readonly artifact: WsBuildArtifactSnapshot | null;
  readonly versions?: ReadonlyArray<WsDagCellVersionSnapshot>;
}

export type WsServerEvent =
  | {
      readonly type: "cell:state";
      readonly cell: number;
      readonly state: UiCellState;
    }
  | {
      readonly type: "cell:token";
      readonly cell: number;
      readonly token: string;
    }
  | {
      readonly type: "cell:complete";
      readonly cell: number;
      readonly action: "plan" | "build" | "commit";
      readonly artifact: WsBuildArtifactSnapshot | null;
    }
  | {
      readonly type: "cell:error";
      readonly cell: number;
      readonly error: string;
    }
  | {
      readonly type: "dag:updated";
      readonly cells: ReadonlyArray<WsDagCellSnapshot>;
    };

export const createNotebookFromDag = (cells: ReadonlyArray<WsDagCellSnapshot>): NotebookViewModel =>
  createInitialNotebook(cells.map((cell) => toUiCell(cell, undefined)));

export const syncNotebookFromDag = (
  notebook: NotebookViewModel,
  cells: ReadonlyArray<WsDagCellSnapshot>,
): NotebookViewModel => {
  const previousByIndex = new Map<number, UiCell>();

  for (const cell of notebook.cells) {
    previousByIndex.set(cell.index, cell);
  }

  return replaceNotebookCells(
    notebook,
    cells.map((cell) => toUiCell(cell, previousByIndex.get(cell.index))),
  );
};

export const applyServerEvent = (
  notebook: NotebookViewModel,
  event: WsServerEvent,
): NotebookViewModel => {
  switch (event.type) {
    case "cell:state":
      return setCellState(notebook, event.cell, event.state);
    case "cell:token": {
      const candidate = notebook.cells.find((cell) => cell.index === event.cell);
      const withRunningState =
        candidate?.liveOutput === null || candidate?.liveOutput === undefined
          ? startCellLiveOutput(notebook, event.cell, "build")
          : notebook;

      return appendCellLiveToken(withRunningState, event.cell, event.token);
    }
    case "cell:complete": {
      if (event.action === "build" && event.artifact !== null) {
        const built = setCellOutput(notebook, event.cell, {
          summary: event.artifact.summary,
          patch: event.artifact.patch,
          commitRef: null,
        });

        return clearCellLiveOutput(built, event.cell);
      }

      if (event.action === "plan") {
        const targetCell = notebook.cells.find((cell) => cell.index === event.cell);
        if (targetCell === undefined) {
          return clearCellLiveOutput(notebook, event.cell);
        }

        const expandedPlan = `${targetCell.input.trimEnd()}\n\n<!-- drift:planned from live stream -->\n`;
        const planned = appendCellVersion(notebook, event.cell, expandedPlan);

        return clearCellLiveOutput(planned, event.cell);
      }

      if (event.action === "commit") {
        const now = new Date();
        const commitRef = now.toISOString().slice(2, 19).replaceAll(":", "").replaceAll("-", "");
        const committed = setCellCommitRef(notebook, event.cell, commitRef);

        return clearCellLiveOutput(committed, event.cell);
      }

      return clearCellLiveOutput(notebook, event.cell);
    }
    case "cell:error": {
      const withError = setCellState(notebook, event.cell, "error");
      return appendCellLiveToken(withError, event.cell, `\n${event.error}`);
    }
    case "dag:updated":
      return syncNotebookFromDag(notebook, event.cells);
  }
};

const toUiCell = (snapshot: WsDagCellSnapshot, previous: UiCell | undefined): UiCell => {
  const versions = normalizeSnapshotVersions({
    snapshot,
    fallbackContent: previous?.input ?? "",
    previousVersions: previous?.versions ?? [],
  });

  const latestVersion = versions[versions.length - 1];
  const input = snapshot.content ?? latestVersion?.content ?? previous?.input ?? "";

  return {
    index: snapshot.index,
    title: snapshot.title,
    dependencies: [...snapshot.dependencies],
    dependents: [...snapshot.dependents],
    state: snapshot.state,
    input,
    output:
      snapshot.artifact === null
        ? (previous?.output ?? null)
        : {
            summary: snapshot.artifact.summary,
            patch: snapshot.artifact.patch,
            commitRef: snapshot.artifactRef,
          },
    liveOutput: previous?.liveOutput ?? null,
    versions,
    selectedVersion: previous?.selectedVersion ?? null,
  };
};

const normalizeSnapshotVersions = (args: {
  readonly snapshot: WsDagCellSnapshot;
  readonly fallbackContent: string;
  readonly previousVersions: ReadonlyArray<UiCellVersion>;
}): ReadonlyArray<UiCellVersion> => {
  const explicit = args.snapshot.versions;
  if (explicit !== undefined && explicit.length > 0) {
    return [...explicit].sort((left, right) => left.version - right.version);
  }

  const targetCount = Math.max(args.snapshot.version, 1);
  const previousByVersion = new Map<number, string>();

  for (const previousVersion of args.previousVersions) {
    previousByVersion.set(previousVersion.version, previousVersion.content);
  }

  const fallback =
    args.snapshot.content ??
    args.previousVersions[args.previousVersions.length - 1]?.content ??
    args.fallbackContent;

  const versions: UiCellVersion[] = [];

  for (let version = 1; version <= targetCount; version += 1) {
    const previousContent = previousByVersion.get(version);

    versions.push({
      version,
      content:
        previousContent ??
        (version === targetCount
          ? fallback
          : `# Cell ${args.snapshot.index} v${version}\n\nPlan snapshot.`),
    });
  }

  return versions;
};
