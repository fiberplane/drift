import type {
  NotebookToolbarState,
  NotebookViewModel,
  StreamingCellAction,
  UiCell,
  UiCellOutput,
  UiCellState,
  UiCellVersion,
} from "../types.ts";

export const createInitialNotebook = (cells: ReadonlyArray<UiCell> = []): NotebookViewModel => {
  const normalized = normalizeCells(cells);
  const firstCell = normalized[0];

  return {
    cells: normalized,
    activeCell: firstCell === undefined ? null : firstCell.index,
  };
};

export const replaceNotebookCells = (
  notebook: NotebookViewModel,
  cells: ReadonlyArray<UiCell>,
): NotebookViewModel => {
  const normalized = normalizeCells(cells);
  const activeExists = normalized.some((cell) => cell.index === notebook.activeCell);
  const firstCell = normalized[0];

  return {
    ...notebook,
    cells: normalized,
    activeCell: activeExists
      ? notebook.activeCell
      : firstCell === undefined
        ? null
        : firstCell.index,
  };
};

export const setActiveCell = (
  notebook: NotebookViewModel,
  cellIndex: number,
): NotebookViewModel => {
  const hasCell = notebook.cells.some((cell) => cell.index === cellIndex);
  if (!hasCell) {
    return notebook;
  }

  return {
    ...notebook,
    activeCell: cellIndex,
  };
};

export const updateCellInput = (
  notebook: NotebookViewModel,
  cellIndex: number,
  input: string,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    return {
      ...cell,
      input,
      state: "stale",
      selectedVersion: null,
      liveOutput: null,
      output: null,
    };
  }),
});

export const setCellState = (
  notebook: NotebookViewModel,
  cellIndex: number,
  state: UiCellState,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) =>
    cell.index === cellIndex
      ? {
          ...cell,
          state,
        }
      : cell,
  ),
});

export const setCellOutput = (
  notebook: NotebookViewModel,
  cellIndex: number,
  output: UiCellOutput | null,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    return {
      ...cell,
      output,
      liveOutput: null,
      state: output === null ? cell.state : "clean",
    };
  }),
});

export const setCellCommitRef = (
  notebook: NotebookViewModel,
  cellIndex: number,
  commitRef: string,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex || cell.output === null) {
      return cell;
    }

    return {
      ...cell,
      output: {
        ...cell.output,
        commitRef,
      },
    };
  }),
});

export const startCellLiveOutput = (
  notebook: NotebookViewModel,
  cellIndex: number,
  action: StreamingCellAction,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    return {
      ...cell,
      state: "running",
      liveOutput: {
        action,
        content: "",
      },
    };
  }),
});

export const appendCellLiveToken = (
  notebook: NotebookViewModel,
  cellIndex: number,
  token: string,
): NotebookViewModel => {
  if (token === "") {
    return notebook;
  }

  return {
    ...notebook,
    cells: notebook.cells.map((cell) => {
      if (cell.index !== cellIndex || cell.liveOutput === null) {
        return cell;
      }

      return {
        ...cell,
        liveOutput: {
          ...cell.liveOutput,
          content: `${cell.liveOutput.content}${token}`,
        },
      };
    }),
  };
};

export const clearCellLiveOutput = (
  notebook: NotebookViewModel,
  cellIndex: number,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) =>
    cell.index === cellIndex
      ? {
          ...cell,
          liveOutput: null,
        }
      : cell,
  ),
});

export const appendCellVersion = (
  notebook: NotebookViewModel,
  cellIndex: number,
  content: string,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    const latestVersion = getLatestVersionNumber(cell);

    return {
      ...cell,
      input: content,
      versions: [
        ...cell.versions,
        {
          version: latestVersion + 1,
          content,
        },
      ],
      selectedVersion: null,
      liveOutput: null,
      output: null,
      state: "stale",
    };
  }),
});

export const selectCellVersion = (
  notebook: NotebookViewModel,
  cellIndex: number,
  version: number | null,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    if (version === null) {
      return {
        ...cell,
        selectedVersion: null,
      };
    }

    const target = cell.versions.find((candidate) => candidate.version === version);
    if (target === undefined) {
      return cell;
    }

    const latestVersion = getLatestVersionNumber(cell);

    return {
      ...cell,
      selectedVersion: target.version === latestVersion ? null : target.version,
    };
  }),
});

export const stepCellVersion = (
  notebook: NotebookViewModel,
  cellIndex: number,
  direction: -1 | 1,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex || cell.versions.length === 0) {
      return cell;
    }

    const versionNumbers = cell.versions.map((version) => version.version);
    const latestVersion = getLatestVersionNumber(cell);
    const currentVersion = cell.selectedVersion ?? latestVersion;

    const currentIndex = versionNumbers.findIndex((version) => version === currentVersion);
    const safeCurrentIndex = currentIndex < 0 ? versionNumbers.length - 1 : currentIndex;
    const nextIndex = Math.max(
      0,
      Math.min(versionNumbers.length - 1, safeCurrentIndex + direction),
    );
    const nextVersion = versionNumbers[nextIndex];

    if (nextVersion === undefined) {
      return cell;
    }

    return {
      ...cell,
      selectedVersion: nextVersion === latestVersion ? null : nextVersion,
    };
  }),
});

export const restoreCellVersion = (
  notebook: NotebookViewModel,
  cellIndex: number,
  version: number,
): NotebookViewModel => ({
  ...notebook,
  cells: notebook.cells.map((cell) => {
    if (cell.index !== cellIndex) {
      return cell;
    }

    const target = cell.versions.find((candidate) => candidate.version === version);
    if (target === undefined) {
      return cell;
    }

    const latestVersion = getLatestVersionNumber(cell);
    const backupVersion = latestVersion + 1;
    const restoredVersion = latestVersion + 2;

    return {
      ...cell,
      input: target.content,
      versions: [
        ...cell.versions,
        {
          version: backupVersion,
          content: cell.input,
        },
        {
          version: restoredVersion,
          content: target.content,
        },
      ],
      selectedVersion: null,
      liveOutput: null,
      output: null,
      state: "stale",
    };
  }),
});

export const getCellDisplayedInput = (cell: UiCell): string => {
  if (cell.selectedVersion === null) {
    return cell.input;
  }

  const selected = cell.versions.find((candidate) => candidate.version === cell.selectedVersion);
  return selected?.content ?? cell.input;
};

export const isViewingVersionHistory = (cell: UiCell): boolean => cell.selectedVersion !== null;

export const listStaleCellIndexes = (notebook: NotebookViewModel): ReadonlyArray<number> =>
  notebook.cells
    .filter((cell) => cell.state === "stale")
    .map((cell) => cell.index)
    .sort((left, right) => left - right);

export const listUncommittedCellIndexes = (notebook: NotebookViewModel): ReadonlyArray<number> =>
  notebook.cells
    .filter((cell) => isCellCommitReady(cell))
    .map((cell) => cell.index)
    .sort((left, right) => left - right);

export const createToolbarState = (notebook: NotebookViewModel): NotebookToolbarState => {
  const staleCount = listStaleCellIndexes(notebook).length;
  const uncommittedCount = listUncommittedCellIndexes(notebook).length;

  return {
    staleCount,
    uncommittedCount,
    canPlanAll: staleCount > 0,
    canBuildAll: staleCount > 0,
    canCommitAll: uncommittedCount > 0,
  };
};

export const isCellCommitReady = (cell: UiCell): boolean =>
  cell.state === "clean" && cell.output !== null && cell.output.commitRef === null;

const normalizeCells = (cells: ReadonlyArray<UiCell>): ReadonlyArray<UiCell> =>
  [...cells].map((cell) => normalizeCell(cell)).sort((left, right) => left.index - right.index);

const normalizeCell = (cell: UiCell): UiCell => {
  const versions = normalizeVersions(cell.versions, cell.input);
  const latestVersion = versions[versions.length - 1];
  const selectedVersion =
    cell.selectedVersion === null ||
    versions.some((version) => version.version === cell.selectedVersion)
      ? cell.selectedVersion
      : null;

  return {
    ...cell,
    dependents: [...cell.dependents].sort((left, right) => left - right),
    versions,
    selectedVersion:
      latestVersion !== undefined && selectedVersion === latestVersion.version
        ? null
        : selectedVersion,
  };
};

const normalizeVersions = (
  versions: ReadonlyArray<UiCellVersion>,
  fallbackContent: string,
): ReadonlyArray<UiCellVersion> => {
  if (versions.length === 0) {
    return [
      {
        version: 1,
        content: fallbackContent,
      },
    ];
  }

  return [...versions].sort((left, right) => left.version - right.version);
};

const getLatestVersionNumber = (cell: UiCell): number => {
  const latest = cell.versions[cell.versions.length - 1];
  return latest?.version ?? 1;
};
