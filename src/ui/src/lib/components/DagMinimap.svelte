<script lang="ts">
  import type { UiCell } from "../types.ts";

  interface Props {
    readonly cells: ReadonlyArray<UiCell>;
    readonly activeCell: number | null;
    readonly onSelect?: (cellIndex: number) => void;
  }

  const noopSelect = (_cellIndex: number): void => {};

  let { cells, activeCell, onSelect = noopSelect }: Props = $props();

  const orderedCells = $derived([...cells].sort((left, right) => left.index - right.index));
  const staleCount = $derived(orderedCells.filter((cell) => cell.state === "stale").length);

  const toDependenciesLabel = (cell: UiCell): string =>
    cell.dependencies.length === 0 ? "root" : `← ${cell.dependencies.join(", ")}`;
</script>

<aside class="dag-minimap" aria-label="dependency minimap">
  <header>
    <h2>DAG</h2>
    <p>{staleCount} stale</p>
  </header>

  {#if orderedCells.length === 0}
    <p class="empty">No cells yet.</p>
  {:else}
    <ol>
      {#each orderedCells as cell (cell.index)}
        <li>
          <button
            type="button"
            class={`node state-${cell.state} ${activeCell === cell.index ? "is-active" : ""}`}
            onclick={() => onSelect(cell.index)}
          >
            <span class="index">{cell.index}</span>
            <span class="title">{cell.title}</span>
            <span class="deps">{toDependenciesLabel(cell)}</span>
          </button>
        </li>
      {/each}
    </ol>
  {/if}
</aside>

<style>
  .dag-minimap {
    border: 1px solid var(--border-light);
    border-radius: var(--radius-lg);
    background: var(--bg-card);
    padding: 0.75rem;
    display: grid;
    gap: 0.6rem;
    align-content: start;
    position: sticky;
    top: 5rem;
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 0.6rem;
  }

  h2 {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.62rem;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-muted);
  }

  header p {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.6rem;
    font-weight: 500;
    color: var(--stale);
  }

  ol {
    margin: 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.3rem;
    max-height: 28rem;
    overflow: auto;
  }

  .node {
    width: 100%;
    border: 1px solid var(--border-light);
    border-radius: var(--radius-sm);
    padding: 0.35rem 0.45rem;
    background: var(--bg-inset);
    cursor: pointer;
    display: grid;
    grid-template-columns: auto 1fr;
    grid-template-areas:
      "index title"
      "index deps";
    column-gap: 0.45rem;
    row-gap: 0.05rem;
    text-align: left;
    transition: all 0.12s ease;
  }

  .node:hover {
    border-color: var(--border-mid);
    background: var(--bg-wash);
  }

  .node.is-active {
    border-color: var(--accent-border);
    box-shadow: 0 0 0 1px var(--accent-light);
    background: var(--accent-light);
  }

  .index {
    grid-area: index;
    font-family: var(--font-mono);
    font-size: 0.65rem;
    font-weight: 500;
    border-radius: 999px;
    background: var(--bg-wash);
    min-width: 1.3rem;
    align-self: start;
    text-align: center;
    padding: 0.1rem 0.25rem;
    color: var(--text-tertiary);
  }

  .title {
    grid-area: title;
    font-family: var(--font-body);
    font-size: 0.76rem;
    font-weight: 500;
    color: var(--text-body);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .deps {
    grid-area: deps;
    font-family: var(--font-mono);
    font-size: 0.6rem;
    color: var(--text-muted);
  }

  .state-clean .index {
    background: var(--clean-bg);
    color: var(--clean);
  }

  .state-stale {
    border-left: 2px solid var(--stale);
  }

  .state-stale .index {
    background: var(--stale-bg);
    color: var(--stale);
  }

  .state-running {
    border-left: 2px solid var(--running);
  }

  .state-running .index {
    background: var(--running-bg);
    color: var(--running);
    animation: gentle-pulse 2.5s ease-in-out infinite;
  }

  .state-error {
    border-left: 2px solid var(--error);
  }

  .state-error .index {
    background: var(--error-bg);
    color: var(--error);
  }

  .empty {
    margin: 0;
    font-size: 0.8rem;
    color: var(--text-muted);
    font-style: italic;
  }
</style>
