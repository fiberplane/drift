import { existsSync, watch } from "node:fs";
import { join } from "node:path";

export interface FileChange {
  readonly path: string;
  readonly kind: "created" | "updated" | "deleted";
}

export interface DriftWatcher {
  readonly close: () => void;
}

export const createWatcherSummary = (changes: ReadonlyArray<FileChange>): string => {
  if (changes.length === 0) {
    return "no changes";
  }

  const details = changes.map((change) => `${change.kind}:${change.path}`).join(", ");
  return `${changes.length} file changes detected (${details})`;
};

export const watchDriftCells = (args: {
  readonly rootDir: string;
  readonly onReload: (changes: ReadonlyArray<FileChange>) => void;
  readonly debounceMs?: number;
}): DriftWatcher => {
  const cellsDir = join(args.rootDir, ".drift", "cells");
  if (!existsSync(cellsDir)) {
    return {
      close: () => {},
    };
  }

  const debounceMs = args.debounceMs ?? 80;
  const pendingChanges = new Map<string, FileChange>();
  let timer: ReturnType<typeof setTimeout> | null = null;

  const flush = (): void => {
    timer = null;
    if (pendingChanges.size === 0) {
      return;
    }

    const changes = [...pendingChanges.values()];
    pendingChanges.clear();
    args.onReload(changes);
  };

  const watcher = watch(cellsDir, { recursive: true }, (eventType, fileName) => {
    const normalizedPath = normalizeWatcherPath(fileName);
    if (normalizedPath === null) {
      return;
    }

    const absolutePath = join(cellsDir, normalizedPath);
    const change: FileChange = {
      path: normalizedPath,
      kind: detectChangeKind({
        eventType,
        absolutePath,
      }),
    };

    pendingChanges.set(change.path, change);

    if (timer !== null) {
      clearTimeout(timer);
    }

    timer = setTimeout(flush, debounceMs);
  });

  return {
    close: () => {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }

      watcher.close();
    },
  };
};

const normalizeWatcherPath = (path: string | Buffer | null): string | null => {
  if (path === null) {
    return null;
  }

  const raw = typeof path === "string" ? path : path.toString("utf8");
  const normalized = raw.trim().replaceAll("\\", "/");

  if (normalized === "") {
    return null;
  }

  return normalized;
};

const detectChangeKind = (args: {
  readonly eventType: "rename" | "change";
  readonly absolutePath: string;
}): FileChange["kind"] => {
  if (args.eventType === "change") {
    return "updated";
  }

  return existsSync(args.absolutePath) ? "created" : "deleted";
};
