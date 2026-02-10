import { startDriftEditServer } from "../server/index.ts";
import type { CliContext } from "./types.ts";

interface ParsedEditArgs {
  readonly host: string;
  readonly port: number;
}

export const runEditCommand = (args: readonly string[], context: CliContext): number => {
  const parsed = parseEditArgs(args);
  if (!parsed.ok) {
    context.writeError(parsed.error);
    return 1;
  }

  const startServer =
    context.dependencies?.startEditServer ??
    ((serverArgs: { readonly host: string; readonly port: number }) =>
      startDriftEditServer({
        host: serverArgs.host,
        port: serverArgs.port,
        cwd: context.cwd,
      }));

  const server = startServer({
    host: parsed.value.host,
    port: parsed.value.port,
  });

  context.writeLine(`drift edit running at http://${server.host}:${server.port}`);
  context.writeLine("Press Ctrl+C to stop.");

  return 0;
};

const parseEditArgs = (
  args: readonly string[],
):
  | {
      readonly ok: true;
      readonly value: ParsedEditArgs;
    }
  | {
      readonly ok: false;
      readonly error: string;
    } => {
  let host = "localhost";
  let port = 4747;

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === "--host") {
      const hostValue = args[index + 1];
      if (hostValue === undefined || hostValue.trim() === "") {
        return {
          ok: false,
          error: "Usage: drift edit [--host HOST] [--port PORT]",
        };
      }
      host = hostValue;
      index += 1;
      continue;
    }

    if (token === "--port") {
      const portValue = args[index + 1];
      if (portValue === undefined) {
        return {
          ok: false,
          error: "Usage: drift edit [--host HOST] [--port PORT]",
        };
      }

      const parsedPort = Number.parseInt(portValue, 10);
      if (!Number.isFinite(parsedPort) || parsedPort <= 0) {
        return {
          ok: false,
          error: "Port must be a positive integer.",
        };
      }

      port = parsedPort;
      index += 1;
      continue;
    }

    return {
      ok: false,
      error: "Usage: drift edit [--host HOST] [--port PORT]",
    };
  }

  return {
    ok: true,
    value: {
      host,
      port,
    },
  };
};
