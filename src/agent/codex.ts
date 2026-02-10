import { agentErr, agentOk, type AgentProvider } from "./types.ts";

export const codexAgentProvider: AgentProvider = {
  backend: "codex",
  stream: (invocation) => {
    if (shouldFail(invocation.prompt, "codex")) {
      return agentErr({
        exitCode: 1,
        stderr: "codex process exited with a non-zero status",
      });
    }

    return agentOk([
      `[codex:${invocation.call}]`,
      `cell=${invocation.cellIndex}`,
      `model=${invocation.model ?? "default"}`,
    ]);
  },
};

const shouldFail = (prompt: string, backend: string): boolean =>
  prompt.includes("<!-- drift:agent-fail -->") ||
  prompt.includes(`<!-- drift:agent-fail:${backend} -->`);
