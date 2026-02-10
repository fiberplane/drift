import { describe, expect, test } from "bun:test";

import {
  claudeAgentProvider,
  parseCellAgentOverride,
  parseProjectAgentConfig,
  resolveAgentSelection,
  streamAgentCall,
} from "./index.ts";

describe("agent selection", () => {
  test("reads backend and model from project config", () => {
    const parsed = parseProjectAgentConfig(`agent: codex\nmodel: gpt-5\nresolver: explicit\n`);

    expect(parsed).toEqual({
      backend: "codex",
      model: "gpt-5",
    });
  });

  test("defaults to claude/null when config values are missing or invalid", () => {
    const parsed = parseProjectAgentConfig(`agent: mystery\nmodel: null\n`);

    expect(parsed).toEqual({
      backend: "claude",
      model: null,
    });
  });

  test("per-cell metadata overrides project backend", () => {
    const selection = resolveAgentSelection({
      configRaw: `agent: codex\nmodel: sonnet\n`,
      cellContent: "## Build API\n\n<!-- agent: pi -->\n",
    });

    expect(selection).toEqual({
      backend: "pi",
      model: "sonnet",
    });
  });

  test("invalid per-cell metadata is ignored", () => {
    expect(parseCellAgentOverride("## Cell\n\n<!-- agent: unknown -->\n")).toBeNull();
  });
});

describe("agent backends", () => {
  test("streams plan/build tokens from selected backend", () => {
    const streamed = streamAgentCall({
      request: {
        cellIndex: 7,
        call: "build",
        prompt: "Implement routes",
        backend: "pi",
        model: "sonnet",
      },
    });

    expect(streamed.ok).toBe(true);

    if (!streamed.ok) {
      return;
    }

    expect(streamed.value).toEqual(["[pi:build]", "cell=7", "model=sonnet"]);
  });

  test("maps provider failures to AgentError", () => {
    const streamed = streamAgentCall({
      request: {
        cellIndex: 2,
        call: "plan",
        prompt: "<!-- drift:agent-fail -->",
        backend: "claude",
        model: null,
      },
    });

    expect(streamed.ok).toBe(false);

    if (streamed.ok) {
      return;
    }

    expect(streamed.error._tag).toBe("AgentError");
    expect(streamed.error.cellIndex).toBe(2);
    expect(streamed.error.agent).toBe("claude");
    expect(streamed.error.exitCode).toBe(1);
  });

  test("returns AgentError when backend provider is missing", () => {
    const streamed = streamAgentCall({
      request: {
        cellIndex: 3,
        call: "build",
        prompt: "Generate patch",
        backend: "pi",
        model: null,
      },
      providers: [claudeAgentProvider],
    });

    expect(streamed.ok).toBe(false);

    if (streamed.ok) {
      return;
    }

    expect(streamed.error._tag).toBe("AgentError");
    expect(streamed.error.stderr).toContain("No provider configured for pi");
  });
});
