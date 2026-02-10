import { existsSync } from "node:fs";

import { Either } from "effect";

import { commitWithVcs, type VcsCommand, type VcsCommandResult } from "../core/vcs.ts";
import type { CliDependencies } from "./types.ts";

const decoder = new TextDecoder();

const runCommand = (command: VcsCommand): VcsCommandResult => {
  const result = Bun.spawnSync({
    cmd: [...command.cmd],
    cwd: command.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  return {
    exitCode: result.exitCode ?? 1,
    stdout: decoder.decode(result.stdout),
    stderr: decoder.decode(result.stderr),
  };
};

export const commitFilesWithDetectedVcs: CliDependencies["commitFiles"] = (args) => {
  const commitResult = commitWithVcs(
    {
      cwd: args.cwd,
      backend: args.backend,
      files: args.files,
      message: args.message,
      cellIndices: args.cellIndices,
    },
    {
      pathExists: (path) => existsSync(path),
      runCommand,
    },
  );

  if (Either.isLeft(commitResult)) {
    return Either.left({
      message: commitResult.left.stderr,
    });
  }

  return Either.right({
    ref: commitResult.right.ref,
  });
};

export const startPlaceholderEditServer: CliDependencies["startEditServer"] = (args) => {
  const server = Bun.serve({
    hostname: args.host,
    port: args.port,
    fetch: () =>
      new Response(
        `<!doctype html><html><head><title>drift edit</title></head><body><h1>drift edit</h1><p>Web UI scaffold is running.</p></body></html>`,
        {
          headers: {
            "content-type": "text/html; charset=utf-8",
          },
        },
      ),
  });

  return {
    host: args.host,
    port: server.port ?? args.port,
  };
};
