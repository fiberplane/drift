export type UiCellState = "clean" | "stale" | "running" | "error";

export type CellAction = "plan" | "build" | "commit";

export type StreamingCellAction = Extract<CellAction, "plan" | "build">;

export type ToolbarAction = "plan-all" | "build-all" | "commit-all";

export interface UiCellVersion {
  readonly version: number;
  readonly content: string;
}

export interface UiCellLiveOutput {
  readonly action: StreamingCellAction;
  readonly content: string;
}

export interface UiCellOutput {
  readonly summary: string;
  readonly patch: string | null;
  readonly commitRef: string | null;
}

export interface UiCell {
  readonly index: number;
  readonly title: string;
  readonly dependencies: ReadonlyArray<number>;
  readonly dependents: ReadonlyArray<number>;
  readonly state: UiCellState;
  readonly input: string;
  readonly output: UiCellOutput | null;
  readonly liveOutput: UiCellLiveOutput | null;
  readonly versions: ReadonlyArray<UiCellVersion>;
  readonly selectedVersion: number | null;
}

export interface NotebookViewModel {
  readonly cells: ReadonlyArray<UiCell>;
  readonly activeCell: number | null;
}

export interface CellActionRequest {
  readonly action: CellAction;
  readonly cellIndex: number;
}

export interface CellInputChange {
  readonly cellIndex: number;
  readonly value: string;
}

export interface CellVersionSelectionChange {
  readonly cellIndex: number;
  readonly version: number | null;
}

export interface CellVersionRestoreRequest {
  readonly cellIndex: number;
  readonly version: number;
}

export interface ToolbarActionRequest {
  readonly action: ToolbarAction;
}

export interface NotebookToolbarState {
  readonly staleCount: number;
  readonly uncommittedCount: number;
  readonly canPlanAll: boolean;
  readonly canBuildAll: boolean;
  readonly canCommitAll: boolean;
}
