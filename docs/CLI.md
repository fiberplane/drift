---
drift:
  files:
    - src/main.zig@sig:1f0ab611cebf2ea0
---

# CLI Reference

`drift check` and `drift status` both support `--format <text|json>` for tool integration (default `text`). The JSON wire format is documented in [`check-json-schema.md`](./check-json-schema.md) (`drift.check.v1`). Usage and command errors exit non-zero. An unknown `--format` value is rejected with an error rather than falling through to the text path.

## drift check / drift lint

Check all specs for staleness. The primary command. Exits 1 if any anchor is stale. `drift lint` is an alias.

```
drift check [--format text|json]
```

The JSON output emits the `drift.check.v1` schema with summary counts, per-spec results, per-anchor reason codes, and (best-effort) git blame on stale anchors. The exit code is the same as the text path: 0 on pass, 1 on stale. Errors writing the JSON payload (broken pipe, encoder failure) exit non-zero rather than emitting a truncated document. See [`check-json-schema.md`](./check-json-schema.md) for the full schema.

Scans the repo for git-tracked markdown files with `drift:` frontmatter or `<!-- drift: ... -->` HTML comments. For each spec, checks if any bound file was modified after the spec. Reports stale anchors with reasons.

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

vendor/shared-skill.md
  SKIP   src/main.rs (origin: github:acme/other-repo)

2 specs stale, 1 ok
```

Specs with an `origin:` field that doesn't match the current repo are skipped — their anchors reference files in a different repository.

## drift status

Show all specs and their anchors without checking staleness. This includes explicit frontmatter anchors, `<!-- drift: ... -->` HTML comment anchors, and inline `@./path` references from the spec body.

```
drift status [--format json]
```

```
$ drift status

docs/auth.md (3 anchors)
  files:
    - src/auth/provider.ts#AuthConfig@qpvuntsm
    - src/auth/login.ts@qpvuntsm
    - src/auth/session.ts

docs/payments.md (1 anchor)
  files:
    - src/payments/stripe.ts

docs/project.md (0 anchors)
```

## drift link

Add or refresh anchors in a spec's frontmatter. `drift link` computes a content signature (`@sig:`) from the target file's current syntax fingerprint and uses it as provenance. If the target file doesn't exist or can't be fingerprinted, it falls back to the current HEAD SHA.

```
drift link <spec-path> <file[@provenance]>
drift link <spec-path> <file#Symbol[@provenance]>
drift link <spec-path>
```

**Targeted mode** — links a single anchor:

```
$ drift link docs/auth.md src/auth/session.ts
added src/auth/session.ts@sig:a1b2c3d4e5f6a7b8 to docs/auth.md

$ drift link docs/auth.md src/auth/provider.ts#AuthConfig
added src/auth/provider.ts#AuthConfig@sig:c3d4e5f6a7b8a1b2 to docs/auth.md
```

**Blanket mode** — refreshes all anchors in a spec:

```
$ drift link docs/auth.md
relinked all anchors in docs/auth.md
```

Each anchor gets its own content signature computed from the current file on disk.

If the spec file doesn't have `drift:` frontmatter yet, it's added. If the file is already bound, the provenance is updated in place. If you provide an explicit `@provenance` suffix, it is used as-is.

## drift unlink

Remove an anchor from a spec's YAML frontmatter or `<!-- drift: ... -->` HTML comment block.

```
drift unlink <spec-path> <file>
drift unlink <spec-path> <file#Symbol>
```

The provenance suffix is not needed for unlinking -- the file path (with optional symbol) is sufficient to identify the anchor.

```
$ drift unlink docs/auth.md src/auth/old-handler.ts
removed src/auth/old-handler.ts from docs/auth.md
```
