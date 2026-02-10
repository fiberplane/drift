import { Either } from "effect";

import type { VcsBackendPreference } from "../core/vcs.ts";

export interface CliDependencies {
  readonly commitFiles: (args: {
    readonly cwd: string;
    readonly backend: VcsBackendPreference;
    readonly files: readonly string[];
    readonly message: string;
    readonly cellIndices: readonly number[];
  }) => Either.Either<{ readonly ref: string }, { readonly message: string }>;
  readonly startEditServer: (args: { readonly host: string; readonly port: number }) => {
    readonly host: string;
    readonly port: number;
  };
}

export interface CliContext {
  readonly cwd: string;
  readonly now: () => Date;
  readonly writeLine: (line: string) => void;
  readonly writeError: (line: string) => void;
  readonly dependencies?: Partial<CliDependencies>;
}

export const createProcessContext = (): CliContext => ({
  cwd: process.cwd(),
  now: () => new Date(),
  writeLine: (line) => {
    process.stdout.write(`${line}\n`);
  },
  writeError: (line) => {
    process.stderr.write(`${line}\n`);
  },
});

export const parseCellIndex = (raw: string): number | null => {
  if (raw.trim() === "") {
    return null;
  }

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) {
    return null;
  }

  if (parsed < 0) {
    return null;
  }

  return parsed;
};

export const normalizePath = (path: string): string => path.replaceAll("\\", "/");
