import { join } from "node:path";

import { formatAgentError, resolveAgentSelection, streamAgentCall } from "../agent/index.ts";
import {
  err,
  ok,
  runAllStaleBuild,
  runOneCellBuild,
  type BuildCallbacks,
  type BuildExecutionReport,
  type EngineError,
  type ExecutionCell,
  type Result,
} from "../core/execution-engine.ts";
import { applyUnifiedDiff } from "../core/diff.ts";
import { formatIndexList, summarizeDiff } from "./format.ts";
import {
  ensureGeneratedFile,
  initializeProjectFromMarkdown,
  loadProject,
  persistExecutionArtifacts,
  type DriftCellRecord,
  type DriftProject,
  type ProjectError,
} from "./project-store.ts";
import { parseCellIndex, type CliContext } from "./types.ts";

interface ParsedRunArgs {
  readonly targetCell: number | null;
  readonly markdownPath: string | null;
  readonly stream: boolean;
}

export const runRunCommand = (args: readonly string[], context: CliContext): number => {
  const parsedArgs = parseRunArgs(args);
  if (!parsedArgs.ok) {
    context.writeError(parsedArgs.error);
    return 1;
  }

  if (parsedArgs.value.markdownPath !== null) {
    const markdownPath = join(context.cwd, parsedArgs.value.markdownPath);
    const initResult = initializeProjectFromMarkdown({
      rootDir: context.cwd,
      markdownPath,
      nowIso: context.now().toISOString(),
    });

    if (!initResult.ok) {
      printProjectError(context, initResult.error);
      return 1;
    }

    context.writeLine(`✓ Initialized .drift from ${parsedArgs.value.markdownPath}`);
  }

  const projectResult = loadProject(context.cwd);
  if (!projectResult.ok) {
    printProjectError(context, projectResult.error);
    return 1;
  }

  const project = projectResult.value;
  const callbacks = createBuildCallbacks({
    project,
    stream: parsedArgs.value.stream,
    context,
  });

  const executionCells = project.cells.map(toExecutionCell);

  const report =
    parsedArgs.value.targetCell === null
      ? runAllStaleBuild({
          cells: executionCells,
          callbacks,
        })
      : runOneCellBuild({
          cells: executionCells,
          targetCell: parsedArgs.value.targetCell,
          callbacks,
        });

  if (!report.ok) {
    printEngineError(context, report.error);
    return 1;
  }

  const persistResult = persistExecutionArtifacts({
    project,
    executedCellIndexes: report.value.executed,
    updatedCells: report.value.cells,
  });

  if (!persistResult.ok) {
    printProjectError(context, persistResult.error);
    return 1;
  }

  if (parsedArgs.value.targetCell === null) {
    printRunAllSummary({ context, project, report: report.value });
  } else {
    printRunOneSummary({
      context,
      project,
      report: report.value,
      targetCell: parsedArgs.value.targetCell,
    });
  }

  return 0;
};

const parseRunArgs = (args: readonly string[]): Result<string, ParsedRunArgs> => {
  let stream = true;
  const positional: string[] = [];

  for (const arg of args) {
    if (arg === "--no-stream") {
      stream = false;
      continue;
    }

    positional.push(arg);
  }

  if (positional.length > 1) {
    return err("Usage: drift run [cell|file.md] [--no-stream]");
  }

  const first = positional[0];
  if (first === undefined) {
    return ok({ targetCell: null, markdownPath: null, stream });
  }

  const asCell = parseCellIndex(first);
  if (asCell !== null) {
    return ok({ targetCell: asCell, markdownPath: null, stream });
  }

  return ok({ targetCell: null, markdownPath: first, stream });
};

const createBuildCallbacks = (args: {
  readonly project: DriftProject;
  readonly stream: boolean;
  readonly context: CliContext;
}): BuildCallbacks => {
  const cellsByIndex = new Map<number, DriftCellRecord>();
  for (const cell of args.project.cells) {
    cellsByIndex.set(cell.index, cell);
  }

  return {
    runBuild: ({ cell }) => {
      const sourceCell = cellsByIndex.get(cell.index);
      if (sourceCell === undefined) {
        return err({
          tag: "agent-error",
          cellIndex: cell.index,
          message: `Cell ${cell.index} was not found in project map.`,
        });
      }

      const selection = resolveAgentSelection({
        configRaw: args.project.configRaw,
        cellContent: sourceCell.content,
      });

      const streamedAgent = streamAgentCall({
        request: {
          cellIndex: sourceCell.index,
          call: "build",
          prompt: sourceCell.content,
          backend: selection.backend,
          model: selection.model,
        },
      });

      if (!streamedAgent.ok) {
        return err({
          tag: "agent-error",
          cellIndex: sourceCell.index,
          message: formatAgentError(streamedAgent.error),
        });
      }

      if (args.stream) {
        const modelLabel = selection.model === null ? "" : ` (${selection.model})`;

        args.context.writeLine("");
        args.context.writeLine(`▶ Cell ${sourceCell.index}: ${sourceCell.title}`);
        args.context.writeLine(
          `  ├─ Deps: ${
            sourceCell.dependencies.length === 0
              ? "(none)"
              : formatIndexList(sourceCell.dependencies)
          }`,
        );
        args.context.writeLine(`  ├─ Agent: ${selection.backend}${modelLabel}`);

        for (const token of streamedAgent.value) {
          args.context.writeLine(`  │  ${token}`);
        }

        args.context.writeLine("  │");
      }

      const generated = ensureGeneratedFile({
        cellIndex: sourceCell.index,
        title: sourceCell.title,
        content: sourceCell.content,
      });

      if (args.stream) {
        for (const patchLine of generated.patch.trimEnd().split("\n")) {
          args.context.writeLine(`  │  ${patchLine}`);
        }
      }

      const applyResult = applyUnifiedDiff({
        cwd: args.project.rootDir,
        cellIndex: sourceCell.index,
        rawOutput: generated.patch,
      });

      if (!applyResult.ok) {
        if (applyResult.error._tag === "InvalidDiffError") {
          return err({
            tag: "invalid-diff",
            cellIndex: sourceCell.index,
            message: "Generated output was not a valid unified diff.",
          });
        }

        return err({
          tag: "diff-apply",
          cellIndex: sourceCell.index,
          message: applyResult.error.stderr,
        });
      }

      return ok({
        files: applyResult.value.files,
        patch: applyResult.value.patch,
        timestamp: args.context.now().toISOString(),
      });
    },
    reviewBuild: ({ cell }) => {
      const sourceCell = cellsByIndex.get(cell.index);
      if (sourceCell === undefined) {
        return err({
          tag: "agent-error",
          cellIndex: cell.index,
          message: `Cell ${cell.index} was not found in project map.`,
        });
      }

      const warnings = sourceCell.content.includes("TODO")
        ? "\n⚠ Contains TODO markers that may need follow-up."
        : "";

      return ok(`Added generated scaffold for ${sourceCell.title}.${warnings}`);
    },
  };
};

const toExecutionCell = (cell: DriftCellRecord): ExecutionCell => ({
  index: cell.index,
  dependencies: cell.dependencies,
  dependents: cell.dependents,
  state: cell.state,
  artifact: cell.artifact,
});

const printRunAllSummary = (args: {
  readonly context: CliContext;
  readonly project: DriftProject;
  readonly report: BuildExecutionReport;
}): void => {
  const executedSet = new Set(args.report.executed);
  const reportCells = new Map<number, ExecutionCell>();
  for (const cell of args.report.cells) {
    reportCells.set(cell.index, cell);
  }

  args.context.writeLine("");

  for (const sourceCell of args.project.cells) {
    const currentCell = reportCells.get(sourceCell.index);
    if (currentCell === undefined) {
      continue;
    }

    if (sourceCell.index === 0) {
      args.context.writeLine(`  0: ${sourceCell.title}              ✅ (context only)`);
      continue;
    }

    if (!executedSet.has(sourceCell.index)) {
      const symbol = currentCell.state === "clean" ? "✅" : "🟡";
      const suffix = currentCell.state === "clean" ? "already clean" : "stale";
      args.context.writeLine(
        `  ${sourceCell.index}: ${sourceCell.title}            ${symbol} (${suffix})`,
      );
      continue;
    }

    if (currentCell.artifact === null) {
      continue;
    }

    const diff = summarizeDiff(currentCell.artifact.patch);
    const filesLabel =
      currentCell.artifact.files.length === 0
        ? "(no files)"
        : currentCell.artifact.files.join(", ");
    args.context.writeLine(
      `  ${sourceCell.index}: ${sourceCell.title}            🔄 → ✅  +${diff.additions} -${diff.deletions} in ${filesLabel}`,
    );

    const summary = currentCell.artifact.summary.trim();
    if (summary !== "") {
      args.context.writeLine(`     ${summary}`);
    }
  }

  const nonContextCells = args.report.cells.filter((cell) => cell.index !== 0);
  const cleanCells = nonContextCells.filter((cell) => cell.state === "clean").length;
  args.context.writeLine("");
  args.context.writeLine(`✅ ${cleanCells}/${nonContextCells.length} cells clean.`);
};

const printRunOneSummary = (args: {
  readonly context: CliContext;
  readonly project: DriftProject;
  readonly report: BuildExecutionReport;
  readonly targetCell: number;
}): void => {
  const sourceCell = args.project.cells.find((cell) => cell.index === args.targetCell);
  if (sourceCell === undefined) {
    return;
  }

  const targetCell = args.report.cells.find((cell) => cell.index === args.targetCell);
  if (targetCell === undefined || targetCell.artifact === null) {
    return;
  }

  const dependencyStatuses = sourceCell.dependencies.map((dependency) => {
    const dependencyCell = args.report.cells.find((cell) => cell.index === dependency);
    const symbol = dependencyCell?.state === "clean" ? "✅" : "🟡";
    return `${dependency} ${symbol}`;
  });

  args.context.writeLine("");
  args.context.writeLine(`▶ Cell ${sourceCell.index}: ${sourceCell.title}`);
  args.context.writeLine(
    `  ├─ Deps: ${
      dependencyStatuses.length === 0 ? "(none)" : `${dependencyStatuses.join(", ")} (all clean)`
    }`,
  );

  const diff = summarizeDiff(targetCell.artifact.patch);
  const files =
    targetCell.artifact.files.length === 0 ? "(no files)" : targetCell.artifact.files.join(", ");
  args.context.writeLine(`  ├─ Diff: +${diff.additions} -${diff.deletions} in ${files}`);
  args.context.writeLine(`  └─ ${targetCell.artifact.summary.trim()}`);

  args.context.writeLine("");
  if (args.report.eligibleDescendants.length === 0) {
    args.context.writeLine(`✅ Cell ${sourceCell.index} clean.`);
    return;
  }

  args.context.writeLine(
    `✅ Cell ${sourceCell.index} clean. Cells [${formatIndexList(args.report.eligibleDescendants)}] now eligible.`,
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

const printEngineError = (context: CliContext, error: EngineError): void => {
  switch (error.tag) {
    case "missing-cell":
      context.writeError(`Missing cell ${error.cellIndex}.`);
      return;
    case "cycle-detected":
      context.writeError(`Cycle detected across cells: ${error.cells.join(", ")}.`);
      return;
    case "cell-error":
      context.writeError(
        `Cell ${error.error.cellIndex} failed (${error.error.tag}): ${error.error.message}`,
      );
      return;
    case "ancestor-failed":
      context.writeError(
        `Cell ${error.targetCell} could not run because ancestor ${error.failedCell} failed: ${error.cause.message}`,
      );
      return;
  }
};
