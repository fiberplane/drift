# Design

## Problem

Specs and code drift apart. Documentation describes intent, code implements it, and over time the two diverge silently. In agent-driven workflows this is acute: agents change code without updating specs, and stale specs produce stale prompts that produce wrong code.

## Solution

drift makes the anchor between specs and code explicit and enforceable. Any markdown file can declare which code it governs. When that code changes, `drift lint` flags the spec as stale. The lint runs as a CI gate or pre-commit hook — agents that change code must update the specs they affect.

## Data Model

### Spec

A spec is any markdown file with entries in `drift.lock`. Specs are pure markdown — no frontmatter, no HTML comments, no inline markers. A file becomes a drift spec by having at least one binding in the lockfile.

```markdown
# Auth Architecture

The login flow uses AuthConfig for token validation.
Provider selection happens at startup based on environment.

<!-- depends: docs/project.md -->
```

The spec itself contains no drift metadata. All bindings between specs and code live in `drift.lock` at the repo root.

### Anchors

An anchor is a declared relationship between a spec and a code artifact. Anchors are stored as lines in `drift.lock`, not in the spec files.

```
docs/auth.md -> src/auth/login.ts sig:e4f8a2c10b3d7890
docs/auth.md -> src/auth/provider.ts#AuthConfig sig:1a2b3c4d5e6f7890
```

Each line is a binding: a spec path, an arrow separator, a target path (optionally with `#Symbol`), and trailing key:value metadata. The `sig:` field records a content signature — a normalized fingerprint of the target at the time the anchor was last verified.

Anchors can be file-level (`src/auth/login.ts`) or symbol-level (`src/auth/provider.ts#AuthConfig`). Bare targets without a `sig:` field are valid — they declare a binding without provenance.

`drift link` produces `sig:` provenance by default. Content signatures are VCS-independent — they encode a fingerprint of the code itself, so staleness detection works without querying git history.

### Origin-Qualified Anchors

An anchor can carry an `origin:` field to declare which repository it belongs to:

```
docs/auth.md -> src/auth/login.ts sig:e4f8a2c10b3d7890 origin:github:fiberplane/drift
```

When `drift lint` runs, it resolves the current repo's identity from `git remote get-url origin` and normalizes it to `github:owner/repo` format. If an anchor's `origin:` doesn't match the current repo, it is reported as `SKIP` — it belongs to a different repository and can't be checked locally.

This lets specs travel across repo boundaries (vendored docs, shared skill files, monorepo imports) without producing false STALE reports. Anchors without an `origin:` field are always checked — origin qualification is opt-in.

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

Provenance is per-anchor: each anchor's `sig:` field in the lockfile records when the anchor was last verified.

### Content signatures (`sig:`) — primary format

`drift link` computes a normalized syntax fingerprint of each anchor's target and stores it as a 16-character hex string in the lockfile: `docs/auth.md -> src/auth/login.ts sig:a1b2c3d4e5f6a7b8`. At lint time, drift recomputes the fingerprint from the current file on disk and compares it to the stored value. If they match the anchor is fresh; if they differ it is stale.

Content signatures are VCS-independent — they work in fresh clones, shallow clones, and detached-HEAD states without querying git history. For supported tree-sitter languages, the fingerprint is based on the normalized syntax tree so formatting-only changes do not trigger staleness.

### Detection algorithm

1. Read `drift.lock` to get all bindings
2. For each anchor, extract its `sig:` value
3. Recompute the fingerprint from the current file on disk
4. Compare — if they differ, the anchor is stale
5. If no `sig:` field — the anchor has no provenance, report as stale

File reads are cached per lint run (`FileCache` in `main.zig`). When multiple anchors reference the same file, the content is read once.

Because provenance is per-anchor, updating one anchor's signature doesn't affect staleness detection for other anchors in the same spec. A spec with three anchors can have two fresh and one stale.

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
           ┌───────┬───────┼───────┬───────┬────────┐
           ▼       ▼       ▼       ▼       ▼        ▼
        lint.zig status  link   unlink   refs    (commands/)
                  .zig   .zig    .zig    .zig
           │
           ├───────────────┼────────────┐
           ▼               ▼            ▼
     ┌────────────┐  ┌──────────┐ ┌─────────┐
     │lockfile.zig│  │symbols.zig│ │ vcs.zig │
     │            │  │          │ │         │
     │ read/write │  │ parse    │ │ git log │
     │ drift.lock │  │ bound    │ │ jj log  │
     │ bindings   │  │ files,   │ │ blame   │
     │            │  │ hash     │ │ cat-file│
     │            │  │ symbols  │ │         │
     └────────────┘  └──────────┘ └─────────┘
           │              │            │
           │         tree-sitter       │
           │         (on demand)       │
           └──────────────┬────────────┘
```

Additional modules:
- `lockfile.zig` — read, write, and query `drift.lock` bindings; line-oriented parser and serializer
- `frontmatter.zig` — legacy migration only: strips old YAML frontmatter and `<!-- drift: ... -->` comment blocks during `drift link`
- `markdown.zig` — markdown-aware utilities: fenced code / inline code detection, frontmatter boundary parsing
- `main.zig` — CLI entry point, argument parsing, subcommand dispatch
- `commands/lint.zig` — lint engine: file/content caching, anchor staleness checks, report formatting
- `commands/status.zig` — spec listing in text and JSON formats
- `commands/link.zig` — anchor linking with auto-provenance (content signatures)
- `commands/unlink.zig` — anchor removal from lockfile
- `commands/refs.zig` — reverse lookup: which specs reference a given target

### lockfile.zig

Reads and writes `drift.lock`. The file is line-oriented: each non-blank, non-comment line is a binding in the format `<spec> -> <target> <key:value>...`. Parsing is two splits: `splitSequence(" -> ")` for the spec/rest boundary, then `splitScalar(' ')` for target and trailing key:value pairs. Writing sorts all lines lexically and appends a trailing newline.

Discovery: walks up from cwd checking for `drift.lock` at each directory. The lockfile's directory becomes the project root for resolving relative paths.

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

### drift.lock

The lockfile is a flat, line-oriented file at the repo root. Every binding between a spec and a code target is one line.

```
# drift.lock — managed by drift, do not edit manually
docs/auth.md -> src/auth/login.ts sig:e4f8a2c10b3d7890
docs/auth.md -> src/auth/provider.ts#AuthConfig sig:1a2b3c4d5e6f7890 origin:github:fiberplane/drift
docs/payments.md -> src/payments/stripe.ts sig:9a8b7c6d5e4f3210
```

Format rules:
- One binding per line: `<spec> -> <target> <key:value>...`
- Sorted lexically by full line content
- Trailing key:value pairs for extensible metadata (`sig:`, `origin:`, future fields)
- Lines starting with `#` are comments, blank lines ignored
- Discovery: walk up from cwd until `drift.lock` is found

### .drift/config.yaml

Optional project-level settings. The `.drift/` directory exists only for configuration (scan globs, VCS backend override, etc.).

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
