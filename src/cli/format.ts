export const summarizeDiff = (
  patch: string,
): { readonly additions: number; readonly deletions: number } => {
  const lines = patch.replaceAll("\r\n", "\n").split("\n");
  let additions = 0;
  let deletions = 0;

  for (const line of lines) {
    if (line.startsWith("+++") || line.startsWith("@@")) {
      continue;
    }
    if (line.startsWith("+")) {
      additions += 1;
      continue;
    }

    if (line.startsWith("---")) {
      continue;
    }

    if (line.startsWith("-")) {
      deletions += 1;
    }
  }

  return {
    additions,
    deletions,
  };
};

export const formatIndexList = (indexes: readonly number[]): string => indexes.join(", ");
