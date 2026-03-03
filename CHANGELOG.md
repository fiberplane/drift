# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-03

Initial release. Complete rewrite in Zig from the original TypeScript/Effect prototype.

### Features

- Bind markdown specs to code files and AST symbols via YAML frontmatter or `<!-- drift: -->` HTML comments
- `drift lint` — check all specs for staleness, exit 1 if any are stale
- `drift status` — show all specs and their anchors
- `drift link` — add or refresh anchors with auto-provenance stamping
- `drift unlink` — remove an anchor from a spec
- Symbol-level anchors (`file.ts#SymbolName`) via tree-sitter — changes elsewhere in the file don't trigger staleness
- Inline `@./path` references in spec body, parsed and tracked alongside frontmatter anchors
- Content-based staleness detection — compares file/symbol content at provenance revision vs current
- Per-anchor provenance via `@change` suffix — each anchor tracks independently
- git and jj VCS support, auto-detected from `.jj` or `.git`
- 6 languages supported: TypeScript, Python, Rust, Go, Zig, Java
- GitHub Action (`fiberplane/drift@main`) for CI integration
- `--format json` output for tool integration
- Claude Code skill for agent-assisted spec maintenance

### Architecture

- Single static binary, no runtime dependencies
- Stateless — no index, no cache, no daemon. Every lint run starts clean.
- On-demand tree-sitter parsing — only bound files are parsed
- Cross-compiled for aarch64-macos, x86_64-macos, x86_64-linux, aarch64-linux
