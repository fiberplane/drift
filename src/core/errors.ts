import { Data } from "effect";

export class DagCycleError extends Data.TaggedError("DagCycleError")<{
  readonly cells: ReadonlyArray<number>;
}> {}

export class InvalidDiffError extends Data.TaggedError("InvalidDiffError")<{
  readonly cellIndex: number;
  readonly rawOutput: string;
}> {}

export class DiffApplyError extends Data.TaggedError("DiffApplyError")<{
  readonly cellIndex: number;
  readonly patch: string;
  readonly stderr: string;
}> {}

export class AgentError extends Data.TaggedError("AgentError")<{
  readonly cellIndex: number;
  readonly agent: string;
  readonly exitCode: number | null;
  readonly stderr: string;
}> {}

export type AncestorFailedCause = InvalidDiffError | DiffApplyError | AgentError;

export class AncestorFailedError extends Data.TaggedError("AncestorFailedError")<{
  readonly targetCell: number;
  readonly failedCell: number;
  readonly cause: AncestorFailedCause;
}> {}

export class ImportNotFoundError extends Data.TaggedError("ImportNotFoundError")<{
  readonly cellIndex: number;
  readonly importRef: string;
}> {}

export class InlineCommandError extends Data.TaggedError("InlineCommandError")<{
  readonly cellIndex: number;
  readonly command: string;
  readonly exitCode: number;
  readonly stderr: string;
}> {}

export class VcsCommitError extends Data.TaggedError("VcsCommitError")<{
  readonly cellIndices: ReadonlyArray<number>;
  readonly stderr: string;
}> {}

export class DriftDetectedError extends Data.TaggedError("DriftDetectedError")<{
  readonly cellIndex: number;
  readonly files: ReadonlyArray<string>;
}> {}

export class LoadProjectError extends Data.TaggedError("LoadProjectError")<{
  readonly path: string;
  readonly message: string;
}> {}

export class ParseMarkdownError extends Data.TaggedError("ParseMarkdownError")<{
  readonly message: string;
  readonly cellIndex: number | null;
}> {}

export type DriftError =
  | DagCycleError
  | InvalidDiffError
  | DiffApplyError
  | AgentError
  | AncestorFailedError
  | ImportNotFoundError
  | InlineCommandError
  | VcsCommitError
  | DriftDetectedError
  | LoadProjectError
  | ParseMarkdownError;
