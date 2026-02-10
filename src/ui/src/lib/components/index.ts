export const notebookCoreComponents = [
  "Notebook.svelte",
  "Cell.svelte",
  "CellHeader.svelte",
  "CellInput.svelte",
  "CellOutput.svelte",
] as const;

export const notebookAdvancedComponents = [
  "LiveStream.svelte",
  "VersionScrubber.svelte",
  "DiffView.svelte",
  "Summary.svelte",
  "Comments.svelte",
  "DagMinimap.svelte",
] as const;

export const plannedComponents = [
  ...notebookCoreComponents,
  ...notebookAdvancedComponents,
] as const;
