
<img width="276" height="84" alt="Drift Logo" src="https://github.com/user-attachments/assets/19618b90-d43e-4e92-8497-9674a87693e2" />

Bind docs to code and check for drift.

Any markdown file in your repo can declare anchors to code — specific files or AST symbols. When bound code changes, `drift check` flags the doc as stale. Agents that change code must update the docs they affect.

## Install

### Homebrew

```bash
brew install fiberplane/tap/drift
```

### Shell installer

```bash
curl -fsSL https://drift.fp.dev/install.sh | sh
```

To install a specific version:

```bash
curl -fsSL https://drift.fp.dev/install.sh | sh -s -- --version vX.Y.Z
```

Or build from source:

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

### Coding agent skill (Claude Code, Codex)

```bash
curl -fsSL https://drift.fp.dev/install.sh | sh
npx skills add fiberplane/drift
```

The skill teaches coding agents how to maintain drift anchors. Once installed, the agent will run `drift link` to stamp provenance and keep docs in sync as it makes code changes. When `drift check` is in CI, stale docs block merges — so the agent can't silently break documentation.

## Usage

Write a markdown doc, then bind it to code:

```
drift link docs/auth.md src/auth/login.ts
drift link docs/auth.md src/auth/provider.ts#AuthConfig
```

`drift link` writes the binding to `drift.lock` at the repo root and stamps a content signature — an AST fingerprint of the target file or symbol. It hashes what's on disk, so uncommitted files work fine. You can also reference code inline — `@./src/auth/provider.ts#AuthConfig` in the doc body — and `drift link` will stamp those too.

Check if docs are fresh:

```
drift check
```

Refresh all anchors in a doc after updating it:

```
drift link docs/auth.md
```

### What a doc anchor looks like

After linking, bindings live in `drift.lock` at the repo root:

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

You can also use inline references in the doc body — `@./src/auth/provider.ts#AuthConfig` — and `drift link` will stamp those in the lockfile too.

Every anchor has three parts:

```
src/auth/provider.ts   #AuthConfig   sig = "1a2b3c4d5e6f7890"
└── file path ──────┘  └─ symbol ─┘  └──────── signature ────────┘
```

- **Path** — the file you're binding to, relative to the repo root.
- **Symbol** — optional `#Name` suffix that narrows the anchor to a specific declaration (function, class, type). Only changes to that symbol trigger staleness.
- **Signature** — content fingerprint stamped by `drift link`. An XxHash3 hash of the file or symbol's normalized AST, so staleness detection doesn't depend on VCS history. Rebasing, amending, or linking uncommitted files all work. Per-anchor, so different files track independently.

### Cross-repo docs (origin)

Docs that travel across repo boundaries — installed skills, vendored docs, shared templates — can declare where their anchors belong via an `origin` field:

```toml
version = 1

[[bindings]]
doc = "docs/skill.md"
target = "src/main.zig"
origin = "github:fiberplane/drift"
sig = "a1b2c3d4e5f67890"
```

When `origin` doesn't match the current repo, `drift check` skips those anchors instead of reporting false "file not found" errors. Anchors without `origin` are always checked.

## Commands

```
drift check         Check all docs for staleness (exits 1 if stale)
drift status        Show all doc anchors from drift.lock
drift link          Add or refresh bindings in drift.lock
drift unlink        Remove a binding from drift.lock
drift refs          Reverse lookup — which docs reference a given file
```

`drift lint` is an alias for `drift check`.

## How staleness works

Each anchor's `sig` field records a fingerprint of the code at the time it was linked. `drift check` recomputes the fingerprint from the current file and compares. For supported languages (TypeScript, Python, Rust, Go, Zig, Java), comparison is syntax-aware — drift parses with tree-sitter and hashes a normalized AST fingerprint (node kinds + token text, no whitespace or position data). Reformatting won't trigger false positives. Symbol-level anchors (`#AuthConfig`) narrow this to just that declaration's subtree. Unsupported languages fall back to raw content comparison.

No VCS history is needed for staleness detection — `drift check` works entirely from the stored signature and current file content.

```
$ drift check

docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig (changed after doc)
          changed by mike in e4f8a2c (Mar 15)
          "refactor: split auth config into separate concerns"
  STALE   src/core/old-module.ts (file not found)
  ok      src/auth/login.ts

docs/payments.md
  ok

1 doc stale, 1 ok
```

## CI

`drift check` exits 1 when any doc is stale, so it works as a CI gate:

```yaml
# .github/workflows/drift.yml
name: Drift
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: fiberplane/drift@main
      - run: drift check
```

For faster CI runs, use `--changed` to scope checking to docs affected by the files that changed in the PR:

```yaml
      - run: drift check --changed src/auth
```

`fetch-depth: 0` is recommended — drift uses VCS history for blame info on stale anchors. With `sig` provenance (the default), staleness detection itself doesn't need history. The setup action auto-detects platform, downloads the right binary from GitHub releases, and verifies its checksum before installing.

## Development

Requires Zig 0.16.0. The repo includes a `.mise.toml` file for [mise](https://mise.jdx.dev/). If you haven't already, [activate mise](https://mise.jdx.dev/getting-started.html#activate-mise) in your shell, then:

```bash
mise install        # installs zig 0.16.0
zig build test      # run tests
zig build -Doptimize=ReleaseSafe  # build release binary
```

Enable the pre-push hook to run build, lint, and tests before every push:

```bash
git config core.hooksPath hooks
```
