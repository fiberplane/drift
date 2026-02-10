<script lang="ts">
  interface Props {
    readonly text: string;
  }

  let { text }: Props = $props();

  const hasWarning = $derived(text.toLowerCase().includes("warning"));
</script>

<section class="summary">
  <h3>Summary</h3>
  <pre class:warning={hasWarning}>{text}</pre>
</section>

<style>
  .summary {
    display: grid;
    gap: 0.3rem;
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

  pre {
    margin: 0;
    white-space: pre-wrap;
    font-family: var(--font-body);
    font-size: 0.85rem;
    font-weight: 400;
    line-height: 1.55;
    color: var(--text-body);
  }

  pre.warning {
    color: var(--stale);
  }
</style>
