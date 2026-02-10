import { runCli } from "./index.ts";
import { createProcessContext } from "./types.ts";

const exitCode = runCli(Bun.argv.slice(2), createProcessContext());
if (exitCode !== 0) {
  process.exitCode = exitCode;
}
