import { existsSync } from "node:fs";
import { join } from "node:path";

import type { CliDependencies } from "./types.ts";

const decoder = new TextDecoder();

export const commitFilesWithDetectedVcs: CliDependencies["commitFiles"] = (args) => {
  const usesJj = existsSync(join(args.cwd, ".jj"));

  if (usesJj) {
    return commitWithJj(args);
  }

  return commitWithGit(args);
};

const commitWithJj: CliDependencies["commitFiles"] = (args) => {
  const commitResult = Bun.spawnSync({
    cmd: ["jj", "commit", "-m", args.message, ...args.files],
    cwd: args.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (commitResult.exitCode !== 0) {
    return {
      ok: false,
      message: decoder.decode(commitResult.stderr).trim() || "jj commit failed",
    };
  }

  const refResult = Bun.spawnSync({
    cmd: ["jj", "log", "-r", "@-", "--no-graph", "--template", "commit_id.short()"],
    cwd: args.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (refResult.exitCode !== 0) {
    return {
      ok: false,
      message: decoder.decode(refResult.stderr).trim() || "Could not read jj commit ref",
    };
  }

  const ref = decoder.decode(refResult.stdout).trim();
  if (ref === "") {
    return {
      ok: false,
      message: "Could not resolve jj commit ref",
    };
  }

  return {
    ok: true,
    ref,
  };
};

const commitWithGit: CliDependencies["commitFiles"] = (args) => {
  const addResult = Bun.spawnSync({
    cmd: ["git", "add", ...args.files],
    cwd: args.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (addResult.exitCode !== 0) {
    return {
      ok: false,
      message: decoder.decode(addResult.stderr).trim() || "git add failed",
    };
  }

  const commitResult = Bun.spawnSync({
    cmd: ["git", "commit", "-m", args.message],
    cwd: args.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (commitResult.exitCode !== 0) {
    return {
      ok: false,
      message: decoder.decode(commitResult.stderr).trim() || "git commit failed",
    };
  }

  const refResult = Bun.spawnSync({
    cmd: ["git", "rev-parse", "--short", "HEAD"],
    cwd: args.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (refResult.exitCode !== 0) {
    return {
      ok: false,
      message: decoder.decode(refResult.stderr).trim() || "Could not read git ref",
    };
  }

  const ref = decoder.decode(refResult.stdout).trim();
  if (ref === "") {
    return {
      ok: false,
      message: "Could not resolve git commit ref",
    };
  }

  return {
    ok: true,
    ref,
  };
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
