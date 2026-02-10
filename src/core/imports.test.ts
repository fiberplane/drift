import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Either } from "effect";

import { parseImports, resolveImportsInContent } from "./imports.ts";

const tempDirs: string[] = [];

const createTempProject = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "drift-imports-"));
  tempDirs.push(directory);
  return directory;
};

afterEach(() => {
  for (const directory of tempDirs.splice(0, tempDirs.length)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("imports", () => {
  test("parseImports supports file/glob/range/symbol and ignores fenced code blocks", () => {
    const content = [
      "@./src/routes/todos.ts",
      "@./src/**/*.ts",
      "@./src/api.ts:10-50",
      "@./src/types.ts#UserInterface",
      "",
      "```ts",
      "@./ignored.ts",
      "```",
    ].join("\n");

    expect(parseImports(content)).toEqual([
      {
        raw: "@./src/routes/todos.ts",
        kind: "file",
        path: "./src/routes/todos.ts",
        range: undefined,
        symbol: undefined,
      },
      {
        raw: "@./src/**/*.ts",
        kind: "glob",
        path: "./src/**/*.ts",
        range: undefined,
        symbol: undefined,
      },
      {
        raw: "@./src/api.ts:10-50",
        kind: "range",
        path: "./src/api.ts",
        range: [10, 50],
        symbol: undefined,
      },
      {
        raw: "@./src/types.ts#UserInterface",
        kind: "symbol",
        path: "./src/types.ts",
        range: undefined,
        symbol: "UserInterface",
      },
    ]);
  });

  test("resolveImportsInContent resolves references deterministically", () => {
    const projectRoot = createTempProject();
    const srcDir = join(projectRoot, "src");
    mkdirSync(srcDir, { recursive: true });

    writeFileSync(
      join(srcDir, "a.ts"),
      ["export const first = 1;", "export const second = 2;", "export const third = 3;", ""].join(
        "\n",
      ),
    );
    writeFileSync(join(srcDir, "b.ts"), "export const onlyInB = true;\n");
    writeFileSync(
      join(srcDir, "types.ts"),
      [
        "export interface UserInterface {",
        "  readonly id: string;",
        "}",
        "",
        "export const helper = true;",
        "",
      ].join("\n"),
    );

    const content = ["@./src/*.ts", "@./src/a.ts:2-3", "@./src/types.ts#UserInterface"].join("\n");

    const result = resolveImportsInContent({
      cellIndex: 4,
      projectRoot,
      content,
    });

    expect(Either.isRight(result)).toBeTrue();
    if (Either.isLeft(result)) {
      return;
    }

    const firstAIndex = result.right.indexOf('<file path="src/a.ts">');
    const firstBIndex = result.right.indexOf('<file path="src/b.ts">');
    const firstTypesIndex = result.right.indexOf('<file path="src/types.ts">');

    expect(firstAIndex).toBeLessThan(firstBIndex);
    expect(firstBIndex).toBeLessThan(firstTypesIndex);

    expect(result.right).toContain("export const second = 2;\nexport const third = 3;");
    expect(result.right).toContain("export interface UserInterface {");
  });

  test("resolveImportsInContent ignores fenced references and fails on unresolved imports", () => {
    const projectRoot = createTempProject();
    mkdirSync(join(projectRoot, "src"), { recursive: true });

    const content = ["```markdown", "@./src/missing.ts", "```", "@./src/also-missing.ts"].join(
      "\n",
    );

    const result = resolveImportsInContent({
      cellIndex: 9,
      projectRoot,
      content,
    });

    expect(Either.isLeft(result)).toBeTrue();
    if (Either.isRight(result)) {
      return;
    }

    expect(result.left._tag).toBe("ImportNotFoundError");
    expect(result.left.cellIndex).toBe(9);
    expect(result.left.importRef).toBe("@./src/also-missing.ts");
  });
});
