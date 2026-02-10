import { join } from "node:path";
import { writeFileSync } from "node:fs";

import { Either } from "effect";

import { assembleProjectMarkdown, loadProject, type ProjectError } from "./project-store.ts";
import type { CliContext } from "./types.ts";

export const runAssembleCommand = (args: readonly string[], context: CliContext): number => {
  const parsed = parseAssembleArgs(args);
  if (!parsed.ok) {
    context.writeError(parsed.error);
    return 1;
  }

  const projectResult = loadProject(context.cwd);
  if (Either.isLeft(projectResult)) {
    printProjectError(context, projectResult.left);
    return 1;
  }

  const markdown = assembleProjectMarkdown(projectResult.right);
  if (parsed.value.outputPath === null) {
    context.writeLine(markdown.trimEnd());
    return 0;
  }

  const outputPath = join(context.cwd, parsed.value.outputPath);
  writeFileSync(outputPath, markdown);
  context.writeLine(`✓ Assembled markdown written to ${parsed.value.outputPath}`);
  return 0;
};

const parseAssembleArgs = (
  args: readonly string[],
):
  | {
      readonly ok: true;
      readonly value: {
        readonly outputPath: string | null;
      };
    }
  | {
      readonly ok: false;
      readonly error: string;
    } => {
  if (args.length === 0) {
    return {
      ok: true,
      value: {
        outputPath: null,
      },
    };
  }

  if (args.length !== 2 || args[0] !== "-o") {
    return {
      ok: false,
      error: "Usage: drift assemble [-o FILE]",
    };
  }

  return {
    ok: true,
    value: {
      outputPath: args[1] ?? null,
    },
  };
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
