# CLI Reference

`drift check` and `drift status` both support `--format <text|json>` for tool integration (default `text`). The JSON wire format is documented in [`check-json-schema.md`](./check-json-schema.md) (`drift.check.v1`). Usage and command errors exit non-zero. An unknown `--format` value is rejected with an error rather than falling through to the text path.

## drift check / drift lint

Check all specs for staleness. The primary command. Exits 1 if any anchor is stale. `drift lint` is an alias.

```
drift check [--format text|json] [--changed <path>]
```

Reads bindings from `drift.lock`, recomputes content signatures for each target, and compares against the stored `sig:` values. Reports stale anchors with reasons.

The `--changed <path>` flag scopes checking to specs whose targets match the given path prefix. This enables efficient CI integration — a pipeline that knows which files changed can check only the affected specs without running a full lint.

The JSON output emits the `drift.check.v1` schema with summary counts, per-spec results, per-anchor reason codes, and (best-effort) git blame on stale anchors. The exit code is the same as the text path: 0 on pass, 1 on stale. Errors writing the JSON payload (broken pipe, encoder failure) exit non-zero rather than emitting a truncated document. See [`check-json-schema.md`](./check-json-schema.md) for the full schema.

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

Anchors with an `origin:` field that doesn't match the current repo are skipped — they reference files in a different repository.

## drift status

Show all specs and their anchors without checking staleness. Reads bindings from `drift.lock`.

```
drift status [--format json]
```

```
$ drift status

docs/auth.md (3 anchors)
  files:
    - src/auth/provider.ts#AuthConfig
    - src/auth/login.ts
    - src/auth/session.ts

docs/payments.md (1 anchor)
  files:
    - src/payments/stripe.ts
```

## drift link

Add or refresh bindings in `drift.lock`. `drift link` computes a content signature (`sig:`) from the target file's current syntax fingerprint and writes it to the lockfile. Creates `drift.lock` if it doesn't exist.

```
drift link <spec-path> <file>
drift link <spec-path> <file#Symbol>
drift link <spec-path>
```

**Targeted mode** — adds a single binding to `drift.lock`:

```
$ drift link docs/auth.md src/auth/session.ts
added docs/auth.md -> src/auth/session.ts sig:a1b2c3d4e5f6a7b8

$ drift link docs/auth.md src/auth/provider.ts#AuthConfig
added docs/auth.md -> src/auth/provider.ts#AuthConfig sig:c3d4e5f6a7b8a1b2
```

**Blanket mode** — refreshes all `sig:` values for that spec in `drift.lock`:

```
$ drift link docs/auth.md
relinked all anchors in docs/auth.md
```

Each anchor gets its own content signature computed from the current file on disk.

If the spec has legacy embedded anchors (YAML frontmatter or `<!-- drift: ... -->` HTML comments), `drift link` migrates them: writes the bindings to `drift.lock` and strips the embedded metadata from the spec file. No separate migration command — linking on the new version handles it.

## drift unlink

Remove a binding from `drift.lock`.

```
drift unlink <spec-path> <file>
drift unlink <spec-path> <file#Symbol>
```

The signature is not needed for unlinking — the spec path and target (with optional symbol) identify the binding.

```
$ drift unlink docs/auth.md src/auth/old-handler.ts
removed docs/auth.md -> src/auth/old-handler.ts from drift.lock
```

## drift refs

Reverse lookup — shows which specs reference a given target. Reads `drift.lock` and filters entries where the target matches.

```
drift refs <path>
drift refs <path#Symbol>
```

```
$ drift refs src/auth/login.ts
docs/auth.md
docs/onboarding.md

$ drift refs src/auth/provider.ts#AuthConfig
docs/auth.md
```

Returns spec paths, one per line. Exits 0 regardless of whether matches are found.
