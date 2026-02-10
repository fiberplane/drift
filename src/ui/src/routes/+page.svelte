<script lang="ts">
  import Notebook from "../lib/components/Notebook.svelte";
  import { createInitialNotebook } from "../lib/state/index.ts";
  import type { CellActionRequest, ToolbarActionRequest } from "../lib/types.ts";

  const initialModel = createInitialNotebook([
    {
      index: 0,
      title: "Project constraints",
      dependencies: [],
      state: "clean",
      input: "# Project\n\nDefine runtime and architecture constraints.",
      output: {
        summary: "Baseline constraints captured and synced to CLAUDE.md.",
        commitRef: "a9227d52",
      },
    },
    {
      index: 1,
      title: "Execution pipeline",
      dependencies: [0],
      state: "stale",
      input: "# Execution pipeline\n\nDescribe how run/plan/commit should flow.",
      output: null,
    },
  ]);

  let actions = $state<string[]>([]);

  const appendAction = (message: string): void => {
    actions = [message, ...actions].slice(0, 8);
  };

  const handleCellAction = (request: CellActionRequest): void => {
    appendAction(`cell ${request.cellIndex}: ${request.action}`);
  };

  const handleToolbarAction = (request: ToolbarActionRequest): void => {
    appendAction(`toolbar: ${request.action}`);
  };
</script>

<main>
  <Notebook initialModel={initialModel} onCellAction={handleCellAction} onToolbarAction={handleToolbarAction} />

  <section class="event-log">
    <h2>Recent actions</h2>

    {#if actions.length === 0}
      <p>No actions yet.</p>
    {:else}
      <ul>
        {#each actions as action, index (`${action}-${index}`)}
          <li>{action}</li>
        {/each}
      </ul>
    {/if}
  </section>
</main>

<style>
  main {
    display: grid;
    gap: 1rem;
    padding: 1rem;
  }

  .event-log {
    max-width: 62rem;
    margin: 0 auto;
    width: 100%;
    border: 1px solid #e5e7eb;
    border-radius: 0.75rem;
    padding: 0.75rem;
  }

  h2 {
    margin: 0;
    font-size: 0.95rem;
  }

  p {
    margin: 0.5rem 0 0;
    color: #6b7280;
  }

  ul {
    margin: 0.5rem 0 0;
    padding-left: 1.1rem;
    display: grid;
    gap: 0.2rem;
    font-size: 0.85rem;
    color: #374151;
  }
</style>
