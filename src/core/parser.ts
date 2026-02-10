import { Either } from "effect";

import { applyDagToCells, buildDagGraph } from "./dag.ts";
import { DagCycleError, ParseMarkdownError } from "./errors.ts";
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

const FRONTMATTER_SEPARATOR = "---";
const DEPENDS_PATTERN = /<!--\s*depends:\s*([^>]+?)\s*-->/iu;
const AGENT_PATTERN = /<!--\s*agent:\s*([^>]+?)\s*-->/iu;
const SUMMARY_BLOCK_PATTERN = /<!--\s*drift:summary\s*-->([\s\S]*?)<!--\s*\/drift:summary\s*-->/iu;
const DIFF_BLOCK_PATTERN = /<!--\s*drift:diff\s*-->([\s\S]*?)<!--\s*\/drift:diff\s*-->/iu;
const DEFAULT_ARTIFACT_TIMESTAMP = "1970-01-01T00:00:00.000Z";

export interface ParsedMarkdownProject {
  readonly config: DriftConfig;
  readonly frontmatter: string;
  readonly cells: ReadonlyArray<Cell>;
}

export type MarkdownParserError = ParseMarkdownError | DagCycleError;

export const parseProjectMarkdown = (
  markdown: string,
): Either.Either<ParsedMarkdownProject, MarkdownParserError> => {
  const normalized = normalizeNewlines(markdown).trim();
  if (!normalized.startsWith(`${FRONTMATTER_SEPARATOR}\n`)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: null,
        message: "Assembled markdown must start with YAML frontmatter.",
      }),
    );
  }

  const frontmatterEnd = normalized.indexOf(`\n${FRONTMATTER_SEPARATOR}\n`, 4);
  if (frontmatterEnd < 0) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: null,
        message: "Missing closing frontmatter separator.",
      }),
    );
  }

  const frontmatter = normalized.slice(4, frontmatterEnd).trimEnd();
  const configResult = decodeConfig(frontmatter);
  if (Either.isLeft(configResult)) {
    return Either.left(configResult.left);
  }

  const body = normalized.slice(frontmatterEnd + 5).trim();
  const chunks = splitCellSegments(body);

  if (chunks.length === 0) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: null,
        message: "Assembled markdown has no cell sections.",
      }),
    );
  }

  const cells: Cell[] = [];
  for (let index = 0; index < chunks.length; index += 1) {
    const chunk = chunks[index];
    if (chunk === undefined) {
      continue;
    }

    const cellResult = parseCellChunk({
      chunk,
      index,
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

  const validatedResult = validateCells(hydratedCells);
  if (Either.isLeft(validatedResult)) {
    return Either.left(validatedResult.left);
  }

  return Either.right({
    config: configResult.right,
    frontmatter,
    cells: validatedResult.right,
  });
};

const decodeConfig = (frontmatter: string): Either.Either<DriftConfig, ParseMarkdownError> => {
  const yamlResult = parseConfigYaml(frontmatter);
  if (Either.isLeft(yamlResult)) {
    return Either.left(yamlResult.left);
  }

  const decoded = decodeDriftConfig(yamlResult.right);
  if (Either.isLeft(decoded)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: null,
        message: formatDecodeError(decoded.left),
      }),
    );
  }

  return Either.right(decoded.right);
};

const parseCellChunk = (args: {
  readonly chunk: string;
  readonly index: number;
}): Either.Either<Cell, ParseMarkdownError> => {
  const extractedResult = extractArtifactBlocks(args.chunk, args.index);
  if (Either.isLeft(extractedResult)) {
    return Either.left(extractedResult.left);
  }

  const explicitDepsResult = parseExplicitDeps({
    content: extractedResult.right.content,
    cellIndex: args.index,
  });
  if (Either.isLeft(explicitDepsResult)) {
    return Either.left(explicitDepsResult.left);
  }

  const agentResult = parseAgent({
    content: extractedResult.right.content,
    cellIndex: args.index,
  });
  if (Either.isLeft(agentResult)) {
    return Either.left(agentResult.left);
  }

  const cellPayload: Cell = {
    index: args.index,
    content: extractedResult.right.content,
    explicitDeps: explicitDepsResult.right,
    agent: agentResult.right,
    imports: parseImports(extractedResult.right.content),
    inlines: parseInlines(extractedResult.right.content),
    version: 1,
    dependencies: [],
    dependents: [],
    state: extractedResult.right.artifact === null ? "stale" : "clean",
    comments: parseComments(extractedResult.right.content),
    artifact: extractedResult.right.artifact,
    lastInputHash: null,
  };

  const decodedCell = decodeCell(cellPayload);
  if (Either.isLeft(decodedCell)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: args.index,
        message: formatDecodeError(decodedCell.left),
      }),
    );
  }

  return Either.right(decodedCell.right);
};

const extractArtifactBlocks = (
  chunk: string,
  cellIndex: number,
): Either.Either<
  {
    readonly content: string;
    readonly artifact: BuildArtifact | null;
  },
  ParseMarkdownError
> => {
  const summaryMatch = chunk.match(SUMMARY_BLOCK_PATTERN);
  const diffMatch = chunk.match(DIFF_BLOCK_PATTERN);

  if ((summaryMatch === null) !== (diffMatch === null)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex,
        message: "Cell artifact blocks must include both summary and diff sections.",
      }),
    );
  }

  let content = chunk;
  if (summaryMatch !== null) {
    const summaryBlock = summaryMatch[0];
    if (summaryBlock !== undefined) {
      content = content.replace(summaryBlock, "");
    }
  }

  if (diffMatch !== null) {
    const diffBlock = diffMatch[0];
    if (diffBlock !== undefined) {
      content = content.replace(diffBlock, "");
    }
  }

  const normalizedContent = content.trim();

  if (summaryMatch === null || diffMatch === null) {
    return Either.right({
      content: normalizedContent,
      artifact: null,
    });
  }

  const summary = summaryMatch[1]?.trim() ?? "";
  const diff = diffMatch[1]?.trim() ?? "";

  const decodedArtifact = decodeBuildArtifact({
    files: [],
    ref: null,
    timestamp: DEFAULT_ARTIFACT_TIMESTAMP,
    summary,
    patch: diff,
  });

  if (Either.isLeft(decodedArtifact)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex,
        message: formatDecodeError(decodedArtifact.left),
      }),
    );
  }

  return Either.right({
    content: normalizedContent,
    artifact: decodedArtifact.right,
  });
};

const parseExplicitDeps = (args: {
  readonly content: string;
  readonly cellIndex: number;
}): Either.Either<ReadonlyArray<number> | null, ParseMarkdownError> => {
  const matched = args.content.match(DEPENDS_PATTERN);
  if (matched === null) {
    return Either.right(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: args.cellIndex,
        message: "Cell has an empty depends metadata declaration.",
      }),
    );
  }

  const dependencies: number[] = [];
  for (const rawPart of source.split(",")) {
    const part = rawPart.trim();
    if (part === "") {
      continue;
    }

    if (!/^\d+$/u.test(part)) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: args.cellIndex,
          message: `Cell has invalid dependency index '${part}'.`,
        }),
      );
    }

    dependencies.push(Number.parseInt(part, 10));
  }

  return Either.right([...new Set(dependencies)].sort((left, right) => left - right));
};

const parseAgent = (args: {
  readonly content: string;
  readonly cellIndex: number;
}): Either.Either<AgentBackend | null, ParseMarkdownError> => {
  const matched = args.content.match(AGENT_PATTERN);
  if (matched === null) {
    return Either.right(null);
  }

  const source = matched[1]?.trim() ?? "";
  if (source === "") {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: args.cellIndex,
        message: "Cell has an empty agent metadata declaration.",
      }),
    );
  }

  const decodedAgent = decodeAgentBackend(source);
  if (Either.isLeft(decodedAgent)) {
    return Either.left(
      new ParseMarkdownError({
        cellIndex: args.cellIndex,
        message: `Cell has invalid agent '${source}'.`,
      }),
    );
  }

  return Either.right(decodedAgent.right);
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

const validateCells = (
  cells: ReadonlyArray<Cell>,
): Either.Either<ReadonlyArray<Cell>, ParseMarkdownError> => {
  const validated: Cell[] = [];

  for (const cell of cells) {
    const decoded = decodeCell(cell);
    if (Either.isLeft(decoded)) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: cell.index,
          message: formatDecodeError(decoded.left),
        }),
      );
    }

    validated.push(decoded.right);
  }

  return Either.right(validated);
};

const parseConfigYaml = (
  source: string,
): Either.Either<Record<string, unknown>, ParseMarkdownError> => {
  const config: Record<string, unknown> = {};
  let currentSection: "vcs" | "execution" | null = null;

  for (const rawLine of normalizeNewlines(source).split("\n")) {
    const trimmed = rawLine.trim();
    if (trimmed === "" || trimmed.startsWith("#")) {
      continue;
    }

    const matched = trimmed.match(/^([A-Za-z][\w-]*):\s*(.*)$/u);
    if (matched === null) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: null,
          message: `Invalid frontmatter line '${trimmed}'.`,
        }),
      );
    }

    const key = matched[1];
    if (key === undefined) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: null,
          message: `Invalid frontmatter line '${trimmed}'.`,
        }),
      );
    }

    const valueSource = matched[2] ?? "";
    const indent = countLeadingSpaces(rawLine);

    if (indent === 0) {
      currentSection = null;

      if ((key === "vcs" || key === "execution") && valueSource === "") {
        config[key] = {};
        currentSection = key;
        continue;
      }

      config[key] = parseYamlScalar(valueSource);
      continue;
    }

    if (currentSection === null) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: null,
          message: `Unexpected indentation in line '${trimmed}'.`,
        }),
      );
    }

    const section = config[currentSection];
    if (typeof section !== "object" || section === null) {
      return Either.left(
        new ParseMarkdownError({
          cellIndex: null,
          message: `Frontmatter section '${currentSection}' must be an object.`,
        }),
      );
    }

    Reflect.set(section, key, parseYamlScalar(valueSource));
  }

  return Either.right(config);
};

const splitCellSegments = (content: string): ReadonlyArray<string> => {
  if (content.trim() === "") {
    return [];
  }

  const segments: string[] = [];
  let current: string[] = [];

  for (const line of normalizeNewlines(content).split("\n")) {
    if (line.trim() === FRONTMATTER_SEPARATOR) {
      const chunk = current.join("\n").trim();
      if (chunk !== "") {
        segments.push(chunk);
      }

      current = [];
      continue;
    }

    current.push(line);
  }

  const trailing = current.join("\n").trim();
  if (trailing !== "") {
    segments.push(trailing);
  }

  return segments;
};
