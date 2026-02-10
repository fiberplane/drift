<script lang="ts">
  import type { CellAction, CellActionRequest, UiCell } from "../types.ts";

  interface Props {
    readonly cell: UiCell;
    readonly canCommit?: boolean;
    readonly onAction?: (request: CellActionRequest) => void;
  }

  const noopAction = (_request: CellActionRequest): void => {};

  const formatState = (state: UiCell["state"]): string => {
    switch (state) {
      case "clean":
        return "Clean";
      case "stale":
        return "Stale";
      case "running":
        return "Running";
      case "error":
        return "Error";
    }
  };

  const toDependenciesLabel = (dependencies: ReadonlyArray<number>): string =>
    dependencies.length === 0 ? "none" : dependencies.join(", ");

  let { cell, canCommit = false, onAction = noopAction }: Props = $props();

  const stateLabel = $derived(formatState(cell.state));
  const dependenciesLabel = $derived(toDependenciesLabel(cell.dependencies));

  const runAction = (action: CellAction): void => {
    if (action === "commit" && !canCommit) {
      return;
    }

    onAction({
      action,
      cellIndex: cell.index,
    });
  };
</script>

<header class="cell-header">
  <div class="meta">
    <h2>Cell {cell.index}: {cell.title}</h2>
    <p class="dependencies">depends on: {dependenciesLabel}</p>
  </div>

  <div class="status-actions">
    <span class={`state-badge state-${cell.state}`}>{stateLabel}</span>

    <div class="actions" role="toolbar" aria-label={`cell ${cell.index} actions`}>
      {#snippet actionButton(label, action, disabled)}
        <button type="button" class={`action action-${action}`} onclick={() => runAction(action)} {disabled}>
          {label}
        </button>
      {/snippet}

      {@render actionButton("⟐ Plan", "plan", false)}
      {@render actionButton("▶ Build", "build", false)}
      {@render actionButton("✓ Commit", "commit", !canCommit)}
    </div>
  </div>
</header>

<style>
  .cell-header {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    align-items: flex-start;
  }

  .meta h2 {
    margin: 0;
    font-size: 1rem;
  }

  .dependencies {
    margin: 0.25rem 0 0;
    color: #6b7280;
    font-size: 0.875rem;
  }

  .status-actions {
    display: flex;
    gap: 0.75rem;
    align-items: center;
  }

  .state-badge {
    border-radius: 999px;
    padding: 0.2rem 0.65rem;
    font-size: 0.75rem;
    font-weight: 600;
    border: 1px solid transparent;
  }

  .state-clean {
    color: #0f5132;
    background: #d1e7dd;
    border-color: #badbcc;
  }

  .state-stale {
    color: #664d03;
    background: #fff3cd;
    border-color: #ffecb5;
  }

  .state-running {
    color: #055160;
    background: #cff4fc;
    border-color: #b6effb;
  }

  .state-error {
    color: #842029;
    background: #f8d7da;
    border-color: #f5c2c7;
  }

  .actions {
    display: flex;
    gap: 0.4rem;
  }

  .action {
    border: 1px solid #d1d5db;
    border-radius: 0.5rem;
    background: #fff;
    padding: 0.35rem 0.6rem;
    font-size: 0.8rem;
    cursor: pointer;
  }

  .action:disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }
</style>
