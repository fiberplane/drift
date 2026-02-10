import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { DiffApplyError, InvalidDiffError } from "./errors.ts";

export interface DiffSummary {
  readonly additions: number;
  readonly deletions: number;
}

export interface AppliedUnifiedDiff {
  readonly patch: string;
  readonly files: readonly string[];
}

export type ApplyUnifiedDiffResult =
  | {
      readonly ok: true;
      readonly value: AppliedUnifiedDiff;
    }
  | {
      readonly ok: false;
      readonly error: InvalidDiffError | DiffApplyError;
    };

interface ParsedUnifiedDiff {
  readonly patch: string;
  readonly files: readonly ParsedFilePatch[];
}

interface ParsedFilePatch {
  readonly oldPath: string;
  readonly newPath: string;
  readonly hunks: readonly ParsedHunk[];
}

interface ParsedHunk {
  readonly oldStart: number;
  readonly oldCount: number;
  readonly newStart: number;
  readonly newCount: number;
  readonly lines: readonly string[];
}

type ParseResult<A> =
  | {
      readonly ok: true;
      readonly value: A;
    }
  | {
      readonly ok: false;
      readonly error: InvalidDiffError;
    };

type ApplyFileResult =
  | {
      readonly ok: true;
    }
  | {
      readonly ok: false;
      readonly error: DiffApplyError;
    };

export const summarizeUnifiedDiff = (patch: string): DiffSummary => {
  const lines = patch.split("\n");
  let additions = 0;
  let deletions = 0;

  for (const line of lines) {
    if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) {
      continue;
    }

    if (line.startsWith("+")) {
      additions += 1;
      continue;
    }

    if (line.startsWith("-")) {
      deletions += 1;
    }
  }

  return { additions, deletions };
};

export const applyUnifiedDiff = (args: {
  readonly cwd: string;
  readonly cellIndex: number;
  readonly rawOutput: string;
}): ApplyUnifiedDiffResult => {
  const parsed = parseUnifiedDiff({
    cellIndex: args.cellIndex,
    rawOutput: args.rawOutput,
  });

  if (!parsed.ok) {
    return {
      ok: false,
      error: parsed.error,
    };
  }

  const touchedFiles: string[] = [];
  const seen = new Set<string>();

  for (const filePatch of parsed.value.files) {
    const touchedPath = getTouchedPath(filePatch);
    if (touchedPath === null) {
      return {
        ok: false,
        error: createInvalidDiffError({
          cellIndex: args.cellIndex,
          rawOutput: args.rawOutput,
        }),
      };
    }

    const applyResult = applyFilePatch({
      cwd: args.cwd,
      cellIndex: args.cellIndex,
      patch: parsed.value.patch,
      filePatch,
    });

    if (!applyResult.ok) {
      return {
        ok: false,
        error: applyResult.error,
      };
    }

    if (!seen.has(touchedPath)) {
      seen.add(touchedPath);
      touchedFiles.push(touchedPath);
    }
  }

  return {
    ok: true,
    value: {
      patch: parsed.value.patch,
      files: touchedFiles,
    },
  };
};

const parseUnifiedDiff = (args: {
  readonly cellIndex: number;
  readonly rawOutput: string;
}): ParseResult<ParsedUnifiedDiff> => {
  const normalizedRaw = normalizePatch(args.rawOutput);
  const lines = splitPatchLines(normalizedRaw);

  if (lines.length === 0) {
    return parseErr(args);
  }

  const files: ParsedFilePatch[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (line === undefined) {
      break;
    }

    if (line.startsWith("--- ")) {
      const parsedFile = parseFilePatch({
        lines,
        index,
        cellIndex: args.cellIndex,
        rawOutput: args.rawOutput,
      });

      if (!parsedFile.ok) {
        return parsedFile;
      }

      files.push(parsedFile.value.filePatch);
      index = parsedFile.value.nextIndex;
      continue;
    }

    if (isDiffMetadataLine(line) || line.trim() === "") {
      index += 1;
      continue;
    }

    return parseErr(args);
  }

  if (files.length === 0) {
    return parseErr(args);
  }

  const normalizedPatch = normalizedRaw.endsWith("\n") ? normalizedRaw : `${normalizedRaw}\n`;

  return parseOk({
    patch: normalizedPatch,
    files,
  });
};

const parseFilePatch = (args: {
  readonly lines: readonly string[];
  readonly index: number;
  readonly cellIndex: number;
  readonly rawOutput: string;
}): ParseResult<{
  readonly filePatch: ParsedFilePatch;
  readonly nextIndex: number;
}> => {
  const oldHeader = args.lines[args.index];
  if (oldHeader === undefined) {
    return parseErr(args);
  }

  const oldPath = parseHeaderPath(oldHeader, "--- ");
  if (oldPath === null) {
    return parseErr(args);
  }

  const nextHeader = args.lines[args.index + 1];
  if (nextHeader === undefined || !nextHeader.startsWith("+++ ")) {
    return parseErr(args);
  }

  const newPath = parseHeaderPath(nextHeader, "+++ ");
  if (newPath === null || (oldPath === "/dev/null" && newPath === "/dev/null")) {
    return parseErr(args);
  }

  const hunks: ParsedHunk[] = [];
  let cursor = args.index + 2;

  while (cursor < args.lines.length) {
    const line = args.lines[cursor];
    if (line === undefined) {
      break;
    }

    if (line.startsWith("--- ")) {
      break;
    }

    if (line.startsWith("@@ ")) {
      const parsedHunk = parseHunk({
        lines: args.lines,
        index: cursor,
        cellIndex: args.cellIndex,
        rawOutput: args.rawOutput,
      });

      if (!parsedHunk.ok) {
        return parsedHunk;
      }

      hunks.push(parsedHunk.value.hunk);
      cursor = parsedHunk.value.nextIndex;
      continue;
    }

    if (isDiffMetadataLine(line) || line.trim() === "") {
      cursor += 1;
      continue;
    }

    return parseErr(args);
  }

  if (hunks.length === 0) {
    return parseErr(args);
  }

  return parseOk({
    filePatch: {
      oldPath,
      newPath,
      hunks,
    },
    nextIndex: cursor,
  });
};

const parseHunk = (args: {
  readonly lines: readonly string[];
  readonly index: number;
  readonly cellIndex: number;
  readonly rawOutput: string;
}): ParseResult<{
  readonly hunk: ParsedHunk;
  readonly nextIndex: number;
}> => {
  const header = args.lines[args.index];
  if (header === undefined) {
    return parseErr(args);
  }

  const headerMatch = header.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/u);
  if (headerMatch === null) {
    return parseErr(args);
  }

  const oldStartRaw = headerMatch[1];
  const newStartRaw = headerMatch[3];

  if (oldStartRaw === undefined || newStartRaw === undefined) {
    return parseErr(args);
  }

  const oldStart = parseHunkNumber(oldStartRaw);
  const oldCount = parseHunkNumber(headerMatch[2] ?? "1");
  const newStart = parseHunkNumber(newStartRaw);
  const newCount = parseHunkNumber(headerMatch[4] ?? "1");

  if (oldStart === null || oldCount === null || newStart === null || newCount === null) {
    return parseErr(args);
  }

  const lines: string[] = [];
  let cursor = args.index + 1;

  while (cursor < args.lines.length) {
    const line = args.lines[cursor];
    if (line === undefined) {
      break;
    }

    if (line.startsWith("@@ ") || line.startsWith("--- ")) {
      break;
    }

    if (
      line === "\\ No newline at end of file" ||
      line.startsWith(" ") ||
      line.startsWith("+") ||
      line.startsWith("-")
    ) {
      lines.push(line);
      cursor += 1;
      continue;
    }

    return parseErr(args);
  }

  const observedOldCount = lines.filter(
    (line) => line.startsWith(" ") || line.startsWith("-"),
  ).length;
  const observedNewCount = lines.filter(
    (line) => line.startsWith(" ") || line.startsWith("+"),
  ).length;

  if (observedOldCount !== oldCount || observedNewCount !== newCount) {
    return parseErr(args);
  }

  return parseOk({
    hunk: {
      oldStart,
      oldCount,
      newStart,
      newCount,
      lines,
    },
    nextIndex: cursor,
  });
};

const applyFilePatch = (args: {
  readonly cwd: string;
  readonly cellIndex: number;
  readonly patch: string;
  readonly filePatch: ParsedFilePatch;
}): ApplyFileResult => {
  const sourcePath =
    args.filePatch.oldPath === "/dev/null" ? null : join(args.cwd, args.filePatch.oldPath);
  const sourceContent = sourcePath === null ? "" : readTextFile(sourcePath);

  if (sourcePath !== null && sourceContent === null) {
    return applyErr({
      cellIndex: args.cellIndex,
      patch: args.patch,
      stderr: `Diff target does not exist: ${args.filePatch.oldPath}`,
    });
  }

  const sourceLines = splitContentLines(sourceContent ?? "");
  const outputLines: string[] = [];
  let sourceCursor = 0;

  for (const hunk of args.filePatch.hunks) {
    const hunkStart = Math.max(0, hunk.oldStart - 1);

    if (hunkStart < sourceCursor) {
      return applyErr({
        cellIndex: args.cellIndex,
        patch: args.patch,
        stderr: `Overlapping hunk detected for ${getTouchedPath(args.filePatch) ?? "unknown"}.`,
      });
    }

    while (sourceCursor < hunkStart) {
      const sourceLine = sourceLines[sourceCursor];
      if (sourceLine === undefined) {
        return applyErr({
          cellIndex: args.cellIndex,
          patch: args.patch,
          stderr: `Hunk out of range for ${getTouchedPath(args.filePatch) ?? "unknown"}.`,
        });
      }

      outputLines.push(sourceLine);
      sourceCursor += 1;
    }

    for (const hunkLine of hunk.lines) {
      if (hunkLine === "\\ No newline at end of file") {
        continue;
      }

      const marker = hunkLine[0];
      const value = hunkLine.slice(1);
      const sourceLine = sourceLines[sourceCursor];

      if (marker === " ") {
        if (sourceLine !== value) {
          return applyErr({
            cellIndex: args.cellIndex,
            patch: args.patch,
            stderr: createHunkMismatchMessage(args.filePatch, sourceCursor, value, sourceLine),
          });
        }

        outputLines.push(value);
        sourceCursor += 1;
        continue;
      }

      if (marker === "-") {
        if (sourceLine !== value) {
          return applyErr({
            cellIndex: args.cellIndex,
            patch: args.patch,
            stderr: createHunkMismatchMessage(args.filePatch, sourceCursor, value, sourceLine),
          });
        }

        sourceCursor += 1;
        continue;
      }

      if (marker === "+") {
        outputLines.push(value);
        continue;
      }

      return applyErr({
        cellIndex: args.cellIndex,
        patch: args.patch,
        stderr: `Unsupported hunk marker '${marker}' in ${getTouchedPath(args.filePatch) ?? "unknown"}.`,
      });
    }
  }

  while (sourceCursor < sourceLines.length) {
    const sourceLine = sourceLines[sourceCursor];
    if (sourceLine === undefined) {
      break;
    }

    outputLines.push(sourceLine);
    sourceCursor += 1;
  }

  const targetPath = getTouchedPath(args.filePatch);
  if (targetPath === null) {
    return applyErr({
      cellIndex: args.cellIndex,
      patch: args.patch,
      stderr: "Patch did not contain a valid target file path.",
    });
  }

  if (args.filePatch.newPath === "/dev/null") {
    const deletePath = join(args.cwd, targetPath);
    if (existsSync(deletePath)) {
      rmSync(deletePath);
    }

    return {
      ok: true,
    };
  }

  const absolutePath = join(args.cwd, targetPath);
  mkdirSync(dirname(absolutePath), { recursive: true });
  const rendered = outputLines.length === 0 ? "" : `${outputLines.join("\n")}\n`;
  writeFileSync(absolutePath, rendered);

  return {
    ok: true,
  };
};

const parseHeaderPath = (line: string, prefix: "--- " | "+++ "): string | null => {
  if (!line.startsWith(prefix)) {
    return null;
  }

  const rawPath = line.slice(prefix.length).trim();
  if (rawPath === "") {
    return null;
  }

  const token = rawPath.split("\t")[0]?.split(" ")[0] ?? "";
  if (token === "") {
    return null;
  }

  if (token === "/dev/null") {
    return token;
  }

  const normalized = token.replaceAll("\\", "/");
  const withoutPrefix =
    normalized.startsWith("a/") || normalized.startsWith("b/") ? normalized.slice(2) : normalized;

  if (withoutPrefix === "" || withoutPrefix.startsWith("/")) {
    return null;
  }

  const segments = withoutPrefix.split("/");
  if (segments.some((segment) => segment === "..")) {
    return null;
  }

  return withoutPrefix;
};

const getTouchedPath = (filePatch: ParsedFilePatch): string | null => {
  if (filePatch.newPath !== "/dev/null") {
    return filePatch.newPath;
  }

  if (filePatch.oldPath !== "/dev/null") {
    return filePatch.oldPath;
  }

  return null;
};

const isDiffMetadataLine = (line: string): boolean =>
  line.startsWith("diff --git ") ||
  line.startsWith("index ") ||
  line.startsWith("new file mode ") ||
  line.startsWith("deleted file mode ") ||
  line.startsWith("similarity index ") ||
  line.startsWith("rename from ") ||
  line.startsWith("rename to ");

const normalizePatch = (patch: string): string => patch.replaceAll("\r\n", "\n").trim();

const splitPatchLines = (patch: string): string[] => {
  if (patch === "") {
    return [];
  }

  return patch.split("\n");
};

const splitContentLines = (content: string): string[] => {
  if (content === "") {
    return [];
  }

  const normalized = content.replaceAll("\r\n", "\n");
  const lines = normalized.split("\n");

  if (lines[lines.length - 1] === "") {
    lines.pop();
  }

  return lines;
};

const parseHunkNumber = (value: string): number | null => {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }

  return parsed;
};

const readTextFile = (path: string): string | null => {
  if (!existsSync(path)) {
    return null;
  }

  return readFileSync(path, "utf8");
};

const createHunkMismatchMessage = (
  filePatch: ParsedFilePatch,
  sourceCursor: number,
  expected: string,
  actual: string | undefined,
): string => {
  const touchedPath = getTouchedPath(filePatch) ?? "unknown";
  const actualLabel = actual === undefined ? "<end-of-file>" : actual;
  return `Hunk does not match ${touchedPath} at line ${sourceCursor + 1}. Expected '${expected}', found '${actualLabel}'.`;
};

const parseOk = <A>(value: A): ParseResult<A> => ({
  ok: true,
  value,
});

const parseErr = (args: {
  readonly cellIndex: number;
  readonly rawOutput: string;
}): ParseResult<never> => ({
  ok: false,
  error: createInvalidDiffError(args),
});

const applyErr = (args: {
  readonly cellIndex: number;
  readonly patch: string;
  readonly stderr: string;
}): ApplyFileResult => ({
  ok: false,
  error: new DiffApplyError({
    cellIndex: args.cellIndex,
    patch: args.patch,
    stderr: args.stderr,
  }),
});

const createInvalidDiffError = (args: {
  readonly cellIndex: number;
  readonly rawOutput: string;
}): InvalidDiffError =>
  new InvalidDiffError({
    cellIndex: args.cellIndex,
    rawOutput: args.rawOutput,
  });
