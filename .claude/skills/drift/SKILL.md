---
name: drift
description: Drift spec-to-code anchor conventions. Use when editing code that is bound by drift specs, updating specs, working with drift frontmatter, or when drift check reports stale anchors.
drift:
  origin: github:fiberplane/drift
  files:
    - src/main.zig@sig:3560999bb08f8512
    - src/frontmatter.zig@sig:ef9880e4f1a96c16
    - src/scanner.zig@sig:9ccfb8091a6c8ef2
    - src/vcs.zig@sig:b9481e9cf295501a
---

# Drift

drift binds markdown specs to code and lints for staleness.

## Why this matters for agents

When you change code without updating the specs that describe it, those specs become stale. Stale specs get loaded as context in future sessions and produce wrong code based on wrong descriptions. This compounds — each session that trusts a stale spec makes things worse. drift makes the anchor explicit and enforceable so this feedback loop breaks.

## CRITICAL: never relink without reviewing

`drift link` refreshes provenance — it tells drift "I've reviewed this code and the spec is accurate." If you relink without actually updating the spec prose to match the code change, you are lying to every future session that loads that spec. Read the stale report, understand what changed, update the prose, THEN relink.

## After you change code

Check if any specs reference the files you touched:

```bash
drift check
```

If a spec is stale because of your change:
1. Read the blame info to understand what changed and why
2. Update the spec's prose to reflect what you changed
3. Refresh provenance: `drift link <spec-path> <file-you-changed>`
4. Verify: `drift check`

Do not skip this. Leaving a spec stale is worse than leaving it unwritten.

## After you change a spec

Refresh all anchors in the spec to snapshot current state:

```bash
drift link docs/my-spec.md
```

This updates provenance on both frontmatter anchors and inline `@./` references.

## When you create new code

If the new code is covered by an existing spec, add an anchor:

```bash
drift link docs/auth.md src/auth/new-handler.ts
```

If the new code deserves its own spec, write one and link it:

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

Update the spec prose to reflect the rename.

## When you refactor

Refactors that move code between files or rename symbols can break multiple specs at once. Run `drift check` after refactoring to find all affected specs, then update each one.

## When drift check fails in CI

Someone changed bound code without updating specs. Read the lint output to see which specs are stale and why, update the spec prose, then `drift link` to refresh provenance.

## Anchor syntax

Frontmatter:
```yaml
drift:
  files:
    - src/auth/login.ts                          # file-level, no provenance
    - src/auth/provider.ts#AuthConfig             # symbol-level (AST node)
    - src/auth/login.ts@sig:a1b2c3d4e5f6a7b8     # with content signature (primary)
    - src/auth/login.ts@2d3a4080                  # with VCS SHA (legacy)
```

HTML comment (alternative to frontmatter, invisible on GitHub):
```markdown
<!-- drift:
  files:
    - src/auth/login.ts@sig:a1b2c3d4e5f6a7b8
-->
```

Inline (in spec body):
```markdown
The auth flow uses @./src/auth/provider.ts#AuthConfig for validation.
```

`drift link` stamps frontmatter, HTML comment, and inline anchors with content signatures (`@sig:<hex>`). Content signatures are AST fingerprints of the target, so staleness detection works without querying VCS history. This means `drift link` works on uncommitted files — no need to commit first.

## Cross-repo specs (origin)

Specs installed from other repos (like this skill) declare `origin: github:owner/repo` so `drift check` skips their anchors in consumer repos. If you're writing a spec that will be distributed to other repos, add origin to prevent false positives:

```yaml
drift:
  origin: github:your-org/your-repo
  files:
    - src/main.ts@sig:a1b2c3d4e5f6a7b8
```

## Staleness

`drift check` exits 1 if any anchor is stale. For supported languages (TypeScript, Python, Rust, Go, Zig, Java), comparison is syntax-aware — formatting-only changes won't trigger staleness. Stale reports include git blame info (author, commit, message) so you know what changed and why.

Reasons:
- **changed after spec** — file/symbol content differs from provenance snapshot
- **file not found** — bound file no longer exists
- **symbol not found** — bound symbol no longer exists in the file

`drift lint` is an alias for `drift check`.
