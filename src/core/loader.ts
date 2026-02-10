import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { Either } from "effect";

import { applyDagToCells, buildDagGraph } from "./dag.ts";
import { err, ok, type Result } from "./execution-engine.ts";
import { DagCycleError, LoadProjectError } from "./errors.ts";
import { parseImports } from "./imports.ts";
import { parseInlines } from "./inlines.ts";
import { resolveDependencies } from "./resolver.ts";
import {
  decodeAgentBackend,
  decodeBuildArtifact,
  decodeCell,
  decodeDriftConfig,
  type AgentBackend,
  type BuildArtifact,
  type Cell,
  type DriftConfig,
} from "./schemas.ts";

const VERSION_FILE_PATTERN = /^v(\d+)\.md$/u;
const DEPENDS_PATTERN = /<!--\s*depends:\s*([^>]+?)\s*-->/iu;
const AGENT_PATTERN = /<!--\s*agent:\s*([^>]+?)\s*-->/iu;
const DEFAULT_ARTIFACT_TIMESTAMP = "1970-01-01T00:00:00.000Z";

export interface LoadedProject {
  readonly config: DriftConfig;
  readonly cells: ReadonlyArray<Cell>;
}

export type LoaderError = LoadProjectError | DagCycleError;

export const createEmptyProject = (config: DriftConfig): LoadedProject => ({
  config,
  cells: [],
});

export const loadProjectFromDisk = (rootDir: string): Result<LoaderError, LoadedProject> => {
  const driftDir = join(rootDir, ".drift");
  const configPath = join(driftDir, "config.yaml");
  const cellsPath = join(driftDir, "cells");

  const configResult = loadConfig(configPath);
  if (!configResult.ok) {
    return configResult;
  }

  if (!existsSync(cellsPath)) {
    return err(
      new LoadProjectError({
        path: cellsPath,
        message: "Missing cells directory.",
      }),
    );
  }

  const indexesResult = discoverCellIndexes(cellsPath);
  if (!indexesResult.ok) {
    return indexesResult;
  }

  const cells: Cell[] = [];
  for (const index of indexesResult.value) {
    const cellResult = loadCell({
      cellIndex: index,
      cellsPath,
    });
    if (!cellResult.ok) {
      return cellResult;
    }

    cells.push(cellResult.value);
  }

  const dependencyMap = resolveDependencies(configResult.value.resolver, cells);
  const dagResult = buildDagGraph(dependencyMap);
  if (!dagResult.ok) {
    return err(dagResult.error);
  }

  const hydratedCells = applyDagToCells({
    cells,
    dependenciesByCell: dagResult.value.dependenciesByCell,
    dependentsByCell: dagResult.value.dependentsByCell,
  });

  const validatedCellsResult = validateCells(hydratedCells, cellsPath);
  if (!validatedCellsResult.ok) {
    return validatedCellsResult;
  }

  return ok({
    config: configResult.value,
    cells: validatedCellsResult.value,
  });
};

const loadConfig = (configPath: string): Result<LoadProjectError, DriftConfig> => {
  if (!existsSync(configPath)) {
    return err(
      new LoadProjectError({
        path: configPath,
        message: "Missing Drift config file.",
      }),
    );
  }

  const source = normalizeNewlines(readFileSync(configPath, "utf8"));
  const parsedResult = parseConfigYaml({
    source,
    path: configPath,
  });
  if (!parsedResult.ok) {
    return parsedResult;
  }

  const decoded = decodeDriftConfig(parsedResult.value);
  if (Either.isLeft(decoded)) {
    return err(
      new LoadProjectError({
        path: configPath,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return ok(decoded.right);
};

const discoverCellIndexes = (
  cellsPath: string,
): Result<LoadProjectError, ReadonlyArray<number>> => {
  const indexes = readdirSync(cellsPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => parseCellIndex(entry.name))
    .filter((index): index is number => index !== null)
    .sort((left, right) => left - right);

  return ok(indexes);
};

const parseCellIndex = (value: string): number | null => {
  if (!/^\d+$/u.test(value)) {
    return null;
  }

  return Number.parseInt(value, 10);
};

const loadCell = (args: {
  readonly cellIndex: number;
  readonly cellsPath: string;
}): Result<LoadProjectError, Cell> => {
  const cellPath = join(args.cellsPath, String(args.cellIndex));
  const versionsResult = discoverVersions({
    cellPath,
    cellIndex: args.cellIndex,
  });
  if (!versionsResult.ok) {
    return versionsResult;
  }

  const latestVersion = versionsResult.value[versionsResult.value.length - 1];
  if (latestVersion === undefined) {
    return err(
      new LoadProjectError({
        path: cellPath,
        message: "Cell has no version files.",
      }),
    );
  }

  const versionPath = join(cellPath, latestVersion.fileName);
  const content = normalizeNewlines(readFileSync(versionPath, "utf8"));

  const explicitDepsResult = parseExplicitDeps({
    content,
    cellIndex: args.cellIndex,
    path: versionPath,
  });
  if (!explicitDepsResult.ok) {
    return explicitDepsResult;
  }

  const agentResult = parseCellAgent({
    content,
    cellIndex: args.cellIndex,
    path: versionPath,
  });
  if (!agentResult.ok) {
    return agentResult;
  }

  const artifactResult = loadArtifact({
    cellPath,
    cellIndex: args.cellIndex,
  });
  if (!artifactResult.ok) {
    return artifactResult;
  }

  const cellResult = createValidatedCell({
    cellIndex: args.cellIndex,
    content,
    version: versionsResult.value.length,
    explicitDeps: explicitDepsResult.value,
    agent: agentResult.value,
    artifact: artifactResult.value,
    state: determineCellState({
      artifact: artifactResult.value,
      versionPath,
    }),
    path: versionPath,
  });
  if (!cellResult.ok) {
    return cellResult;
  }

  return cellResult;
};

const discoverVersions = (args: {
  readonly cellPath: string;
  readonly cellIndex: number;
}): Result<
  LoadProjectError,
  ReadonlyArray<{ readonly fileName: string; readonly value: number }>
> => {
  const versions = readdirSync(args.cellPath)
    .map((fileName) => {
      const matched = fileName.match(VERSION_FILE_PATTERN);
      if (matched === null) {
        return null;
      }

      const versionRaw = matched[1];
      if (versionRaw === undefined) {
        return null;
      }

      return {
        fileName,
        value: Number.parseInt(versionRaw, 10),
      };
    })
    .filter(
      (version): version is { readonly fileName: string; readonly value: number } =>
        version !== null,
    )
    .sort((left, right) => left.value - right.value);

  if (versions.length === 0) {
    return err(
      new LoadProjectError({
        path: args.cellPath,
        message: `Cell ${args.cellIndex} has no versioned markdown files.`,
      }),
    );
  }

  for (let index = 0; index < versions.length; index += 1) {
    const version = versions[index];
    if (version === undefined) {
      continue;
    }

    const expected = index + 1;
    if (version.value !== expected) {
      return err(
        new LoadProjectError({
          path: args.cellPath,
          message: `Cell ${args.cellIndex} has missing versions. Expected v${expected}.md but found v${version.value}.md.`,
        }),
      );
    }
  }

  return ok(versions);
};

const parseExplicitDeps = (args: {
  readonly content: string;
  readonly cellIndex: number;
  readonly path: string;
}): Result<LoadProjectError, ReadonlyArray<number> | null> => {
  const matched = args.content.match(DEPENDS_PATTERN);
  if (matched === null) {
    return ok(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return err(
      new LoadProjectError({
        path: args.path,
        message: `Cell ${args.cellIndex} has an empty depends metadata declaration.`,
      }),
    );
  }

  const parsed: number[] = [];
  for (const rawPart of source.split(",")) {
    const part = rawPart.trim();
    if (part === "") {
      continue;
    }

    if (!/^\d+$/u.test(part)) {
      return err(
        new LoadProjectError({
          path: args.path,
          message: `Cell ${args.cellIndex} has invalid dependency index '${part}'.`,
        }),
      );
    }

    parsed.push(Number.parseInt(part, 10));
  }

  return ok([...new Set(parsed)].sort((left, right) => left - right));
};

const parseCellAgent = (args: {
  readonly content: string;
  readonly cellIndex: number;
  readonly path: string;
}): Result<LoadProjectError, AgentBackend | null> => {
  const matched = args.content.match(AGENT_PATTERN);
  if (matched === null) {
    return ok(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return err(
      new LoadProjectError({
        path: args.path,
        message: `Cell ${args.cellIndex} has an empty agent metadata declaration.`,
      }),
    );
  }

  const decoded = decodeAgentBackend(source);
  if (Either.isLeft(decoded)) {
    return err(
      new LoadProjectError({
        path: args.path,
        message: `Cell ${args.cellIndex} has invalid agent '${source}'.`,
      }),
    );
  }

  return ok(decoded.right);
};

const parseComments = (content: string): ReadonlyArray<string> => {
  const comments: string[] = [];

  for (const line of normalizeNewlines(content).split("\n")) {
    const matched = line.match(/^\s*>\s?(.*)$/u);
    if (matched === null) {
      continue;
    }

    const comment = matched[1]?.trim() ?? "";
    if (comment === "") {
      continue;
    }

    comments.push(comment);
  }

  return comments;
};

const loadArtifact = (args: {
  readonly cellPath: string;
  readonly cellIndex: number;
}): Result<LoadProjectError, BuildArtifact | null> => {
  const artifactsPath = join(args.cellPath, "artifacts");
  const buildPath = join(artifactsPath, "build.yaml");
  const patchPath = join(artifactsPath, "build.patch");
  const summaryPath = join(artifactsPath, "summary.md");

  const hasBuild = existsSync(buildPath);
  const hasPatch = existsSync(patchPath);
  const hasSummary = existsSync(summaryPath);

  if (!hasBuild && !hasPatch && !hasSummary) {
    return ok(null);
  }

  if (!(hasBuild && hasPatch && hasSummary)) {
    return err(
      new LoadProjectError({
        path: artifactsPath,
        message: `Cell ${args.cellIndex} has incomplete artifacts. Expected build.yaml, build.patch, and summary.md.`,
      }),
    );
  }

  const metadataResult = parseBuildMetadata({
    source: normalizeNewlines(readFileSync(buildPath, "utf8")),
    path: buildPath,
  });
  if (!metadataResult.ok) {
    return metadataResult;
  }

  const artifactPayload = {
    files: metadataResult.value.files,
    ref: metadataResult.value.ref,
    timestamp: metadataResult.value.timestamp,
    summary: readFileSync(summaryPath, "utf8"),
    patch: readFileSync(patchPath, "utf8"),
  };

  const decoded = decodeBuildArtifact(artifactPayload);
  if (Either.isLeft(decoded)) {
    return err(
      new LoadProjectError({
        path: buildPath,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return ok(decoded.right);
};

const determineCellState = (args: {
  readonly artifact: BuildArtifact | null;
  readonly versionPath: string;
}): Cell["state"] => {
  if (args.artifact === null) {
    return "stale";
  }

  const artifactTime = Date.parse(args.artifact.timestamp);
  if (!Number.isFinite(artifactTime)) {
    return "stale";
  }

  const versionTime = statSync(args.versionPath).mtime.getTime();
  return artifactTime >= versionTime ? "clean" : "stale";
};

const validateCells = (
  cells: ReadonlyArray<Cell>,
  cellsPath: string,
): Result<LoadProjectError, ReadonlyArray<Cell>> => {
  const validated: Cell[] = [];

  for (const cell of cells) {
    const decoded = decodeCell(cell);
    if (Either.isLeft(decoded)) {
      return err(
        new LoadProjectError({
          path: join(cellsPath, String(cell.index)),
          message: formatDecodeError(decoded.left),
        }),
      );
    }

    validated.push(decoded.right);
  }

  return ok(validated);
};

const createValidatedCell = (args: {
  readonly cellIndex: number;
  readonly content: string;
  readonly version: number;
  readonly explicitDeps: ReadonlyArray<number> | null;
  readonly agent: AgentBackend | null;
  readonly artifact: BuildArtifact | null;
  readonly state: Cell["state"];
  readonly path: string;
}): Result<LoadProjectError, Cell> => {
  const payload: Cell = {
    index: args.cellIndex,
    content: args.content,
    explicitDeps: args.explicitDeps,
    agent: args.agent,
    imports: parseImports(args.content),
    inlines: parseInlines(args.content),
    version: args.version,
    dependencies: [],
    dependents: [],
    state: args.state,
    comments: parseComments(args.content),
    artifact: args.artifact,
    lastInputHash: null,
  };

  const decoded = decodeCell(payload);
  if (Either.isLeft(decoded)) {
    return err(
      new LoadProjectError({
        path: args.path,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return ok(decoded.right);
};

const parseConfigYaml = (args: {
  readonly source: string;
  readonly path: string;
}): Result<LoadProjectError, Record<string, unknown>> => {
  const root: Record<string, unknown> = {};
  let currentSection: "vcs" | "execution" | null = null;

  for (const rawLine of normalizeNewlines(args.source).split("\n")) {
    const trimmed = rawLine.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    const indent = countLeadingSpaces(rawLine);
    const matched = trimmed.match(/^([A-Za-z][\w-]*):\s*(.*)$/u);
    if (matched === null) {
      return err(
        new LoadProjectError({
          path: args.path,
          message: `Invalid config line '${trimmed}'.`,
        }),
      );
    }

    const key = matched[1];
    if (key === undefined) {
      return err(
        new LoadProjectError({
          path: args.path,
          message: `Invalid config line '${trimmed}'.`,
        }),
      );
    }

    const valueSource = matched[2] ?? "";

    if (indent === 0) {
      currentSection = null;

      if ((key === "vcs" || key === "execution") && valueSource === "") {
        root[key] = {};
        currentSection = key;
        continue;
      }

      root[key] = parseYamlScalar(valueSource);
      continue;
    }

    if (currentSection === null) {
      return err(
        new LoadProjectError({
          path: args.path,
          message: `Unexpected indentation in line '${trimmed}'.`,
        }),
      );
    }

    const sectionValue = root[currentSection];
    if (typeof sectionValue !== "object" || sectionValue === null) {
      return err(
        new LoadProjectError({
          path: args.path,
          message: `Config section '${currentSection}' must be an object.`,
        }),
      );
    }

    Reflect.set(sectionValue, key, parseYamlScalar(valueSource));
  }

  return ok(root);
};

const parseBuildMetadata = (args: {
  readonly source: string;
  readonly path: string;
}): Result<
  LoadProjectError,
  { readonly files: ReadonlyArray<string>; readonly ref: string | null; readonly timestamp: string }
> => {
  const files: string[] = [];
  let readingFiles = false;
  let ref: string | null = null;
  let timestamp: string | null = null;

  for (const rawLine of normalizeNewlines(args.source).split("\n")) {
    const trimmed = rawLine.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    if (trimmed === "files:" || trimmed.startsWith("files:")) {
      readingFiles = true;

      if (trimmed === "files: []") {
        readingFiles = false;
      }

      continue;
    }

    if (readingFiles && trimmed.startsWith("- ")) {
      files.push(trimmed.slice(2).trim());
      continue;
    }

    if (trimmed.startsWith("ref:")) {
      readingFiles = false;
      const value = trimmed.slice("ref:".length).trim();
      ref = value === "" || value === "null" ? null : value;
      continue;
    }

    if (trimmed.startsWith("timestamp:")) {
      readingFiles = false;
      const value = trimmed.slice("timestamp:".length).trim();
      timestamp = value;
      continue;
    }
  }

  if (timestamp === null || timestamp === "") {
    return err(
      new LoadProjectError({
        path: args.path,
        message: "build.yaml is missing a timestamp.",
      }),
    );
  }

  return ok({
    files,
    ref,
    timestamp,
  });
};

const parseYamlScalar = (source: string): unknown => {
  const trimmed = source.trim();

  if (trimmed === "" || trimmed === "null") {
    return null;
  }

  if (trimmed === "true") {
    return true;
  }

  if (trimmed === "false") {
    return false;
  }

  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }

  return trimmed;
};

const countLeadingSpaces = (line: string): number => {
  const matched = line.match(/^\s*/u);
  const prefix = matched?.[0] ?? "";
  return prefix.length;
};

const formatDecodeError = (error: unknown): string =>
  typeof error === "string" ? error : JSON.stringify(error, null, 2);

const normalizeNewlines = (value: string): string => value.replaceAll("\r\n", "\n");

export const createArtifactFromSummaryAndDiff = (args: {
  readonly summary: string;
  readonly diff: string;
  readonly timestamp?: string;
}): Result<LoadProjectError, BuildArtifact> => {
  const payload = {
    files: [],
    ref: null,
    timestamp: args.timestamp ?? DEFAULT_ARTIFACT_TIMESTAMP,
    summary: args.summary,
    patch: args.diff,
  };

  const decoded = decodeBuildArtifact(payload);
  if (Either.isLeft(decoded)) {
    return err(
      new LoadProjectError({
        path: "markdown",
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return ok(decoded.right);
};
