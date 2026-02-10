import { describe, expect, test } from "bun:test";

import { Either } from "effect";

import { parseProjectMarkdown } from "./parser.ts";

describe("parser", () => {
  test("parseProjectMarkdown returns validated cells with metadata and artifact blocks", () => {
    const markdown = [
      "---",
      "agent: pi",
      "model: null",
      "resolver: explicit",
      "---",
      "# System",
      "",
      "> Keep architecture constraints visible.",
      "",
      "---",
      "## Feature <!-- depends: 0 --> <!-- agent: codex -->",
      "",
      "> Keep changes focused.",
      "",
      "Read @./README.md and run !`echo ok`.",
      "",
      "<!-- drift:summary -->",
      "Added feature implementation.",
      "<!-- /drift:summary -->",
      "",
      "<!-- drift:diff -->",
      "diff --git a/src/feature.ts b/src/feature.ts",
      "<!-- /drift:diff -->",
      "",
    ].join("\n");

    const result = parseProjectMarkdown(markdown);

    expect(Either.isRight(result)).toBe(true);
    if (Either.isLeft(result)) {
      return;
    }

    expect(result.right.config.agent).toBe("pi");
    expect(result.right.cells).toHaveLength(2);

    const rootCell = result.right.cells[0];
    const featureCell = result.right.cells[1];

    expect(rootCell?.index).toBe(0);
    expect(rootCell?.dependencies).toEqual([]);

    expect(featureCell?.index).toBe(1);
    expect(featureCell?.version).toBe(1);
    expect(featureCell?.explicitDeps).toEqual([0]);
    expect(featureCell?.agent).toBe("codex");
    expect(featureCell?.comments).toEqual(["Keep changes focused."]);
    expect(featureCell?.imports.map((candidate) => candidate.raw)).toEqual(["@./README.md"]);
    expect(featureCell?.inlines.map((candidate) => candidate.raw)).toEqual(["!`echo ok`"]);
    expect(featureCell?.dependencies).toEqual([0]);
    expect(featureCell?.artifact?.summary).toContain("Added feature implementation.");
    expect(featureCell?.artifact?.patch).toContain("diff --git");
  });

  test("parseProjectMarkdown returns ParseMarkdownError for invalid frontmatter", () => {
    const markdown = ["---", "agent: claude", "model: null", "# Missing frontmatter close"].join(
      "\n",
    );

    const result = parseProjectMarkdown(markdown);

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left._tag).toBe("ParseMarkdownError");
    expect(result.left.message).toContain("Missing closing frontmatter separator");
  });

  test("parseProjectMarkdown returns ParseMarkdownError for invalid per-cell agent metadata", () => {
    const markdown = [
      "---",
      "model: null",
      "---",
      "## Feature <!-- agent: unknown -->",
      "",
      "Build this feature.",
      "",
    ].join("\n");

    const result = parseProjectMarkdown(markdown);

    expect(Either.isLeft(result)).toBe(true);
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left._tag).toBe("ParseMarkdownError");
    if (result.left._tag === "ParseMarkdownError") {
      expect(result.left.cellIndex).toBe(0);
    }
  });
});
