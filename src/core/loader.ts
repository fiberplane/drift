import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { Either } from "effect";

import { applyDagToCells, buildDagGraph } from "./dag.ts";
import { DagCycleError, LoadProjectError } from "./errors.ts";
import { parseImports } from "./imports.ts";
import { parseInlines } from "./inlines.ts";
import {
  countLeadingSpaces,
  formatDecodeError,
  normalizeNewlines,
  parseYamlScalar,
} from "./parsing-utils.ts";
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

export const loadProjectFromDisk = (rootDir: string): Either.Either<LoadedProject, LoaderError> => {
  const driftDir = join(rootDir, ".drift");
  const configPath = join(driftDir, "config.yaml");
  const cellsPath = join(driftDir, "cells");

  const configResult = loadConfig(configPath);
  if (Either.isLeft(configResult)) {
    return Either.left(configResult.left);
  }

  if (!existsSync(cellsPath)) {
    return Either.left(
      new LoadProjectError({
        path: cellsPath,
        message: "Missing cells directory.",
      }),
    );
  }

  const indexesResult = discoverCellIndexes(cellsPath);
  if (Either.isLeft(indexesResult)) {
    return Either.left(indexesResult.left);
  }

  const cells: Cell[] = [];
  for (const index of indexesResult.right) {
    const cellResult = loadCell({
      cellIndex: index,
      cellsPath,
    });
    if (Either.isLeft(cellResult)) {
      return Either.left(cellResult.left);
    }

    cells.push(cellResult.right);
  }

  const dependencyMap = resolveDependencies(configResult.right.resolver, cells);
  const dagResult = buildDagGraph(dependencyMap);
  if (Either.isLeft(dagResult)) {
    return Either.left(dagResult.left);
  }

  const hydratedCells = applyDagToCells({
    cells,
    dependenciesByCell: dagResult.right.dependenciesByCell,
    dependentsByCell: dagResult.right.dependentsByCell,
  });

  const validatedCellsResult = validateCells(hydratedCells, cellsPath);
  if (Either.isLeft(validatedCellsResult)) {
    return Either.left(validatedCellsResult.left);
  }

  return Either.right({
    config: configResult.right,
    cells: validatedCellsResult.right,
  });
};

const loadConfig = (configPath: string): Either.Either<DriftConfig, LoadProjectError> => {
  if (!existsSync(configPath)) {
    return Either.left(
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
  if (Either.isLeft(parsedResult)) {
    return Either.left(parsedResult.left);
  }

  const decoded = decodeDriftConfig(parsedResult.right);
  if (Either.isLeft(decoded)) {
    return Either.left(
      new LoadProjectError({
        path: configPath,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return Either.right(decoded.right);
};

const discoverCellIndexes = (
  cellsPath: string,
): Either.Either<ReadonlyArray<number>, LoadProjectError> => {
  const indexes = readdirSync(cellsPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => parseCellIndex(entry.name))
    .filter((index): index is number => index !== null)
    .sort((left, right) => left - right);

  return Either.right(indexes);
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
}): Either.Either<Cell, LoadProjectError> => {
  const cellPath = join(args.cellsPath, String(args.cellIndex));
  const versionsResult = discoverVersions({
    cellPath,
    cellIndex: args.cellIndex,
  });
  if (Either.isLeft(versionsResult)) {
    return Either.left(versionsResult.left);
  }

  const latestVersion = versionsResult.right[versionsResult.right.length - 1];
  if (latestVersion === undefined) {
    return Either.left(
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
  if (Either.isLeft(explicitDepsResult)) {
    return Either.left(explicitDepsResult.left);
  }

  const agentResult = parseCellAgent({
    content,
    cellIndex: args.cellIndex,
    path: versionPath,
  });
  if (Either.isLeft(agentResult)) {
    return Either.left(agentResult.left);
  }

  const artifactResult = loadArtifact({
    cellPath,
    cellIndex: args.cellIndex,
  });
  if (Either.isLeft(artifactResult)) {
    return Either.left(artifactResult.left);
  }

  const cellResult = createValidatedCell({
    cellIndex: args.cellIndex,
    content,
    version: versionsResult.right.length,
    explicitDeps: explicitDepsResult.right,
    agent: agentResult.right,
    artifact: artifactResult.right,
    state: determineCellState({
      artifact: artifactResult.right,
      versionPath,
    }),
    path: versionPath,
  });
  if (Either.isLeft(cellResult)) {
    return Either.left(cellResult.left);
  }

  return cellResult;
};

const discoverVersions = (args: {
  readonly cellPath: string;
  readonly cellIndex: number;
}): Either.Either<
  ReadonlyArray<{ readonly fileName: string; readonly value: number }>,
  LoadProjectError
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
    return Either.left(
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
      return Either.left(
        new LoadProjectError({
          path: args.cellPath,
          message: `Cell ${args.cellIndex} has missing versions. Expected v${expected}.md but found v${version.value}.md.`,
        }),
      );
    }
  }

  return Either.right(versions);
};

const parseExplicitDeps = (args: {
  readonly content: string;
  readonly cellIndex: number;
  readonly path: string;
}): Either.Either<ReadonlyArray<number> | null, LoadProjectError> => {
  const matched = args.content.match(DEPENDS_PATTERN);
  if (matched === null) {
    return Either.right(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return Either.left(
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
      return Either.left(
        new LoadProjectError({
          path: args.path,
          message: `Cell ${args.cellIndex} has invalid dependency index '${part}'.`,
        }),
      );
    }

    parsed.push(Number.parseInt(part, 10));
  }

  return Either.right([...new Set(parsed)].sort((left, right) => left - right));
};

const parseCellAgent = (args: {
  readonly content: string;
  readonly cellIndex: number;
  readonly path: string;
}): Either.Either<AgentBackend | null, LoadProjectError> => {
  const matched = args.content.match(AGENT_PATTERN);
  if (matched === null) {
    return Either.right(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return Either.left(
      new LoadProjectError({
        path: args.path,
        message: `Cell ${args.cellIndex} has an empty agent metadata declaration.`,
      }),
    );
  }

  const decoded = decodeAgentBackend(source);
  if (Either.isLeft(decoded)) {
    return Either.left(
      new LoadProjectError({
        path: args.path,
        message: `Cell ${args.cellIndex} has invalid agent '${source}'.`,
      }),
    );
  }

  return Either.right(decoded.right);
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
}): Either.Either<BuildArtifact | null, LoadProjectError> => {
  const artifactsPath = join(args.cellPath, "artifacts");
  const buildPath = join(artifactsPath, "build.yaml");
  const patchPath = join(artifactsPath, "build.patch");
  const summaryPath = join(artifactsPath, "summary.md");

  const hasBuild = existsSync(buildPath);
  const hasPatch = existsSync(patchPath);
  const hasSummary = existsSync(summaryPath);

  if (!hasBuild && !hasPatch && !hasSummary) {
    return Either.right(null);
  }

  if (!(hasBuild && hasPatch && hasSummary)) {
    return Either.left(
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
  if (Either.isLeft(metadataResult)) {
    return Either.left(metadataResult.left);
  }

  const artifactPayload = {
    files: metadataResult.right.files,
    ref: metadataResult.right.ref,
    timestamp: metadataResult.right.timestamp,
    summary: readFileSync(summaryPath, "utf8"),
    patch: readFileSync(patchPath, "utf8"),
  };

  const decoded = decodeBuildArtifact(artifactPayload);
  if (Either.isLeft(decoded)) {
    return Either.left(
      new LoadProjectError({
        path: buildPath,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return Either.right(decoded.right);
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
): Either.Either<ReadonlyArray<Cell>, LoadProjectError> => {
  const validated: Cell[] = [];

  for (const cell of cells) {
    const decoded = decodeCell(cell);
    if (Either.isLeft(decoded)) {
      return Either.left(
        new LoadProjectError({
          path: join(cellsPath, String(cell.index)),
          message: formatDecodeError(decoded.left),
        }),
      );
    }

    validated.push(decoded.right);
  }

  return Either.right(validated);
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
}): Either.Either<Cell, LoadProjectError> => {
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
    return Either.left(
      new LoadProjectError({
        path: args.path,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return Either.right(decoded.right);
};

const parseConfigYaml = (args: {
  readonly source: string;
  readonly path: string;
}): Either.Either<Record<string, unknown>, LoadProjectError> => {
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
      return Either.left(
        new LoadProjectError({
          path: args.path,
          message: `Invalid config line '${trimmed}'.`,
        }),
      );
    }

    const key = matched[1];
    if (key === undefined) {
      return Either.left(
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
      return Either.left(
        new LoadProjectError({
          path: args.path,
          message: `Unexpected indentation in line '${trimmed}'.`,
        }),
      );
    }

    const sectionValue = root[currentSection];
    if (typeof sectionValue !== "object" || sectionValue === null) {
      return Either.left(
        new LoadProjectError({
          path: args.path,
          message: `Config section '${currentSection}' must be an object.`,
        }),
      );
    }

    Reflect.set(sectionValue, key, parseYamlScalar(valueSource));
  }

  return Either.right(root);
};

const parseBuildMetadata = (args: {
  readonly source: string;
  readonly path: string;
}): Either.Either<
  {
    readonly files: ReadonlyArray<string>;
    readonly ref: string | null;
    readonly timestamp: string;
  },
  LoadProjectError
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
    return Either.left(
      new LoadProjectError({
        path: args.path,
        message: "build.yaml is missing a timestamp.",
      }),
    );
  }

  return Either.right({
    files,
    ref,
    timestamp,
  });
};

export const createArtifactFromSummaryAndDiff = (args: {
  readonly summary: string;
  readonly diff: string;
  readonly timestamp?: string;
}): Either.Either<BuildArtifact, LoadProjectError> => {
  const payload = {
    files: [],
    ref: null,
    timestamp: args.timestamp ?? DEFAULT_ARTIFACT_TIMESTAMP,
    summary: args.summary,
    patch: args.diff,
  };

  const decoded = decodeBuildArtifact(payload);
  if (Either.isLeft(decoded)) {
    return Either.left(
      new LoadProjectError({
        path: "markdown",
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return Either.right(decoded.right);
};
