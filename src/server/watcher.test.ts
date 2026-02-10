import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { createWatcherSummary, watchDriftCells } from "./watcher.ts";

describe("server watcher", () => {
  test("createWatcherSummary includes change details", () => {
    expect(
      createWatcherSummary([
        { path: "1/v2.md", kind: "updated" },
        { path: "2/artifacts/build.yaml", kind: "deleted" },
      ]),
    ).toBe("2 file changes detected (updated:1/v2.md, deleted:2/artifacts/build.yaml)");

    expect(createWatcherSummary([])).toBe("no changes");
  });

  test("watchDriftCells returns noop watcher when project cells dir is missing", () => {
    const root = mkdtempSync(join(tmpdir(), "drift-watcher-"));
    let called = false;

    const watcher = watchDriftCells({
      rootDir: root,
      onReload: () => {
        called = true;
      },
    });

    watcher.close();
    expect(called).toBe(false);

    rmSync(root, { recursive: true, force: true });
  });
});
