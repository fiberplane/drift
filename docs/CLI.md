# CLI Reference

`drift check` and `drift status` both support `--format <text|json>` for tool integration (default `text`). The JSON wire format is documented in [`check-json-schema.md`](./check-json-schema.md) (`drift.check.v1`). Usage and command errors exit non-zero. An unknown `--format` value is rejected with an error rather than falling through to the text path.

## drift check / drift lint

Check all docs for staleness. The primary command. Exits 1 if any anchor is stale or any link is broken. `drift lint` is an alias.

```
drift check [--format text|json] [--changed <path>]
```

Reads bindings from `drift.lock`, recomputes content signatures for each target, and compares against the stored `sig:` values. Reports stale anchors with reasons.

The `--changed <path>` flag scopes checking to docs whose targets match the given path prefix. This enables efficient CI integration — a pipeline that knows which files changed can check only the affected docs without running a full lint.

The JSON output emits the `drift.check.v1` schema with summary counts, per-doc results, per-anchor reason codes, and (best-effort) git blame on stale anchors. The exit code is the same as the text path: 0 on pass, 1 on stale. Errors writing the JSON payload (broken pipe, encoder failure) exit non-zero rather than emitting a truncated document. See [`check-json-schema.md`](./check-json-schema.md) for the full schema.

```
$ drift lint

docs/auth.md
  STALE   src/auth/provider.ts#AuthConfig (changed after doc)
          changed by mike in e4f8a2c (2026-03-15T10:00:00+00:00)
          "refactor: split auth config into separate concerns"
  BROKEN  docs/old-guide.md (link target not found)

docs/overview.md
  STALE   docs/auth.md#Authentication (changed after doc)

docs/payments.md
  ok

docs/project.md
  STALE   src/core/old-module.ts (file not found)

vendor/shared-skill.md
  SKIP   src/main.rs (origin: github:acme/other-repo)

2 docs stale, 1 ok, 1 broken link
```

- `STALE` means a lockfile anchor's target has changed since the signature was recorded.
- `BROKEN` means a plain markdown link in the doc points to a file that doesn't exist — no lockfile entry is needed for this check.

Anchors with an `origin:` field that doesn't match the current repo are skipped — they reference files in a different repository.

## drift status

Show all docs and their anchors without checking staleness. Reads bindings from `drift.lock`.

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
drift link <doc-path> <file>
drift link <doc-path> <file#Symbol>
drift link <doc-path>
```

**Targeted mode** — adds a single binding to `drift.lock`:

```
$ drift link docs/auth.md src/auth/session.ts
added docs/auth.md -> src/auth/session.ts sig:a1b2c3d4e5f6a7b8

$ drift link docs/auth.md src/auth/provider.ts#AuthConfig
added docs/auth.md -> src/auth/provider.ts#AuthConfig sig:c3d4e5f6a7b8a1b2

$ drift link docs/overview.md docs/auth.md#Authentication
added docs/overview.md -> docs/auth.md#Authentication sig:d4e5f6a7b8c9d0e1
```

**Blanket mode** — refreshes all `sig:` values for that doc in `drift.lock`:

```
$ drift link docs/auth.md
relinked all anchors in docs/auth.md
```

Each anchor gets its own content signature computed from the current file on disk.

## drift unlink

Remove a binding from `drift.lock`.

```
drift unlink <doc-path> <file>
drift unlink <doc-path> <file#Symbol>
```

The signature is not needed for unlinking — the doc path and target (with optional symbol) identify the binding.

```
$ drift unlink docs/auth.md src/auth/old-handler.ts
removed docs/auth.md -> src/auth/old-handler.ts from drift.lock
```

## drift refs

Reverse lookup — shows which docs reference a given target. Reads `drift.lock` and filters entries where the target matches.

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

Returns doc paths, one per line. Exits 0 regardless of whether matches are found.
