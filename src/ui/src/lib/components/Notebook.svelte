<script lang="ts">
  import Cell from "./Cell.svelte";
  import DagMinimap from "./DagMinimap.svelte";
  import { createToolbarState } from "../state/index.ts";
  import type {
    CellActionRequest,
    CellInputChange,
    CellVersionRestoreRequest,
    CellVersionSelectionChange,
    NotebookViewModel,
    ToolbarAction,
    ToolbarActionRequest,
  } from "../types.ts";

  interface Props {
    readonly model: NotebookViewModel;
    readonly onCellAction?: (request: CellActionRequest) => void;
    readonly onToolbarAction?: (request: ToolbarActionRequest) => void;
    readonly onCellInput?: (change: CellInputChange) => void;
    readonly onMinimapSelect?: (cellIndex: number) => void;
    readonly onVersionSelect?: (change: CellVersionSelectionChange) => void;
    readonly onVersionRestore?: (request: CellVersionRestoreRequest) => void;
  }

  const noop = (): void => {};

  const {
    model,
    onCellAction = noop,
    onToolbarAction = noop,
    onCellInput = noop,
    onMinimapSelect = noop,
    onVersionSelect = noop,
    onVersionRestore = noop,
  }: Props = $props();

  const toolbar = $derived(createToolbarState(model));

  const handleCellInput = (change: CellInputChange): void => {
    onCellInput(change);
  };

  const handleCellAction = (request: CellActionRequest): void => {
    onCellAction(request);
  };

  const handleVersionSelect = (change: CellVersionSelectionChange): void => {
    onVersionSelect(change);
  };

  const handleVersionRestore = (request: CellVersionRestoreRequest): void => {
    onVersionRestore(request);
  };

  const handleToolbarAction = (action: ToolbarAction): void => {
    onToolbarAction({ action });
  };

  const handleMinimapSelect = (cellIndex: number): void => {
    onMinimapSelect(cellIndex);
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

  {#if model.cells.length === 0}
    <p class="empty">No cells yet. Add your first spec cell to begin.</p>
  {:else}
    <div class="workspace">
      <DagMinimap cells={model.cells} activeCell={model.activeCell} onSelect={handleMinimapSelect} />

      <div class="cells">
        {#each model.cells as cell (cell.index)}
          <Cell
            {cell}
            isActive={model.activeCell === cell.index}
            onAction={handleCellAction}
            onInput={handleCellInput}
            onVersionSelect={handleVersionSelect}
            onVersionRestore={handleVersionRestore}
          />
        {/each}
      </div>
    </div>
  {/if}
</section>

<style>
  .notebook {
    display: grid;
    gap: 0;
    max-width: 76rem;
    margin: 0 auto;
    padding: 0 2rem;
    width: 100%;
  }

  .toolbar {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
    padding: 1.25rem 0 1rem;
    border-bottom: 1px solid var(--border-light);
    position: sticky;
    top: 0;
    background: var(--bg-page);
    z-index: 10;
  }

  h1 {
    margin: 0;
    font-family: var(--font-display);
    font-size: 1.6rem;
    font-weight: 400;
    font-style: italic;
    color: var(--text-body);
    letter-spacing: -0.02em;
  }

  .toolbar-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
  }

  .toolbar-button {
    border: 1px solid var(--border-mid);
    border-radius: var(--radius-sm);
    background: var(--bg-card);
    padding: 0.35rem 0.7rem;
    font-family: var(--font-body);
    font-size: 0.8rem;
    font-weight: 400;
    color: var(--text-secondary);
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .toolbar-button:hover:not(:disabled) {
    border-color: var(--border-strong);
    color: var(--text-body);
  }

  .toolbar-button:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }

  .toolbar-button .count {
    min-width: 1.3rem;
    text-align: center;
    border-radius: 999px;
    background: var(--bg-inset);
    padding: 0.05rem 0.35rem;
    font-family: var(--font-mono);
    font-size: 0.65rem;
    font-weight: 500;
    color: var(--text-tertiary);
  }

  .workspace {
    display: grid;
    grid-template-columns: 15rem minmax(0, 1fr);
    gap: 1.5rem;
    align-items: start;
    padding-top: 1.25rem;
    padding-bottom: 4rem;
  }

  .cells {
    display: grid;
    gap: 1.15rem;
  }

  .empty {
    margin: 0;
    color: var(--text-tertiary);
    font-style: italic;
    padding: 3rem 0;
  }

  @media (max-width: 960px) {
    .notebook {
      padding: 0 1rem;
    }
    .workspace {
      grid-template-columns: 1fr;
    }
  }
</style>
