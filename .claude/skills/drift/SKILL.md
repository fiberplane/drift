---
name: drift
description: Drift spec-to-code anchor conventions. Use when editing code that is bound by drift specs, updating specs, working with drift frontmatter, or when drift lint reports stale anchors.
drift:
  files:
    - src/main.zig@uvukztro
    - src/frontmatter.zig@uvukztro
    - src/scanner.zig@uvukztro
    - src/vcs.zig@uvukztro
---

# Drift

drift binds markdown specs to code and lints for staleness.

## Why this matters for agents

When you change code without updating the specs that describe it, those specs become stale. Stale specs get loaded as context in future sessions and produce wrong code based on wrong descriptions. This compounds — each session that trusts a stale spec makes things worse. drift makes the anchor explicit and enforceable so this feedback loop breaks.

## After you change code

Check if any specs reference the files you touched:

```bash
drift lint
```

If a spec is stale because of your change:
1. Update the spec's prose to reflect what you changed
2. Refresh provenance: `drift link <spec-path> <file-you-changed>`
3. Verify: `drift lint`

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

If a bound file is deleted or renamed, `drift lint` will report it as STALE with "file not found". Remove the stale anchor:

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

Refactors that move code between files or rename symbols can break multiple specs at once. Run `drift lint` after refactoring to find all affected specs, then update each one.

## When drift lint fails in CI

Someone changed bound code without updating specs. Read the lint output to see which specs are stale and why, update the spec prose, then `drift link` to refresh provenance.

## Anchor syntax

Frontmatter:
```yaml
drift:
  files:
    - src/auth/login.ts              # file-level
    - src/auth/provider.ts#AuthConfig # symbol-level (AST node)
    - src/auth/login.ts@abc123       # with provenance
```

Inline (in spec body):
```markdown
The auth flow uses @./src/auth/provider.ts#AuthConfig for validation.
```

`drift link` stamps both frontmatter and inline anchors with provenance.

## Staleness

`drift lint` exits 1 if any anchor is stale. Reasons:
- **changed after spec** — file/symbol content differs from provenance snapshot
- **file not found** — bound file no longer exists
- **symbol not found** — bound symbol no longer exists in the file
