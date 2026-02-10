<script lang="ts">
  import CellHeader from "./CellHeader.svelte";
  import CellInput from "./CellInput.svelte";
  import CellOutput from "./CellOutput.svelte";
  import LiveStream from "./LiveStream.svelte";
  import {
    getCellDisplayedInput,
    isCellCommitReady,
    isViewingVersionHistory,
  } from "../state/index.ts";
  import type {
    CellActionRequest,
    CellInputChange,
    CellVersionRestoreRequest,
    CellVersionSelectionChange,
    UiCell,
  } from "../types.ts";

  interface Props {
    readonly cell: UiCell;
    readonly isActive?: boolean;
    readonly onAction?: (request: CellActionRequest) => void;
    readonly onInput?: (change: CellInputChange) => void;
    readonly onVersionSelect?: (change: CellVersionSelectionChange) => void;
    readonly onVersionRestore?: (request: CellVersionRestoreRequest) => void;
  }

  const noopAction = (_request: CellActionRequest): void => {};
  const noopInput = (_change: CellInputChange): void => {};
  const noopVersionSelect = (_change: CellVersionSelectionChange): void => {};
  const noopVersionRestore = (_request: CellVersionRestoreRequest): void => {};

  let {
    cell,
    isActive = false,
    onAction = noopAction,
    onInput = noopInput,
    onVersionSelect = noopVersionSelect,
    onVersionRestore = noopVersionRestore,
  }: Props = $props();

  const canCommit = $derived(isCellCommitReady(cell));
  const cellClassName = $derived(isActive ? "cell is-active" : "cell");
  const displayedInput = $derived(getCellDisplayedInput(cell));
  const viewingHistory = $derived(isViewingVersionHistory(cell));
  const inputDisabled = $derived(cell.state === "running" || viewingHistory);

  const handleAction = (request: CellActionRequest): void => {
    onAction(request);
  };

  const handleInput = (change: CellInputChange): void => {
    onInput(change);
  };

  const handleVersionSelect = (change: CellVersionSelectionChange): void => {
    onVersionSelect(change);
  };

  const handleVersionRestore = (request: CellVersionRestoreRequest): void => {
    onVersionRestore(request);
  };
</script>

<article class={cellClassName} aria-current={isActive ? "true" : undefined}>
  <CellHeader
    {cell}
    {canCommit}
    onAction={handleAction}
    onVersionSelect={handleVersionSelect}
    onVersionRestore={handleVersionRestore}
  />

  {#if viewingHistory}
    <p class="history-note">
      Viewing historical snapshot <code>v{cell.selectedVersion}</code>. Use <strong>Latest</strong> to return to
      editable mode.
    </p>
  {/if}

  <CellInput cellIndex={cell.index} value={displayedInput} disabled={inputDisabled} onInput={handleInput} />

  {#if cell.liveOutput !== null}
    <LiveStream action={cell.liveOutput.action} content={cell.liveOutput.content} />
  {/if}

  <CellOutput
    summary={cell.output?.summary ?? null}
    patch={cell.output?.patch ?? null}
    commitRef={cell.output?.commitRef ?? null}
  />
</article>

<style>
  .cell {
    display: grid;
    gap: 0.8rem;
    border: 1px solid var(--border-light);
    border-radius: var(--radius-lg);
    padding: 1.1rem 1.25rem;
    background: var(--bg-card);
    transition: border-color 0.2s ease, box-shadow 0.2s ease;
  }

  .cell.is-active {
    border-color: var(--accent-border);
    box-shadow: 0 0 0 1px var(--accent-light);
  }

  .history-note {
    margin: 0;
    padding: 0.45rem 0.7rem;
    border-radius: var(--radius-sm);
    border: 1px solid var(--running-border);
    background: var(--running-bg);
    color: var(--running);
    font-family: var(--font-body);
    font-size: 0.8rem;
  }

  code {
    font-family: var(--font-mono);
    font-size: 0.74rem;
    font-weight: 500;
  }
</style>
