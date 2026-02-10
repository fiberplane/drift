<script lang="ts">
  import type { CellInputChange } from "../types.ts";

  interface Props {
    readonly cellIndex: number;
    readonly value: string;
    readonly disabled?: boolean;
    readonly onInput?: (change: CellInputChange) => void;
  }

  const noopInput = (_change: CellInputChange): void => {};

  let { cellIndex, value, disabled = false, onInput = noopInput }: Props = $props();

  const handleInput = (event: Event): void => {
    const target = event.currentTarget;
    if (!(target instanceof HTMLTextAreaElement)) {
      return;
    }

    onInput({
      cellIndex,
      value: target.value,
    });
  };
</script>

<div class="cell-input">
  <label for={`cell-${cellIndex}-input`}>Markdown</label>

  <textarea
    id={`cell-${cellIndex}-input`}
    value={value}
    oninput={handleInput}
    {disabled}
    spellcheck="false"
    rows="10"
  ></textarea>
</div>

<style>
  .cell-input {
    display: grid;
    gap: 0.3rem;
  }

  label {
    font-family: var(--font-mono);
    font-size: 0.62rem;
    font-weight: 500;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }

  textarea {
    width: 100%;
    min-height: 10rem;
    border-radius: var(--radius-md);
    border: 1px solid var(--border-light);
    padding: 0.75rem 0.85rem;
    font-family: var(--font-mono);
    font-size: 0.82rem;
    font-weight: 400;
    line-height: 1.55;
    color: var(--text-body);
    background: var(--bg-inset);
    resize: vertical;
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }

  textarea:focus {
    outline: none;
    border-color: var(--accent);
    box-shadow: 0 0 0 2px var(--accent-light);
    background: var(--bg-card);
  }

  textarea:disabled {
    background: var(--bg-wash);
    color: var(--text-tertiary);
    cursor: not-allowed;
  }
</style>
