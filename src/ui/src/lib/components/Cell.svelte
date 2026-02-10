<script lang="ts">
  import CellHeader from "./CellHeader.svelte";
  import CellInput from "./CellInput.svelte";
  import CellOutput from "./CellOutput.svelte";
  import { isCellCommitReady } from "../state/index.ts";
  import type { CellActionRequest, CellInputChange, UiCell } from "../types.ts";

  interface Props {
    readonly cell: UiCell;
    readonly isActive?: boolean;
    readonly onAction?: (request: CellActionRequest) => void;
    readonly onInput?: (change: CellInputChange) => void;
  }

  const noopAction = (_request: CellActionRequest): void => {};
  const noopInput = (_change: CellInputChange): void => {};

  let { cell, isActive = false, onAction = noopAction, onInput = noopInput }: Props = $props();

  const canCommit = $derived(isCellCommitReady(cell));
  const cellClassName = $derived(isActive ? "cell is-active" : "cell");

  const handleAction = (request: CellActionRequest): void => {
    onAction(request);
  };

  const handleInput = (change: CellInputChange): void => {
    onInput(change);
  };
</script>

<article class={cellClassName} aria-current={isActive ? "true" : undefined}>
  <CellHeader {cell} {canCommit} onAction={handleAction} />
  <CellInput cellIndex={cell.index} value={cell.input} disabled={cell.state === "running"} onInput={handleInput} />
  <CellOutput summary={cell.output?.summary ?? null} commitRef={cell.output?.commitRef ?? null} />
</article>

<style>
  .cell {
    display: grid;
    gap: 0.8rem;
    border: 1px solid #e5e7eb;
    border-radius: 0.85rem;
    padding: 0.9rem;
    background: #ffffff;
    box-shadow: 0 1px 1px rgba(15, 23, 42, 0.04);
  }

  .cell.is-active {
    border-color: #6366f1;
    box-shadow: 0 0 0 1px rgba(99, 102, 241, 0.25);
  }
</style>
