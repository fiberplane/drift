<script lang="ts">
  import Comments from "./Comments.svelte";
  import DiffView from "./DiffView.svelte";
  import Summary from "./Summary.svelte";

  interface Props {
    readonly summary: string | null;
    readonly patch: string | null;
    readonly commitRef?: string | null;
    readonly diffComments?: ReadonlyArray<string>;
  }

  let { summary, patch, commitRef = null, diffComments = [] }: Props = $props();

  const hasSummary = $derived(summary !== null && summary.trim() !== "");
</script>

<section class="cell-output" aria-live="polite">
  {#if hasSummary}
    <Summary text={summary ?? ""} />
  {:else}
    <p class="empty">Build output will appear here after the first successful build.</p>
  {/if}

  <DiffView {patch} />

  <Comments comments={diffComments} />

  {#if commitRef !== null}
    <p class="commit-ref">
      Commit ref: <code>{commitRef}</code>
    </p>
  {/if}
</section>

<style>
  .cell-output {
    display: grid;
    gap: 0.5rem;
    padding: 0.75rem 0.85rem;
    border-radius: var(--radius-md);
    background: var(--bg-inset);
    border: 1px solid var(--border-light);
  }

  .empty {
    margin: 0;
    color: var(--text-muted);
    font-size: 0.82rem;
    font-style: italic;
  }

  .commit-ref {
    margin: 0;
    font-size: 0.78rem;
    color: var(--text-secondary);
  }

  code {
    font-family: var(--font-mono);
    font-size: 0.74rem;
    font-weight: 500;
    background: var(--bg-card);
    border: 1px solid var(--border-mid);
    border-radius: var(--radius-sm);
    padding: 0.08rem 0.3rem;
    color: var(--clean);
  }
</style>
