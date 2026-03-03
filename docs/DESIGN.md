---
drift:
  files:
    - src/main.zig@vwznuuvt
    - src/frontmatter.zig@vwznuuvt
    - src/scanner.zig@vwznuuvt
    - src/symbols.zig@vwznuuvt
    - src/vcs.zig@vwznuuvt
---

# Design

## Problem

Specs and code drift apart. Documentation describes intent, code implements it, and over time the two diverge silently. In agent-driven workflows this is acute: agents change code without updating specs, and stale specs produce stale prompts that produce wrong code.

## Solution

drift makes the anchor between specs and code explicit and enforceable. Any markdown file can declare which code it governs. When that code changes, `drift lint` flags the spec as stale. The lint runs as a CI gate or pre-commit hook — agents that change code must update the specs they affect.

## Data Model

### Spec

A spec is any markdown file with a `drift:` key in its YAML frontmatter. Specs can live anywhere in the repo. drift discovers them by scanning for the frontmatter marker.

```markdown
---
drift:
  files:
    - src/auth/login.ts@qpvuntsm
    - src/auth/provider.ts#AuthConfig@qpvuntsm
---

# Auth Architecture

The login flow uses @./src/auth/provider.ts#AuthConfig@qpvuntsm for token validation.

<!-- depends: docs/project.md -->
```

### Anchors

An anchor is a declared relationship between a spec and a code artifact. Two sources:

**Explicit anchors** — listed in `drift.files` frontmatter. Can be file-level (`src/auth/login.ts`) or symbol-level (`src/auth/provider.ts#AuthConfig`).

**Implicit anchors** — `@./path` and `@./path#Symbol` references in the spec body. Parsed from content, treated identically to explicit anchors for staleness detection.

Each anchor can optionally carry provenance — a VCS reference (git SHA or jj change ID) recording which change last addressed this anchor. The syntax is `path@change`:

- `src/auth/login.ts` — bound file, no provenance yet
- `src/auth/login.ts@qpvuntsm` — bound file with provenance at change qpvuntsm
- `src/auth/provider.ts#AuthConfig@qpvuntsm` — symbol anchor with provenance
- In inline references: `@./src/auth/login.ts@qpvuntsm`

The `@change` suffix is optional. Bare paths still work. Different anchors can have different provenance since each file tracks its own change independently. There is no separate `changes:` list.

In jj, change IDs are stable across rewrites. In git, SHAs may become unreachable after rebase, but staleness detection is VCS-history-based, not SHA-based, so this doesn't affect correctness.

### Symbol-Level Anchors

An anchor like `src/auth/provider.ts#AuthConfig` resolves to a specific AST symbol rather than the whole file. drift parses the file with tree-sitter, finds the symbol's declaration, and hashes its content. Changes elsewhere in the file don't trigger staleness.

Resolution uses tree-sitter `.scm` queries per language. A simple query finds named declarations:

```scheme
[
  (function_declaration name: (identifier) @name)
  (class_declaration name: (type_identifier) @name)
  (type_alias_declaration name: (type_identifier) @name)
  (interface_declaration name: (type_identifier) @name)
  (lexical_declaration (variable_declarator name: (identifier) @name))
] @definition
```

Filter captures where `@name` matches the target symbol. Extract `@definition` node text. Hash it.

If the symbol is not found, the anchor is reported as STALE with reason "symbol not found".

### Dependencies

Specs can depend on other specs via `<!-- depends: path/to/other.md -->` comments. This declares that one spec builds on another's context. Dependencies are used for DAG ordering when composing prompts (future), not for staleness detection.

## Staleness Detection

For each spec, drift determines staleness by comparing VCS history. Provenance is per-anchor: each anchor's `@change` suffix records the last change where that anchor was addressed.

1. For each anchor, determine its baseline — the anchor's provenance change if present, otherwise the last commit that modified the spec file
2. Check the anchor against its baseline:
   - **File-level**: was this file modified in any commit after the baseline?
   - **Symbol-level**: parse the file, hash the symbol content, compare against the hash at the baseline
3. If any anchor has changed after its baseline, the spec is stale

The VCS query is:
```
git log <baseline>..HEAD -- <bound-file>
```

In jj:
```
jj log -r '<baseline>..@' --no-graph -T 'change_id' -- <bound-file>
```

Because provenance is per-anchor, updating one anchor's change reference doesn't affect staleness detection for other anchors in the same spec. A spec with three anchors can have two fresh and one stale.

### Blame Enrichment

When a spec is stale, the lint output includes who changed the bound code:

```
docs/auth.md
  STALE  src/auth/provider.ts#AuthConfig
         changed by mike in e4f8a2c (Mar 15)
         "refactor: split auth config into separate concerns"
```

This is a free byproduct of the VCS query — `git log` gives author and message.

### Missing Anchors

If a file anchor can't be resolved (file doesn't exist), it's reported as STALE with reason "file not found":

```
docs/auth.md
  STALE   src/core/old-module.ts
          file not found
```

If a symbol anchor can't be resolved (symbol not found in file), it's reported as STALE with reason "symbol not found":

```
docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig
          symbol not found
```

## Architecture

```
                    ┌─────────────┐
                    │  drift lint  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌────────────┐ ┌──────────┐ ┌─────────┐
        │ scanner.zig│ │symbols.zig│ │ vcs.zig │
        │            │ │          │ │         │
        │ find spec  │ │ parse    │ │ git log │
        │ files,     │ │ bound    │ │ jj log  │
        │ extract    │ │ files,   │ │ blame   │
        │ anchors    │ │ hash     │ │         │
        │            │ │ symbols  │ │         │
        └────────────┘ └──────────┘ └─────────┘
              │            │            │
              │       tree-sitter       │
              │       (on demand)       │
              └────────────┬────────────┘
                           ▼
                    ┌─────────────┐
                    │   main.zig  │
                    │  ok / stale │
                    └─────────────┘
```

Additional modules:
- `frontmatter.zig` — YAML frontmatter parsing and editing
- `main.zig` — CLI entry point, command dispatch, report formatting

### scanner.zig

Walks the repo looking for markdown files with `drift:` frontmatter. Parses frontmatter to extract explicit anchors. Parses content to extract implicit anchors (`@` references). No index — scans on every run. Performance is bounded by the number of markdown files, not the size of the codebase.

### symbols.zig

For each anchor, resolves the current state:

- **File-level**: stat the file, hash its content
- **Symbol-level**: parse with tree-sitter, find the symbol via `.scm` query, hash the symbol's content

Parsing is on-demand. Only files that are actually bound get parsed. A lint run that checks 10 specs anchoring to 30 symbols across 20 files does 20 tree-sitter parses — milliseconds.

### vcs.zig

Shells out to git or jj. Auto-detected from `.jj` (preferred) or `.git` directory. Operations:

- `log`: find commits that modified a file after a given point
- `blame`: get author/message for a commit
- `rev-parse` / equivalent: resolve refs

No libgit2, no jj library. Subprocess cost is negligible for the number of queries drift makes.

## On-Disk Format

drift requires minimal on-disk state:

```
.drift/
  config.yaml       # optional project-level settings
```

Specs live anywhere in the repo — they're just markdown files. The `.drift/` directory exists only for optional configuration (scan globs, VCS backend override, etc.).

```yaml
# .drift/config.yaml (optional)
scan:
  include:
    - "docs/**/*.md"
    - "*.md"
  exclude:
    - "node_modules/**"
    - "vendor/**"
vcs: auto    # auto | git | jj
```

If no config exists, drift scans all `*.md` and `**/*.md` files and auto-detects the VCS.
