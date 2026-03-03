---
drift:
  files:
    - src/main.zig@uvukztro
    - src/symbols.zig@uvukztro
    - src/vcs.zig@uvukztro
---

# Decisions

## 1. Zig over TypeScript

The previous drift implementation was TypeScript/Bun with the Effect ecosystem. The rewrite uses Zig because:

- Tree-sitter is a C library. Zig has first-class C interop — no N-API bindings, no WASM overhead, no native addon compatibility issues.
- drift is a lint tool. It should be fast enough to run as a pre-commit hook with no perceptible delay. Zig produces a single static binary with predictable performance.
- drift's scope shrank significantly during redesign. The execution engine, build artifacts, server, and UI were all removed. What remains (parse markdown, resolve symbols, query VCS, format output) is ~2k lines of Zig.

## 2. On-demand parsing, no index

drift knows exactly which files it cares about — they're declared in spec frontmatter and `@` imports. It parses only those files, only when checking them. A lint run that touches 20 files does 20 tree-sitter parses. No index, no cache, no invalidation logic.

This keeps the tool stateless. Every `drift lint` run starts clean, reads specs, resolves anchors, queries VCS, reports. Nothing to get stale except the specs themselves.

## 3. Unified anchor syntax with inline provenance

Anchors and provenance live together in the spec file's YAML frontmatter using the `file@change` syntax, not in separate `files:` and `changes:` lists. Each anchor carries its own provenance as an `@change` suffix (e.g. `src/auth/login.ts@qpvuntsm`). The spec file is self-contained — its anchors, dependencies, and provenance are all in one place.

This design means provenance is per-anchor rather than per-spec. When an agent updates code for one anchor, it stamps just that anchor's change reference without affecting others. A spec with three anchors can have two fresh and one stale, and the `@change` suffix makes it immediately visible which anchors have been addressed.

`drift link` edits the spec file directly. The anchor is visible to anyone reading the spec. The VCS tracks when anchors were added or removed as part of the spec's history.

The alternative (a central evidence file) enables querying "which specs bind to this file?" without scanning all specs. We chose scanning because: the number of spec files is small (tens, not thousands), scanning is fast (just frontmatter parsing, no tree-sitter), and self-contained specs are easier to reason about.

## 4. VCS-based staleness, no lockfile

Staleness is detected by comparing VCS history: "was any bound file modified after the spec was last modified?" This requires no stored state beyond what the VCS already tracks.

We considered a lockfile (stored content hashes per anchor). A lockfile would enable offline staleness detection and wouldn't depend on VCS history ordering. We rejected it because:

- It introduces an escape hatch: `drift lock` could silence lint warnings without updating the spec
- It's redundant state that can itself drift from reality
- VCS history is reliable for the common rebase/merge patterns developers actually use
- The one edge case (interactive rebase reordering unrelated commits) produces safe false positives, not dangerous false negatives

## 5. Symbol-level anchors via tree-sitter

File-level anchors are coarse. If a spec binds to `src/auth/provider.ts` and someone adds an unrelated utility at the bottom of the file, the spec is flagged stale for no reason.

Symbol-level anchors (`src/auth/provider.ts#AuthConfig`) resolve to a specific AST declaration. Only changes to that symbol trigger staleness. This uses tree-sitter with per-language `.scm` queries.

The resolution is simple: parse file, run query, filter by symbol name, hash the matched node's text. If the symbol is not found, the anchor is reported as STALE with reason "symbol not found".

We chose tree-sitter over regex because:
- Regex breaks on string literals containing declaration keywords
- Regex can't reliably determine block boundaries in all languages
- Tree-sitter grammars exist for every mainstream language
- The per-file parse cost is negligible (sub-millisecond)

File-level anchors remain the default. Symbol-level is opt-in for precision where it matters.

## 6. Specs live anywhere, not in a special directory

Early designs had specs in `.drift/nodes/`. The final design allows any markdown file in the repo to be a drift spec by adding `drift:` frontmatter.

This means existing documentation can be incrementally adopted. You don't move files into a special directory — you add frontmatter to docs you already have. The `.drift/` directory exists only for optional configuration.

Discovery is by scanning — drift walks the repo looking for markdown files with the frontmatter marker. This is fast because it only needs to read the first few lines of each file (frontmatter is at the top).

## 7. git and jj support, auto-detected

drift shells out to git or jj rather than using a library. The VCS is auto-detected by checking for `.jj` (preferred) or `.git`.

jj's stable change IDs are a better fit for provenance tracking (the `@change` suffix on anchors) because they survive rewrites. git SHAs may become unreachable after rebase, but staleness detection uses file-level VCS history queries, not stored SHAs, so this doesn't affect correctness.

## 8. Vendored tree-sitter core, grammars as build deps

The tree-sitter C library and zig-tree-sitter bindings are vendored (in `vendor/`) because the upstream zig packaging uses `.name = "tree-sitter"` (a hyphen, invalid as a zig enum literal). This is an upstream compatibility issue.

Grammar C sources are NOT vendored. They're declared as lazy dependencies in `build.zig.zon` and fetched by Zig's package manager. This avoids vendoring hundreds of kilobytes of C source per grammar.

Starting with 6 languages: TypeScript, Python, Rust, Go, Zig, Java. More can be added by declaring the dependency and adding a `.scm` query file.
