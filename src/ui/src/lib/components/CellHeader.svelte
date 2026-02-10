<script lang="ts">
  import VersionScrubber from "./VersionScrubber.svelte";
  import type {
    CellAction,
    CellActionRequest,
    CellVersionRestoreRequest,
    CellVersionSelectionChange,
    UiCell,
  } from "../types.ts";

  interface Props {
    readonly cell: UiCell;
    readonly canCommit?: boolean;
    readonly onAction?: (request: CellActionRequest) => void;
    readonly onVersionSelect?: (change: CellVersionSelectionChange) => void;
    readonly onVersionRestore?: (request: CellVersionRestoreRequest) => void;
  }

  const noopAction = (_request: CellActionRequest): void => {};
  const noopVersionSelect = (_change: CellVersionSelectionChange): void => {};
  const noopVersionRestore = (_request: CellVersionRestoreRequest): void => {};

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

  let {
    cell,
    canCommit = false,
    onAction = noopAction,
    onVersionSelect = noopVersionSelect,
    onVersionRestore = noopVersionRestore,
  }: Props = $props();

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

  const selectVersion = (version: number | null): void => {
    onVersionSelect({
      cellIndex: cell.index,
      version,
    });
  };

  const restoreVersion = (version: number): void => {
    onVersionRestore({
      cellIndex: cell.index,
      version,
    });
  };
</script>

<header class="cell-header">
  <div class="meta">
    <h2>Cell {cell.index}: {cell.title}</h2>
    <p class="dependencies">depends on: {dependenciesLabel}</p>

    <VersionScrubber
      versions={cell.versions}
      selectedVersion={cell.selectedVersion}
      disabled={cell.state === "running"}
      onSelect={selectVersion}
      onRestore={restoreVersion}
    />
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

  .meta {
    display: grid;
    gap: 0.3rem;
    min-width: 0;
  }

  .meta h2 {
    margin: 0;
    font-family: var(--font-display);
    font-size: 1.05rem;
    font-weight: 400;
    color: var(--text-body);
    letter-spacing: -0.01em;
  }

  .dependencies {
    margin: 0;
    color: var(--text-tertiary);
    font-family: var(--font-mono);
    font-size: 0.68rem;
    font-weight: 400;
    letter-spacing: 0.01em;
  }

  .status-actions {
    display: flex;
    gap: 0.6rem;
    align-items: center;
    flex-shrink: 0;
  }

  .state-badge {
    border-radius: 999px;
    padding: 0.18rem 0.55rem;
    font-family: var(--font-mono);
    font-size: 0.62rem;
    font-weight: 500;
    letter-spacing: 0.04em;
    border: 1px solid transparent;
  }

  .state-clean {
    color: var(--clean);
    background: var(--clean-bg);
    border-color: var(--clean-border);
  }

  .state-stale {
    color: var(--stale);
    background: var(--stale-bg);
    border-color: var(--stale-border);
  }

  .state-running {
    color: var(--running);
    background: var(--running-bg);
    border-color: var(--running-border);
    animation: gentle-pulse 2.5s ease-in-out infinite;
  }

  .state-error {
    color: var(--error);
    background: var(--error-bg);
    border-color: var(--error-border);
  }

  .actions {
    display: flex;
    gap: 0.3rem;
  }

  .action {
    border: 1px solid var(--border-mid);
    border-radius: var(--radius-sm);
    background: var(--bg-card);
    padding: 0.3rem 0.55rem;
    font-family: var(--font-body);
    font-size: 0.78rem;
    font-weight: 400;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .action:hover:not(:disabled) {
    border-color: var(--border-strong);
    color: var(--text-body);
  }

  .action-build:hover:not(:disabled) {
    border-color: var(--clean-border);
    color: var(--clean);
  }

  .action-plan:hover:not(:disabled) {
    border-color: var(--accent-border);
    color: var(--accent);
  }

  .action-commit:hover:not(:disabled) {
    border-color: var(--stale-border);
    color: var(--stale);
  }

  .action:disabled {
    cursor: not-allowed;
    opacity: 0.35;
  }
</style>
