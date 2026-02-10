<script lang="ts">
  import Cell from "./Cell.svelte";
  import {
    createInitialNotebook,
    createToolbarState,
    setActiveCell,
    setCellState,
    updateCellInput,
  } from "../state/index.ts";
  import type {
    CellActionRequest,
    CellInputChange,
    NotebookViewModel,
    ToolbarAction,
    ToolbarActionRequest,
  } from "../types.ts";

  interface Props {
    readonly initialModel?: NotebookViewModel;
    readonly onCellAction?: (request: CellActionRequest) => void;
    readonly onToolbarAction?: (request: ToolbarActionRequest) => void;
  }

  const noopCellAction = (_request: CellActionRequest): void => {};
  const noopToolbarAction = (_request: ToolbarActionRequest): void => {};

  let {
    initialModel: notebook = createInitialNotebook(),
    onCellAction = noopCellAction,
    onToolbarAction = noopToolbarAction,
  }: Props = $props();

  const toolbar = $derived(createToolbarState(notebook));

  const handleCellInput = (change: CellInputChange): void => {
    notebook = setActiveCell(notebook, change.cellIndex);
    notebook = updateCellInput(notebook, change.cellIndex, change.value);
  };

  const handleCellAction = (request: CellActionRequest): void => {
    notebook = setActiveCell(notebook, request.cellIndex);

    if (request.action === "plan" || request.action === "build") {
      notebook = setCellState(notebook, request.cellIndex, "running");
    }

    onCellAction(request);
  };

  const handleToolbarAction = (action: ToolbarAction): void => {
    onToolbarAction({ action });
  };

  const isToolbarActionDisabled = (action: ToolbarAction): boolean => {
    switch (action) {
      case "plan-all":
        return !toolbar.canPlanAll;
      case "build-all":
        return !toolbar.canBuildAll;
      case "commit-all":
        return !toolbar.canCommitAll;
    }
  };
</script>

<section class="notebook">
  <header class="toolbar">
    <h1>Drift notebook</h1>

    <div class="toolbar-actions" role="toolbar" aria-label="notebook actions">
      {#snippet toolbarButton(label, action, count)}
        <button
          type="button"
          class={`toolbar-button action-${action}`}
          onclick={() => handleToolbarAction(action)}
          disabled={isToolbarActionDisabled(action)}
        >
          <span>{label}</span>
          <span class="count">{count}</span>
        </button>
      {/snippet}

      {@render toolbarButton("Plan all stale", "plan-all", toolbar.staleCount)}
      {@render toolbarButton("Build all stale", "build-all", toolbar.staleCount)}
      {@render toolbarButton("Commit all uncommitted", "commit-all", toolbar.uncommittedCount)}
    </div>
  </header>

  {#if notebook.cells.length === 0}
    <p class="empty">No cells yet. Add your first spec cell to begin.</p>
  {:else}
    <div class="cells">
      {#each notebook.cells as cell (cell.index)}
        <Cell {cell} isActive={notebook.activeCell === cell.index} onAction={handleCellAction} onInput={handleCellInput} />
      {/each}
    </div>
  {/if}
</section>

<style>
  .notebook {
    display: grid;
    gap: 1rem;
    max-width: 62rem;
    margin: 0 auto;
    padding: 1rem;
  }

  .toolbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
    border-bottom: 1px solid #e5e7eb;
    padding-bottom: 0.75rem;
  }

  h1 {
    margin: 0;
    font-size: 1.1rem;
  }

  .toolbar-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.45rem;
  }

  .toolbar-button {
    border: 1px solid #d1d5db;
    border-radius: 0.55rem;
    background: #fff;
    padding: 0.35rem 0.7rem;
    font-size: 0.82rem;
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    cursor: pointer;
  }

  .toolbar-button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .toolbar-button .count {
    min-width: 1.4rem;
    text-align: center;
    border-radius: 999px;
    background: #f3f4f6;
    padding: 0.02rem 0.35rem;
    font-size: 0.72rem;
  }

  .cells {
    display: grid;
    gap: 0.8rem;
  }

  .empty {
    margin: 0;
    color: #6b7280;
  }
</style>
