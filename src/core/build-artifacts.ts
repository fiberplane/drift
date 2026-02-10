import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { BuildArtifact } from "./execution-engine.ts";

export interface WriteBuildArtifactsArgs {
  readonly cellDir: string;
  readonly artifact: BuildArtifact;
  readonly ref: string | null;
}

export const writeBuildArtifacts = (args: WriteBuildArtifactsArgs): void => {
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

export const renderBuildYaml = (args: {
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
