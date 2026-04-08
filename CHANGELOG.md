# Changelog

All notable changes to this project will be documented in this file.

## [0.7.0] - 2026-04-08

### Features

- Drift.lock lockfile, refs command, --changed flag (#17) (8f0d655)
- Drift check --format json (drift.check.v1) (#16) (807c460)

## [0.6.2] - 2026-04-01

### Bug Fixes

- Increase max_output_bytes for git ls-files in scanner (058b798)

## [0.6.1] - 2026-03-31

### Refactor

- Extract command modules from main.zig into src/commands/ (54a514a)

## [0.6.0] - 2026-03-31

### Documentation

- Document origin-qualified anchors in README and SKILL.md (#14) (b520e99)
- Update README and SKILL.md for v0.5.0 (#13) (ebfeeb9)

### Features

- Origin-qualified anchors for cross-repo specs (#11) (e2f9916)

## [0.5.0] - 2026-03-30

### Features

- Content-addressed provenance with sig: prefix (#12) (963bd07)
- Trigger homebrew tap sync after releases (#6) (f600f31)

## [0.4.2] - 2026-03-26

### Bug Fixes

- Inject release version into drift binary (#5) (fc1142a)

## [0.4.1] - 2026-03-25

### Bug Fixes

- Harden CLI correctness and anchor handling (ea30340)

### Documentation

- Relink drift anchors after scanner refactor (7020701)
- Update skill with drift check, review-before-relink rule, blame info (8cf9f9c)
- Fix README install section and restore logo (650a5f6)
- Tighten README install section, add anchor anatomy diagram (a054656)

### Refactor

- Use git ls-files for spec discovery instead of hardcoded skip list (d7d189a)
- Move queries to src/queries, replace symlink with @embedFile (bd70482)

## [0.4.0] - 2026-03-24

### Documentation

- Relink drift anchors to new HEAD (137c516)
- Update README with drift check, blame output, agent skill wording (982ee91)

### Features

- Add git blame info to stale anchor reports (c726b5d)

## [0.3.6] - 2026-03-23

### Features

- Publish release checksums and verify installer downloads (#1) (148c1dd)

## [0.3.5] - 2026-03-17

### Bug Fixes

- Ignore formatting-only drift in syntax-aware checks (c258b58)

### Documentation

- Relink drift anchors to pushed parent (a23d107)
- Relink drift anchors for syntax-aware checks (3bdac98)
- Relink stale jj anchors to git SHAs (6c0cfb0)

## [0.3.4] - 2026-03-16

### Bug Fixes

- Disable jj VCS detection, always use git (8dc8010)

## [0.3.3] - 2026-03-04

### Bug Fixes

- Disable UBSan for vendored C code in ReleaseSafe builds (5163722)

## [0.3.2] - 2026-03-04

### Bug Fixes

- Define NDEBUG for tree-sitter C code in ReleaseSafe builds (22566b9)

## [0.3.1] - 2026-03-04

### Bug Fixes

- Relink drift anchors after workflow changes (62b52ff)
- Use baseline CPU for x86_64-linux to avoid illegal instruction on CI runners (e0dc4eb)

## [0.3.0] - 2026-03-04

### Features

- Add check command as alias for lint (5dde802)

## [0.2.0] - 2026-03-03

### Bug Fixes

- Relink RELEASING.md after cliff.toml change (b438932)
- Filter non-conventional commits from changelog (781270c)

### Documentation

- Rename binding→anchor in all user-facing language (69b5a86)
- Rename binding→anchor in all user-facing language (0e06d09)
- Mention mise activate in development setup (0cb3eb0)
- Add development setup section to README (4a16511)
- Remove stale lore references from DECISIONS.md (9737c65)
- Fix tag push commands in RELEASING.md (af6cd92)

## [0.1.0] - 2026-03-03

### Documentation

- Add initial CHANGELOG.md for v0.1.0 (a565856)

### Features

- Switch to git-cliff and conventional commits for releases (8c13043)

### Refactor

- Split main.zig into frontmatter, scanner, symbols, and vcs modules (a396903)

