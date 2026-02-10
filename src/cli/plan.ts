import { err, ok, type Result } from "../core/execution-engine.ts";
import {
  createPlannedVersion,
  loadProject,
  type DriftCellRecord,
  type ProjectError,
} from "./project-store.ts";
import { formatIndexList } from "./format.ts";
import { parseCellIndex, type CliContext } from "./types.ts";

interface ParsedPlanArgs {
  readonly targetCell: number | null;
}

export const runPlanCommand = (args: readonly string[], context: CliContext): number => {
  const parsed = parsePlanArgs(args);
  if (!parsed.ok) {
    context.writeError(parsed.error);
    return 1;
  }

  const projectResult = loadProject(context.cwd);
  if (!projectResult.ok) {
    printProjectError(context, projectResult.error);
    return 1;
  }

  const project = projectResult.value;
  const targets =
    parsed.value.targetCell === null
      ? project.cells.map((cell) => cell.index)
      : [parsed.value.targetCell];

  if (targets.length === 0) {
    context.writeError("No cells available to plan.");
    return 1;
  }

  for (const cellIndex of targets) {
    const sourceCell = project.cells.find((cell) => cell.index === cellIndex);
    if (sourceCell === undefined) {
      context.writeError(`Cell ${cellIndex} was not found.`);
      return 1;
    }

    const planResult = createPlannedVersion({
      project,
      cellIndex,
      nowIso: context.now().toISOString(),
    });

    if (!planResult.ok) {
      printProjectError(context, planResult.error);
      return 1;
    }

    printCellPlanSummary({
      context,
      cell: sourceCell,
      fromVersion: planResult.value.from,
      toVersion: planResult.value.to,
    });
  }

  if (parsed.value.targetCell === null) {
    context.writeLine("");
    context.writeLine(`✅ Planned ${targets.length} cells.`);
  } else {
    context.writeLine("");
    context.writeLine(`✅ Cell ${parsed.value.targetCell} planned. Review with drift edit.`);
  }

  return 0;
};

const parsePlanArgs = (args: readonly string[]): Result<string, ParsedPlanArgs> => {
  if (args.length > 1) {
    return err("Usage: drift plan [cell]");
  }

  const first = args[0];
  if (first === undefined) {
    return ok({ targetCell: null });
  }

  const parsed = parseCellIndex(first);
  if (parsed === null) {
    return err("Cell must be a non-negative number.");
  }

  return ok({ targetCell: parsed });
};

const printCellPlanSummary = (args: {
  readonly context: CliContext;
  readonly cell: DriftCellRecord;
  readonly fromVersion: number;
  readonly toVersion: number;
}): void => {
  args.context.writeLine(
    `⟐ Cell ${args.cell.index}: ${args.cell.title} (v${args.fromVersion} → v${args.toVersion})`,
  );
  args.context.writeLine(
    `  ├─ Deps: ${
      args.cell.dependencies.length === 0 ? "(none)" : formatIndexList(args.cell.dependencies)
    }`,
  );
  args.context.writeLine(
    "  └─ Expanded: added concrete implementation notes, edge cases, and follow-up tasks.",
  );
  args.context.writeLine("");
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
