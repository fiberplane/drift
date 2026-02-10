<script lang="ts">
  import type { StreamingCellAction } from "../types.ts";

  interface Props {
    readonly action: StreamingCellAction;
    readonly content: string;
  }

  let { action, content }: Props = $props();

  let streamContainer: HTMLPreElement | null = null;

  const actionLabel = $derived(action === "plan" ? "Planning" : "Building");

  $effect(() => {
    syncScroll(content);
  });

  const syncScroll = (_content: string): void => {
    if (streamContainer === null) {
      return;
    }

    streamContainer.scrollTop = streamContainer.scrollHeight;
  };
</script>

<section class="live-stream" aria-live="polite">
  <header>
    <h3>{actionLabel} · live output</h3>
  </header>

  <pre bind:this={streamContainer}>{content}</pre>
</section>

<style>
  .live-stream {
    display: grid;
    gap: 0.4rem;
    border: 1px solid var(--running-border);
    border-radius: var(--radius-md);
    background: var(--running-bg);
    padding: 0.7rem 0.85rem;
  }

  h3 {
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.62rem;
    font-weight: 500;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--running);
    animation: gentle-pulse 2.5s ease-in-out infinite;
  }

  pre {
    margin: 0;
    max-height: 14rem;
    overflow: auto;
    white-space: pre-wrap;
    font-family: var(--font-mono);
    font-size: 0.76rem;
    font-weight: 400;
    line-height: 1.5;
    color: var(--text-body);
  }
</style>
