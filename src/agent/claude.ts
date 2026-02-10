import { agentErr, agentOk, type AgentProvider } from "./types.ts";

export const claudeAgentProvider: AgentProvider = {
  backend: "claude",
  stream: (invocation) => {
    if (shouldFail(invocation.prompt, "claude")) {
      return agentErr({
        exitCode: 1,
        stderr: "claude process exited with a non-zero status",
      });
    }

    return agentOk([
      `[claude:${invocation.call}]`,
      `cell=${invocation.cellIndex}`,
      `model=${invocation.model ?? "default"}`,
    ]);
  },
};

const shouldFail = (prompt: string, backend: string): boolean =>
  prompt.includes("<!-- drift:agent-fail -->") ||
  prompt.includes(`<!-- drift:agent-fail:${backend} -->`);
