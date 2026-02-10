import { Either } from "effect";

import { formatAgentError, resolveAgentSelection, streamAgentCall } from "../agent/index.ts";
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
  if (Either.isLeft(parsed)) {
    context.writeError(parsed.left);
    return 1;
  }

  const projectResult = loadProject(context.cwd);
  if (Either.isLeft(projectResult)) {
    printProjectError(context, projectResult.left);
    return 1;
  }

  const project = projectResult.right;
  const targets =
    parsed.right.targetCell === null
      ? project.cells.map((cell) => cell.index)
      : [parsed.right.targetCell];

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

    const selection = resolveAgentSelection({
      configRaw: project.configRaw,
      cellContent: sourceCell.content,
    });

    const streamedAgent = streamAgentCall({
      request: {
        cellIndex,
        call: "plan",
        prompt: sourceCell.content,
        backend: selection.backend,
        model: selection.model,
      },
    });

    if (!streamedAgent.ok) {
      context.writeError(
        `Cell ${cellIndex} failed (agent-error): ${formatAgentError(streamedAgent.error)}`,
      );
      return 1;
    }

    const planResult = createPlannedVersion({
      project,
      cellIndex,
      nowIso: context.now().toISOString(),
    });

    if (Either.isLeft(planResult)) {
      printProjectError(context, planResult.left);
      return 1;
    }

    printCellPlanSummary({
      context,
      cell: sourceCell,
      fromVersion: planResult.right.from,
      toVersion: planResult.right.to,
      backend: selection.backend,
      model: selection.model,
      tokens: streamedAgent.value,
    });
  }

  if (parsed.right.targetCell === null) {
    context.writeLine("");
    context.writeLine(`✅ Planned ${targets.length} cells.`);
  } else {
    context.writeLine("");
    context.writeLine(`✅ Cell ${parsed.right.targetCell} planned. Review with drift edit.`);
  }

  return 0;
};

const parsePlanArgs = (args: readonly string[]): Either.Either<ParsedPlanArgs, string> => {
  if (args.length > 1) {
    return Either.left("Usage: drift plan [cell]");
  }

  const first = args[0];
  if (first === undefined) {
    return Either.right({ targetCell: null });
  }

  const parsed = parseCellIndex(first);
  if (parsed === null) {
    return Either.left("Cell must be a non-negative number.");
  }

  return Either.right({ targetCell: parsed });
};

const printCellPlanSummary = (args: {
  readonly context: CliContext;
  readonly cell: DriftCellRecord;
  readonly fromVersion: number;
  readonly toVersion: number;
  readonly backend: string;
  readonly model: string | null;
  readonly tokens: ReadonlyArray<string>;
}): void => {
  const modelLabel = args.model === null ? "" : ` (${args.model})`;

  args.context.writeLine(
    `⟐ Cell ${args.cell.index}: ${args.cell.title} (v${args.fromVersion} → v${args.toVersion})`,
  );
  args.context.writeLine(
    `  ├─ Deps: ${
      args.cell.dependencies.length === 0 ? "(none)" : formatIndexList(args.cell.dependencies)
    }`,
  );
  args.context.writeLine(`  ├─ Agent: ${args.backend}${modelLabel}`);

  for (const token of args.tokens) {
    args.context.writeLine(`  │  ${token}`);
  }

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
