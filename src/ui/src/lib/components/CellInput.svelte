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
    gap: 0.35rem;
  }

  label {
    font-size: 0.82rem;
    font-weight: 600;
    color: #4b5563;
  }

  textarea {
    width: 100%;
    min-height: 10rem;
    border-radius: 0.65rem;
    border: 1px solid #d1d5db;
    padding: 0.65rem 0.75rem;
    font-family: "SFMono-Regular", ui-monospace, Menlo, monospace;
    font-size: 0.85rem;
    line-height: 1.4;
    background: #fff;
    resize: vertical;
  }

  textarea:disabled {
    background: #f3f4f6;
    cursor: not-allowed;
  }
</style>
