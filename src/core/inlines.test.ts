import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Either } from "effect";

import { parseInlines, resolveInlinesInContent } from "./inlines.ts";

const tempDirs: string[] = [];

const createTempProject = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "drift-inlines-"));
  tempDirs.push(directory);
  return directory;
};

afterEach(() => {
  for (const directory of tempDirs.splice(0, tempDirs.length)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("inlines", () => {
  test("parseInlines ignores fenced code blocks", () => {
    const content = ["!`echo before`", "```bash", "!`echo ignored`", "```", "!`echo after`"].join(
      "\n",
    );

    expect(parseInlines(content)).toEqual([
      {
        raw: "!`echo before`",
        command: "echo before",
      },
      {
        raw: "!`echo after`",
        command: "echo after",
      },
    ]);
  });

  test("resolveInlinesInContent executes commands in the project root", () => {
    const projectRoot = createTempProject();

    const result = resolveInlinesInContent({
      cellIndex: 3,
      projectRoot,
      content: "cwd: !`pwd`",
    });

    expect(Either.isRight(result)).toBeTrue();
    if (Either.isLeft(result)) {
      return;
    }

    expect(result.right).toContain(projectRoot);
  });

  test("resolveInlinesInContent returns InlineCommandError on non-zero exits", () => {
    const projectRoot = createTempProject();

    const result = resolveInlinesInContent({
      cellIndex: 5,
      projectRoot,
      content: "!`echo boom 1>&2; exit 7`",
    });

    expect(Either.isLeft(result)).toBeTrue();
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left._tag).toBe("InlineCommandError");
    expect(result.left.cellIndex).toBe(5);
    expect(result.left.command).toBe("echo boom 1>&2; exit 7");
    expect(result.left.exitCode).toBe(7);
    expect(result.left.stderr).toContain("boom");
  });
});
