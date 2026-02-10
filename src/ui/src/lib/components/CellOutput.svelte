<script lang="ts">
  interface Props {
    readonly summary: string | null;
    readonly commitRef?: string | null;
  }

  let { summary, commitRef = null }: Props = $props();

  const hasSummary = $derived(summary !== null && summary.trim() !== "");
  const hasWarning = $derived(summary?.toLowerCase().includes("warning") ?? false);
</script>

<section class="cell-output" aria-live="polite">
  {#if hasSummary}
    <h3>Summary</h3>
    <pre class:warning={hasWarning}>{summary}</pre>
  {:else}
    <p class="empty">Build output will appear here after the first successful build.</p>
  {/if}

  {#if commitRef !== null}
    <p class="commit-ref">
      Commit ref: <code>{commitRef}</code>
    </p>
  {/if}
</section>

<style>
  .cell-output {
    display: grid;
    gap: 0.4rem;
    padding: 0.75rem;
    border-radius: 0.65rem;
    background: #f9fafb;
    border: 1px solid #e5e7eb;
  }

  h3 {
    margin: 0;
    font-size: 0.86rem;
    color: #374151;
  }

  pre {
    margin: 0;
    white-space: pre-wrap;
    font-size: 0.82rem;
    line-height: 1.4;
    color: #1f2937;
  }

  pre.warning {
    color: #92400e;
  }

  .empty {
    margin: 0;
    color: #6b7280;
    font-size: 0.82rem;
  }

  .commit-ref {
    margin: 0;
    font-size: 0.8rem;
    color: #374151;
  }

  code {
    font-family: "SFMono-Regular", ui-monospace, Menlo, monospace;
    font-size: 0.8rem;
    background: #fff;
    border: 1px solid #d1d5db;
    border-radius: 0.4rem;
    padding: 0.1rem 0.35rem;
  }
</style>
