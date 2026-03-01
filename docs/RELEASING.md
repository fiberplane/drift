---
drift:
  files:
    - .github/workflows/release.yml@kznzovvs
---

# Releasing

Source of truth: `.github/workflows/release.yml`.

## Flow

1. Push to `main` triggers the workflow (also runnable via `workflow_dispatch`).
2. Concurrency enabled with `cancel-in-progress: true` — newer pushes cancel in-flight runs.
3. Prepares release metadata (tag, name, release notes from commit bodies).
4. Cross-compiles with Zig 0.15.2 for 4 targets: aarch64-macos, x86_64-macos, x86_64-linux, aarch64-linux.
5. Packages each as `drift-<target>.tar.gz`.
6. Creates a GitHub prerelease with all tarballs attached.

Tags follow `nightly-<run_number>` format.

## Release notes convention

Release notes come from commit **bodies** only (never subjects). Only content under a `## RN:` or `## RN` heading is included. The section ends at the next H2 heading. Trailers (`Key: value` at end of body) are stripped.

Dedupe uses optional `RN-ID: <stable-id>` in commit bodies — jj-friendly since change IDs aren't stable across rewrites. If no RN sections found, the release body says so.

### Example commit message

```text
feat: add python symbol resolution

Details not included in release notes.

## RN:
- Add Python support for symbol-level bindings
RN-ID: python-symbols

Co-authored-by: Someone <x@y.z>
```

Included: the two bullet points. Excluded: everything outside `## RN:`, trailers, and the `RN-ID:` line itself.
