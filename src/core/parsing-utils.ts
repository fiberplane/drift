export const normalizeNewlines = (value: string): string => value.replaceAll("\r\n", "\n");

export const countLeadingSpaces = (line: string): number => {
  const matched = line.match(/^\s*/u);
  const prefix = matched?.[0] ?? "";
  return prefix.length;
};

export const parseYamlScalar = (source: string): unknown => {
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

export const formatDecodeError = (error: unknown): string =>
  typeof error === "string" ? error : JSON.stringify(error, null, 2);
