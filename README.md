<!-- drift:
  files:
    - src/main.zig@xlwuyosp


-->

# drift

Bind specs to code. Lint for drift.

Any markdown file in your repo can declare bindings to code — specific files or AST symbols. When bound code changes, `drift lint` flags the spec as stale. Agents that change code must update the specs they affect.

## Install

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

## Quickstart with Claude Code

Install the CLI and the agent skill:

```bash
zig build -Doptimize=ReleaseSafe --prefix ~/.local
npx skills add fiberplane/drift
```

The skill teaches Claude Code how to maintain drift bindings — when to link, when to update specs, and how to handle stale bindings. Once installed, you can tell Claude to add drift to your existing docs:

> "Add drift bindings to docs/auth.md for src/auth/login.ts and src/auth/provider.ts#AuthConfig"

> "Run drift lint and fix any stale specs"

> "Write a spec for the payment module and bind it to the relevant source files"

Claude will run `drift link` to stamp provenance and keep specs in sync as it makes code changes. When drift lint is in CI, stale specs block merges — so the agent can't silently break documentation.

## Usage

Write a markdown spec, then bind it to code:

```
drift link docs/auth.md src/auth/login.ts
drift link docs/auth.md src/auth/provider.ts#AuthConfig
```

`drift link` adds the binding to the spec's YAML frontmatter and auto-appends provenance (current git HEAD or jj change ID). You can also reference code inline — `@./src/auth/provider.ts#AuthConfig` in the spec body — and `drift link` will stamp those with provenance too.

Check if specs are fresh:

```
drift lint
```

Refresh all bindings in a spec after updating it:

```
drift link docs/auth.md
```

### What a spec looks like

After linking, your spec has frontmatter bindings and (optionally) inline references:

```markdown
---
drift:
  files:
    - src/auth/login.ts@qpvuntsm
    - src/auth/provider.ts#AuthConfig@qpvuntsm
---

# Auth Architecture

Users authenticate via OAuth2. The validation flow uses @./src/auth/provider.ts#AuthConfig@qpvuntsm ...
```

Each binding carries provenance via an `@change` suffix — a snapshot of which VCS change you last reviewed that file at. Provenance is per-binding, so different files track independently.

If you don't want frontmatter visible in render frontends like GitHub, wrap it in an HTML comment instead — drift picks it up the same way:

```markdown
<!-- drift:
  files:
    - src/auth/login.ts@qpvuntsm
    - src/auth/provider.ts#AuthConfig@qpvuntsm
-->
```

## Commands

```
drift lint          Check all specs for staleness (exits 1 if stale)
drift status        Show all specs and their bindings
drift link          Add a binding to a spec (auto-appends provenance)
drift unlink        Remove a binding from a spec
```

## How staleness works

For each binding with provenance, drift compares the file's content at the provenance revision against its current content. If they differ, the spec is stale. This is content-based — git rebases that don't change content won't trigger false positives, and jj rewrites that do change content won't slip through.

For symbol-level bindings (`#AuthConfig`), drift parses the file with tree-sitter and compares just the symbol's AST node. Changes elsewhere in the file don't trigger staleness.

Staleness is reported with a reason:

```
$ drift lint

docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig
          changed after spec
  STALE   src/core/old-module.ts
          file not found

docs/payments.md
  ok

1 spec stale, 1 ok
```

Reasons include:
- **changed after spec** — the bound file (or symbol) was modified after the spec
- **file not found** — the bound file no longer exists
- **symbol not found** — the bound symbol no longer exists in the file

## CI

`drift lint` exits 1 when any spec is stale, so it works as a CI gate:

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
      - run: drift lint
```

`fetch-depth: 0` is required — drift needs VCS history to compare content at provenance revisions. The setup action auto-detects platform and downloads the right binary from GitHub releases.

## VCS support

git and jj. Auto-detected from `.jj` or `.git` directory. In jj, the `@change` provenance suffix stores stable change IDs that survive rewrites.

## Development

Requires Zig 0.15.2. The repo includes a `.tool-versions` file for [mise](https://mise.jdx.dev/) (or asdf). If you haven't already, [activate mise](https://mise.jdx.dev/getting-started.html#activate-mise) in your shell, then:

```bash
mise install        # installs zig 0.15.2
zig build test      # run tests
zig build -Doptimize=ReleaseSafe  # build release binary
```

Enable the pre-push hook to run build, lint, and tests before every push:

```bash
git config core.hooksPath hooks
```
