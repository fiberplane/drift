# CLI Reference

All commands support `--format json` for tool integration.

## drift init

Create a `.drift/config.yaml` in the current directory.

```
drift init
```

If `.drift/config.yaml` already exists, exits with an error.

Creates a minimal config:

```yaml
scan:
  include:
    - "**/*.md"
  exclude:
    - "node_modules/**"
    - "vendor/**"
    - ".git/**"
    - ".jj/**"
vcs: auto
```

## drift lint

Check all specs for staleness. The primary command.

```
drift lint [--exit-code] [--format json]
```

Scans the repo for markdown files with `drift:` frontmatter. For each spec, checks if any bound file was modified after the spec. Reports stale and broken bindings with blame.

```
$ drift lint

docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig
          changed by mike in e4f8a2c (Mar 15)
          "refactor: split auth config into separate concerns"
  STALE   src/auth/login.ts
          changed by mike in e4f8a2c (Mar 15)

docs/payments.md
  ok

docs/project.md
  BROKEN  src/core/old-module.ts
          file not found

2 specs stale, 1 broken, 1 ok
```

`--exit-code`: exit 1 if any spec is stale or broken. Use in CI or pre-commit hooks.

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
  depends:
    - docs/project.md

docs/payments.md (1 binding)
  files:
    - src/payments/stripe.ts

docs/project.md (0 bindings)
```

## drift link

Add a binding to a spec's frontmatter. The argument format encodes both the file path and optional provenance.

```
drift link <spec-path> <file[@change]>
drift link <spec-path> <file#Symbol[@change]>
```

Edits the spec file's YAML frontmatter directly.

```
$ drift link docs/auth.md src/auth/session.ts
added src/auth/session.ts to docs/auth.md

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
