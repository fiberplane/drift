<script lang="ts">
  type DiffLayout = "split" | "stacked";

  interface Props {
    readonly patch: string | null;
  }

  let { patch }: Props = $props();

  let expanded = $state(false);
  let layout = $state<DiffLayout>("split");

  const hasPatch = $derived(patch !== null && patch.trim() !== "");
  const patchContent = $derived(patch ?? "");
  const changedLineCount = $derived(countChangedLines(patchContent));
  const usingPierreDiffs = $derived(hasPierreRendererBridge());
  const statusLabel = $derived(usingPierreDiffs ? "@pierre/diffs" : "fallback renderer");

  const toggleExpanded = (): void => {
    expanded = !expanded;
  };

  const toggleLayout = (): void => {
    layout = layout === "split" ? "stacked" : "split";
  };

  function countChangedLines(value: string): number {
    if (value.trim() === "") {
      return 0;
    }

    return value
      .split("\n")
      .filter((line) => {
        if (line.startsWith("+++ ") || line.startsWith("--- ") || line.startsWith("@@")) {
          return false;
        }

        return line.startsWith("+") || line.startsWith("-");
      })
      .length;
  }

  function hasPierreRendererBridge(): boolean {
    const maybeWindow = Reflect.get(globalThis, "window");
    if (!isRecord(maybeWindow)) {
      return false;
    }

    const rendererCandidate = maybeWindow["__PIERRE_DIFFS__"];
    if (!isRecord(rendererCandidate)) {
      return false;
    }

    const renderCandidate = rendererCandidate["render"];
    return typeof renderCandidate === "function";
  }

  function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null;
  }
</script>

<section class="diff-view">
  <header>
    <h3>Diff</h3>

    <div class="controls">
      <span class="meta">{changedLineCount} changed lines · {statusLabel}</span>

      <button type="button" onclick={toggleExpanded} disabled={!hasPatch}>
        {expanded ? "Hide" : "Show"} diff
      </button>

      <button type="button" onclick={toggleLayout} disabled={!expanded || !hasPatch}>
        Layout: {layout}
      </button>
    </div>
  </header>

  {#if !hasPatch}
    <p class="empty">No patch captured yet. Build the cell to render a diff.</p>
  {:else if expanded}
    {#if usingPierreDiffs}
      <p class="hint">@pierre/diffs bridge detected — rendering unified patch with matching layout mode.</p>
    {/if}

    <pre class={`surface surface-${layout}`}>{patchContent}</pre>
  {/if}
</section>

<style>
  .diff-view {
    display: grid;
    gap: 0.5rem;
    border-top: 1px solid var(--border-light);
    padding-top: 0.6rem;
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  h3 {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.62rem;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted);
  }

  .controls {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 0.35rem;
  }

  .meta {
    font-family: var(--font-mono);
    font-size: 0.65rem;
    color: var(--text-tertiary);
  }

  button {
    border: 1px solid var(--border-mid);
    border-radius: var(--radius-sm);
    background: var(--bg-card);
    padding: 0.2rem 0.5rem;
    font-family: var(--font-body);
    font-size: 0.74rem;
    color: var(--text-secondary);
    cursor: pointer;
    transition: all 0.15s ease;
  }

  button:hover:not(:disabled) {
    border-color: var(--border-strong);
    color: var(--text-body);
  }

  button:disabled {
    cursor: not-allowed;
    opacity: 0.4;
  }

  .surface {
    margin: 0;
    max-height: 20rem;
    overflow: auto;
    border: 1px solid var(--border-light);
    border-radius: var(--radius-md);
    padding: 0.75rem;
    font-family: var(--font-mono);
    font-size: 0.74rem;
    font-weight: 400;
    line-height: 1.5;
    background: var(--bg-card);
    color: var(--text-secondary);
    white-space: pre;
  }

  .surface-stacked {
    white-space: pre-wrap;
  }

  .hint {
    margin: 0;
    font-size: 0.74rem;
    color: var(--text-tertiary);
    font-style: italic;
  }

  .empty {
    margin: 0;
    color: var(--text-muted);
    font-size: 0.8rem;
    font-style: italic;
  }
</style>
