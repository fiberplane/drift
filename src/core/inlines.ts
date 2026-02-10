import { Either } from "effect";

import { InlineCommandError } from "./errors.ts";
import type { Inline } from "./schemas.ts";

const INLINE_REFERENCE_PATTERN = /!`([^`\n]+)`/g;
const MARKDOWN_FENCE_PATTERN = /^\s*```/;
const textDecoder = new TextDecoder();

interface ResolveInlinesArgs {
  readonly cellIndex: number;
  readonly projectRoot: string;
  readonly content: string;
}

export const parseInlines = (content: string): ReadonlyArray<Inline> => {
  const inlines: Inline[] = [];

  forEachMarkdownLineOutsideFences(content, (line) => {
    for (const match of line.matchAll(INLINE_REFERENCE_PATTERN)) {
      const command = match[1];
      if (command === undefined) {
        continue;
      }

      inlines.push({
        raw: `!\`${command}\``,
        command,
      });
    }
  });

  return inlines;
};

export const resolveInlinesInContent = (
  args: ResolveInlinesArgs,
): Either.Either<string, InlineCommandError> => {
  const lines = normalizeNewlines(args.content).split("\n");
  const resolvedLines: string[] = [];

  let insideFence = false;
  for (const line of lines) {
    if (MARKDOWN_FENCE_PATTERN.test(line)) {
      insideFence = !insideFence;
      resolvedLines.push(line);
      continue;
    }

    if (insideFence) {
      resolvedLines.push(line);
      continue;
    }

    const lineResult = resolveInlinesInLine({
      line,
      cellIndex: args.cellIndex,
      projectRoot: args.projectRoot,
    });
    if (Either.isLeft(lineResult)) {
      return lineResult;
    }

    resolvedLines.push(lineResult.right);
  }

  return Either.right(resolvedLines.join("\n"));
};

const resolveInlinesInLine = (args: {
  readonly line: string;
  readonly cellIndex: number;
  readonly projectRoot: string;
}): Either.Either<string, InlineCommandError> => {
  const matches = [...args.line.matchAll(INLINE_REFERENCE_PATTERN)];
  if (matches.length === 0) {
    return Either.right(args.line);
  }

  let resolved = "";
  let cursor = 0;

  for (const match of matches) {
    const start = match.index;
    const rawMatch = match[0];
    const command = match[1];

    if (start === undefined || command === undefined) {
      continue;
    }

    resolved += args.line.slice(cursor, start);

    const commandResult = executeInlineCommand({
      cellIndex: args.cellIndex,
      projectRoot: args.projectRoot,
      command,
    });
    if (Either.isLeft(commandResult)) {
      return commandResult;
    }

    resolved += commandResult.right;
    cursor = start + rawMatch.length;
  }

  resolved += args.line.slice(cursor);
  return Either.right(resolved);
};

const executeInlineCommand = (args: {
  readonly cellIndex: number;
  readonly projectRoot: string;
  readonly command: string;
}): Either.Either<string, InlineCommandError> => {
  const result = Bun.spawnSync({
    cmd: ["/bin/bash", "-lc", args.command],
    cwd: args.projectRoot,
    stdout: "pipe",
    stderr: "pipe",
  });

  if (result.exitCode !== 0) {
    return Either.left(
      new InlineCommandError({
        cellIndex: args.cellIndex,
        command: args.command,
        exitCode: result.exitCode ?? 1,
        stderr: textDecoder.decode(result.stderr).trim(),
      }),
    );
  }

  return Either.right(textDecoder.decode(result.stdout));
};

const normalizeNewlines = (value: string): string => value.replaceAll("\r\n", "\n");

const forEachMarkdownLineOutsideFences = (
  content: string,
  onLine: (line: string) => void,
): void => {
  const lines = normalizeNewlines(content).split("\n");

  let insideFence = false;
  for (const line of lines) {
    if (MARKDOWN_FENCE_PATTERN.test(line)) {
      insideFence = !insideFence;
      continue;
    }

    if (insideFence) {
      continue;
    }

    onLine(line);
  }
};
