# Drift

Spec-driven agentic development with lazy evaluation.

## Overview

Drift is a CLI tool and local web UI for iterative, spec-driven software development. You write cells — markdown files describing intent — and Drift organizes them into a DAG, uses coding agents to derive code, and manages versions as cells evolve. When you edit a cell, downstream cells are invalidated. Re-evaluation is lazy: nothing runs until you ask it to.

The `.drift/` directory is the source of truth. The codebase is the output. A flat markdown doc can be assembled from the cells at any time for sharing or review.

## Core Concepts

### Cells

A cell is a cell. It has an **input** (text you write — prose, constraints, code snippets, images, whatever) and an **output** (agent-generated diff + review summary). Every cell is the same type. Every cell is runnable. Every cell is a composable intent element.

There is no distinction between "spec cells" and "impl cells." A cell that says "Book has title, isbn, genre" and a cell that says "Implement the books router at src/routes/books.ts" are both just cells. One produces a diff for a data model, the other for a router. The DAG determines what context flows where.

### Lazy Evaluation (Marimo-style)

Drift borrows its execution model from Marimo:

1. Cells form a DAG via dependencies
2. Edit a cell → mark all transitive descendants as **stale**
3. Stale cells are **not** automatically run (agents are expensive)
4. When you run a cell, **all stale ancestors are built first** — each one gets its own agent call, producing code on disk, so that downstream cells see up-to-date files via `@`-imports
5. After a cell runs, any stale children that now have all-clean ancestors become eligible to run

This means you can run a leaf cell and Drift will automatically resolve the full chain above it. Each stale ancestor is a separate agent invocation — there's no way around this because each cell produces files that later cells reference. Or you can run everything with "Build all stale."

### Cell Actions

Every cell has three actions: **Plan**, **Build**, and **Commit**.

**⟐ Plan**: The agent reads the cell content + dependencies and expands/refines the cell's intent. The output is written back into the cell as a new version. You can plan multiple times — each pass makes the spec richer.

**▶ Build**: The agent reads the cell content + dependencies and produces a unified diff. The diff is applied to the **working copy**. Nothing is committed. A second review pass summarizes what was done and flags mismatches.

**✓ Commit**: Commits the files this cell touched to VCS (git or jj). The commit ref is stored in the cell's artifact metadata. Only available after a successful build with uncommitted changes.

Plan is for sketching. Build is for executing. Commit is for snapshotting. You can build several cells, review all the changes in the working copy, then commit them individually or batch.

### Build Output

When a cell is built, two things happen:

**Pass 1 — Generate**: The agent receives the cell's content plus the content and outputs of its dependencies. It produces a unified diff against files in the working directory. The diff is applied automatically to the working copy.

**Pass 2 — Review**: A second agent call reviews the diff against the cell's intent. It produces a short summary of what was done and flags anything that doesn't match. This summary is the primary thing you read.

### Artifacts

After a build, the cell's artifact metadata is updated:

```yaml
# .drift/cells/3/artifacts/build.yaml
files:                          # files this cell touched
  - src/routes/todos.ts
ref: null                       # git hash or jj change-id, set on commit
timestamp: 2025-02-10T14:30:00Z
```

`build.patch` is also written as a display cache — what the agent produced, shown in the UI diff viewer. It is not the source of truth for rollback; the VCS is.

`summary.md` contains the review pass output.

### Commit Behavior

When you commit a cell:

1. Stage only the files listed in `build.yaml`
2. Create a commit: `drift: cell 3 — CRUD Routes`
3. Store the ref (git hash or jj change-id) in `build.yaml`
4. Cell state becomes committed (✅ with ref)

**jj**: Creates or amends a change. Nearly free — jj's working copy model means every state already has an identity.

**git**: Creates a commit. Multiple cell commits can be squashed later. Drift doesn't force a workflow — it just gives you the commit button.

**Batch commit**: Select multiple cells in the UI or `drift commit 1 2 3` in the CLI. One commit containing all their files. The same ref is written to each cell's `build.yaml`.

### Plan Versioning

Each plan pass creates a version snapshot. Versions are stored as numbered markdown files in the cell's directory:

```
.drift/cells/3/
├── v1.md    # "we need auth, OAuth probably"
├── v2.md    # expanded with providers, session strategy
└── v3.md    # full spec with routes, models, @-imports
```

The highest-numbered version is current. Previous versions are read-only snapshots.

In the UI, cells with plan history show a version indicator (`v3`). Click or arrow-key to scrub through versions. Diff between any two versions on demand. Rolling back saves the current as a new snapshot first — rollback is never destructive.

## Storage

The `.drift/` directory is the source of truth.

### Directory Structure

```
.drift/
├── config.yaml                  # Project config (agent, model, resolver, vcs, execution)
├── cells/
│   ├── 0/
│   │   └── v1.md               # Cell content (highest version is current)
│   ├── 1/
│   │   ├── v1.md               # Initial draft
│   │   ├── v2.md               # After first plan
│   │   └── artifacts/
│   │       ├── build.yaml      # Metadata: files touched, VCS ref, timestamp
│   │       ├── build.patch     # Display cache: last agent-generated diff
│   │       └── summary.md      # Last review summary
│   ├── 3/
│   │   ├── v1.md
│   │   ├── v2.md
│   │   ├── v3.md
│   │   └── artifacts/
│   │       ├── build.yaml
│   │       ├── build.patch
│   │       ├── summary.md
│   │       └── error.log       # If last build failed
│   └── ...
└── cache/                       # Resolved imports, inline outputs
```

Cell directories are numbered. The highest `v<N>.md` file is the current version. Build artifacts live in `artifacts/`. Everything is plain files — human-readable, git-trackable.

### Config

`.drift/config.yaml`:

```yaml
agent: claude              # default agent backend: claude | pi | codex
model: sonnet              # model hint passed to the agent
resolver: explicit         # dependency strategy: explicit | linear | inferred
vcs:
  backend: auto            # auto-detect git/jj, or explicit: git | jj
execution:
  parallel: false          # true = parallelize independent cells within a level
```

All fields are optional. Defaults: `agent: claude`, `resolver: explicit`, `vcs.backend: auto`, `execution.parallel: false`.

### Cell Files

A cell file is plain markdown with optional HTML comment metadata:

```markdown
## Books <!-- depends: 0 -->

Book: {title, isbn, author_id, genre}.
CRUD at /books. Auth required.

@./src/routes/books.ts
```

Metadata in the HTML comment: `depends: N, M` for dependencies, `agent: pi` for per-cell agent override. Both optional.

### Comments

Blockquotes are comments. Visible in the UI, stripped from agent prompts.

```markdown
> Should we validate ISBN format here? —sam
> Shared validator, see cell 6. —alice
```

### Imports

`@` references inline file contents into the prompt at assembly time. They give cells precise context beyond what dependency cells provide.

```markdown
## CRUD Routes <!-- depends: 1, 2 -->

CRUD at /todos. Filter by completed status.

@./src/routes/todos.ts
@./src/db/schema.ts
```

**Supported forms:**

| Syntax | Effect |
|--------|--------|
| `@./path/to/file.ts` | Inline entire file (relative to project root) |
| `@./src/**/*.ts` | Glob — inline all matching files |
| `@./src/api.ts:10-50` | Line range — lines 10 through 50 |
| `@./src/types.ts#UserInterface` | Symbol extraction — a specific export |

Globs respect `.gitignore`. Imported content is wrapped with the file path for the agent:

```
<file path="src/routes/todos.ts">
...file contents...
</file>
```

Imports inside fenced code blocks are ignored (so you can document the syntax without triggering it).

When a cell targets a file for modification, `@`-importing that file is how the agent sees the current state on disk. The diff is generated against this state.

### Command Inlines

`` !`command` `` executes a shell command and inlines its stdout at prompt assembly time. Useful for dynamic context.

```markdown
## Fix Failing Tests <!-- depends: 3 -->

These tests are failing:

!`bun test src/routes/todos.test.ts 2>&1 | tail -30`

Fix them.

@./src/routes/todos.test.ts
@./src/routes/todos.ts
```

The command runs in the project root. Output is inlined verbatim. Commands run at prompt assembly time (just before the agent call), so they reflect current state.

### Build Artifacts

After a cell is built, artifacts are written to `.drift/cells/<index>/artifacts/`:

- `build.yaml` — metadata: files touched, VCS ref (null until committed), timestamp
- `build.patch` — display cache: the raw diff the agent produced (shown in UI)
- `summary.md` — the review pass output

Overwritten on each build. The patch is applied to the working copy via `git apply`. See **Cell Actions → Commit Behavior** for how the VCS ref gets populated.

### Assembled Output

`drift assemble` produces a single flat markdown file from the cell directory — useful for sharing, review, or running from scratch in a fresh repo.

```
drift assemble                   # → stdout
drift assemble -o PLAN.md       # → file
```

The assembled file uses `---` cell separators, includes frontmatter from `config.yaml`, and embeds build outputs as HTML comments — the same format that `drift init` can parse back into a `.drift/` directory.

### Bootstrapping

You can start from either direction:

**From scratch**: `drift new` creates a `.drift/` directory with config and a cell 0.

**From an existing markdown file**: `drift init spec.md` parses the markdown (splitting on `---`, extracting frontmatter, extracting `<!-- drift:summary -->` / `<!-- drift:diff -->` blocks) and creates the `.drift/` directory from it.

This means the assembled markdown format is a valid interchange format. You can `drift assemble` on one machine, send the file, and `drift init` on another to reconstruct the project.

### Full Example

```
.drift/
├── config.yaml     # agent: claude, model: sonnet
├── cells/
│   ├── 0/
│   │   └── v1.md   # "# Todo API\nExpress + TypeScript + Zod..."
│   ├── 1/
│   │   └── v1.md   # "## Data Model <!-- depends: 0 -->\n..."
│   ├── 2/
│   │   └── v1.md   # "## Database <!-- depends: 0 -->\n..."
│   ├── 3/
│   │   ├── v1.md   # "## CRUD Routes <!-- depends: 1, 2 -->\n..."
│   │   └── artifacts/
│   │       ├── build.yaml
│   │       ├── build.patch
│   │       └── summary.md
│   └── 4/
│       └── v1.md   # "## Tests <!-- depends: 1, 3 -->\n..."
```

Five cells. Each one runs. Cell 0 sets system context. Cell 3 depends on cells 1 and 2, so the agent sees the data model and database setup when generating routes. Cell 4 depends on cells 1 and 3 — its content uses `@`-imports and a command inline to show the agent current test output.

## Dependency Resolution

Dependencies determine the DAG. The resolution strategy is pluggable.

### Interface

```typescript
import { Schema } from "effect"

const Edge = Schema.Struct({
  from: Schema.Number,  // dependency (upstream)
  to: Schema.Number,    // dependent (downstream)
})

interface DependencyResolver {
  resolve(cells: readonly Cell[]): Effect.Effect<typeof Edge.Type[], DagCycleError>
}
```

### Strategies

**Explicit** (v1 default): Read `<!-- depends: N, M -->` from each cell. Cells with no explicit declaration depend on cell 0 only.

**Linear**: Each cell depends on all cells above it. Simple, coarse, no annotations needed.

**Inferred**: An agent call examines all cells and classifies which ones relate to which. Clever but adds latency and cost.

### Override Behavior

Explicit `<!-- depends: -->` declarations always take priority. If a cell has explicit deps, they are used regardless of the active strategy. The resolver only fills in dependencies for cells that don't declare them.

This means you can use Linear or Inferred as a baseline and override specific cells with explicit declarations where the automatic resolution gets it wrong.

## Cell States

| State | Symbol | Meaning |
|-------|--------|---------|
| Clean | ✅ | Output matches current input. Diff applied to disk. |
| Stale | 🟡 | An ancestor changed. Needs re-evaluation. |
| Running | 🔄 | Agent is currently generating output. Streams in real time. |
| Error | 🔴 | Agent failed or diff didn't apply. |

While a cell is in the Running state, agent output streams token-by-token into a **live output** panel below the cell input. For builds, this shows the diff as it's being generated. For plans, this shows the expanded spec forming in real time. The live output replaces with the final summary/diff once the run completes (or an error on failure).

### State Transitions

```
[new/edited cell]
    │
    ▼
  Stale 🟡 ──▶ Triggered ──▶ Running 🔄 ──▶ Clean ✅
    ▲                            │               │
    │                            ▼               │
    │                         Error 🔴           │
    │                                            │
    └──────── [ancestor edited] ◀────────────────┘
```

### Ancestor Resolution and Execution Order

When you build a cell:

1. Walk up the DAG and collect all stale ancestors
2. Topologically sort them into levels (cells with no unresolved deps in the same level)
3. Execute each level in cell-index order, one cell at a time
4. Then run the target cell
5. Mark newly-eligible descendants as runnable (but don't auto-run them)

Each cell gets its own agent call. This is unavoidable — cell 2 might `@`-import a file that cell 1 creates, so cell 1 must finish and write to disk before cell 2's prompt is assembled.

**Example:** Running cell 6 (Tests) with everything stale:

```
Level 0:  [0]           ← context cell, no agent call
Level 1:  [1] → [2] → [3]   ← sequential: 1 creates schema.ts,
                                2 imports it, 3 imports both
Level 2:  [4] → [5]          ← sequential: 4 writes users.ts,
                                5 can see it if needed
Level 3:  [6]                 ← target cell
```

Total: 6 agent calls, sequential.

### Parallel Execution (opt-in)

Within a topological level, cells that are DAG-independent *can* run in parallel. Off by default.

```yaml
# config.yaml
execution:
  parallel: false    # true = parallelize independent cells within a level
```

**Why off by default:** Parallel execution exposes latent dependency bugs. Cells 1 and 2 might be DAG-independent but practically coupled — cell 2's agent generates `import { TodoSchema } from './schema'`, a file that cell 1 is simultaneously creating. Sequential execution masks this (cell 2 happens to run after cell 1 by index order). Parallel execution surfaces it as a failure.

Parallel also risks file conflicts: two cells in the same level touching the same file produce two diffs against the same base state. The second `git apply` fails.

**When parallel is enabled:**

1. Group stale cells by topological level
2. Within each level, run all cells concurrently
3. If `git apply` fails for a cell (conflict), retry it sequentially after the rest of the level completes
4. If retry also fails, cell enters error state

This gives the speed win (wall-clock time = O(DAG depth) instead of O(cells)) while gracefully handling the common conflict case. But the default is sequential because it's predictable and safe.

## Prompt Assembly

When a cell is executed (plan or build), Drift assembles a prompt from the DAG. Before assembly, all `@`-imports are resolved (files read, globs expanded, symbols extracted) and `` !`command` `` inlines are executed. The resolved content replaces the `@` and `` !` `` references in the cell text.

### Build Prompt

```
# System context
{cell 0 content — always included, with imports resolved}

# Dependencies
{for each dependency in topological order:
  cell content (imports resolved) + last output (diff) if clean}

# What changed
{if re-evaluating: diff of input changes since last run}

# Task
{cell content, with all @-imports and !`commands` resolved}

Generate a unified diff.
If a file does not exist, diff against /dev/null.
Respond ONLY with the unified diff.
```

### Review Prompt

```
# Intent
{cell content}

# Dependencies
{dependency cell contents}

# Generated diff
{the diff from pass 1}

# Task
Summarize what was done in 2-4 sentences.
Flag anything that doesn't match the intent. Prefix warnings with ⚠.
```

### Plan Prompt

```
# System context
{cell 0 content — always included, with imports resolved}

# Dependencies
{for each dependency in topological order:
  cell content (imports resolved) + last output (diff) if clean}

# Current cell content
{cell content, with all @-imports and !`commands` resolved}

# Task
Expand this cell into a detailed, actionable spec.
Research what's needed, define concrete requirements,
suggest @-imports for relevant files, and add dependency
declarations if missing.

Respond ONLY with the new cell content (markdown).
Do not include ```markdown fences.
```

The plan output is written as a new version file (e.g., `v2.md`) in `.drift/cells/<index>/`. The previous version is preserved.

## Diff Handling

### Generation

The agent produces a unified diff. Target files are determined by `@`-imports in the cell — the agent sees the current file contents and generates a diff against them. A cell can target multiple files.

### Validation and Application

```bash
echo "$diff" | git apply --check  # validate
echo "$diff" | git apply          # apply
```

No approval step. The spec is the approval.

### New Files

If the target file doesn't exist, the diff is against `/dev/null`:

```diff
--- /dev/null
+++ b/src/routes/books.ts
@@ -0,0 +1,47 @@
+import { Router } from 'express';
+...
```

### Multi-file Output

A single cell can produce diffs touching multiple files. The unified diff format naturally supports this — multiple file sections in one patch.

### Drift Detection

Drift checks if files on disk still match what a cell last produced. Two detection methods:

- **With VCS ref**: If `build.yaml` has a ref, diff the committed state against the working copy for those files. Any changes not made by Drift are detected.
- **Without VCS ref**: Hash the files listed in `build.yaml` at build time, compare on next load. Cruder but works before commit.

If a file was manually edited, the cell shows a "drifted" indicator — distinct from stale (drifted = code moved independently of spec). You can re-build to reconcile, or commit to accept the manual changes as-is.

## CLI

Mirrors Marimo's subcommand model: `run` builds headlessly, `edit` opens the interactive UI.

```
drift run [cell]             # Build all cells (or a specific cell + stale ancestors)
drift plan [cell]            # Plan all cells (or a specific cell)
drift commit [cell...]       # Commit built cells to VCS (all uncommitted, or specific cells)
drift edit                   # Open the web UI (default: http://localhost:4747)
drift new                    # Create a new .drift/ project
drift init <file.md>         # Bootstrap .drift/ from an existing markdown file
drift assemble [-o FILE]     # Assemble cells into a single markdown file
```

`drift run` is the primary command. Point it at a project and it implements the whole thing — reads `.drift/`, resolves the DAG, builds every cell top-down. This is the "just build it" mode. Also accepts an assembled markdown file: `drift run PLAN.md` will `init` + `run` in one step.

`drift plan` is the same but runs the plan pass instead — expands every cell's intent without producing diffs. Useful for fleshing out a rough spec before building.

`drift commit` commits cell changes to VCS. Without arguments, commits all cells that have uncommitted builds. With cell numbers, commits only those. Multiple cells in one `drift commit` produce a single commit with all their files.

`drift edit` is the interactive mode. Opens the web UI where you can plan, build, and commit cells individually, inspect diffs, scrub through plan versions, and iterate.

`drift assemble` reads `.drift/cells/` and outputs a flat markdown file with `---` separators, frontmatter from `config.yaml`, and build outputs embedded as HTML comments. This is the interchange format — `drift init` can parse it back.

### `drift run`

```
$ drift run

  0: Todo API              ✅ (context only)
  1: Data Model            🔄 → ✅  +47 in src/db/schema.ts
  2: Database              🔄 → ✅  +83 in src/db/index.ts
  3: CRUD Routes           🔄 → ✅  +34 -2 in src/routes/todos.ts
     ⚠ No error handling for invalid UUIDs.
  4: Tests                 🔄 → ✅  +91 in src/routes/todos.test.ts

✅ 4/4 cells clean.
```

### `drift plan 3`

```
⟐ Cell 3: CRUD Routes (v1 → v2)
  ├─ Deps: 1, 2
  └─ Expanded: added filtering spec, error handling
     requirements, pagination strategy.

✅ Cell 3 planned. Review with drift edit.
```

### `drift run 3`

```
$ drift run 3

▶ Cell 3: CRUD Routes
  ├─ Deps: 1 ✅, 2 ✅ (all clean)
  ├─ Agent: claude
  │
  │  --- a/src/routes/todos.ts        ← streams live
  │  +++ b/src/routes/todos.ts
  │  @@ -1,4 +1,38 @@
  │  +import { Router } from "express"
  │  ...
  │
  ├─ Diff: +34 -2 in src/routes/todos.ts
  └─ Added CRUD endpoints with Zod validation.
     Filtering by completed status via ?completed=true|false.
     ⚠ No error handling for invalid UUIDs.

✅ Cell 3 clean. Cells [4] now eligible.
```

In the CLI, agent output streams directly to stdout as it arrives. The final summary replaces the stream. Use `--no-stream` to suppress live output and only show the final result.

### `drift commit 3`

```
✓ Cell 3: CRUD Routes
  ├─ Files: src/routes/todos.ts
  ├─ Commit: a1b2c3d (drift: cell 3 — CRUD Routes)
  └─ Ref saved to .drift/cells/3/artifacts/build.yaml

✅ Cell 3 committed.
```

### `drift commit 1 2 3`

```
✓ Cells 1, 2, 3 → single commit
  ├─ Files: src/db/schema.ts, src/db/index.ts, src/routes/todos.ts
  ├─ Commit: e4f5g6h (drift: cells 1, 2, 3 — Data Model, Database, CRUD Routes)
  └─ Ref saved to all 3 cells.

✅ 3 cells committed.
```

## Web UI (`drift edit`)

### Architecture

Bun + `@effect/platform` HttpApi server, SvelteKit frontend (SPA mode). Server watches `.drift/cells/` and pushes updates via WebSocket. Edits in the UI write back to cell files. Edits in an external editor are detected and synced to the UI.

The server exposes endpoints for cell execution. The UI triggers runs, the server spawns agents, streams progress back over WebSocket.

### Config Panel

`config.yaml` renders as an editable config panel at the top of the notebook (or in a sidebar). Changes write back to the file. This is where you pick the agent, model, and resolver strategy.

### Cell Rendering

Every cell renders the same way:

1. **Header**: Cell index, heading (if present), dependency list, state badge, **⟐ Plan** (secondary), **▶ Build** (primary), **✓ Commit** (enabled when built + uncommitted). If plan history exists, a version indicator (`v3`) with left/right arrows.
2. **Input**: Editable markdown. The cell's content. Comments (blockquotes) rendered with muted styling.
3. **Live output** (during Running state only): Streaming agent output rendered as it arrives. Monospace, auto-scrolling, muted styling. For builds, raw diff tokens stream in. For plans, the expanding spec text streams in. Disappears when execution completes, replaced by the final output below.
4. **Output** (below input, after first build):
   - **Summary** (primary): The review text. Warnings highlighted. This is what you read.
   - **Diff** (collapsed, expandable): Rendered via `@pierre/diffs`. Split/stacked views, syntax highlighting, line selection. Comments/annotations via the `@pierre/diffs` annotation system.
   - **Commit ref** (if committed): Short hash linking to VCS.

### Cell Execution

Plan, Build, and Commit are all triggered from the UI.

- **Build one cell**: Click ▶ or `Shift+Enter`. Stale ancestors resolve first. Produces a diff applied to working copy.
- **Plan one cell**: Click ⟐ or `Alt+Enter`. Agent expands the cell content. Previous content saved as version snapshot. Cell text updates in place.
- **Commit one cell**: Click ✓. Stages only this cell's files, creates a VCS commit, stores the ref.
- **Build all stale**: Global action in the toolbar.
- **Plan all stale**: Global action in the toolbar (secondary).
- **Commit all uncommitted**: Global action in the toolbar. Single commit with all uncommitted cell files.
- **Progress**: Cell shows 🔄 spinner and live output panel during plan/build. Agent tokens stream in real time via WebSocket. Plan completion updates the cell text; build completion shows summary + diff. Live output panel collapses away.
- **Cancel**: Running cells can be cancelled (kills the agent process). Live output preserved for inspection until dismissed.

The server handles execution — the UI sends `{ action: "plan" | "build" | "commit", cell: N }` over WebSocket. The server resolves the DAG, spawns agents, and streams token-by-token output back. Messages:

```typescript
// Server → Client
{ type: "cell:state", cell: number, state: CellState }
{ type: "cell:token", cell: number, token: string }         // streaming chunk
{ type: "cell:complete", cell: number, artifact: BuildArtifact }
{ type: "cell:error", cell: number, error: string }
{ type: "dag:updated", cells: Cell[] }                       // after file watcher triggers
```

### Plan Version History

Cells with plan history show a version scrubber in the header: `◀ v3 ▶`. Click or arrow-key to browse previous versions. The cell content swaps to the selected version (read-only when viewing history).

- **Diff between versions**: Click the version indicator to open a version timeline. Select any two versions to diff them side-by-side.
- **Rollback**: Select a past version and click "Restore." The current content is saved as a new snapshot first — rollback is never destructive.
- **Version storage**: `.drift/cells/<index>/v1.md`, `v2.md`, etc.

### Interactions

- **Edit a cell**: Updates the cell's version file, marks descendants stale
- **Plan a cell**: ⟐ button or Alt+Enter
- **Build a cell**: ▶ button or Shift+Enter
- **Commit a cell**: ✓ button (only when built + uncommitted)
- **Build all stale**: Toolbar button (primary)
- **Commit all uncommitted**: Toolbar button
- **Browse versions**: ◀ ▶ arrows on cells with plan history
- **Add a cell**: Creates a new `.drift/cells/<N>/v1.md`
- **Add a comment**: Appends a blockquote to the cell

### DAG Minimap

Sidebar showing the dependency graph. Stale cells highlighted. Click to scroll. Shows the shape of the spec at a glance.

### Real-time Sync

Server watches `.drift/cells/` via `fs.watch` (recursive). On external change to any cell file, re-read, recompute DAG, push to UI via WebSocket. The UI is always in sync regardless of edit source.

## Tech Stack

| Layer | Technology |
|-------|------------|
| Runtime | Bun |
| Language | TypeScript (ESM) |
| Core framework | Effect |
| Data modeling | `@effect/schema` |
| Web server | `@effect/platform` (HttpApi) |
| Frontend | SvelteKit (SPA mode) |
| Diff rendering | `@pierre/diffs` |
| Markdown rendering | `marked` |
| Real-time sync | WebSocket |
| Process spawning | `@effect/platform` (Command) |
| Linting | `ast-grep` (structural, no type-checker needed) |

## Project Structure

```
drift/
├── package.json
├── CLAUDE.md                    # Agent coding conventions (included in all prompts)
├── .ast-grep/
│   └── rules/                   # Lint rules enforcing CLAUDE.md conventions
├── src/
│   ├── cli/                    # CLI entry point and commands
│   │   ├── index.ts
│   │   ├── run.ts
│   │   ├── plan.ts
│   │   ├── commit.ts
│   │   ├── edit.ts
│   │   ├── new.ts
│   │   ├── init.ts
│   │   └── assemble.ts
│   ├── core/                   # Pure logic (no IO)
│   │   ├── schemas.ts          # Effect Schemas (Cell, DriftConfig, BuildArtifact, etc.)
│   │   ├── errors.ts           # Tagged errors (DagCycleError, AgentError, etc.)
│   │   ├── loader.ts           # Load .drift/cells/ → Cell[]
│   │   ├── parser.ts           # Parse markdown → Cell[] (for drift init)
│   │   ├── assembler.ts        # Cell[] → flat markdown (for drift assemble)
│   │   ├── dag.ts              # Build DAG, topological sort
│   │   ├── resolver.ts         # DependencyResolver interface + implementations
│   │   ├── imports.ts          # @-import resolution (files, globs, symbols, line ranges)
│   │   ├── inlines.ts          # !`command` inline execution
│   │   ├── versions.ts         # Plan version history (snapshot, restore, diff)
│   │   ├── vcs.ts              # VCS abstraction (git/jj commit, ref storage)
│   │   ├── invalidation.ts     # Stale propagation
│   │   ├── prompt.ts           # Prompt assembly from DAG
│   │   └── diff.ts             # Diff validation and application
│   ├── agent/                  # Agent backends
│   │   ├── types.ts            # AgentBackend service: returns Stream<string> (token chunks)
│   │   ├── claude.ts
│   │   ├── pi.ts
│   │   └── codex.ts
│   ├── server/                 # Web UI backend
│   │   ├── index.ts            # HttpApi server
│   │   ├── api.ts              # HttpApi routes (plan, build, commit)
│   │   ├── ws.ts               # WebSocket handler
│   │   └── watcher.ts          # File watcher → re-load → push
│   └── ui/                     # SvelteKit frontend
│       └── src/
│           ├── routes/
│           │   └── +page.svelte
│           └── lib/
│               ├── components/
│               │   ├── Notebook.svelte
│               │   ├── Cell.svelte         # Universal cell: input + output
│               │   ├── CellHeader.svelte
│               │   ├── CellInput.svelte    # Editable markdown
│               │   ├── CellOutput.svelte   # Summary + diff
│               │   ├── LiveStream.svelte   # Streaming agent output during Running state
│               │   ├── VersionScrubber.svelte # Plan version history ◀ v3 ▶
│               │   ├── DiffView.svelte     # @pierre/diffs wrapper
│               │   ├── Summary.svelte
│               │   ├── Comments.svelte
│               │   └── DagMinimap.svelte
│               ├── state/                  # Svelte 5 runes, not stores
│               │   ├── notebook.svelte.ts  # $state() for cell list, DAG
│               │   └── ws.svelte.ts        # WebSocket connection + streaming state
│               └── types.ts
```

## Loader

### Algorithm

1. Read `.drift/config.yaml` → `DriftConfig`
2. Enumerate `.drift/cells/*/` directories, sorted numerically
3. For each cell directory:
   - Read the highest-numbered `v<N>.md` file as current content
   - Extract `<!-- depends: N, M -->` and `<!-- agent: X -->` if present
   - Extract blockquotes as comments
   - Parse `@`-references (outside fenced code blocks) → `Import[]`
   - Parse `` !`command` `` references (outside fenced code blocks) → `Inline[]`
   - Read `artifacts/build.yaml`, `artifacts/build.patch`, and `artifacts/summary.md` if they exist
   - Count version files to set `version`
4. Pass cells through the active `DependencyResolver` to build the DAG
5. Validate: no cycles, all referenced indices exist

### Markdown Parser (for `drift init`)

When bootstrapping from a markdown file:

1. Extract YAML frontmatter → `.drift/config.yaml`
2. Split remainder on `/^---$/m`
3. For each segment, create `.drift/cells/<index>/v1.md`
4. Extract `<!-- drift:summary -->` and `<!-- drift:diff -->` blocks → `artifacts/`

### Schemas and Errors

```typescript
import { Data, Schema } from "effect"

// --- Schemas ---

const AgentBackend = Schema.Literal("claude", "pi", "codex")

const VcsConfig = Schema.Struct({
  backend: Schema.optionalWith(Schema.Literal("auto", "git", "jj"), { default: () => "auto" as const }),
})

const ExecutionConfig = Schema.Struct({
  parallel: Schema.optionalWith(Schema.Boolean, { default: () => false }),
})

const DriftConfig = Schema.Struct({
  agent: Schema.optionalWith(AgentBackend, { default: () => "claude" as const }),
  model: Schema.NullOr(Schema.String),
  resolver: Schema.optionalWith(
    Schema.Literal("explicit", "linear", "inferred"),
    { default: () => "explicit" as const }
  ),
  vcs: Schema.optionalWith(VcsConfig, { default: () => ({ backend: "auto" as const }) }),
  execution: Schema.optionalWith(ExecutionConfig, { default: () => ({ parallel: false }) }),
})

const ImportKind = Schema.Literal("file", "glob", "range", "symbol")

const Import = Schema.Struct({
  raw: Schema.String,
  kind: ImportKind,
  path: Schema.String,
  range: Schema.optional(Schema.Tuple(Schema.Number, Schema.Number)),
  symbol: Schema.optional(Schema.String),
})

const Inline = Schema.Struct({
  raw: Schema.String,
  command: Schema.String,
})

const CellState = Schema.Literal("clean", "stale", "running", "error")

const BuildArtifact = Schema.Struct({
  files: Schema.Array(Schema.String),
  ref: Schema.NullOr(Schema.String),     // VCS ref, null until committed
  timestamp: Schema.String,               // ISO 8601
  summary: Schema.String,
  patch: Schema.String,                   // display cache
})

const Cell = Schema.Struct({
  index: Schema.Number,
  content: Schema.String,
  explicitDeps: Schema.NullOr(Schema.Array(Schema.Number)),
  agent: Schema.NullOr(AgentBackend),
  imports: Schema.Array(Import),
  inlines: Schema.Array(Inline),
  version: Schema.Number,
  dependencies: Schema.Array(Schema.Number),
  dependents: Schema.Array(Schema.Number),
  state: CellState,
  comments: Schema.Array(Schema.String),
  artifact: Schema.NullOr(BuildArtifact),
  lastInputHash: Schema.NullOr(Schema.String),
})

// --- Tagged Errors ---

// DAG has a cycle — spec is invalid
class DagCycleError extends Data.TaggedError("DagCycleError")<{
  readonly cells: ReadonlyArray<number>   // cell indices forming the cycle
}> {}

// Agent produced output that isn't a valid unified diff
class InvalidDiffError extends Data.TaggedError("InvalidDiffError")<{
  readonly cellIndex: number
  readonly rawOutput: string              // what the agent actually returned
}> {}

// git apply (or jj equivalent) failed — patch doesn't apply cleanly
class DiffApplyError extends Data.TaggedError("DiffApplyError")<{
  readonly cellIndex: number
  readonly patch: string
  readonly stderr: string
}> {}

// Agent process exited non-zero or timed out
class AgentError extends Data.TaggedError("AgentError")<{
  readonly cellIndex: number
  readonly agent: string
  readonly exitCode: number | null
  readonly stderr: string
}> {}

// A stale ancestor failed during cascading build
class AncestorFailedError extends Data.TaggedError("AncestorFailedError")<{
  readonly targetCell: number
  readonly failedCell: number
  readonly cause: InvalidDiffError | DiffApplyError | AgentError
}> {}

// @-import references a file/glob that doesn't exist
class ImportNotFoundError extends Data.TaggedError("ImportNotFoundError")<{
  readonly cellIndex: number
  readonly importRef: string              // the raw @-reference
}> {}

// !`command` inline exited non-zero
class InlineCommandError extends Data.TaggedError("InlineCommandError")<{
  readonly cellIndex: number
  readonly command: string
  readonly exitCode: number
  readonly stderr: string
}> {}

// VCS commit failed
class VcsCommitError extends Data.TaggedError("VcsCommitError")<{
  readonly cellIndices: ReadonlyArray<number>
  readonly stderr: string
}> {}

// File on disk was modified outside of Drift after last build
class DriftDetectedError extends Data.TaggedError("DriftDetectedError")<{
  readonly cellIndex: number
  readonly files: ReadonlyArray<string>   // files that drifted
}> {}
```

## Error Handling

All errors are modeled as Effect tagged errors (see Data Structures above). This gives exhaustive matching, structured context, and clean propagation through the Effect pipeline.

**`InvalidDiffError`**: Agent produced output that isn't a valid unified diff. Cell enters error state. Raw output stored in the error for debugging. User can retry or simplify the cell.

**`DiffApplyError`**: `git apply` failed — patch doesn't apply cleanly against current file state. Cell enters error state. Includes the patch and stderr. User can re-build (regenerates against current state) or fix the file manually. When `execution.parallel` is enabled, triggers automatic sequential retry before surfacing.

**`AgentError`**: Agent process exited non-zero or timed out. Includes exit code and stderr. User can retry, switch agents, or simplify the cell.

**`AncestorFailedError`**: A stale ancestor failed during cascading build. Wraps the ancestor's underlying error (`InvalidDiffError`, `DiffApplyError`, or `AgentError`). Execution halts — the target cell stays stale. User fixes the failed ancestor first.

**`DagCycleError`**: Loader detects a cycle in the dependency graph. Spec is invalid. Error includes the cell indices forming the cycle.

**`ImportNotFoundError`**: An `@`-import references a file or glob that matches nothing. Cell can't assemble its prompt. User fixes the path or creates the file.

**`InlineCommandError`**: A `` !`command` `` inline exited non-zero. Includes the command, exit code, and stderr. User fixes the command or the underlying issue.

**`VcsCommitError`**: Commit failed (e.g., nothing to commit, merge conflict, permissions). Includes stderr from git/jj.

**`DriftDetectedError`**: Files on disk were modified outside of Drift after the last build. Not a hard failure — surfaces as a "drifted" indicator in the UI. User can re-build to reconcile or commit to accept manual changes.

### Error Recovery

Errors are surfaced in the UI per-cell (state badge turns 🔴, error details expandable). In the CLI, errors print with full context and a suggested action. All errors carry enough structured data for programmatic handling — e.g., a future auto-retry layer could match on `DiffApplyError` and re-run with a fresh file read.

## Code Quality Guardrails

Drift uses two layers of enforcement to prevent code slop: a `CLAUDE.md` file for agent instructions and `ast-grep` rules for automated linting. Both are checked before any PR or commit.

### CLAUDE.md

Lives at the project root. Every agent call (build or plan) includes this as system context. This is the source of truth for coding conventions.

```markdown
# CLAUDE.md

## Stack
- Runtime: Bun
- Language: TypeScript (strict, ESM only)
- Core: Effect ecosystem (`effect`, `@effect/schema`, `@effect/platform`)
- Frontend: SvelteKit with Svelte 5 runes
- No default exports except Svelte components

## Effect Patterns

### Always
- `Effect.gen(function*() { ... })` for effectful code — generator syntax, not pipe chains
- `yield*` inside generators, never `await`
- Tagged errors via `Data.TaggedError` for all failure cases — no string errors
- `Schema.Struct`, `Schema.Literal`, etc. for all data shapes — no hand-written interfaces for data
- `Schema.decode` / `Schema.encode` for all parsing — no manual validation
- `Effect.tryPromise` to wrap unavoidable Promise-based APIs (e.g. fetch)
- Services via `Context.Tag` + `Layer` — no module-level singletons
- `readonly` on arrays, records, and fields by default
- `Effect.acquireRelease` for resource management (file handles, subprocesses)

### Never
- `Promise` or `async/await` — wrap in Effect
- `try/catch` — use `Effect.catchTag` or `Effect.catchAll`
- `throw` — use `Effect.fail(new SomeTaggedError({ ... }))`
- `any` type — use `unknown` and decode through Schema
- `as` type assertions — decode or refine instead
- `enum` — use `Schema.Literal` or `as const` satisfies
- `namespace` or `require()`
- `console.log` — use `Effect.log` / `Effect.logDebug`

### Patterns

```typescript
// YES: tagged error + generator
class FileNotFound extends Data.TaggedError("FileNotFound")<{
  readonly path: string
}> {}

const readCell = (index: number) =>
  Effect.gen(function*() {
    const fs = yield* FileSystem
    const content = yield* fs.readFileString(`cells/${index}/v1.md`).pipe(
      Effect.mapError(() => new FileNotFound({ path: `cells/${index}/v1.md` }))
    )
    return yield* Schema.decodeUnknown(Cell)(JSON.parse(content))
  })

// NO: promise, try/catch, any
async function readCell(index: number): Promise<any> {
  try {
    const content = await fs.readFile(...)
    return JSON.parse(content)
  } catch (e) {
    throw new Error("not found")
  }
}
```

## Svelte 5 Patterns

### Always
- `$state()` for reactive state
- `$derived()` for computed values
- `$effect()` for side effects
- `$props()` for component props
- `{#snippet}` blocks for reusable template fragments
- `<Component {prop}>` shorthand when prop name matches

### Never
- `let x = writable()` / stores — runes replaced them
- `$:` reactive statements — use `$derived()` or `$effect()`
- `export let` for props — use `$props()`
- `<slot>` — use `{#snippet}` and `{@render}`
- `onMount` / `onDestroy` — use `$effect()` with cleanup return
- `createEventDispatcher` — use callback props

### Patterns

```svelte
<!-- YES: runes -->
<script lang="ts">
  let { cell, onBuild }: { cell: Cell; onBuild: (index: number) => void } = $props()

  let tokens = $state<string[]>([])
  let summary = $derived(tokens.join(""))

  $effect(() => {
    const ws = new WebSocket(...)
    ws.onmessage = (e) => tokens.push(e.data)
    return () => ws.close()
  })
</script>

<!-- NO: stores, $:, export let, onMount -->
<script lang="ts">
  import { writable } from "svelte/store"
  import { onMount } from "svelte"
  export let cell: Cell

  const tokens = writable<string[]>([])
  $: summary = $tokens.join("")

  onMount(() => { ... })
</script>
```

## General
- Named exports only (except `.svelte` components)
- `import type` for type-only imports
- Prefer `const` over `let`; never `var`
- Exhaustive switch via `never` in default
- File naming: `kebab-case.ts`, `PascalCase.svelte`
```

### ast-grep Rules

`ast-grep` rules in `.ast-grep/rules/` enforce the CLAUDE.md conventions at lint time. Run via `ast-grep scan` in CI and pre-commit.

#### Effect Rules

```yaml
# .ast-grep/rules/no-try-catch.yaml
id: no-try-catch
language: typescript
message: "Use Effect.tryPromise or Effect.catchTag instead of try/catch"
severity: error
rule:
  kind: try_statement

# .ast-grep/rules/no-throw.yaml
id: no-throw
language: typescript
message: "Use Effect.fail(new TaggedError(...)) instead of throw"
severity: error
rule:
  kind: throw_statement

# .ast-grep/rules/no-async-await.yaml
id: no-async-await
language: typescript
message: "Use Effect.gen(function*() { }) with yield* instead of async/await"
severity: error
rule:
  kind: function_declaration
  has:
    kind: async
    # Exceptions: test files, scripts
    not:
      inside:
        kind: call_expression
        has:
          field: function
          regex: "describe|it|test"

# .ast-grep/rules/no-promise-type.yaml
id: no-promise-type
language: typescript
message: "Use Effect.Effect<A, E, R> instead of Promise<T>"
severity: warning
rule:
  kind: type_reference
  has:
    kind: type_identifier
    regex: "^Promise$"

# .ast-grep/rules/no-console-log.yaml
id: no-console-log
language: typescript
message: "Use Effect.log / Effect.logDebug instead of console.log"
severity: warning
rule:
  kind: call_expression
  pattern: "console.$METHOD($$$ARGS)"
  constraints:
    METHOD:
      regex: "^(log|warn|error|info|debug)$"

# .ast-grep/rules/no-any.yaml
id: no-any
language: typescript
message: "Use unknown and decode through Schema instead of any"
severity: error
rule:
  kind: predefined_type
  regex: "^any$"

# .ast-grep/rules/no-enum.yaml
id: no-enum
language: typescript
message: "Use Schema.Literal or as const satisfies instead of enum"
severity: error
rule:
  kind: enum_declaration

# .ast-grep/rules/no-type-assertion.yaml
id: no-type-assertion
language: typescript
message: "Decode or refine through Schema instead of using 'as' type assertion"
severity: warning
rule:
  kind: as_expression
  not:
    has:
      kind: type_reference
      regex: "^const$"
```

#### Svelte 5 Rules

```yaml
# .ast-grep/rules/no-svelte-stores.yaml
id: no-svelte-stores
language: typescript
message: "Use $state() rune instead of writable/readable/derived stores"
severity: error
rule:
  kind: import_specifier
  regex: "^(writable|readable|derived)$"
  inside:
    kind: import_statement
    has:
      kind: string
      regex: "svelte/store"

# .ast-grep/rules/no-create-event-dispatcher.yaml
id: no-create-event-dispatcher
language: typescript
message: "Use callback props instead of createEventDispatcher"
severity: error
rule:
  kind: call_expression
  pattern: "createEventDispatcher($$$)"

# .ast-grep/rules/no-on-mount.yaml
id: no-on-mount
language: typescript
message: "Use $effect() with cleanup return instead of onMount/onDestroy"
severity: warning
rule:
  kind: import_specifier
  regex: "^(onMount|onDestroy)$"
  inside:
    kind: import_statement
    has:
      kind: string
      regex: "^svelte$"
```

#### General TypeScript Rules

```yaml
# .ast-grep/rules/no-default-export.yaml
id: no-default-export
language: typescript
message: "Use named exports. Default exports only in .svelte files."
severity: warning
rule:
  kind: export_statement
  has:
    kind: default

# .ast-grep/rules/no-var.yaml
id: no-var
language: typescript
message: "Use const or let instead of var"
severity: error
rule:
  kind: variable_declaration
  has:
    kind: var

# .ast-grep/rules/no-require.yaml
id: no-require
language: typescript
message: "Use ESM import instead of require()"
severity: error
rule:
  kind: call_expression
  pattern: "require($$$)"
```

### Pre-commit Hook

```bash
#!/bin/sh
# .githooks/pre-commit
ast-grep scan --rule .ast-grep/rules/ src/
if [ $? -ne 0 ]; then
  echo "ast-grep lint failed. Fix violations before committing."
  exit 1
fi
```

These rules catch ~90% of the common Effect/Svelte anti-patterns at parse time. The remaining 10% (e.g., verifying `Context.Tag` usage, ensuring `Schema.decode` over `JSON.parse`) requires type-aware analysis and is caught in code review or by the review pass agent.

## Future Considerations

Out of scope for v1:

- **Pinning**: Freeze a cell so it never re-evaluates.
- **Branching**: Fork the DAG to explore alternatives.
- **Test execution**: Run tests after applying a diff, show results inline.
- **Collaborative editing**: Multiple users on the same spec.