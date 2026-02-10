<script lang="ts">
  interface Props {
    readonly comments: ReadonlyArray<string>;
  }

  let { comments }: Props = $props();
</script>

<section class="comments" aria-label="diff annotations">
  <h3>Annotations</h3>

  {#if comments.length === 0}
    <p>No annotations yet.</p>
  {:else}
    <ul>
      {#each comments as comment, index (`${comment}-${index}`)}
        <li>{comment}</li>
      {/each}
    </ul>
  {/if}
</section>

<style>
  .comments {
    display: grid;
    gap: 0.3rem;
    border-top: 1px solid var(--border-light);
    padding-top: 0.5rem;
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

  p {
    margin: 0;
    color: var(--text-muted);
    font-size: 0.8rem;
    font-style: italic;
  }

  ul {
    margin: 0;
    padding-left: 1rem;
    display: grid;
    gap: 0.15rem;
    font-size: 0.8rem;
    color: var(--text-secondary);
  }
</style>
