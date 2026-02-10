import { Either } from "effect";

export type CellState = "clean" | "stale" | "running" | "error";

export interface BuildArtifact {
  readonly files: readonly string[];
  readonly patch: string;
  readonly summary: string;
  readonly timestamp: string;
}

export interface ExecutionCell {
  readonly index: number;
  readonly dependencies: readonly number[];
  readonly dependents: readonly number[];
  readonly state: CellState;
  readonly artifact: BuildArtifact | null;
}

export type ExecutionAttempt = "sequential" | "parallel" | "sequential-retry";

export interface BuildOutput {
  readonly files: readonly string[];
  readonly patch: string;
  readonly timestamp: string;
}

export type CellExecutionErrorTag = "agent-error" | "invalid-diff" | "diff-apply";

export interface CellExecutionError {
  readonly tag: CellExecutionErrorTag;
  readonly cellIndex: number;
  readonly message: string;
}

export interface BuildCallbacks {
  readonly runBuild: (args: {
    readonly cell: ExecutionCell;
    readonly attempt: ExecutionAttempt;
  }) => Either.Either<BuildOutput, CellExecutionError>;
  readonly reviewBuild: (args: {
    readonly cell: ExecutionCell;
    readonly patch: string;
  }) => Either.Either<string, CellExecutionError>;
}

export interface BuildExecutionConfig {
  readonly parallel: boolean;
}

export interface BuildExecutionReport {
  readonly cells: readonly ExecutionCell[];
  readonly executed: readonly number[];
  readonly retried: readonly number[];
  readonly eligibleDescendants: readonly number[];
}

export type EngineError =
  | {
      readonly tag: "missing-cell";
      readonly cellIndex: number;
    }
  | {
      readonly tag: "cycle-detected";
      readonly cells: readonly number[];
    }
  | {
      readonly tag: "cell-error";
      readonly error: CellExecutionError;
    }
  | {
      readonly tag: "ancestor-failed";
      readonly targetCell: number;
      readonly failedCell: number;
      readonly cause: CellExecutionError;
    };

type MutableExecutionCell = {
  index: number;
  dependencies: number[];
  dependents: number[];
  state: CellState;
  artifact: BuildArtifact | null;
};

interface ExecutionContext {
  readonly cells: Map<number, MutableExecutionCell>;
  readonly callbacks: BuildCallbacks;
  readonly config: BuildExecutionConfig;
  readonly executed: number[];
  readonly retried: number[];
}

export const runOneCellBuild = (args: {
  readonly cells: readonly ExecutionCell[];
  readonly targetCell: number;
  readonly callbacks: BuildCallbacks;
  readonly config?: BuildExecutionConfig;
}): Either.Either<BuildExecutionReport, EngineError> => {
  const contextResult = createExecutionContext({
    cells: args.cells,
    callbacks: args.callbacks,
    config: args.config,
  });
  if (Either.isLeft(contextResult)) {
    return Either.left(contextResult.left);
  }

  const context = contextResult.right;
  const targetCell = context.cells.get(args.targetCell);
  if (targetCell === undefined) {
    return Either.left({ tag: "missing-cell", cellIndex: args.targetCell });
  }

  const staleAncestorsResult = collectStaleAncestors(context.cells, args.targetCell);
  if (Either.isLeft(staleAncestorsResult)) {
    return Either.left(staleAncestorsResult.left);
  }

  const ancestorLevelsResult = buildTopologicalLevels(context.cells, staleAncestorsResult.right);
  if (Either.isLeft(ancestorLevelsResult)) {
    return Either.left(ancestorLevelsResult.left);
  }

  const ancestorExecutionResult = executeLevels(context, ancestorLevelsResult.right);
  if (Either.isLeft(ancestorExecutionResult)) {
    if (ancestorExecutionResult.left.tag === "cell-error") {
      const target = context.cells.get(args.targetCell);
      if (target !== undefined && target.state !== "error") {
        target.state = "stale";
      }
      return Either.left({
        tag: "ancestor-failed",
        targetCell: args.targetCell,
        failedCell: ancestorExecutionResult.left.error.cellIndex,
        cause: ancestorExecutionResult.left.error,
      });
    }
    return Either.left(ancestorExecutionResult.left);
  }

  const targetExecutionResult = executeCell(context, args.targetCell, "sequential");
  if (Either.isLeft(targetExecutionResult)) {
    return Either.left({ tag: "cell-error", error: targetExecutionResult.left });
  }

  return Either.right(buildExecutionReport(context));
};

export const runAllStaleBuild = (args: {
  readonly cells: readonly ExecutionCell[];
  readonly callbacks: BuildCallbacks;
  readonly config?: BuildExecutionConfig;
}): Either.Either<BuildExecutionReport, EngineError> => {
  const contextResult = createExecutionContext({
    cells: args.cells,
    callbacks: args.callbacks,
    config: args.config,
  });
  if (Either.isLeft(contextResult)) {
    return Either.left(contextResult.left);
  }

  const context = contextResult.right;
  const staleCells = [...context.cells.values()]
    .filter((cell) => cell.state === "stale")
    .map((cell) => cell.index);

  const levelsResult = buildTopologicalLevels(context.cells, staleCells);
  if (Either.isLeft(levelsResult)) {
    return Either.left(levelsResult.left);
  }

  const executionResult = executeLevels(context, levelsResult.right);
  if (Either.isLeft(executionResult)) {
    return Either.left(executionResult.left);
  }

  return Either.right(buildExecutionReport(context));
};

const createExecutionContext = (args: {
  readonly cells: readonly ExecutionCell[];
  readonly callbacks: BuildCallbacks;
  readonly config?: BuildExecutionConfig;
}): Either.Either<ExecutionContext, EngineError> => {
  const map = new Map<number, MutableExecutionCell>();
  for (const cell of args.cells) {
    map.set(cell.index, cloneCell(cell));
  }

  const dependencyValidation = validateDependencies(map);
  if (Either.isLeft(dependencyValidation)) {
    return Either.left(dependencyValidation.left);
  }

  return Either.right({
    cells: map,
    callbacks: args.callbacks,
    config: {
      parallel: args.config?.parallel ?? false,
    },
    executed: [],
    retried: [],
  });
};

const cloneCell = (cell: ExecutionCell): MutableExecutionCell => ({
  index: cell.index,
  dependencies: [...cell.dependencies],
  dependents: [...cell.dependents],
  state: cell.state,
  artifact: cell.artifact,
});

const validateDependencies = (
  cells: ReadonlyMap<number, MutableExecutionCell>,
): Either.Either<void, EngineError> => {
  for (const cell of cells.values()) {
    for (const dependency of cell.dependencies) {
      if (!cells.has(dependency)) {
        return Either.left({
          tag: "missing-cell",
          cellIndex: dependency,
        });
      }
    }
  }

  return Either.right(undefined);
};

const collectStaleAncestors = (
  cells: ReadonlyMap<number, MutableExecutionCell>,
  targetCellIndex: number,
): Either.Either<readonly number[], EngineError> => {
  const targetCell = cells.get(targetCellIndex);
  if (targetCell === undefined) {
    return Either.left({ tag: "missing-cell", cellIndex: targetCellIndex });
  }

  const staleAncestors = new Set<number>();
  const visited = new Set<number>();
  const stack = [...targetCell.dependencies];

  while (stack.length > 0) {
    const currentIndex = stack.pop();
    if (currentIndex === undefined || visited.has(currentIndex)) {
      continue;
    }

    visited.add(currentIndex);

    const currentCell = cells.get(currentIndex);
    if (currentCell === undefined) {
      return Either.left({ tag: "missing-cell", cellIndex: currentIndex });
    }

    if (currentCell.state === "stale") {
      staleAncestors.add(currentIndex);
    }

    for (const dependency of currentCell.dependencies) {
      stack.push(dependency);
    }
  }

  return Either.right([...staleAncestors]);
};

const buildTopologicalLevels = (
  cells: ReadonlyMap<number, MutableExecutionCell>,
  cellIndexes: readonly number[],
): Either.Either<readonly (readonly number[])[], EngineError> => {
  const nodes = new Set<number>(cellIndexes);
  if (nodes.size === 0) {
    return Either.right([]);
  }

  const indegree = new Map<number, number>();
  const edges = new Map<number, number[]>();

  for (const index of nodes) {
    if (!cells.has(index)) {
      return Either.left({ tag: "missing-cell", cellIndex: index });
    }
    indegree.set(index, 0);
  }

  for (const index of nodes) {
    const cell = cells.get(index);
    if (cell === undefined) {
      return Either.left({ tag: "missing-cell", cellIndex: index });
    }

    for (const dependency of cell.dependencies) {
      if (!nodes.has(dependency)) {
        continue;
      }

      const currentIndegree = indegree.get(index);
      if (currentIndegree === undefined) {
        return Either.left({ tag: "missing-cell", cellIndex: index });
      }
      indegree.set(index, currentIndegree + 1);

      const dependents = edges.get(dependency) ?? [];
      dependents.push(index);
      edges.set(dependency, dependents);
    }
  }

  const levels: number[][] = [];
  let frontier = [...nodes]
    .filter((index) => indegree.get(index) === 0)
    .sort((left, right) => left - right);
  let processed = 0;

  while (frontier.length > 0) {
    levels.push(frontier);
    processed += frontier.length;

    const nextFrontier: number[] = [];
    for (const current of frontier) {
      const dependents = edges.get(current) ?? [];
      for (const dependent of dependents) {
        const currentIndegree = indegree.get(dependent);
        if (currentIndegree === undefined) {
          return Either.left({ tag: "missing-cell", cellIndex: dependent });
        }

        const nextIndegree = currentIndegree - 1;
        indegree.set(dependent, nextIndegree);
        if (nextIndegree === 0) {
          nextFrontier.push(dependent);
        }
      }
    }

    frontier = nextFrontier.sort((left, right) => left - right);
  }

  if (processed !== nodes.size) {
    const cycleCells = [...nodes]
      .filter((index) => (indegree.get(index) ?? 0) > 0)
      .sort((left, right) => left - right);

    return Either.left({ tag: "cycle-detected", cells: cycleCells });
  }

  return Either.right(levels);
};

const executeLevels = (
  context: ExecutionContext,
  levels: readonly (readonly number[])[],
): Either.Either<void, EngineError> => {
  for (const level of levels) {
    const executionResult = context.config.parallel
      ? executeParallelLevel(context, level)
      : executeSequentialLevel(context, level);

    if (Either.isLeft(executionResult)) {
      return executionResult;
    }
  }

  return Either.right(undefined);
};

const executeSequentialLevel = (
  context: ExecutionContext,
  level: readonly number[],
): Either.Either<void, EngineError> => {
  for (const cellIndex of level) {
    const result = executeCell(context, cellIndex, "sequential");
    if (Either.isLeft(result)) {
      return Either.left({ tag: "cell-error", error: result.left });
    }
  }

  return Either.right(undefined);
};

const executeParallelLevel = (
  context: ExecutionContext,
  level: readonly number[],
): Either.Either<void, EngineError> => {
  const retryQueue: number[] = [];

  for (const cellIndex of level) {
    const result = executeCell(context, cellIndex, "parallel");
    if (Either.isRight(result)) {
      continue;
    }

    if (result.left.tag === "diff-apply") {
      const cell = context.cells.get(cellIndex);
      if (cell !== undefined) {
        cell.state = "stale";
      }
      retryQueue.push(cellIndex);
      continue;
    }

    return Either.left({ tag: "cell-error", error: result.left });
  }

  for (const cellIndex of retryQueue) {
    context.retried.push(cellIndex);
    const result = executeCell(context, cellIndex, "sequential-retry");
    if (Either.isLeft(result)) {
      return Either.left({ tag: "cell-error", error: result.left });
    }
  }

  return Either.right(undefined);
};

const executeCell = (
  context: ExecutionContext,
  cellIndex: number,
  attempt: ExecutionAttempt,
): Either.Either<void, CellExecutionError> => {
  const cell = context.cells.get(cellIndex);
  if (cell === undefined) {
    return Either.left({
      tag: "agent-error",
      cellIndex,
      message: `Missing cell ${cellIndex}.`,
    });
  }

  cell.state = "running";
  const buildResult = context.callbacks.runBuild({
    cell: toReadonlyCell(cell),
    attempt,
  });
  if (Either.isLeft(buildResult)) {
    cell.state = "error";
    return buildResult;
  }

  const reviewResult = context.callbacks.reviewBuild({
    cell: toReadonlyCell(cell),
    patch: buildResult.right.patch,
  });
  if (Either.isLeft(reviewResult)) {
    cell.state = "error";
    return reviewResult;
  }

  cell.artifact = {
    files: buildResult.right.files,
    patch: buildResult.right.patch,
    summary: reviewResult.right,
    timestamp: buildResult.right.timestamp,
  };
  cell.state = "clean";
  context.executed.push(cellIndex);

  return Either.right(undefined);
};

const toReadonlyCell = (cell: MutableExecutionCell): ExecutionCell => ({
  index: cell.index,
  dependencies: cell.dependencies,
  dependents: cell.dependents,
  state: cell.state,
  artifact: cell.artifact,
});

const buildExecutionReport = (context: ExecutionContext): BuildExecutionReport => ({
  cells: [...context.cells.values()]
    .sort((left, right) => left.index - right.index)
    .map((cell) => toReadonlyCell(cell)),
  executed: [...context.executed],
  retried: [...context.retried],
  eligibleDescendants: collectEligibleDescendants(context.cells),
});

const collectEligibleDescendants = (
  cells: ReadonlyMap<number, MutableExecutionCell>,
): readonly number[] => {
  const orderedCells = [...cells.values()].sort((left, right) => left.index - right.index);
  const eligible: number[] = [];

  for (const cell of orderedCells) {
    if (cell.state !== "stale") {
      continue;
    }

    let dependenciesAreClean = true;
    for (const dependency of cell.dependencies) {
      const dependencyCell = cells.get(dependency);
      if (dependencyCell === undefined || dependencyCell.state !== "clean") {
        dependenciesAreClean = false;
        break;
      }
    }

    if (dependenciesAreClean) {
      eligible.push(cell.index);
    }
  }

  return eligible;
};
