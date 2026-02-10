import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import {
  err,
  ok,
  type BuildArtifact,
  type CellState,
  type ExecutionCell,
  type Result,
} from "../core/execution-engine.ts";
import { normalizePath } from "./types.ts";

export interface DriftCellRecord extends ExecutionCell {
  readonly title: string;
  readonly content: string;
  readonly version: number;
  readonly versionPath: string;
  readonly cellDir: string;
  readonly artifactRef: string | null;
}

export interface DriftProject {
  readonly rootDir: string;
  readonly driftDir: string;
  readonly configRaw: string;
  readonly cells: readonly DriftCellRecord[];
}

export type ProjectError =
  | {
      readonly tag: "missing-drift";
      readonly path: string;
    }
  | {
      readonly tag: "missing-cells";
      readonly path: string;
    }
  | {
      readonly tag: "missing-cell";
      readonly cellIndex: number;
    }
  | {
      readonly tag: "invalid-markdown";
      readonly message: string;
    }
  | {
      readonly tag: "already-exists";
      readonly path: string;
    }
  | {
      readonly tag: "missing-file";
      readonly path: string;
    };

const DEFAULT_CONFIG = `agent: claude
model: sonnet
resolver: explicit
`;

const DEFAULT_CELL_ZERO = `# Project

Describe the project goals and constraints here.
`;

interface ParsedBuildMetadata {
  readonly files: readonly string[];
  readonly ref: string | null;
  readonly timestamp: string | null;
}

export const createNewProject = (rootDir: string): Result<ProjectError, DriftProject> => {
  const driftDir = join(rootDir, ".drift");
  if (existsSync(driftDir)) {
    return err({ tag: "already-exists", path: driftDir });
  }

  const cellsDir = join(driftDir, "cells");
  const cellZeroDir = join(cellsDir, "0");
  mkdirSync(cellZeroDir, { recursive: true });

  writeFileSync(join(driftDir, "config.yaml"), DEFAULT_CONFIG);
  writeFileSync(join(cellZeroDir, "v1.md"), DEFAULT_CELL_ZERO);

  return loadProject(rootDir);
};

export const loadProject = (rootDir: string): Result<ProjectError, DriftProject> => {
  const driftDir = join(rootDir, ".drift");
  if (!existsSync(driftDir)) {
    return err({ tag: "missing-drift", path: driftDir });
  }

  const cellsDir = join(driftDir, "cells");
  if (!existsSync(cellsDir)) {
    return err({ tag: "missing-cells", path: cellsDir });
  }

  const configPath = join(driftDir, "config.yaml");
  const configRaw = existsSync(configPath) ? readFileSync(configPath, "utf8") : DEFAULT_CONFIG;

  const cellIndexes = readdirSync(cellsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => Number.parseInt(entry.name, 10))
    .filter((index) => Number.isFinite(index))
    .sort((left, right) => left - right);

  const cells: DriftCellRecord[] = [];

  for (const index of cellIndexes) {
    const cellDir = join(cellsDir, String(index));
    const versionFiles = readdirSync(cellDir)
      .filter((file) => /^v\d+\.md$/u.test(file))
      .sort((left, right) => parseVersionNumber(left) - parseVersionNumber(right));

    if (versionFiles.length === 0) {
      continue;
    }

    const latestVersionName = versionFiles[versionFiles.length - 1];
    if (latestVersionName === undefined) {
      continue;
    }

    const versionPath = join(cellDir, latestVersionName);
    const content = readFileSync(versionPath, "utf8");
    const dependencies = parseDependencies(content, index);
    const title = parseTitle(content, index);

    const buildMetadata = readBuildMetadata(cellDir);
    const summaryPath = join(cellDir, "artifacts", "summary.md");
    const patchPath = join(cellDir, "artifacts", "build.patch");

    const hasArtifacts =
      buildMetadata.timestamp !== null && existsSync(summaryPath) && existsSync(patchPath);

    const versionMtime = statSync(versionPath).mtime;
    let state: CellState = "stale";

    if (hasArtifacts) {
      const timestamp = buildMetadata.timestamp;
      const artifactDate = timestamp === null ? Number.NaN : Date.parse(timestamp);
      if (Number.isFinite(artifactDate) && versionMtime.getTime() <= artifactDate) {
        state = "clean";
      }
    }

    const artifact: BuildArtifact | null = hasArtifacts
      ? {
          files: [...buildMetadata.files],
          patch: readFileSync(patchPath, "utf8"),
          summary: readFileSync(summaryPath, "utf8"),
          timestamp: buildMetadata.timestamp ?? new Date(0).toISOString(),
        }
      : null;

    cells.push({
      index,
      dependencies,
      dependents: [],
      state,
      artifact,
      title,
      content,
      version: parseVersionNumber(latestVersionName),
      versionPath,
      cellDir,
      artifactRef: buildMetadata.ref,
    });
  }

  const dependentsMap = new Map<number, number[]>();
  for (const cell of cells) {
    dependentsMap.set(cell.index, []);
  }

  for (const cell of cells) {
    for (const dependency of cell.dependencies) {
      const dependents = dependentsMap.get(dependency);
      if (dependents === undefined) {
        continue;
      }
      dependents.push(cell.index);
    }
  }

  const propagatedStates = propagateStaleStates(cells);

  const finalizedCells = cells.map((cell) => ({
    ...cell,
    dependents: [...(dependentsMap.get(cell.index) ?? [])],
    state: propagatedStates.get(cell.index) ?? cell.state,
  }));

  return ok({
    rootDir,
    driftDir,
    configRaw,
    cells: finalizedCells,
  });
};

export const persistExecutionArtifacts = (args: {
  readonly project: DriftProject;
  readonly executedCellIndexes: readonly number[];
  readonly updatedCells: readonly ExecutionCell[];
}): Result<ProjectError, void> => {
  const executed = new Set(args.executedCellIndexes);

  for (const cell of args.updatedCells) {
    if (!executed.has(cell.index)) {
      continue;
    }

    if (cell.artifact === null) {
      continue;
    }

    const sourceCell = args.project.cells.find((candidate) => candidate.index === cell.index);
    if (sourceCell === undefined) {
      return err({ tag: "missing-cell", cellIndex: cell.index });
    }

    writeBuildArtifacts({
      cellDir: sourceCell.cellDir,
      artifact: cell.artifact,
      ref: null,
    });
  }

  return ok(undefined);
};

export const updateCellCommitRef = (args: {
  readonly project: DriftProject;
  readonly cellIndexes: readonly number[];
  readonly ref: string;
}): Result<ProjectError, void> => {
  for (const cellIndex of args.cellIndexes) {
    const cell = args.project.cells.find((candidate) => candidate.index === cellIndex);
    if (cell === undefined || cell.artifact === null) {
      return err({ tag: "missing-cell", cellIndex });
    }

    writeBuildArtifacts({
      cellDir: cell.cellDir,
      artifact: cell.artifact,
      ref: args.ref,
    });
  }

  return ok(undefined);
};

export const createPlannedVersion = (args: {
  readonly project: DriftProject;
  readonly cellIndex: number;
  readonly nowIso: string;
}): Result<ProjectError, { readonly from: number; readonly to: number }> => {
  const cell = args.project.cells.find((candidate) => candidate.index === args.cellIndex);
  if (cell === undefined) {
    return err({ tag: "missing-cell", cellIndex: args.cellIndex });
  }

  const nextVersion = cell.version + 1;
  const nextPath = join(cell.cellDir, `v${nextVersion}.md`);
  const expanded = buildPlannedCellContent(cell.content, args.nowIso);
  writeFileSync(nextPath, expanded);

  return ok({ from: cell.version, to: nextVersion });
};

export const assembleProjectMarkdown = (project: DriftProject): string => {
  const parts: string[] = [];
  parts.push("---");
  parts.push(project.configRaw.trimEnd());
  parts.push("---");

  for (let index = 0; index < project.cells.length; index += 1) {
    const cell = project.cells[index];
    if (cell === undefined) {
      continue;
    }

    const section: string[] = [];
    section.push(cell.content.trimEnd());

    if (cell.artifact !== null) {
      section.push("");
      section.push("<!-- drift:summary -->");
      section.push(cell.artifact.summary.trimEnd());
      section.push("<!-- /drift:summary -->");
      section.push("");
      section.push("<!-- drift:diff -->");
      section.push(cell.artifact.patch.trimEnd());
      section.push("<!-- /drift:diff -->");
    }

    parts.push("");
    parts.push(...section);

    if (index < project.cells.length - 1) {
      parts.push("");
      parts.push("---");
    }
  }

  parts.push("");
  return `${parts.join("\n")}\n`;
};

export const initializeProjectFromMarkdown = (args: {
  readonly rootDir: string;
  readonly markdownPath: string;
  readonly nowIso: string;
}): Result<ProjectError, { readonly cells: number }> => {
  if (!existsSync(args.markdownPath)) {
    return err({ tag: "missing-file", path: args.markdownPath });
  }

  const source = readFileSync(args.markdownPath, "utf8").replaceAll("\r\n", "\n");
  const parsed = parseAssembledMarkdown(source);
  if (!parsed.ok) {
    return parsed;
  }

  const driftDir = join(args.rootDir, ".drift");
  if (existsSync(driftDir)) {
    return err({ tag: "already-exists", path: driftDir });
  }

  const cellsDir = join(driftDir, "cells");
  mkdirSync(cellsDir, { recursive: true });
  writeFileSync(join(driftDir, "config.yaml"), `${parsed.value.config.trimEnd()}\n`);

  for (let index = 0; index < parsed.value.cells.length; index += 1) {
    const parsedCell = parsed.value.cells[index];
    if (parsedCell === undefined) {
      continue;
    }

    const cellDir = join(cellsDir, String(index));
    mkdirSync(cellDir, { recursive: true });
    writeFileSync(join(cellDir, "v1.md"), `${parsedCell.content.trimEnd()}\n`);

    if (parsedCell.summary === null && parsedCell.diff === null) {
      continue;
    }

    const artifact: BuildArtifact = {
      files: [],
      patch: parsedCell.diff ?? "",
      summary: parsedCell.summary ?? "",
      timestamp: args.nowIso,
    };

    writeBuildArtifacts({
      cellDir,
      artifact,
      ref: null,
    });
  }

  return ok({ cells: parsed.value.cells.length });
};

export const ensureGeneratedFile = (args: {
  readonly rootDir: string;
  readonly cellIndex: number;
  readonly title: string;
  readonly content: string;
}): {
  readonly relativePath: string;
  readonly patch: string;
} => {
  const relativePath = normalizePath(join("src", "generated", `cell-${args.cellIndex}.md`));
  const absolutePath = join(args.rootDir, relativePath);
  mkdirSync(dirname(absolutePath), { recursive: true });

  const generated = `# ${args.title}\n\n${args.content.trimEnd()}\n`;
  writeFileSync(absolutePath, generated);

  const lines = generated.trimEnd().split("\n");
  const patchLines = [
    `--- a/${relativePath}`,
    `+++ b/${relativePath}`,
    `@@ -0,0 +1,${lines.length} @@`,
    ...lines.map((line) => `+${line}`),
  ];

  return {
    relativePath,
    patch: `${patchLines.join("\n")}\n`,
  };
};

const propagateStaleStates = (cells: readonly DriftCellRecord[]): Map<number, CellState> => {
  const states = new Map<number, CellState>();

  for (const cell of cells) {
    states.set(cell.index, cell.state);
  }

  let changed = true;
  while (changed) {
    changed = false;

    for (const cell of cells) {
      if ((states.get(cell.index) ?? "stale") !== "clean") {
        continue;
      }

      const dependencyStates = cell.dependencies.map(
        (dependency) => states.get(dependency) ?? "stale",
      );
      if (dependencyStates.some((dependencyState) => dependencyState !== "clean")) {
        states.set(cell.index, "stale");
        changed = true;
      }
    }
  }

  return states;
};

const parseVersionNumber = (fileName: string): number => {
  const matched = fileName.match(/^v(\d+)\.md$/u);
  if (matched === null) {
    return 0;
  }

  const raw = matched[1];
  if (raw === undefined) {
    return 0;
  }

  return Number.parseInt(raw, 10);
};

const parseDependencies = (content: string, index: number): readonly number[] => {
  const matched = content.match(/<!--\s*depends:\s*([^>]+?)\s*-->/iu);
  if (matched === null) {
    if (index === 0) {
      return [];
    }
    return [0];
  }

  const dependencySource = matched[1];
  if (dependencySource === undefined) {
    if (index === 0) {
      return [];
    }
    return [0];
  }

  const values = dependencySource
    .split(",")
    .map((raw) => Number.parseInt(raw.trim(), 10))
    .filter((candidate) => Number.isFinite(candidate));

  return [...new Set(values)].sort((left, right) => left - right);
};

const parseTitle = (content: string, index: number): string => {
  const lines = content.split("\n");
  const heading = lines.find((line) => /^#{1,6}\s+/u.test(line));

  if (heading === undefined) {
    return `Cell ${index}`;
  }

  return heading.replace(/^#{1,6}\s+/u, "").trim();
};

const readBuildMetadata = (cellDir: string): ParsedBuildMetadata => {
  const buildPath = join(cellDir, "artifacts", "build.yaml");
  if (!existsSync(buildPath)) {
    return {
      files: [],
      ref: null,
      timestamp: null,
    };
  }

  return parseBuildYaml(readFileSync(buildPath, "utf8"));
};

const parseBuildYaml = (yaml: string): ParsedBuildMetadata => {
  const lines = yaml.replaceAll("\r\n", "\n").split("\n");

  const files: string[] = [];
  let readingFiles = false;
  let ref: string | null = null;
  let timestamp: string | null = null;

  for (const line of lines) {
    const trimmed = line.trim();

    if (trimmed.startsWith("files:")) {
      readingFiles = true;
      if (trimmed === "files: []") {
        readingFiles = false;
      }
      continue;
    }

    if (trimmed.startsWith("ref:")) {
      readingFiles = false;
      const value = trimmed.slice("ref:".length).trim();
      ref = value === "null" || value === "" ? null : value;
      continue;
    }

    if (trimmed.startsWith("timestamp:")) {
      readingFiles = false;
      const value = trimmed.slice("timestamp:".length).trim();
      timestamp = value === "" ? null : value;
      continue;
    }

    if (readingFiles && trimmed.startsWith("- ")) {
      files.push(trimmed.slice(2).trim());
    }
  }

  return {
    files,
    ref,
    timestamp,
  };
};

const writeBuildArtifacts = (args: {
  readonly cellDir: string;
  readonly artifact: BuildArtifact;
  readonly ref: string | null;
}): void => {
  const artifactsDir = join(args.cellDir, "artifacts");
  mkdirSync(artifactsDir, { recursive: true });

  const buildYaml = renderBuildYaml({
    files: args.artifact.files,
    ref: args.ref,
    timestamp: args.artifact.timestamp,
  });

  writeFileSync(join(artifactsDir, "build.yaml"), buildYaml);
  writeFileSync(join(artifactsDir, "build.patch"), args.artifact.patch);
  writeFileSync(join(artifactsDir, "summary.md"), args.artifact.summary);
};

const renderBuildYaml = (args: {
  readonly files: readonly string[];
  readonly ref: string | null;
  readonly timestamp: string;
}): string => {
  const lines: string[] = [];

  if (args.files.length === 0) {
    lines.push("files: []");
  } else {
    lines.push("files:");
    for (const file of args.files) {
      lines.push(`  - ${file}`);
    }
  }

  lines.push(`ref: ${args.ref ?? "null"}`);
  lines.push(`timestamp: ${args.timestamp}`);

  return `${lines.join("\n")}\n`;
};

const buildPlannedCellContent = (content: string, nowIso: string): string => {
  const lines: string[] = [];
  lines.push(content.trimEnd());
  lines.push("");
  lines.push(`<!-- drift:planned ${nowIso} -->`);
  lines.push("- Expanded execution notes and implementation details.");

  return `${lines.join("\n")}\n`;
};

const parseAssembledMarkdown = (
  source: string,
): Result<
  ProjectError,
  {
    readonly config: string;
    readonly cells: readonly {
      readonly content: string;
      readonly summary: string | null;
      readonly diff: string | null;
    }[];
  }
> => {
  if (!source.startsWith("---\n")) {
    return err({
      tag: "invalid-markdown",
      message: "Assembled markdown must start with YAML frontmatter.",
    });
  }

  const frontmatterEnd = source.indexOf("\n---\n", 4);
  if (frontmatterEnd < 0) {
    return err({
      tag: "invalid-markdown",
      message: "Missing closing frontmatter separator.",
    });
  }

  const config = source.slice(4, frontmatterEnd).trimEnd();
  const remainder = source.slice(frontmatterEnd + "\n---\n".length).trim();

  const chunks = remainder === "" ? [] : remainder.split(/\n---\n/iu);
  const cells = chunks
    .map((chunk) => parseAssembledCell(chunk))
    .filter((chunk) => chunk.content.trim() !== "");

  if (cells.length === 0) {
    return err({
      tag: "invalid-markdown",
      message: "Assembled markdown has no cell sections.",
    });
  }

  return ok({
    config,
    cells,
  });
};

const parseAssembledCell = (
  chunk: string,
): {
  readonly content: string;
  readonly summary: string | null;
  readonly diff: string | null;
} => {
  const summaryMatch = chunk.match(
    /<!--\s*drift:summary\s*-->([\s\S]*?)<!--\s*\/drift:summary\s*-->/iu,
  );
  const diffMatch = chunk.match(/<!--\s*drift:diff\s*-->([\s\S]*?)<!--\s*\/drift:diff\s*-->/iu);

  let content = chunk;
  if (summaryMatch !== null) {
    content = content.replace(summaryMatch[0], "");
  }
  if (diffMatch !== null) {
    content = content.replace(diffMatch[0], "");
  }

  return {
    content: content.trim(),
    summary: summaryMatch?.[1]?.trim() ?? null,
    diff: diffMatch?.[1]?.trim() ?? null,
  };
};
