---
drift:
  files:
    - src/main.zig@kznzovvs
---

# CLI Reference

All commands support `--format json` for tool integration.

## drift lint

Check all specs for staleness. The primary command. Exits 1 if any binding is stale.

```
drift lint [--format json]
```

Scans the repo for markdown files with `drift:` frontmatter. For each spec, checks if any bound file was modified after the spec. Reports stale bindings with reasons.

```
$ drift lint

docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig
          changed after spec
  STALE   src/auth/login.ts
          changed after spec

docs/payments.md
  ok

docs/project.md
  STALE   src/core/old-module.ts
          file not found

2 specs stale, 1 ok
```

## drift status

Show all specs and their bindings without checking staleness.

```
drift status [--format json]
```

```
$ drift status

docs/auth.md (3 bindings)
  files:
    - src/auth/provider.ts#AuthConfig@qpvuntsm
    - src/auth/login.ts@qpvuntsm
    - src/auth/session.ts

docs/payments.md (1 binding)
  files:
    - src/payments/stripe.ts

docs/project.md (0 bindings)
```

## drift link

Add a binding to a spec's frontmatter. When no `@change` suffix is provided, drift auto-appends the current HEAD (git) or current change ID (jj) as provenance.

```
drift link <spec-path> <file[@change]>
drift link <spec-path> <file#Symbol[@change]>
```

Edits the spec file's YAML frontmatter directly.

```
$ drift link docs/auth.md src/auth/session.ts
added src/auth/session.ts@qpvuntsm to docs/auth.md

$ drift link docs/auth.md src/auth/session.ts@qpvuntsm
added src/auth/session.ts@qpvuntsm to docs/auth.md

$ drift link docs/auth.md src/auth/provider.ts#AuthConfig@qpvuntsm
added src/auth/provider.ts#AuthConfig@qpvuntsm to docs/auth.md
```

If the spec file doesn't have `drift:` frontmatter yet, it's added. If the file is already bound, the provenance is updated in place.

## drift unlink

Remove a binding from a spec's frontmatter.

```
drift unlink <spec-path> <file>
drift unlink <spec-path> <file#Symbol>
```

The provenance suffix is not needed for unlinking -- the file path (with optional symbol) is sufficient to identify the binding.

```
$ drift unlink docs/auth.md src/auth/old-handler.ts
removed src/auth/old-handler.ts from docs/auth.md
```
