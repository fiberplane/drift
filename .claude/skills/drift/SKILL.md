---
name: drift
description: Drift doc-to-code anchor conventions. Use when editing code that is bound by drift docs, updating docs, working with drift.lock, or when drift check reports stale anchors.
---

# Drift

drift binds markdown docs to code and lints for staleness.

## Why this matters for agents

When you change code without updating the docs that describe it, those docs become stale. Stale docs get loaded as context in future sessions and produce wrong code based on wrong descriptions. This compounds — each session that trusts a stale doc makes things worse. drift makes the anchor explicit and enforceable so this feedback loop breaks.

## CRITICAL: never relink without reviewing

`drift link` refreshes provenance — it tells drift "I've reviewed this code and the doc is accurate." If you relink without actually updating the doc prose to match the code change, you are lying to every future session that loads that doc. Read the stale report, understand what changed, update the prose, THEN relink.

## After you change code

Find which docs reference the files you touched:

```bash
drift refs src/auth/login.ts
```

Or check all docs at once:

```bash
drift check
```

If a doc is stale because of your change:
1. Read the blame info to understand what changed and why
2. Update the doc's prose to reflect what you changed
3. Refresh provenance: `drift link <doc-path> <file-you-changed>`
4. Verify: `drift check`

Do not skip this. Leaving a doc stale is worse than leaving it unwritten.

## After you change a doc

Refresh all anchors in the doc to snapshot current state:

```bash
drift link docs/my-doc.md
```

This updates provenance on all bindings in `drift.lock` for that doc, including inline `@./` references.

## When you create new code

If the new code is covered by an existing doc, add an anchor:

```bash
drift link docs/auth.md src/auth/new-handler.ts
```

If the new code deserves its own doc, write one and link it:

```bash
drift link docs/new-feature.md src/feature/index.ts
drift link docs/new-feature.md src/feature/types.ts#Config
```

## When you delete or rename code

If a bound file is deleted or renamed, `drift check` will report it as STALE with "file not found". Remove the stale anchor:

```bash
drift unlink docs/auth.md src/auth/old-handler.ts
```

If you renamed the file, unlink the old path and link the new one:

```bash
drift unlink docs/auth.md src/auth/old-name.ts
drift link docs/auth.md src/auth/new-name.ts
```

Update the doc prose to reflect the rename.

## When you refactor

Refactors that move code between files or rename symbols can break multiple docs at once. Run `drift check` after refactoring to find all affected docs, then update each one.

## When drift check fails in CI

Someone changed bound code without updating docs. Read the lint output to see which docs are stale and why, update the doc prose, then `drift link` to refresh provenance.

## Anchor syntax

Bindings in `drift.lock` (primary format):
```
docs/auth.md -> src/auth/login.ts sig:a1b2c3d4e5f6a7b8
docs/auth.md -> src/auth/provider.ts#AuthConfig sig:c3d4e5f6a7b8a1b2
```

Inline references in doc body:
```markdown
The auth flow uses @./src/auth/provider.ts#AuthConfig for validation.
```

`drift link` writes bindings to `drift.lock` and stamps inline anchors with content signatures (`sig:<hex>`). Content signatures are AST fingerprints of the target, so staleness detection works without querying VCS history. This means `drift link` works on uncommitted files — no need to commit first.

If a doc has legacy embedded anchors (YAML frontmatter or `<!-- drift: -->` HTML comments), `drift link` migrates them to `drift.lock` and strips the embedded metadata.

## Cross-repo docs (origin)

Docs installed from other repos (like this skill) carry `origin:` on their bindings in `drift.lock` so `drift check` skips their anchors in consumer repos. If you're writing a doc that will be distributed to other repos, add origin to prevent false positives:

```
docs/skill.md -> src/main.ts sig:a1b2c3d4e5f6a7b8 origin:github:your-org/your-repo
```

## Staleness

`drift check` reads bindings from `drift.lock` and exits 1 if any anchor is stale. Use `drift check --changed <path>` to scope checking to docs whose targets match a given path prefix — useful in CI when you know which files changed. For supported languages (TypeScript, Python, Rust, Go, Zig, Java), comparison is syntax-aware — formatting-only changes won’t trigger staleness. Stale reports include git blame-style context (who last touched the line of interest, which commit, subject) so you can see what changed.

For `--format json`, the payload is `schema_version: drift.check.v1` (see the repo’s `docs/check-json-schema.md`). There, `blame.date` is the **committer** date in ISO 8601 strict form, not author date — use it when you need a stable time ordering after rebases. The summary includes `verification_state` (`none` | `partial` | `full`) describing how many docs were actually checked versus skipped (e.g. origin mismatch).

Reasons:
- **changed after doc** — file/symbol content differs from provenance snapshot
- **file not found** — bound file no longer exists
- **symbol not found** — bound symbol no longer exists in the file

`drift lint` is an alias for `drift check`.
