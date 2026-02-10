import { createNewProject, type ProjectError } from "./project-store.ts";
import type { CliContext } from "./types.ts";

export const runNewCommand = (_args: readonly string[], context: CliContext): number => {
  const result = createNewProject(context.cwd);
  if (!result.ok) {
    printProjectError(context, result.error);
    return 1;
  }

  context.writeLine("✓ Created .drift/ project");
  context.writeLine("  ├─ .drift/config.yaml");
  context.writeLine("  └─ .drift/cells/0/v1.md");
  context.writeLine("");
  context.writeLine("Run `drift edit` to start iterating, or `drift plan`/`drift run` in the CLI.");

  return 0;
};

const printProjectError = (context: CliContext, error: ProjectError): void => {
  switch (error.tag) {
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
    case "invalid-markdown":
      context.writeError(`Invalid markdown input: ${error.message}`);
      return;
    case "missing-file":
      context.writeError(`Missing file: ${error.path}`);
      return;
  }
};
