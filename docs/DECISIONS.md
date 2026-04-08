---
drift:
  files:
    - src/main.zig@sig:3560999bb08f8512
    - src/symbols.zig@sig:1f41e745e5e32c2d
    - src/vcs.zig@sig:b9481e9cf295501a
---

# Decisions

## 1. Zig over TypeScript

The previous drift implementation was TypeScript/Bun with the Effect ecosystem. The rewrite uses Zig because:

- Tree-sitter is a C library. Zig has first-class C interop — no N-API bindings, no WASM overhead, no native addon compatibility issues.
- drift is a lint tool. It should be fast enough to run as a pre-commit hook with no perceptible delay. Zig produces a single static binary with predictable performance.
- drift's scope shrank significantly during redesign. The execution engine, build artifacts, server, and UI were all removed. What remains (parse markdown, resolve symbols, query VCS, format output) is ~2k lines of Zig.

## 2. On-demand parsing, no persistent index

drift knows exactly which files it cares about — they're declared in spec frontmatter, `<!-- drift: ... -->` comments, and `@./` inline references. It parses only those files, only when checking them. A lint run that touches 20 files does 20 tree-sitter parses. No persistent index, no disk cache, no invalidation logic.

Within a single lint run, file content and historical versions are cached in memory (`FileCache`) and VCS queries use a persistent `git cat-file --batch` subprocess (`GitCatFile`). These are per-run optimizations — nothing is written to disk. Every `drift lint` run starts clean, reads specs, resolves anchors, queries VCS, reports. Nothing to get stale except the specs themselves.

## 3. Unified anchor syntax with inline provenance

Anchors and provenance live together in the spec file using the `file@change` syntax, not in separate `files:` and `changes:` lists. Each anchor carries its own provenance as an `@change` suffix (e.g. `src/auth/login.ts@sig:a1b2c3d4e5f6a7b8`). Anchors can appear in YAML frontmatter or in `<!-- drift: ... -->` HTML comments (for specs where visible frontmatter is undesirable). The spec file is self-contained — its anchors, dependencies, and provenance are all in one place.

This design means provenance is per-anchor rather than per-spec. When an agent updates code for one anchor, it stamps just that anchor's change reference without affecting others. A spec with three anchors can have two fresh and one stale, and the `@change` suffix makes it immediately visible which anchors have been addressed.

`drift link` edits the spec file directly. The anchor is visible to anyone reading the spec. The VCS tracks when anchors were added or removed as part of the spec's history.

The alternative (a central evidence file) enables querying "which specs bind to this file?" without scanning all specs. We chose scanning because: the number of spec files is small (tens, not thousands), scanning is fast (just frontmatter parsing, no tree-sitter), and self-contained specs are easier to reason about.

## 4. VCS-based staleness, no lockfile

Staleness is detected by comparing the current code against the bound code at a baseline revision in VCS. For supported tree-sitter languages, drift compares normalized syntax fingerprints so formatting-only changes don't trigger drift; unsupported files fall back to raw content comparison. This requires no stored state beyond what the VCS already tracks.

We considered a lockfile (stored content hashes per anchor). A lockfile would enable offline staleness detection and wouldn't depend on VCS history ordering. We rejected it because:

- It introduces an escape hatch: `drift lock` could silence lint warnings without updating the spec
- It's redundant state that can itself drift from reality
- VCS history is reliable for the common rebase/merge patterns developers actually use
- The one edge case (interactive rebase reordering unrelated commits) produces safe false positives, not dangerous false negatives

## 5. Symbol-level anchors via tree-sitter

File-level anchors are coarse. If a spec binds to `src/auth/provider.ts` and someone adds an unrelated utility at the bottom of the file, the spec is flagged stale for no reason.

Symbol-level anchors (`src/auth/provider.ts#AuthConfig`) resolve to a specific AST declaration. Only changes to that symbol trigger staleness. This uses tree-sitter with per-language `.scm` queries.

The resolution is simple: parse file, run query, filter by symbol name, and hash a normalized traversal of the matched node's subtree. That ignores formatting-only changes while still catching syntax/token changes. If the symbol is not found, the anchor is reported as STALE with reason "symbol not found".

We chose tree-sitter over regex because:
- Regex breaks on string literals containing declaration keywords
- Regex can't reliably determine block boundaries in all languages
- Tree-sitter grammars exist for every mainstream language
- The per-file parse cost is negligible (sub-millisecond)

File-level anchors remain the default. Symbol-level is opt-in for precision where it matters.

## 6. Specs live anywhere, not in a special directory

Early designs had specs in `.drift/nodes/`. The final design allows any markdown file in the repo to be a drift spec by adding `drift:` frontmatter or a `<!-- drift: ... -->` HTML comment.

This means existing documentation can be incrementally adopted. You don't move files into a special directory — you add frontmatter or a drift comment to docs you already have. The `.drift/` directory exists only for optional configuration.

Discovery is by scanning — drift lists all git-tracked markdown files (via `git ls-files -z`) and checks each for drift markers. This is fast because it only needs to parse frontmatter and scan for comment markers.

## 7. git and jj support, auto-detected

drift shells out to git or jj rather than using a library. The VCS is auto-detected by checking for `.jj` (preferred) or `.git`.

jj's stable change IDs are a better fit for provenance tracking (the `@change` suffix on anchors) because they survive rewrites. git SHAs may become unreachable after rebase, but staleness detection uses file-level VCS history queries, not stored SHAs, so this doesn't affect correctness.

## 8. Vendored tree-sitter core, grammars as build deps

The tree-sitter C library and zig-tree-sitter bindings are vendored (in `vendor/`) because the upstream zig packaging uses `.name = "tree-sitter"` (a hyphen, invalid as a zig enum literal). This is an upstream compatibility issue.

Grammar C sources are NOT vendored. They're declared as lazy dependencies in `build.zig.zon` and fetched by Zig's package manager. This avoids vendoring hundreds of kilobytes of C source per grammar.

Starting with 6 languages: TypeScript, Python, Rust, Go, Zig, Java. More can be added by declaring the dependency and adding a `.scm` query file.

## 9. Content signatures over VCS SHAs for provenance

`drift link` now stores provenance as `@sig:<16-char-hex>` — a content-addressed fingerprint of the anchor's target — instead of `@<git-sha>`. The fingerprint is the same normalized syntax hash that staleness detection already computes (XxHash3 of the tree-sitter AST walk, or raw XxHash3 for unsupported languages).

Content signatures solve several problems with VCS-based provenance:

- Shallow clones and fresh clones work without history. `drift lint` with `@sig:` never shells out to git — it reads the file, hashes it, and compares. This makes CI faster and eliminates the `actions/checkout` depth footgun.
- Detached HEAD, rebases, and force pushes don't invalidate provenance. A git SHA can become unreachable; a content fingerprint is always recomputable from the current file.
- The staleness check is a pure function of the file's content, not of VCS state. This makes drift behavior deterministic and easier to reason about.

Legacy `@<sha>` provenance is still supported — `drift lint` detects the format and routes to the VCS-based comparison path. Migration is incremental: running `drift link <spec>` on any spec rewrites its anchors to `@sig:` format.

## 10. Origin-qualified anchors

Specs can declare `origin: github:owner/repo` in their `drift:` frontmatter section. At lint time, drift resolves the current repo's identity from `git remote get-url origin`, normalizes it to `github:owner/repo`, and compares. If a spec's origin doesn't match, its anchors are skipped — they belong to a different repository.

This solves the problem of specs traveling across repository boundaries. Shared skill files, vendored documentation, and monorepo imports all contain anchors that point at files in the source repo, not the consuming repo. Without origin qualification, `drift lint` would report these as STALE (file not found) every time, creating noise. With it, foreign specs are silently skipped and only local specs are checked.

Origin is opt-in. Specs without `origin:` are always checked. The normalized format (`github:owner/repo`) is derived from the git remote URL, handling SSH, HTTPS, and SSH URL formats uniformly.
