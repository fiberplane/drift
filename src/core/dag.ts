import { Either } from "effect";

import { DagCycleError } from "./errors.ts";
import type { Cell } from "./schemas.ts";

export interface DagGraph {
  readonly dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>;
  readonly dependentsByCell: ReadonlyMap<number, ReadonlyArray<number>>;
  readonly levels: ReadonlyArray<ReadonlyArray<number>>;
}

export const orderCellsByIndex = (cells: ReadonlyArray<Cell>): ReadonlyArray<Cell> =>
  [...cells].sort((left, right) => left.index - right.index);

export const getCellByIndex = (cells: ReadonlyArray<Cell>, index: number): Cell | null => {
  for (const cell of cells) {
    if (cell.index === index) {
      return cell;
    }
  }

  return null;
};

export const buildDagGraph = (
  dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>,
): Either.Either<DagGraph, DagCycleError> => {
  const normalizedDependencies = normalizeDependencyMap(dependenciesByCell);
  const dependentsByCell = computeDependents(normalizedDependencies);
  const levelsResult = topologicalLevels(normalizedDependencies, dependentsByCell);

  if (Either.isLeft(levelsResult)) {
    return Either.left(levelsResult.left);
  }

  return Either.right({
    dependenciesByCell: normalizedDependencies,
    dependentsByCell,
    levels: levelsResult.right,
  });
};

export const computeDependents = (
  dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>,
): ReadonlyMap<number, ReadonlyArray<number>> => {
  const orderedIndexes = [...dependenciesByCell.keys()].sort((left, right) => left - right);
  const mutableDependents = new Map<number, number[]>();

  for (const cellIndex of orderedIndexes) {
    mutableDependents.set(cellIndex, []);
  }

  for (const cellIndex of orderedIndexes) {
    const dependencies = dependenciesByCell.get(cellIndex) ?? [];

    for (const dependency of dependencies) {
      const dependents = mutableDependents.get(dependency);
      if (dependents === undefined) {
        continue;
      }

      dependents.push(cellIndex);
    }
  }

  const normalizedDependents = new Map<number, ReadonlyArray<number>>();

  for (const cellIndex of orderedIndexes) {
    const dependents = mutableDependents.get(cellIndex) ?? [];
    normalizedDependents.set(
      cellIndex,
      [...new Set(dependents)].sort((left, right) => left - right),
    );
  }

  return normalizedDependents;
};

export const topologicalLevels = (
  dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>,
  dependentsByCell: ReadonlyMap<number, ReadonlyArray<number>>,
): Either.Either<ReadonlyArray<ReadonlyArray<number>>, DagCycleError> => {
  const indegree = new Map<number, number>();

  for (const cellIndex of dependenciesByCell.keys()) {
    indegree.set(cellIndex, 0);
  }

  for (const [cellIndex, dependencies] of dependenciesByCell) {
    for (const dependency of dependencies) {
      if (!indegree.has(dependency)) {
        continue;
      }

      const currentIndegree = indegree.get(cellIndex) ?? 0;
      indegree.set(cellIndex, currentIndegree + 1);
    }
  }

  const levels: number[][] = [];
  let processed = 0;
  let frontier = [...indegree.entries()]
    .filter((entry) => entry[1] === 0)
    .map((entry) => entry[0])
    .sort((left, right) => left - right);

  while (frontier.length > 0) {
    levels.push(frontier);
    processed += frontier.length;

    const nextFrontier: number[] = [];

    for (const cellIndex of frontier) {
      const dependents = dependentsByCell.get(cellIndex) ?? [];

      for (const dependent of dependents) {
        const currentIndegree = indegree.get(dependent);
        if (currentIndegree === undefined) {
          continue;
        }

        const nextIndegree = currentIndegree - 1;
        indegree.set(dependent, nextIndegree);

        if (nextIndegree === 0) {
          nextFrontier.push(dependent);
        }
      }
    }

    frontier = [...new Set(nextFrontier)].sort((left, right) => left - right);
  }

  if (processed !== indegree.size) {
    const cycleCells = [...indegree.entries()]
      .filter((entry) => entry[1] > 0)
      .map((entry) => entry[0])
      .sort((left, right) => left - right);

    return Either.left(new DagCycleError({ cells: cycleCells }));
  }

  return Either.right(levels);
};

export const applyDagToCells = (args: {
  readonly cells: ReadonlyArray<Cell>;
  readonly dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>;
  readonly dependentsByCell: ReadonlyMap<number, ReadonlyArray<number>>;
}): ReadonlyArray<Cell> =>
  args.cells.map((cell) => ({
    ...cell,
    dependencies: [...(args.dependenciesByCell.get(cell.index) ?? [])],
    dependents: [...(args.dependentsByCell.get(cell.index) ?? [])],
  }));

const normalizeDependencyMap = (
  dependenciesByCell: ReadonlyMap<number, ReadonlyArray<number>>,
): ReadonlyMap<number, ReadonlyArray<number>> => {
  const orderedIndexes = [...dependenciesByCell.keys()].sort((left, right) => left - right);
  const knownIndexes = new Set<number>(orderedIndexes);
  const normalized = new Map<number, ReadonlyArray<number>>();

  for (const cellIndex of orderedIndexes) {
    const dependencies = dependenciesByCell.get(cellIndex) ?? [];
    const deduped = new Set<number>();

    for (const dependency of dependencies) {
      if (dependency === cellIndex) {
        continue;
      }

      if (!knownIndexes.has(dependency)) {
        continue;
      }

      deduped.add(dependency);
    }

    normalized.set(
      cellIndex,
      [...deduped].sort((left, right) => left - right),
    );
  }

  return normalized;
};
