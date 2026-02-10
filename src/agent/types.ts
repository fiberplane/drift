import { AgentError } from "../core/errors.ts";

export const AGENT_BACKEND_NAMES = ["claude", "pi", "codex"] as const;

export type AgentBackendName = (typeof AGENT_BACKEND_NAMES)[number];

export type AgentCall = "plan" | "build";

export interface AgentInvocation {
  readonly cellIndex: number;
  readonly call: AgentCall;
  readonly prompt: string;
  readonly model: string | null;
}

export interface AgentBackendFailure {
  readonly exitCode: number | null;
  readonly stderr: string;
}

export interface AgentProvider {
  readonly backend: AgentBackendName;
  readonly stream: (
    invocation: AgentInvocation,
  ) => AgentResult<AgentBackendFailure, ReadonlyArray<string>>;
}

export interface AgentSelection {
  readonly backend: AgentBackendName;
  readonly model: string | null;
}

export interface AgentCallRequest {
  readonly cellIndex: number;
  readonly call: AgentCall;
  readonly prompt: string;
  readonly backend: AgentBackendName;
  readonly model: string | null;
}

export type AgentResult<E, A> =
  | {
      readonly ok: true;
      readonly value: A;
    }
  | {
      readonly ok: false;
      readonly error: E;
    };

export const agentOk = <A>(value: A): AgentResult<never, A> => ({ ok: true, value });

export const agentErr = <E>(error: E): AgentResult<E, never> => ({ ok: false, error });

export const isAgentBackendName = (value: string): value is AgentBackendName =>
  AGENT_BACKEND_NAMES.some((backend) => backend === value);

export const parseProjectAgentConfig = (configRaw: string): AgentSelection => {
  const backendValue = parseYamlScalar(configRaw, "agent");
  const modelValue = parseYamlScalar(configRaw, "model");

  const backend =
    backendValue !== null && isAgentBackendName(backendValue) ? backendValue : "claude";

  return {
    backend,
    model: decodeModelValue(modelValue),
  };
};

export const parseCellAgentOverride = (cellContent: string): AgentBackendName | null => {
  const matched = cellContent.match(/<!--\s*agent:\s*([a-z0-9-]+)\s*-->/iu);
  const rawValue = matched?.[1]?.trim() ?? null;

  if (rawValue === null) {
    return null;
  }

  return isAgentBackendName(rawValue) ? rawValue : null;
};

export const resolveAgentSelection = (args: {
  readonly configRaw: string;
  readonly cellContent: string;
}): AgentSelection => {
  const project = parseProjectAgentConfig(args.configRaw);
  const override = parseCellAgentOverride(args.cellContent);

  return {
    backend: override ?? project.backend,
    model: project.model,
  };
};

export const mapBackendFailureToAgentError = (args: {
  readonly cellIndex: number;
  readonly backend: AgentBackendName;
  readonly failure: AgentBackendFailure;
}): AgentError =>
  new AgentError({
    cellIndex: args.cellIndex,
    agent: args.backend,
    exitCode: args.failure.exitCode,
    stderr: args.failure.stderr,
  });

export const formatAgentError = (error: AgentError): string => {
  const exitCode = error.exitCode === null ? "unknown" : String(error.exitCode);
  return `${error.agent} backend failed (exit ${exitCode}): ${error.stderr}`;
};

const parseYamlScalar = (raw: string, key: string): string | null => {
  const lines = raw.replaceAll("\r\n", "\n").split("\n");

  for (const line of lines) {
    const matched = line.match(new RegExp(`^\\s*${key}\\s*:\\s*(.*?)\\s*$`, "u"));
    const value = matched?.[1] ?? null;

    if (value === null) {
      continue;
    }

    return normalizeScalarValue(value);
  }

  return null;
};

const normalizeScalarValue = (value: string): string => {
  const withoutComment = value.split("#")[0] ?? value;
  const trimmed = withoutComment.trim();

  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1).trim();
  }

  return trimmed;
};

const decodeModelValue = (value: string | null): string | null => {
  if (value === null) {
    return null;
  }

  if (value === "" || value === "null" || value === "~") {
    return null;
  }

  return value;
};
