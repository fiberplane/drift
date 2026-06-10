# Design

## Problem

Docs and code drift apart. Documentation describes intent, code implements it, and over time the two diverge silently. In agent-driven workflows this is acute: agents change code without updating docs, and stale docs produce stale prompts that produce wrong code.

## Solution

drift makes the anchor between docs and code explicit and enforceable. Any markdown file can declare which code it governs. When that code changes, `drift lint` flags the doc as stale. The lint runs as a CI gate or pre-commit hook — agents that change code must update the docs they affect.

## Data Model

### Doc

A doc is any markdown file with entries in `drift.lock`. Docs are pure markdown — no frontmatter, no HTML comments, no inline markers. A file becomes a drift doc by having at least one binding in the lockfile. All bindings between docs and code live in `drift.lock` at the repo root.

During `drift lint`, each doc is also parsed to extract markdown links. Any relative link pointing to a nonexistent file is reported as `BROKEN` — this requires no lockfile entry.

### Anchors

An anchor is a declared relationship between a doc and a code artifact. Anchors are stored as TOML `[[bindings]]` tables in `drift.lock`, not in the doc files.

```toml
version = 1

[[bindings]]
doc = "docs/auth.md"
target = "src/auth/login.ts"
sig = "e4f8a2c10b3d7890"

[[bindings]]
doc = "docs/auth.md"
target = "src/auth/provider.ts#AuthConfig"
sig = "1a2b3c4d5e6f7890"
```

Each table is a binding: a doc path, a target path (optionally with `#Symbol`), and metadata fields. The `sig` field records a content signature — a normalized fingerprint of the target at the time the anchor was last verified.

Anchors can be file-level (`src/auth/login.ts`) or symbol-level (`src/auth/provider.ts#AuthConfig`). Bare targets without a `sig` field are valid — they declare a binding without provenance.

`drift link` produces `sig` provenance by default. Content signatures are VCS-independent — they encode a fingerprint of the code itself, so staleness detection works without querying git history.

### Origin-Qualified Anchors

An anchor can carry an `origin` field to declare which repository it belongs to:

```toml
version = 1

[[bindings]]
doc = "docs/auth.md"
target = "src/auth/login.ts"
origin = "github:fiberplane/drift"
sig = "e4f8a2c10b3d7890"
```

When `drift lint` runs, it resolves the current repo's identity from `git remote get-url origin` and normalizes it to `github:owner/repo` format. If an anchor's `origin` doesn't match the current repo, it is reported as `SKIP` — it belongs to a different repository and can't be checked locally.

This lets docs travel across repo boundaries (vendored docs, shared skill files, monorepo imports) without producing false STALE reports. Anchors without an `origin` field are always checked — origin qualification is opt-in.

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

Doc-to-doc anchors work the same way. A heading in a markdown file is structurally equivalent to a named symbol. `docs/overview.md -> docs/auth.md#Authentication` resolves `Authentication` as a heading in `docs/auth.md`, and fingerprints the section content (heading + body until the next heading at the same or higher level). Tree-sitter markdown's `section` node provides this grouping natively — an H2 section nests inside an H1 section, and the section node spans from the heading to the start of the next sibling heading.

### Markdown Links

drift checks all markdown links in drift-managed docs for existence. During `drift lint`, each doc is parsed with tree-sitter markdown (block + inline grammars) to extract `[text](target)` links. If the target is a relative path to a file that doesn't exist, the link is reported as `BROKEN`.

This is separate from lockfile anchors — no binding in `drift.lock` is needed. Any markdown link to a relative file path is checked. Links to URLs, fragments-only (`#heading`), and absolute paths are ignored.

```
docs/auth.md
  BROKEN  docs/old-guide.md (link target not found)
```

Broken link detection uses the same tree-sitter parse that doc-to-doc anchor resolution uses. A doc is parsed once; links are extracted from `inline_link` nodes in the inline grammar pass.

## Staleness Detection

Provenance is per-anchor: each anchor's `sig` field in the lockfile records when the anchor was last verified.

### Content signatures (`sig`) — primary format

`drift link` computes a normalized syntax fingerprint of each anchor's target and stores it as a 16-character hex string in the lockfile's `sig` field. At lint time, drift recomputes the fingerprint from the current file on disk and compares it to the stored value. If they match the anchor is fresh; if they differ it is stale.

Content signatures are VCS-independent — they work in fresh clones, shallow clones, and detached-HEAD states without querying git history. For supported tree-sitter languages, the fingerprint is based on the normalized syntax tree so formatting-only changes do not trigger staleness.

### Detection algorithm

1. Read `drift.lock` to get all bindings
2. For each anchor, extract its `sig` value
3. Recompute the fingerprint from the current file on disk
4. Compare — if they differ, the anchor is stale
5. If no `sig` field — the anchor has no provenance, report as stale

File reads are cached per lint run (`FileCache` in `main.zig`). When multiple anchors reference the same file, the content is read once.

Because provenance is per-anchor, updating one anchor's signature doesn't affect staleness detection for other anchors in the same doc. A doc with three anchors can have two fresh and one stale.

### Blame Enrichment

When a doc is stale, the lint output includes who changed the bound code:

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

### Memory model

Every command creates two arena allocators backed by the GPA in `main()`. The **run arena** owns command-lifetime data (lockfile, file cache, result model). The **scratch arena** owns per-item temporaries (path resolution, subprocess output) and is reset between loop iterations. Fixed-width formatting uses stack buffers. Only OS/C resources (child processes, tree-sitter parsers) need explicit `deinit()`. See Decision 12 in `DECISIONS.md` for the full ruleset.

Additional modules:
- `lockfile.zig` — read, write, and query `drift.lock` bindings; TOML parser and serializer
- `markdown.zig` — markdown parsing via tree-sitter (block + inline grammars): link extraction, heading resolution, section fingerprinting
- `main.zig` — CLI entry point, argument parsing, subcommand dispatch
- `commands/lint.zig` — lint engine: file/content caching, anchor staleness checks, report formatting
- `commands/status.zig` — doc listing in text and JSON formats
- `commands/link.zig` — anchor linking with auto-provenance (content signatures)
- `commands/unlink.zig` — anchor removal from lockfile
- `commands/refs.zig` — reverse lookup: which docs reference a given target

### lockfile.zig

Reads and writes `drift.lock`. The on-disk format is TOML array-of-tables: each `[[bindings]]` block contains `doc`, `target`, and metadata keys such as `sig` and `origin`. Parsing skips blank lines and comments, accepts bindings in any order, and also imports the legacy line format for upgrade-on-write compatibility. Writing canonicalizes each binding before output: metadata fields are sorted by key, then blocks are sorted by doc/target and separated by one blank line.

Discovery: walks up from cwd checking for `drift.lock` at each directory. The lockfile's directory becomes the project root for resolving relative paths.

### symbols.zig

For each anchor, resolves the current state:

- **File-level**: stat the file, hash its content
- **Symbol-level**: parse with tree-sitter, find the symbol via `.scm` query, hash a normalized syntax fingerprint of the symbol
- **Heading-level (doc-to-doc)**: parse markdown with tree-sitter, find heading via block grammar's `section`/`atx_heading` nodes, hash the section's normalized syntax tree

Parsing is on-demand. Only files that are actually bound get parsed. A lint run that checks 10 docs anchoring to 30 symbols across 20 files does 20 tree-sitter parses — milliseconds.

### vcs.zig

Shells out to git or jj. Auto-detected from `.jj` (preferred) or `.git` directory. Operations:

- `log`: find commits that modified a file after a given point
- `blame`: get author/message for a commit
- `rev-parse` / equivalent: resolve refs
- `cat-file --batch`: persistent subprocess (`GitCatFile`) for fetching historical file content without spawning a new process per anchor

No libgit2, no jj library. `GitCatFile` keeps a single `git cat-file --batch` process alive for the duration of a lint run, feeding `rev:path` queries via stdin and reading blob content from stdout. All other VCS queries are one-shot subprocesses — the per-query cost is negligible for the number of queries drift makes.

## On-Disk Format

### drift.lock

The lockfile is a TOML file at the repo root. Every binding between a doc and a code target is one `[[bindings]]` table.

```toml
# drift.lock — managed by drift, do not edit manually
version = 1

[[bindings]]
doc = "docs/auth.md"
target = "src/auth/login.ts"
sig = "e4f8a2c10b3d7890"

[[bindings]]
doc = "docs/auth.md"
target = "src/auth/provider.ts#AuthConfig"
origin = "github:fiberplane/drift"
sig = "1a2b3c4d5e6f7890"
```

Format rules:
- `version = 1` declares the lockfile schema version
- One binding per `[[bindings]]` block with `doc`, `target`, and metadata string fields
- Blocks sorted by `(doc, target)` with deterministic tie-breaking for duplicate bindings
- Metadata fields are serialized in key order so semantically equivalent bindings produce identical bytes
- Values are single-line TOML basic strings; drift escapes `\\b`, `\\t`, `\\n`, `\\f`, `\\r`, `\\\"`, and `\\\\`
- Lines starting with `#` are comments, blank lines ignored; inline comments and general TOML tables are outside the lockfile subset
- Discovery: walk up from cwd until `drift.lock` is found

### .drift/config.toml

Optional project-level settings. The `.drift/` directory exists only for configuration (scan globs, VCS backend override, etc.).

The config reuses the lockfile's TOML subset: a mandatory `version = 1` header, `[[array-of-tables]]` blocks, bare keys, and single-line basic strings with the same escapes. Blank lines and full-line `#` comments are ignored; unknown keys or tables are hard errors with a line number, matching lockfile strictness.

```toml
# .drift/config.toml (optional)
version = 1

[[repos]]
origin = "github:acme/server"
path = "../server"
```

Each `[[repos]]` table maps a foreign binding origin to a local checkout, with exactly two keys: `origin` (normalized `github:owner/repo` form, same validation as `--repo` flag specs) and `path` (the checkout's root directory). Relative paths resolve against the lockfile root — not the cwd — so the mapping works no matter where in the checkout `drift check` runs. Unknown keys inside `[[repos]]` are hard errors.

`--repo` flags and `[[repos]]` entries feed the same origin map; when both define the same origin, the CLI flag wins. Flag paths resolve against the cwd, as usual for command-line paths.

If no config exists, drift scans all `*.md` and `**/*.md` files and auto-detects the VCS.
