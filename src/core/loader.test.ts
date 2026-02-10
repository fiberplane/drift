import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

import { loadProjectFromDisk } from "./loader.ts";

const createTempDirectory = (): string => mkdtempSync(join(tmpdir(), "drift-loader-"));

const writeFile = (path: string, content: string): void => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
};

describe("loader", () => {
  test("loadProjectFromDisk loads latest versions, metadata, and artifacts", () => {
    const root = createTempDirectory();

    writeFile(
      join(root, ".drift", "config.yaml"),
      [
        "agent: claude",
        "model: null",
        "resolver: explicit",
        "vcs:",
        "  backend: jj",
        "execution:",
        "  parallel: false",
        "",
      ].join("\n"),
    );

    writeFile(
      join(root, ".drift", "cells", "0", "v1.md"),
      "# System\n\n> Keep constraints visible.\n",
    );

    writeFile(join(root, ".drift", "cells", "1", "v1.md"), "## Old\n\nInitial version.\n");
    writeFile(
      join(root, ".drift", "cells", "1", "v2.md"),
      [
        "## API <!-- depends: 0 --> <!-- agent: pi -->",
        "",
        "> Mention API constraints.",
        "",
        "Read @./README.md and run !`echo drift`.",
        "",
      ].join("\n"),
    );

    writeFile(
      join(root, ".drift", "cells", "1", "artifacts", "build.yaml"),
      [
        "files:",
        "  - src/generated/cell-1.md",
        "ref: deadbeef",
        "timestamp: 2099-01-01T00:00:00.000Z",
        "",
      ].join("\n"),
    );
    writeFile(
      join(root, ".drift", "cells", "1", "artifacts", "summary.md"),
      "Generated API updates.\n",
    );
    writeFile(
      join(root, ".drift", "cells", "1", "artifacts", "build.patch"),
      "diff --git a/src/generated/cell-1.md b/src/generated/cell-1.md\n",
    );

    const result = loadProjectFromDisk(root);

    expect(result.ok).toBe(true);
    if (!result.ok) {
      rmSync(root, { recursive: true, force: true });
      return;
    }

    expect(result.value.config.vcs.backend).toBe("jj");
    expect(result.value.cells).toHaveLength(2);

    const cellZero = result.value.cells[0];
    const cellOne = result.value.cells[1];

    expect(cellZero?.index).toBe(0);
    expect(cellZero?.dependencies).toEqual([]);
    expect(cellZero?.dependents).toEqual([1]);

    expect(cellOne?.index).toBe(1);
    expect(cellOne?.version).toBe(2);
    expect(cellOne?.explicitDeps).toEqual([0]);
    expect(cellOne?.agent).toBe("pi");
    expect(cellOne?.imports.map((candidate) => candidate.raw)).toEqual(["@./README.md"]);
    expect(cellOne?.inlines.map((candidate) => candidate.raw)).toEqual(["!`echo drift`"]);
    expect(cellOne?.comments).toEqual(["Mention API constraints."]);
    expect(cellOne?.dependencies).toEqual([0]);
    expect(cellOne?.dependents).toEqual([]);
    expect(cellOne?.state).toBe("clean");
    expect(cellOne?.artifact?.ref).toBe("deadbeef");

    rmSync(root, { recursive: true, force: true });
  });

  test("loadProjectFromDisk returns LoadProjectError for invalid depends metadata", () => {
    const root = createTempDirectory();

    writeFile(join(root, ".drift", "config.yaml"), "model: null\n");
    writeFile(join(root, ".drift", "cells", "0", "v1.md"), "# System\n");
    writeFile(
      join(root, ".drift", "cells", "1", "v1.md"),
      "## API <!-- depends: root -->\n\nInvalid dependency metadata.\n",
    );

    const result = loadProjectFromDisk(root);

    expect(result.ok).toBe(false);
    if (result.ok) {
      rmSync(root, { recursive: true, force: true });
      return;
    }

    expect(result.error._tag).toBe("LoadProjectError");
    expect(result.error.message).toContain("invalid dependency index");

    rmSync(root, { recursive: true, force: true });
  });

  test("loadProjectFromDisk returns DagCycleError when dependencies form a cycle", () => {
    const root = createTempDirectory();

    writeFile(join(root, ".drift", "config.yaml"), "model: null\nresolver: explicit\n");
    writeFile(join(root, ".drift", "cells", "0", "v1.md"), "# System\n");
    writeFile(join(root, ".drift", "cells", "1", "v1.md"), "## A <!-- depends: 2 -->\n");
    writeFile(join(root, ".drift", "cells", "2", "v1.md"), "## B <!-- depends: 1 -->\n");

    const result = loadProjectFromDisk(root);

    expect(result.ok).toBe(false);
    if (result.ok) {
      rmSync(root, { recursive: true, force: true });
      return;
    }

    expect(result.error._tag).toBe("DagCycleError");
    if (result.error._tag === "DagCycleError") {
      expect(result.error.cells).toEqual([1, 2]);
    }

    rmSync(root, { recursive: true, force: true });
  });
});
