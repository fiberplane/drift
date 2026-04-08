# `drift check --format json` — wire format (`drift.check.v1`)

`drift check --format json` (and its `drift lint --format json` alias) emits a single
JSON document on stdout describing the result of a check run. The schema is identified
by the `schema_version` field. Consumers should match on that exact string and treat
unknown fields as forward-compatible additions.

Process exit code is independent of format: **0 if no anchor is stale, 1 otherwise.**
Errors writing the JSON payload (broken pipe, encoder failure) cause a non-zero exit
rather than a silently truncated document.

## JSON Schema (machine-readable)

The same structure is described by a [JSON Schema](https://json-schema.org/)
([Draft 2020-12](https://json-schema.org/draft/2020-12/json-schema-core.html)) file:

**[`docs/schemas/drift.check.v1.json`](schemas/drift.check.v1.json)** — generated from the payload types; regenerate with:

```sh
zig build gen-check-schema
```

Use it with JSON Schema tooling (e.g. IDE plugins) to check payloads. The canonical Zig
types live in [`src/payload/drift_check_v1.zig`](../src/payload/drift_check_v1.zig); the
schema is emitted from those types in [`src/payload/drift_check_schema_gen.zig`](../src/payload/drift_check_schema_gen.zig).
`drift` writes JSON with `std.json.Stringify.value` from those types. Integration tests parse
stdout back into `payload.DriftCheckV1` and run `validateJsonDocument`. The schema uses
`additionalProperties: true` on objects so that future optional top-level or nested
fields remain valid without updating the schema file immediately.

## Top-level shape

```json
{
  "schema_version": "drift.check.v1",
  "tool": "drift",
  "tool_version": "0.x.y",
  "repo": "github:owner/name" | null,
  "checked_at_ms": 1733000000000,
  "summary": { ... },
  "specs": [ ... ]
}
```

| Field | Type | Notes |
|---|---|---|
| `schema_version` | string | Always `"drift.check.v1"` for this revision. |
| `tool` | string | Always `"drift"`. |
| `tool_version` | string | The drift binary's build version. |
| `repo` | string \| null | Repo identity (e.g. `github:owner/name`) when detectable, else `null`. |
| `checked_at_ms` | integer | Wall-clock time of the run, **milliseconds since Unix epoch**. The `_ms` suffix is intentional — bare `checked_at` would be ambiguous (s/ms/us/ns). |
| `summary` | object | Aggregate counts and overall result. See below. |
| `specs` | array | One entry per discovered spec, in scanner order. |

## `summary`

```json
{
  "result": "pass" | "fail",
  "verification_state": "none" | "partial" | "full",
  "specs_total": 3,
  "specs_checked": 2,
  "specs_skipped": 1,
  "specs_fresh": 2,
  "specs_stale": 0,
  "anchors_total": 7,
  "anchors_fresh": 5,
  "anchors_stale": 0,
  "anchors_skipped": 2
}
```

- `result` is `"fail"` iff any anchor is stale; otherwise `"pass"`. This mirrors the
  process exit code.
- `verification_state` describes **coverage**: how much of the discovered work was
  actually verified versus skipped (e.g. origin mismatch).
  - `"none"`: `specs_total > 0` but `specs_checked == 0` — every spec was skipped, so
    no staleness verification ran. CI dashboards should treat this as a yellow signal:
    `result` may still be `"pass"`.
  - `"partial"`: some specs were checked and some skipped (`specs_checked > 0` and
    `specs_skipped > 0`).
  - `"full"`: nothing was skipped (`specs_skipped == 0`), including the case
    `specs_total == 0` (no specs to skip).
- `specs_checked` is `specs_fresh + specs_stale` — specs that were not skipped.
- All counts are non-negative integers;
  `specs_fresh + specs_stale + specs_skipped == specs_total`.

## `specs[*]`

```json
{
  "path": "docs/auth.md",
  "origin": "github:owner/name" | null,
  "result": "fresh" | "stale" | "skip",
  "anchors": [ ... ]
}
```

A spec's `result` is the worst of its anchors (`stale > skip > fresh`). A spec with
zero anchors is `"fresh"`.

## `specs[*].anchors[*]`

```json
{
  "identity": "src/auth/login.ts#login",
  "raw": "src/auth/login.ts#login@sig:1f0ab611cebf2ea0",
  "kind": "symbol" | "file",
  "path": "src/auth/login.ts",
  "symbol": "login" | null,
  "provenance": { "kind": "sig" | "vcs", "value": "1f0ab611cebf2ea0" } | null,
  "result": "fresh" | "stale" | "skip",
  "reason": { "code": "...", "message": "..." } | null,
  "blame": { "author": "...", "commit": "...", "date": "...", "subject": "..." } | null
}
```

- `identity` is the anchor stripped of its `@provenance` suffix — stable, used by the
  link/unlink commands as the canonical anchor handle.
- `raw` is the original anchor string from the spec, suffix included.
- `kind` is `"symbol"` if `identity` contains a `#`, else `"file"`.
- `provenance.kind` is `"sig"` for content fingerprints (`@sig:hex`) or `"vcs"` for a
  raw commit hash. `null` when the anchor has no provenance suffix.
- `reason` is `null` for fresh anchors. For stale/skipped anchors, `code` is one of the
  enum values below and `message` is the human-readable form (English, stable).
- `blame` is populated on a best-effort basis when an anchor is stale due to file
  content drift; `null` otherwise (or when git blame failed).
  - `commit` is the full Git object id (`git log` `%H`), not an abbreviated SHA.
  - `date` is the committer date in ISO 8601 strict form (`git --date=iso-strict`, e.g.
    `2026-04-07T20:18:31+02:00`), suitable for sorting and comparison.

### `reason.code` values

| Code | When |
|---|---|
| `changed_after_baseline` | The anchored file or symbol differs from its provenance/baseline. |
| `file_not_found` | The anchored file does not exist on disk. |
| `file_not_readable` | The file exists but could not be read (permissions, size limit). |
| `symbol_not_found` | A `file#Symbol` anchor's symbol is no longer present. |
| `fingerprint_unavailable` | A `@sig:` anchor could not be re-fingerprinted (e.g. unknown language). |
| `baseline_unavailable` | Reserved — historical baseline could not be retrieved. (Not currently emitted; held for forward compatibility.) |
| `origin_mismatch` | The spec's `origin:` does not match the current repo identity. Anchors are skipped. |

`reason.message` strings are stable in `v1` and asserted by tests. Changing one is a
schema bump.

## Stability and versioning

This is `drift.check.v1`. Within this identifier:

- New fields **may** be added at the top level, in `summary`, in `specs[*]`, or in
  `specs[*].anchors[*]`. Consumers must ignore unknown fields.
- New `reason.code` values **may** be added. Consumers should handle unknown codes
  gracefully (e.g. fall back to `reason.message`).
- Existing field names, types, and units **will not** change. Renaming
  `checked_at_ms`, repurposing `result`, or changing the unit of any timestamp is a
  breaking change and requires a new `schema_version` string.

## Example: stale anchor with blame

```json
{
  "schema_version": "drift.check.v1",
  "tool": "drift",
  "tool_version": "0.1.0",
  "repo": "github:fiberplane/drift",
  "checked_at_ms": 1733001234567,
  "summary": {
    "result": "fail",
    "verification_state": "full",
    "specs_total": 1,
    "specs_checked": 1,
    "specs_skipped": 0,
    "specs_fresh": 0,
    "specs_stale": 1,
    "anchors_total": 1,
    "anchors_fresh": 0,
    "anchors_stale": 1,
    "anchors_skipped": 0
  },
  "specs": [{
    "path": "docs/auth.md",
    "origin": null,
    "result": "stale",
    "anchors": [{
      "identity": "src/auth/login.ts",
      "raw": "src/auth/login.ts@sig:abc123...",
      "kind": "file",
      "path": "src/auth/login.ts",
      "symbol": null,
      "provenance": { "kind": "sig", "value": "abc123..." },
      "result": "stale",
      "reason": { "code": "changed_after_baseline", "message": "changed after spec" },
      "blame": {
        "author": "Alice",
        "commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        "date": "2026-04-07T14:22:00+00:00",
        "subject": "refactor: rename login handler"
      }
    }]
  }]
}
```
