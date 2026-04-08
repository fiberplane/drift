---
drift:
  files:
    - src/main.zig@sig:3560999bb08f8512
    - src/frontmatter.zig@sig:ef9880e4f1a96c16
    - src/scanner.zig@sig:9ccfb8091a6c8ef2
    - src/symbols.zig@sig:1f41e745e5e32c2d
    - src/vcs.zig@sig:b9481e9cf295501a
---

# Design

## Problem

Specs and code drift apart. Documentation describes intent, code implements it, and over time the two diverge silently. In agent-driven workflows this is acute: agents change code without updating specs, and stale specs produce stale prompts that produce wrong code.

## Solution

drift makes the anchor between specs and code explicit and enforceable. Any markdown file can declare which code it governs. When that code changes, `drift lint` flags the spec as stale. The lint runs as a CI gate or pre-commit hook — agents that change code must update the specs they affect.

## Data Model

### Spec

A spec is any markdown file with drift anchors. Anchors can live in YAML frontmatter or in `<!-- drift: ... -->` HTML comments (useful when you don't want frontmatter visible on GitHub). drift discovers specs by scanning all git-tracked markdown files for either marker.

```markdown
---
drift:
  files:
    - src/auth/login.ts@sig:e4f8a2c10b3d7890
    - src/auth/provider.ts#AuthConfig@sig:1a2b3c4d5e6f7890
---

# Auth Architecture

The login flow uses @./src/auth/provider.ts#AuthConfig@sig:1a2b3c4d5e6f7890 for token validation.

<!-- depends: docs/project.md -->
```

Or equivalently with HTML comments (no frontmatter needed):

```markdown
# Auth Architecture

<!-- drift:
  files:
    - src/auth/login.ts@sig:e4f8a2c10b3d7890
    - src/auth/provider.ts#AuthConfig@sig:1a2b3c4d5e6f7890
-->

The login flow uses @./src/auth/provider.ts#AuthConfig@sig:1a2b3c4d5e6f7890 for token validation.
```

A spec can use both — `parseDriftSpec` merges anchors from frontmatter, HTML comments, and inline `@./` references into a single anchor list.

### Anchors

An anchor is a declared relationship between a spec and a code artifact. Two sources:

**Explicit anchors** — listed in `drift.files` frontmatter. Can be file-level (`src/auth/login.ts`) or symbol-level (`src/auth/provider.ts#AuthConfig`).

**Implicit anchors** — `@./path` and `@./path#Symbol` references in the spec body. Parsed from content, treated identically to explicit anchors for staleness detection.

Each anchor can optionally carry provenance — a content signature or VCS reference recording when the anchor was last verified. The syntax is `path@provenance`:

- `src/auth/login.ts` — bound file, no provenance yet
- `src/auth/login.ts@sig:a1b2c3d4e5f6a7b8` — bound file with content signature
- `src/auth/provider.ts#AuthConfig@sig:a1b2c3d4e5f6a7b8` — symbol anchor with content signature
- `src/auth/login.ts@2d3a4080` — legacy format: bound file with VCS SHA provenance
- In inline references: `@./src/auth/login.ts@sig:a1b2c3d4e5f6a7b8`
- In HTML comments: `<!-- drift: files: - src/auth/login.ts@sig:... -->`

The `@provenance` suffix is optional. Bare paths still work. Different anchors can have different provenance since each file tracks its own change independently. There is no separate `changes:` list.

`drift link` produces `@sig:` provenance by default. Content signatures are VCS-independent — they encode a fingerprint of the code itself, so staleness detection works without querying git history. Legacy `@<sha>` provenance is still supported for backward compatibility.

### Origin-Qualified Anchors

A spec can declare its origin repository via `origin: github:owner/repo` in the `drift:` section. When `drift lint` runs, it resolves the current repo's identity from `git remote get-url origin` and normalizes it to the same `github:owner/repo` format. If a spec's origin doesn't match the current repo, all its anchors are reported as `SKIP` — they belong to a different repository and can't be checked locally.

This lets specs travel across repo boundaries (vendored docs, shared skill files, monorepo imports) without producing false STALE reports. Specs without an `origin:` field are always checked — origin qualification is opt-in.

### Symbol-Level Anchors

An anchor like `src/auth/provider.ts#AuthConfig` resolves to a specific AST symbol rather than the whole file. drift parses the file with tree-sitter, finds the symbol's declaration, and hashes a normalized representation of that subtree. Changes elsewhere in the file don't trigger staleness, and formatting-only changes inside the symbol are ignored.

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

Filter captures where `@name` matches the target symbol. Extract the `@definition` subtree and hash a normalized traversal of it (node kinds, structure, and token text; no layout/position data).

If the symbol is not found, the anchor is reported as STALE with reason "symbol not found".

### Dependencies

Specs can depend on other specs via `<!-- depends: path/to/other.md -->` comments. This declares that one spec builds on another's context. Dependencies are used for DAG ordering when composing prompts (future), not for staleness detection.

## Staleness Detection

Provenance is per-anchor: each anchor's `@` suffix records when the anchor was last verified.

### Content signatures (`@sig:`) — primary format

`drift link` computes a normalized syntax fingerprint of each anchor's target and stores it as a 16-character hex string: `src/auth/login.ts@sig:a1b2c3d4e5f6a7b8`. At lint time, drift recomputes the fingerprint from the current file on disk and compares it to the stored value. If they match the anchor is fresh; if they differ it is stale.

Content signatures are VCS-independent — they work in fresh clones, shallow clones, and detached-HEAD states without querying git history. For supported tree-sitter languages, the fingerprint is based on the normalized syntax tree so formatting-only changes do not trigger staleness.

### VCS SHAs (`@<sha>`) — legacy format

Anchors with a plain git SHA or jj change ID as provenance (e.g. `src/auth/login.ts@2d3a4080`) use VCS-history-based comparison: drift retrieves the file at the baseline revision and compares its fingerprint against the current content. This format still works but `drift link` now produces `@sig:` provenance by default.

### Detection algorithm

1. For each anchor, determine its baseline provenance
2. If provenance starts with `sig:` — recompute the fingerprint from disk and compare against the stored hex
3. If provenance is a VCS ref — retrieve historical content via `git cat-file --batch`, compute fingerprints of both versions, compare
4. If no provenance — fall back to the last commit that modified the spec file
5. If any anchor has changed after its baseline, the spec is stale

File reads and historical content fetches are cached per lint run (`FileCache` in `main.zig`). When multiple anchors reference the same file or revision, the content is read once.

Because provenance is per-anchor, updating one anchor's change reference doesn't affect staleness detection for other anchors in the same spec. A spec with three anchors can have two fresh and one stale.

### Blame Enrichment

When a spec is stale, the lint output includes who changed the bound code:

```
docs/auth.md
  STALE  src/auth/provider.ts#AuthConfig
         changed by mike in e4f8a2c (Mar 15)
         "refactor: split auth config into separate concerns"
```

Text mode prints the **author** name, an abbreviated commit id, the **committer** date (for the timestamp line), and the subject — sourced from `git log` / blame queries on the revision that last touched the anchor.

With `--format json`, the stable `drift.check.v1` document carries the same fields in structured form: `blame.author`, full `blame.commit`, `blame.date`, and `blame.subject`. The `date` field is the **committer** date in ISO 8601 strict form (`git --date=iso-strict`), so it stays comparable and sortable after rebases or cherry-picks (author date can differ). See [`check-json-schema.md`](./check-json-schema.md) for the full schema and summary fields such as `verification_state`.

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
                    │   main.zig  │  CLI entry, arg parsing, dispatch
                    └──────┬──────┘
                           │
           ┌───────┬───────┼───────┬────────┐
           ▼       ▼       ▼       ▼        ▼
        lint.zig status  link   unlink   (commands/)
                  .zig   .zig    .zig
           │
           ├───────────────┼────────────┐
           ▼               ▼            ▼
     ┌────────────┐  ┌──────────┐ ┌─────────┐
     │ scanner.zig│  │symbols.zig│ │ vcs.zig │
     │            │  │          │ │         │
     │ find spec  │  │ parse    │ │ git log │
     │ files,     │  │ bound    │ │ jj log  │
     │ extract    │  │ files,   │ │ blame   │
     │ anchors    │  │ hash     │ │ cat-file│
     │            │  │ symbols  │ │         │
     └────────────┘  └──────────┘ └─────────┘
           │              │            │
           │         tree-sitter       │
           │         (on demand)       │
           └──────────────┬────────────┘
```

Additional modules:
- `frontmatter.zig` — YAML frontmatter and `<!-- drift: ... -->` comment parsing and editing
- `markdown.zig` — markdown-aware utilities: fenced code / inline code detection, frontmatter boundary parsing, drift comment marker search
- `main.zig` — CLI entry point, argument parsing, subcommand dispatch
- `commands/lint.zig` — lint engine: file/content caching, anchor staleness checks, report formatting
- `commands/status.zig` — spec listing in text and JSON formats
- `commands/link.zig` — anchor linking with auto-provenance (content signatures, VCS fallback)
- `commands/unlink.zig` — anchor removal from frontmatter and comment blocks

### scanner.zig

Lists git-tracked markdown files via `git ls-files -z` (NUL-terminated output for robust handling of unusual paths), respecting `.gitignore`. Filters `.md` in-process rather than using pathspec globs. Parses frontmatter and `<!-- drift: ... -->` comments to extract explicit anchors. Parses content to extract inline anchors (`@./` references), merging them with explicit anchors while deduplicating. No index — scans on every run. Performance is bounded by the number of markdown files, not the size of the codebase.

### symbols.zig

For each anchor, resolves the current state:

- **File-level**: stat the file, hash its content
- **Symbol-level**: parse with tree-sitter, find the symbol via `.scm` query, hash a normalized syntax fingerprint of the symbol

Parsing is on-demand. Only files that are actually bound get parsed. A lint run that checks 10 specs anchoring to 30 symbols across 20 files does 20 tree-sitter parses — milliseconds.

### vcs.zig

Shells out to git or jj. Auto-detected from `.jj` (preferred) or `.git` directory. Operations:

- `log`: find commits that modified a file after a given point
- `blame`: get author/message for a commit
- `rev-parse` / equivalent: resolve refs
- `cat-file --batch`: persistent subprocess (`GitCatFile`) for fetching historical file content without spawning a new process per anchor

No libgit2, no jj library. `GitCatFile` keeps a single `git cat-file --batch` process alive for the duration of a lint run, feeding `rev:path` queries via stdin and reading blob content from stdout. All other VCS queries are one-shot subprocesses — the per-query cost is negligible for the number of queries drift makes.

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
