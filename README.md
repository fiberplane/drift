# drift

Spec-driven agentic development with a local-first `.drift/` project format.

## Quickstart

```bash
bun install
```

Create a new project:

```bash
bun run drift:new
# or
bun run drift -- new
```

Run all stale cells:

```bash
bun run drift:run
```

Run one cell:

```bash
bun run drift:run 3
```

Plan one cell (creates a new version snapshot):

```bash
bun run drift:plan 3
```

Commit built cell artifacts:

```bash
bun run drift:commit 3
```

Assemble to markdown and re-initialize from it:

```bash
bun run drift:assemble -- -o PLAN.md
bun run drift:init -- PLAN.md
```

## CLI command guide

`drift` supports the following commands:

- `drift run [cell|file.md] [--no-stream]`
  - Build stale cells, or one target cell with stale ancestors.
  - If you pass `file.md`, Drift initializes `.drift/` from that assembled markdown first.
- `drift plan [cell]`
  - Creates a new `v<N>.md` snapshot with expanded planning notes.
- `drift commit [cell...]`
  - Commits files listed in build artifacts and stores the commit ref in `build.yaml`.
- `drift edit [--host HOST] [--port PORT]`
  - Starts the local edit server.
- `drift new`
  - Scaffolds a fresh `.drift/` directory.
- `drift init <file.md>`
  - Bootstraps `.drift/` from assembled markdown.
- `drift assemble [-o FILE]`
  - Flattens `.drift/cells` into a shareable markdown document.

## `.drift/` format and execution semantics

Drift persists state in files under `.drift/`:

```text
.drift/
├── config.yaml
└── cells/
    ├── 0/v1.md
    └── <n>/
        ├── v1.md
        ├── v2.md
        └── artifacts/
            ├── build.yaml
            ├── build.patch
            └── summary.md
```

- Cells are versioned as `v1.md`, `v2.md`, ...
- `plan` writes a new version file.
- `run` writes build artifacts (`build.yaml`, `build.patch`, `summary.md`).
- Cell state transitions are tracked as `stale`, `running`, `clean`, or `error`.
- `commit` updates `build.yaml` with a VCS ref.

## Development checks

Run tests:

```bash
bun test
```

Run guardrails/lint/format/type checks:

```bash
bun run lint:ast-grep:test
bun run lint:ast-grep
bun run lint:effect
bun run lint
bun run format:check
bun run typecheck
bun run check
```
