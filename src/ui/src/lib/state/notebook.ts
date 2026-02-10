import type {
  NotebookToolbarState,
  NotebookViewModel,
  UiCell,
  UiCellOutput,
  UiCellState,
} from "../types.ts";

export const createInitialNotebook = (cells: ReadonlyArray<UiCell> = []): NotebookViewModel => {
  const firstCell = cells[0];

  return {
    cells: [...cells],
    activeCell: firstCell === undefined ? null : firstCell.index,
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
      state: output === null ? cell.state : "clean",
    };
  }),
});

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
