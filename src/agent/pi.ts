import { agentErr, agentOk, type AgentProvider } from "./types.ts";

export const piAgentProvider: AgentProvider = {
  backend: "pi",
  stream: (invocation) => {
    if (shouldFail(invocation.prompt, "pi")) {
      return agentErr({
        exitCode: 1,
        stderr: "pi process exited with a non-zero status",
      });
    }

    return agentOk([
      `[pi:${invocation.call}]`,
      `cell=${invocation.cellIndex}`,
      `model=${invocation.model ?? "default"}`,
    ]);
  },
};

const shouldFail = (prompt: string, backend: string): boolean =>
  prompt.includes("<!-- drift:agent-fail -->") ||
  prompt.includes(`<!-- drift:agent-fail:${backend} -->`);
