import { existsSync, readFileSync, statSync } from "node:fs";
import { isAbsolute, join, normalize } from "node:path";

import { Either } from "effect";

import { ImportNotFoundError } from "./errors.ts";
import type { Import } from "./schemas.ts";

const IMPORT_REFERENCE_PATTERN = /(^|\s)@([^\s`]+)/g;
const RANGE_REFERENCE_PATTERN = /^(.*):(\d+)-(\d+)$/;
const SYMBOL_REFERENCE_PATTERN = /^(.*)#([A-Za-z_$][\w$]*)$/;
const GLOB_TOKEN_PATTERN = /[*?[{]/;
const MARKDOWN_FENCE_PATTERN = /^\s*```/;

interface ResolveImportsArgs {
  readonly cellIndex: number;
  readonly projectRoot: string;
  readonly content: string;
}

interface ResolveImportReferenceArgs {
  readonly cellIndex: number;
  readonly projectRoot: string;
  readonly importRef: Import;
}

interface ResolvedImport {
  readonly path: string;
  readonly content: string;
}

export const parseImports = (content: string): ReadonlyArray<Import> => {
  const imports: Import[] = [];

  forEachMarkdownLineOutsideFences(content, (line) => {
    for (const match of line.matchAll(IMPORT_REFERENCE_PATTERN)) {
      const reference = match[2];
      if (reference === undefined) {
        continue;
      }

      imports.push(parseImportReference(`@${reference}`));
    }
  });

  return imports;
};

export const resolveImportsInContent = (
  args: ResolveImportsArgs,
): Either.Either<string, ImportNotFoundError> => {
  const lines = normalizeNewlines(args.content).split("\n");
  const resolvedLines: string[] = [];

  let insideFence = false;
  for (const line of lines) {
    if (MARKDOWN_FENCE_PATTERN.test(line)) {
      insideFence = !insideFence;
      resolvedLines.push(line);
      continue;
    }

    if (insideFence) {
      resolvedLines.push(line);
      continue;
    }

    const resolvedLine = resolveImportsInLine({
      line,
      cellIndex: args.cellIndex,
      projectRoot: args.projectRoot,
    });
    if (Either.isLeft(resolvedLine)) {
      return resolvedLine;
    }

    resolvedLines.push(resolvedLine.right);
  }

  return Either.right(resolvedLines.join("\n"));
};

const resolveImportsInLine = (args: {
  readonly line: string;
  readonly cellIndex: number;
  readonly projectRoot: string;
}): Either.Either<string, ImportNotFoundError> => {
  const matches = [...args.line.matchAll(IMPORT_REFERENCE_PATTERN)];
  if (matches.length === 0) {
    return Either.right(args.line);
  }

  let resolved = "";
  let cursor = 0;

  for (const match of matches) {
    const start = match.index;
    const rawMatch = match[0];
    const prefix = match[1] ?? "";
    const reference = match[2];

    if (start === undefined || reference === undefined) {
      continue;
    }

    resolved += args.line.slice(cursor, start);

    const parsedImport = parseImportReference(`@${reference}`);
    const referenceResult = resolveImportReference({
      cellIndex: args.cellIndex,
      projectRoot: args.projectRoot,
      importRef: parsedImport,
    });
    if (Either.isLeft(referenceResult)) {
      return Either.left(referenceResult.left);
    }

    const renderedBlocks = referenceResult.right.map(renderResolvedImport).join("\n\n");
    resolved += `${prefix}${renderedBlocks}`;

    cursor = start + rawMatch.length;
  }

  resolved += args.line.slice(cursor);
  return Either.right(resolved);
};

const resolveImportReference = (
  args: ResolveImportReferenceArgs,
): Either.Either<ReadonlyArray<ResolvedImport>, ImportNotFoundError> => {
  const pathsResult = resolveImportPaths(args);
  if (Either.isLeft(pathsResult)) {
    return Either.left(pathsResult.left);
  }

  const resolved: ResolvedImport[] = [];

  for (const relativePath of pathsResult.right) {
    const absolutePath = toAbsolutePath(args.projectRoot, relativePath);
    if (!existsSync(absolutePath) || !statSync(absolutePath).isFile()) {
      return Either.left(
        new ImportNotFoundError({
          cellIndex: args.cellIndex,
          importRef: args.importRef.raw,
        }),
      );
    }

    const source = normalizeNewlines(readFileSync(absolutePath, "utf8"));
    const contentResult = extractImportedContent({
      cellIndex: args.cellIndex,
      importRef: args.importRef,
      source,
    });
    if (Either.isLeft(contentResult)) {
      return Either.left(contentResult.left);
    }

    resolved.push({
      path: normalizeDisplayPath(relativePath),
      content: contentResult.right,
    });
  }

  return Either.right(resolved.sort((left, right) => left.path.localeCompare(right.path)));
};

const resolveImportPaths = (
  args: ResolveImportReferenceArgs,
): Either.Either<ReadonlyArray<string>, ImportNotFoundError> => {
  if (args.importRef.kind !== "glob") {
    return Either.right([normalizeDisplayPath(args.importRef.path)]);
  }

  const matches = [
    ...new Bun.Glob(args.importRef.path).scanSync({ cwd: args.projectRoot, dot: true }),
  ]
    .map((match) => normalizeDisplayPath(match))
    .sort((left, right) => left.localeCompare(right));

  if (matches.length === 0) {
    return Either.left(
      new ImportNotFoundError({
        cellIndex: args.cellIndex,
        importRef: args.importRef.raw,
      }),
    );
  }

  return Either.right(matches);
};

const extractImportedContent = (args: {
  readonly cellIndex: number;
  readonly importRef: Import;
  readonly source: string;
}): Either.Either<string, ImportNotFoundError> => {
  switch (args.importRef.kind) {
    case "file":
    case "glob":
      return Either.right(args.source.trimEnd());
    case "range": {
      const range = args.importRef.range;
      if (range === undefined) {
        return Either.right(args.source.trimEnd());
      }

      const selectedLines = pickLineRange(args.source, range);
      if (selectedLines === null) {
        return Either.left(
          new ImportNotFoundError({
            cellIndex: args.cellIndex,
            importRef: args.importRef.raw,
          }),
        );
      }

      return Either.right(selectedLines);
    }
    case "symbol": {
      const symbol = args.importRef.symbol;
      if (symbol === undefined) {
        return Either.left(
          new ImportNotFoundError({
            cellIndex: args.cellIndex,
            importRef: args.importRef.raw,
          }),
        );
      }

      const symbolBlock = extractExportedSymbol(args.source, symbol);
      if (symbolBlock === null) {
        return Either.left(
          new ImportNotFoundError({
            cellIndex: args.cellIndex,
            importRef: args.importRef.raw,
          }),
        );
      }

      return Either.right(symbolBlock);
    }
  }
};

const pickLineRange = (source: string, range: readonly [number, number]): string | null => {
  const lines = source.split("\n");

  const start = Math.max(1, Math.min(range[0], range[1]));
  const end = Math.max(range[0], range[1]);

  if (start > lines.length) {
    return null;
  }

  const selected = lines.slice(start - 1, end);
  if (selected.length === 0) {
    return null;
  }

  return selected.join("\n").trimEnd();
};

const extractExportedSymbol = (source: string, symbol: string): string | null => {
  const escapedSymbol = escapeForRegExp(symbol);
  const exportDeclarationPattern = new RegExp(
    `^\\s*export\\s+(?:default\\s+)?(?:declare\\s+)?(?:async\\s+)?(?:function|class|interface|type|const|let|var|enum)\\s+${escapedSymbol}\\b`,
  );
  const exportListPattern = new RegExp(`^\\s*export\\s*\\{[^}]*\\b${escapedSymbol}\\b[^}]*\\}`);

  const lines = source.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line === undefined) {
      continue;
    }

    if (exportListPattern.test(line)) {
      return line.trimEnd();
    }

    if (!exportDeclarationPattern.test(line)) {
      continue;
    }

    return collectExportBlock(lines, index);
  }

  return null;
};

const collectExportBlock = (lines: ReadonlyArray<string>, startIndex: number): string => {
  const collected: string[] = [];
  let braceDepth = 0;
  let sawBrace = false;

  for (let index = startIndex; index < lines.length; index += 1) {
    const line = lines[index];
    if (line === undefined) {
      continue;
    }

    collected.push(line);

    const openBraces = countOccurrences(line, "{");
    const closeBraces = countOccurrences(line, "}");
    if (openBraces > 0) {
      sawBrace = true;
    }

    braceDepth += openBraces - closeBraces;

    const trimmed = line.trim();

    if (index === startIndex) {
      if (sawBrace && braceDepth <= 0) {
        break;
      }

      if (!sawBrace && trimmed.endsWith(";")) {
        break;
      }

      continue;
    }

    if (sawBrace) {
      if (braceDepth <= 0) {
        break;
      }
      continue;
    }

    if (trimmed === "") {
      collected.pop();
      break;
    }

    if (/^\s*export\b/.test(line)) {
      collected.pop();
      break;
    }

    if (trimmed.endsWith(";")) {
      break;
    }
  }

  return collected.join("\n").trimEnd();
};

const countOccurrences = (line: string, character: string): number => {
  let count = 0;

  for (const current of line) {
    if (current === character) {
      count += 1;
    }
  }

  return count;
};

const parseImportReference = (rawReference: string): Import => {
  const referenceBody = rawReference.slice(1);

  const symbolMatch = referenceBody.match(SYMBOL_REFERENCE_PATTERN);
  if (symbolMatch !== null) {
    const path = symbolMatch[1];
    const symbol = symbolMatch[2];

    if (path !== undefined && symbol !== undefined) {
      return {
        raw: rawReference,
        kind: "symbol",
        path,
        range: undefined,
        symbol,
      };
    }
  }

  const rangeMatch = referenceBody.match(RANGE_REFERENCE_PATTERN);
  if (rangeMatch !== null) {
    const path = rangeMatch[1];
    const startRaw = rangeMatch[2];
    const endRaw = rangeMatch[3];

    if (path !== undefined && startRaw !== undefined && endRaw !== undefined) {
      const start = Number.parseInt(startRaw, 10);
      const end = Number.parseInt(endRaw, 10);
      const rangeStart = Math.min(start, end);
      const rangeEnd = Math.max(start, end);

      return {
        raw: rawReference,
        kind: "range",
        path,
        range: [rangeStart, rangeEnd],
        symbol: undefined,
      };
    }
  }

  if (GLOB_TOKEN_PATTERN.test(referenceBody)) {
    return {
      raw: rawReference,
      kind: "glob",
      path: referenceBody,
      range: undefined,
      symbol: undefined,
    };
  }

  return {
    raw: rawReference,
    kind: "file",
    path: referenceBody,
    range: undefined,
    symbol: undefined,
  };
};

const renderResolvedImport = (resolved: ResolvedImport): string => {
  if (resolved.content === "") {
    return `<file path="${resolved.path}">\n</file>`;
  }

  return `<file path="${resolved.path}">\n${resolved.content}\n</file>`;
};

const normalizeDisplayPath = (value: string): string => {
  const slashed = value.replaceAll("\\", "/");
  if (slashed.startsWith("./")) {
    return slashed.slice(2);
  }

  return slashed;
};

const toAbsolutePath = (projectRoot: string, pathValue: string): string => {
  if (isAbsolute(pathValue)) {
    return normalize(pathValue);
  }

  return normalize(join(projectRoot, pathValue));
};

const normalizeNewlines = (value: string): string => value.replaceAll("\r\n", "\n");

const escapeForRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

const forEachMarkdownLineOutsideFences = (
  content: string,
  onLine: (line: string) => void,
): void => {
  const lines = normalizeNewlines(content).split("\n");

  let insideFence = false;
  for (const line of lines) {
    if (MARKDOWN_FENCE_PATTERN.test(line)) {
      insideFence = !insideFence;
      continue;
    }

    if (insideFence) {
      continue;
    }

    onLine(line);
  }
};
