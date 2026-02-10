import { AgentError } from "../core/errors.ts";
import { claudeAgentProvider } from "./claude.ts";
import { codexAgentProvider } from "./codex.ts";
import { piAgentProvider } from "./pi.ts";
import {
  agentErr,
  mapBackendFailureToAgentError,
  type AgentCallRequest,
  type AgentProvider,
  type AgentResult,
} from "./types.ts";

export * from "./types.ts";
export * from "./claude.ts";
export * from "./pi.ts";
export * from "./codex.ts";

export const agentProviders = [claudeAgentProvider, piAgentProvider, codexAgentProvider] as const;

export const streamAgentCall = (args: {
  readonly request: AgentCallRequest;
  readonly providers?: ReadonlyArray<AgentProvider>;
}): AgentResult<AgentError, ReadonlyArray<string>> => {
  const provider = findProvider(args.request.backend, args.providers ?? agentProviders);
  if (provider === null) {
    return agentErr(
      new AgentError({
        cellIndex: args.request.cellIndex,
        agent: args.request.backend,
        exitCode: null,
        stderr: `No provider configured for ${args.request.backend}.`,
      }),
    );
  }

  const streamed = provider.stream({
    cellIndex: args.request.cellIndex,
    call: args.request.call,
    prompt: args.request.prompt,
    model: args.request.model,
  });

  if (!streamed.ok) {
    return agentErr(
      mapBackendFailureToAgentError({
        cellIndex: args.request.cellIndex,
        backend: args.request.backend,
        failure: streamed.error,
      }),
    );
  }

  return streamed;
};

const findProvider = (
  backend: AgentProvider["backend"],
  providers: ReadonlyArray<AgentProvider>,
): AgentProvider | null => {
  for (const provider of providers) {
    if (provider.backend === backend) {
      return provider;
    }
  }

  return null;
};
