# drift

Bind specs to code. Lint for drift.

Any markdown file in your repo can declare bindings to code — specific files or AST symbols. When bound code changes, `drift lint` flags the spec as stale. Agents that change code must update the specs they affect.

## Install

```
zig build -Doptimize=ReleaseSafe
```

## Usage

Mark any markdown file as a drift spec by adding frontmatter:

```markdown
---
drift:
  files:
    - src/auth/login.ts@qpvuntsm
    - src/auth/provider.ts#AuthConfig@qpvuntsm
---

# Auth Architecture

Users authenticate via OAuth2. The token validation flow uses @./src/auth/provider.ts#AuthConfig@qpvuntsm ...
```

Bindings come from two sources:
- **Explicit**: listed in `drift.files` frontmatter
- **Implicit**: `@./path` and `@./path#Symbol` references in content

Each binding can carry provenance via an `@change` suffix (e.g. `src/auth/login.ts@qpvuntsm`). The suffix is optional -- bare paths work without it. Provenance is per-binding, so different files can track different changes.

Check if specs are fresh:

```
drift lint
```

Link a binding with provenance:

```
drift link docs/auth.md src/auth/session.ts@qpvuntsm
```

## Commands

```
drift init          Create .drift/config.yaml in current directory
drift lint          Check all specs for staleness
drift status        Show all specs and their bindings
drift link          Add a binding (with optional provenance) to a spec
drift unlink        Remove a binding from a spec
```

## How staleness works

For each spec, drift finds the last VCS commit that modified the spec file. Then it checks if any bound file was modified in a later commit. If so, the spec is stale.

For symbol-level bindings (`#AuthConfig`), drift parses the bound file with tree-sitter and hashes just the symbol's content. The spec is stale only if that specific symbol changed — not the whole file.

Staleness output includes blame: who changed the bound code, in which commit, with what message.

## VCS support

git and jj. Auto-detected from `.jj` or `.git` directory. In jj, the `@change` provenance suffix stores stable change IDs that survive rewrites.
