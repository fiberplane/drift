# Versioning Notes

Use this guide when adapting examples across Effect versions.

- Keep docs aligned to the Effect version in your package.json.
- Prefer the latest Effect major release in examples.
- Validate examples against current docs and API reference.
- Treat release notes as the source of truth for breaking changes.

## Mental model

- Examples are written against a specific Effect version; treat them as versioned APIs.
- When a type signature changes, update all dependent types consistently (Effect, Stream, Layer, Fiber, Exit, etc.).
- Prefer upgrading code to the current version rather than backporting docs.

## Walkthrough: update an older snippet to current Effect

1. Identify the Effect version the example targets.
2. Check the current signatures in the API reference and adjust types accordingly.
3. Update related types (Stream, Layer, Exit, Fiber, Pool) to match the current version.
4. Re-run TypeScript checks and fix any remaining mismatches.

## Wiring guide

- Pin `effect` to a known major/minor and keep references consistent with that version.
- Add a migration step in upgrades: update dependencies → compile → update docs.
- When sharing examples, include the minimum version (“Effect >= 3.0”) in the doc header or in the example comment.

## Pitfalls

- Copying snippets from older blogs without validating against current APIs.
- Updating Effect without updating related docs and examples.
- Ignoring changes in adjacent types (e.g., Layer/Stream) after a version bump.
