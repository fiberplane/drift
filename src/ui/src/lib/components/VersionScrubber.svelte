<script lang="ts">
  import type { UiCellVersion } from "../types.ts";

  interface Props {
    readonly versions: ReadonlyArray<UiCellVersion>;
    readonly selectedVersion: number | null;
    readonly disabled?: boolean;
    readonly onSelect?: (version: number | null) => void;
    readonly onRestore?: (version: number) => void;
  }

  const noopSelect = (_version: number | null): void => {};
  const noopRestore = (_version: number): void => {};

  let {
    versions,
    selectedVersion,
    disabled = false,
    onSelect = noopSelect,
    onRestore = noopRestore,
  }: Props = $props();

  const orderedVersions = $derived([...versions].sort((left, right) => left.version - right.version));
  const latestVersion = $derived(orderedVersions[orderedVersions.length - 1]?.version ?? 1);
  const currentVersion = $derived(selectedVersion ?? latestVersion);
  const currentIndex = $derived(
    orderedVersions.findIndex((version) => version.version === currentVersion),
  );
  const safeCurrentIndex = $derived(currentIndex < 0 ? orderedVersions.length - 1 : currentIndex);

  const canGoBackward = $derived(safeCurrentIndex > 0);
  const canGoForward = $derived(safeCurrentIndex < orderedVersions.length - 1);
  const isBrowsingHistory = $derived(selectedVersion !== null);

  const step = (direction: -1 | 1): void => {
    const nextIndex = Math.max(0, Math.min(orderedVersions.length - 1, safeCurrentIndex + direction));
    const nextVersion = orderedVersions[nextIndex];

    if (nextVersion === undefined) {
      return;
    }

    onSelect(nextVersion.version === latestVersion ? null : nextVersion.version);
  };

  const restore = (): void => {
    if (selectedVersion === null) {
      return;
    }

    onRestore(selectedVersion);
  };
</script>

<div class="version-scrubber" role="group" aria-label="plan history">
  <button type="button" onclick={() => step(-1)} disabled={!canGoBackward || disabled}>◀</button>

  <span class:history={isBrowsingHistory}>v{currentVersion}</span>

  <button type="button" onclick={() => step(1)} disabled={!canGoForward || disabled}>▶</button>

  {#if isBrowsingHistory}
    <button type="button" class="link" onclick={() => onSelect(null)} disabled={disabled}>
      Latest
    </button>

    <button type="button" class="restore" onclick={restore} disabled={disabled}>
      Restore
    </button>
  {/if}
</div>

<style>
  .version-scrubber {
    display: inline-flex;
    align-items: center;
    gap: 0.2rem;
    border: 1px solid var(--border-mid);
    border-radius: 999px;
    padding: 0.12rem 0.25rem;
    background: var(--bg-inset);
  }

  span {
    min-width: 2.3rem;
    text-align: center;
    font-family: var(--font-mono);
    font-size: 0.7rem;
    font-weight: 400;
    color: var(--text-tertiary);
  }

  span.history {
    color: var(--accent);
    font-weight: 500;
  }

  button {
    border: 1px solid transparent;
    background: transparent;
    border-radius: var(--radius-sm);
    font-family: var(--font-body);
    font-size: 0.7rem;
    color: var(--text-secondary);
    cursor: pointer;
    padding: 0.1rem 0.3rem;
    transition: all 0.12s ease;
  }

  button:hover:not(:disabled) {
    background: var(--bg-wash);
    color: var(--text-body);
  }

  button:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .restore {
    border-color: var(--error-border);
    background: var(--error-bg);
    color: var(--error);
  }

  .restore:hover:not(:disabled) {
    background: var(--error-border);
  }

  .link {
    color: var(--accent);
  }

  .link:hover:not(:disabled) {
    color: var(--text-body);
  }
</style>
