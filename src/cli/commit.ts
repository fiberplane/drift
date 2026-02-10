import {
  loadProject,
  updateCellCommitRef,
  type DriftCellRecord,
  type ProjectError,
} from "./project-store.ts";
import { formatIndexList } from "./format.ts";
import { parseCellIndex, type CliContext } from "./types.ts";
import { commitFilesWithDetectedVcs } from "./vcs.ts";

export const runCommitCommand = (args: readonly string[], context: CliContext): number => {
  const requestedCells: number[] = [];

  for (const arg of args) {
    const parsed = parseCellIndex(arg);
    if (parsed === null) {
      context.writeError(`Cell must be a non-negative number: ${arg}`);
      return 1;
    }
    requestedCells.push(parsed);
  }

  const projectResult = loadProject(context.cwd);
  if (!projectResult.ok) {
    printProjectError(context, projectResult.error);
    return 1;
  }

  const project = projectResult.value;

  const targetCells =
    requestedCells.length === 0
      ? project.cells.filter((cell) => cell.artifact !== null && cell.artifactRef === null)
      : requestedCells
          .map((requestedIndex) => project.cells.find((cell) => cell.index === requestedIndex))
          .filter((candidate): candidate is DriftCellRecord => candidate !== undefined);

  if (targetCells.length === 0) {
    context.writeError("No built cells with uncommitted artifacts were found.");
    return 1;
  }

  if (requestedCells.length > 0 && targetCells.length !== requestedCells.length) {
    const found = new Set(targetCells.map((cell) => cell.index));
    const missing = requestedCells.filter((index) => !found.has(index));
    context.writeError(`Unknown or unbuildable cells: ${formatIndexList(missing)}`);
    return 1;
  }

  if (targetCells.some((cell) => cell.artifact === null)) {
    context.writeError("All selected cells must be built before commit.");
    return 1;
  }

  const allFiles = new Set<string>();
  for (const cell of targetCells) {
    const artifact = cell.artifact;
    if (artifact === null) {
      continue;
    }

    for (const file of artifact.files) {
      allFiles.add(file);
    }
  }

  if (allFiles.size === 0) {
    context.writeError("Selected cells do not have tracked files to commit.");
    return 1;
  }

  const commitMessage = createCommitMessage(targetCells);
  const commitFiles = context.dependencies?.commitFiles ?? commitFilesWithDetectedVcs;
  const commitResult = commitFiles({
    cwd: context.cwd,
    files: [...allFiles],
    message: commitMessage,
  });

  if (!commitResult.ok) {
    context.writeError(`Commit failed: ${commitResult.message}`);
    return 1;
  }

  const updateResult = updateCellCommitRef({
    project,
    cellIndexes: targetCells.map((cell) => cell.index),
    ref: commitResult.ref,
  });

  if (!updateResult.ok) {
    printProjectError(context, updateResult.error);
    return 1;
  }

  printCommitSummary({
    context,
    cells: targetCells,
    ref: commitResult.ref,
    files: [...allFiles],
  });

  return 0;
};

const createCommitMessage = (cells: readonly DriftCellRecord[]): string => {
  if (cells.length === 1) {
    const cell = cells[0];
    if (cell === undefined) {
      return "drift: cell update";
    }

    return `drift: cell ${cell.index} — ${cell.title}`;
  }

  const indexes = cells.map((cell) => cell.index);
  const titles = cells.map((cell) => cell.title);

  return `drift: cells ${formatIndexList(indexes)} — ${titles.join(", ")}`;
};

const printCommitSummary = (args: {
  readonly context: CliContext;
  readonly cells: readonly DriftCellRecord[];
  readonly ref: string;
  readonly files: readonly string[];
}): void => {
  const indexes = args.cells.map((cell) => cell.index);
  const label =
    args.cells.length === 1
      ? `✓ Cell ${indexes[0]}: ${args.cells[0]?.title ?? ""}`
      : `✓ Cells ${formatIndexList(indexes)} → single commit`;

  args.context.writeLine(label);
  args.context.writeLine(`  ├─ Files: ${args.files.join(", ")}`);
  args.context.writeLine(`  ├─ Commit: ${args.ref}`);
  args.context.writeLine(
    `  └─ Ref saved to ${
      args.cells.length === 1
        ? `.drift/cells/${indexes[0]}/artifacts/build.yaml`
        : "all selected cells"
    }`,
  );
  args.context.writeLine("");
  args.context.writeLine(
    `✅ ${args.cells.length} cell${args.cells.length === 1 ? "" : "s"} committed.`,
  );
};

const printProjectError = (context: CliContext, error: ProjectError): void => {
  switch (error.tag) {
    case "missing-drift":
      context.writeError(`Missing Drift project: ${error.path}`);
      return;
    case "missing-cells":
      context.writeError(`Missing cell directory: ${error.path}`);
      return;
    case "missing-cell":
      context.writeError(`Cell ${error.cellIndex} was not found.`);
      return;
    case "invalid-markdown":
      context.writeError(`Invalid markdown input: ${error.message}`);
      return;
    case "already-exists":
      context.writeError(`Path already exists: ${error.path}`);
      return;
    case "missing-file":
      context.writeError(`Missing file: ${error.path}`);
      return;
  }
};
