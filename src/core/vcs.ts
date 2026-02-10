import { createHash } from "node:crypto";
import { join } from "node:path";

import { Either } from "effect";

import { VcsCommitError } from "./errors.ts";

export type VcsBackendName = "git" | "jj";
export type VcsBackendPreference = VcsBackendName | "auto";

export interface CommitRequest {
  readonly cwd: string;
  readonly backend: VcsBackendPreference;
  readonly files: ReadonlyArray<string>;
  readonly message: string;
  readonly cellIndices: ReadonlyArray<number>;
}

export interface VcsCommand {
  readonly cwd: string;
  readonly cmd: ReadonlyArray<string>;
}

export interface VcsCommandResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
}

export interface VcsRuntime {
  readonly pathExists: (path: string) => boolean;
  readonly runCommand: (command: VcsCommand) => VcsCommandResult;
  readonly readTextFile: (path: string) => string | null;
}

export interface CommitSuccess {
  readonly backend: VcsBackendName;
  readonly ref: string;
}

export interface DriftDetectionRequest {
  readonly cwd: string;
  readonly backend: VcsBackendPreference;
  readonly files: ReadonlyArray<string>;
  readonly ref: string | null;
  readonly previousHashes: Readonly<Record<string, string | null>>;
}

export interface DriftDetectionResult {
  readonly backend: VcsBackendName;
  readonly method: "ref" | "hash";
  readonly driftedFiles: ReadonlyArray<string>;
}

export const resolveVcsBackend = (args: {
  readonly cwd: string;
  readonly backend: VcsBackendPreference;
  readonly pathExists: (path: string) => boolean;
}): VcsBackendName => {
  if (args.backend !== "auto") {
    return args.backend;
  }

  if (args.pathExists(join(args.cwd, ".jj"))) {
    return "jj";
  }

  if (args.pathExists(join(args.cwd, ".git"))) {
    return "git";
  }

  return "git";
};

export const commitWithVcs = (
  request: CommitRequest,
  runtime: Pick<VcsRuntime, "pathExists" | "runCommand">,
): Either.Either<CommitSuccess, VcsCommitError> => {
  const files = normalizeFiles(request.files);
  if (files.length === 0) {
    return failCommit(request, "No files were selected for commit.");
  }

  const backend = resolveVcsBackend({
    cwd: request.cwd,
    backend: request.backend,
    pathExists: runtime.pathExists,
  });

  const commitResult =
    backend === "git"
      ? commitWithGit({
          cwd: request.cwd,
          files,
          message: request.message,
          runCommand: runtime.runCommand,
        })
      : commitWithJj({
          cwd: request.cwd,
          files,
          message: request.message,
          runCommand: runtime.runCommand,
        });

  if (Either.isLeft(commitResult)) {
    return failCommit(request, commitResult.left);
  }

  return Either.right({
    backend,
    ref: commitResult.right,
  });
};

export const detectDrift = (
  request: DriftDetectionRequest,
  runtime: VcsRuntime,
): DriftDetectionResult => {
  const files = normalizeFiles(request.files);
  const backend = resolveVcsBackend({
    cwd: request.cwd,
    backend: request.backend,
    pathExists: runtime.pathExists,
  });

  if (request.ref !== null) {
    const fromRef = detectDriftFromRef({
      cwd: request.cwd,
      backend,
      ref: request.ref,
      files,
      runCommand: runtime.runCommand,
    });

    if (fromRef !== null) {
      return {
        backend,
        method: "ref",
        driftedFiles: fromRef,
      };
    }
  }

  const currentHashes = snapshotFileHashes(
    {
      cwd: request.cwd,
      files,
    },
    {
      readTextFile: runtime.readTextFile,
    },
  );

  const driftedFiles = files.filter((file) => {
    const previous = request.previousHashes[file];
    if (previous === undefined) {
      return false;
    }

    const current = currentHashes[file] ?? null;
    return previous !== current;
  });

  return {
    backend,
    method: "hash",
    driftedFiles,
  };
};

export const snapshotFileHashes = (
  args: {
    readonly cwd: string;
    readonly files: ReadonlyArray<string>;
  },
  runtime: Pick<VcsRuntime, "readTextFile">,
): Record<string, string | null> => {
  const files = normalizeFiles(args.files);
  const hashes: Record<string, string | null> = {};

  for (const file of files) {
    const absolutePath = join(args.cwd, file);
    const content = runtime.readTextFile(absolutePath);
    hashes[file] = content === null ? null : sha256(content);
  }

  return hashes;
};

export const parseProjectVcsBackend = (configRaw: string): VcsBackendPreference => {
  const lines = configRaw.replaceAll("\r\n", "\n").split("\n");

  let inVcsSection = false;
  let vcsIndent = 0;

  for (const line of lines) {
    const trimmed = line.trim();

    if (!inVcsSection) {
      const vcsMatch = line.match(/^(\s*)vcs\s*:\s*(.*?)\s*$/u);
      if (vcsMatch === null) {
        continue;
      }

      const inlineValue = vcsMatch[2] ?? "";
      if (inlineValue !== "") {
        const inlineBackend = parseInlineBackend(inlineValue);
        return inlineBackend ?? "auto";
      }

      const indent = vcsMatch[1] ?? "";
      vcsIndent = indent.length;
      inVcsSection = true;
      continue;
    }

    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    const currentIndent = countIndent(line);
    if (currentIndent <= vcsIndent) {
      break;
    }

    const backendMatch = trimmed.match(/^backend\s*:\s*(.*?)\s*$/u);
    const rawBackend = backendMatch?.[1];
    if (rawBackend === undefined) {
      continue;
    }

    const normalizedBackend = normalizeScalarValue(rawBackend);
    return isVcsBackendPreference(normalizedBackend) ? normalizedBackend : "auto";
  }

  return "auto";
};

export const formatCommitSummary = (request: Pick<CommitRequest, "backend" | "files">): string => {
  const fileCount = normalizeFiles(request.files).length;
  const noun = fileCount === 1 ? "file" : "files";

  return `${request.backend} commit (${fileCount} ${noun})`;
};

const commitWithGit = (args: {
  readonly cwd: string;
  readonly files: ReadonlyArray<string>;
  readonly message: string;
  readonly runCommand: (command: VcsCommand) => VcsCommandResult;
}): Either.Either<string, string> => {
  const addResult = args.runCommand({
    cwd: args.cwd,
    cmd: ["git", "add", "--", ...args.files],
  });

  if (addResult.exitCode !== 0) {
    return Either.left(readCommandMessage(addResult, "git add failed"));
  }

  const commitResult = args.runCommand({
    cwd: args.cwd,
    cmd: ["git", "commit", "-m", args.message, "--only", "--", ...args.files],
  });

  if (commitResult.exitCode !== 0) {
    return Either.left(readCommandMessage(commitResult, "git commit failed"));
  }

  const refResult = args.runCommand({
    cwd: args.cwd,
    cmd: ["git", "rev-parse", "--short", "HEAD"],
  });

  if (refResult.exitCode !== 0) {
    return Either.left(readCommandMessage(refResult, "Could not read git ref"));
  }

  const ref = refResult.stdout.trim();
  if (ref === "") {
    return Either.left("Could not resolve git commit ref");
  }

  return Either.right(ref);
};

const commitWithJj = (args: {
  readonly cwd: string;
  readonly files: ReadonlyArray<string>;
  readonly message: string;
  readonly runCommand: (command: VcsCommand) => VcsCommandResult;
}): Either.Either<string, string> => {
  const commitResult = args.runCommand({
    cwd: args.cwd,
    cmd: ["jj", "commit", "-m", args.message, "--", ...args.files],
  });

  if (commitResult.exitCode !== 0) {
    return Either.left(readCommandMessage(commitResult, "jj commit failed"));
  }

  const refResult = args.runCommand({
    cwd: args.cwd,
    cmd: ["jj", "log", "-r", "@-", "--no-graph", "--template", "commit_id.short()"],
  });

  if (refResult.exitCode !== 0) {
    return Either.left(readCommandMessage(refResult, "Could not read jj commit ref"));
  }

  const ref = refResult.stdout.trim();
  if (ref === "") {
    return Either.left("Could not resolve jj commit ref");
  }

  return Either.right(ref);
};

const failCommit = (
  request: CommitRequest,
  stderr: string,
): Either.Either<CommitSuccess, VcsCommitError> =>
  Either.left(
    new VcsCommitError({
      cellIndices: [...request.cellIndices],
      stderr,
    }),
  );

const detectDriftFromRef = (args: {
  readonly cwd: string;
  readonly backend: VcsBackendName;
  readonly ref: string;
  readonly files: ReadonlyArray<string>;
  readonly runCommand: (command: VcsCommand) => VcsCommandResult;
}): ReadonlyArray<string> | null => {
  const command =
    args.backend === "git"
      ? ["git", "diff", "--name-only", args.ref, "--", ...args.files]
      : ["jj", "diff", "--from", args.ref, "--to", "@", "--name-only", "--", ...args.files];

  const diffResult = args.runCommand({
    cwd: args.cwd,
    cmd: command,
  });

  if (diffResult.exitCode !== 0) {
    return null;
  }

  const changed = new Set<string>();
  for (const line of diffResult.stdout.replaceAll("\r\n", "\n").split("\n")) {
    const normalized = normalizePath(line.trim());
    if (normalized === "") {
      continue;
    }
    changed.add(normalized);
  }

  return args.files.filter((file) => changed.has(file));
};

const readCommandMessage = (result: VcsCommandResult, fallback: string): string => {
  const stderr = result.stderr.trim();
  if (stderr !== "") {
    return stderr;
  }

  const stdout = result.stdout.trim();
  if (stdout !== "") {
    return stdout;
  }

  return fallback;
};

const normalizeFiles = (files: ReadonlyArray<string>): string[] => {
  const deduped: string[] = [];
  const seen = new Set<string>();

  for (const rawFile of files) {
    const candidate = normalizePath(rawFile.trim());
    if (candidate === "") {
      continue;
    }

    if (seen.has(candidate)) {
      continue;
    }

    seen.add(candidate);
    deduped.push(candidate);
  }

  return deduped;
};

const normalizePath = (value: string): string => value.replaceAll("\\", "/");

const sha256 = (content: string): string => createHash("sha256").update(content).digest("hex");

const countIndent = (line: string): number => {
  const matched = line.match(/^(\s*)/u);
  const indent = matched?.[1] ?? "";
  return indent.length;
};

const parseInlineBackend = (value: string): VcsBackendPreference | null => {
  const matched = value.match(/backend\s*:\s*([^,}]+)/u);
  const backendValue = matched?.[1];
  if (backendValue === undefined) {
    return null;
  }

  const normalized = normalizeScalarValue(backendValue);
  return isVcsBackendPreference(normalized) ? normalized : null;
};

const normalizeScalarValue = (value: string): string => {
  const withoutComment = value.split("#")[0] ?? value;
  const trimmed = withoutComment.trim();

  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1).trim();
  }

  return trimmed;
};

const isVcsBackendPreference = (value: string): value is VcsBackendPreference =>
  value === "auto" || value === "git" || value === "jj";
