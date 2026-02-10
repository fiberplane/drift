import { runAssembleCommand } from "./assemble.ts";
import { runCommitCommand } from "./commit.ts";
import { runEditCommand } from "./edit.ts";
import { runInitCommand } from "./init.ts";
import { runNewCommand } from "./new.ts";
import { runPlanCommand } from "./plan.ts";
import { runRunCommand } from "./run.ts";
import { createProcessContext, type CliContext } from "./types.ts";

export const runCli = (
  argv: readonly string[],
  context: CliContext = createProcessContext(),
): number => {
  const command = argv[0];
  const args = argv.slice(1);

  if (command === undefined || command === "-h" || command === "--help") {
    context.writeLine(renderHelp());
    return 0;
  }

  switch (command) {
    case "run":
      return runRunCommand(args, context);
    case "plan":
      return runPlanCommand(args, context);
    case "commit":
      return runCommitCommand(args, context);
    case "edit":
      return runEditCommand(args, context);
    case "new":
      return runNewCommand(args, context);
    case "init":
      return runInitCommand(args, context);
    case "assemble":
      return runAssembleCommand(args, context);
    default:
      context.writeError(`Unknown command: ${command}`);
      context.writeLine("");
      context.writeLine(renderHelp());
      return 1;
  }
};

export const renderHelp = (): string =>
  [
    "drift - spec-driven agentic development",
    "",
    "Usage:",
    "  drift run [cell|file.md] [--no-stream]",
    "  drift plan [cell]",
    "  drift commit [cell...]",
    "  drift edit [--host HOST] [--port PORT]",
    "  drift new",
    "  drift init <file.md>",
    "  drift assemble [-o FILE]",
  ].join("\n");
