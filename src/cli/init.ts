import { join } from "node:path";

import { Either } from "effect";

import { initializeProjectFromMarkdown, type ProjectError } from "./project-store.ts";
import type { CliContext } from "./types.ts";

export const runInitCommand = (args: readonly string[], context: CliContext): number => {
  const markdownFile = args[0];
  if (markdownFile === undefined) {
    context.writeError("Usage: drift init <file.md>");
    return 1;
  }

  const markdownPath = join(context.cwd, markdownFile);
  const result = initializeProjectFromMarkdown({
    rootDir: context.cwd,
    markdownPath,
    nowIso: context.now().toISOString(),
  });

  if (Either.isLeft(result)) {
    printProjectError(context, result.left);
    return 1;
  }

  context.writeLine(`✓ Initialized .drift from ${markdownFile}`);
  context.writeLine(`  └─ Created ${result.right.cells} cell directories`);

  return 0;
};

const printProjectError = (context: CliContext, error: ProjectError): void => {
  switch (error.tag) {
    case "missing-file":
      context.writeError(`Missing file: ${error.path}`);
      return;
    case "invalid-markdown":
      context.writeError(`Invalid markdown input: ${error.message}`);
      return;
    case "already-exists":
      context.writeError(`Path already exists: ${error.path}`);
      return;
    case "missing-drift":
      context.writeError(`Missing Drift project: ${error.path}`);
      return;
    case "missing-cells":
      context.writeError(`Missing cell directory: ${error.path}`);
      return;
    case "missing-cell":
      context.writeError(`Cell ${error.cellIndex} was not found.`);
      return;
  }
};
