# CLAUDE.md

@.fp/FP_CLAUDE.md

## Stack

- Language: Zig 0.15.2
- C interop: tree-sitter (vendor/tree-sitter + vendor/zig-tree-sitter, parsed on demand)
- Grammars: lazy zig build deps (not vendored)
- CLI: zig-clap 0.11.0
- VCS: shell out to git/jj (no libgit2)
- Hashing: std.hash.XxHash3 for content comparison

## Architecture

drift binds markdown specs to code and lints for staleness. No daemon, no index, no cache. Every `drift lint` run is stateless: read specs, parse referenced files on demand, hash symbols, query VCS, report.

Reference: docs/DESIGN.md, docs/DECISIONS.md, docs/CLI.md

## Zig Conventions

- Arena allocator per command lifecycle
- DebugAllocator in Debug builds for leak detection
- File-is-the-struct pattern (Ghostty convention)
- Every `try alloc` except the last needs `errdefer free`
- No `anyerror` in public APIs — explicit error sets
- `zig fmt` enforced
- All tests use `std.testing.allocator`

## Code Patterns

- Explicit error sets, no `anyerror` in public signatures
- Tagged unions for VCS dispatch (Git | Jj)
- Comptime string maps for language detection (extension → grammar)
- Shell out for VCS operations via `std.process.Child`
- Tree-sitter queries loaded from `queries/<language>.scm` at comptime

## Adding a Language

1. Add grammar dependency to `build.zig.zon`
2. Add grammar compilation to `build.zig` grammars array
3. Add extern declaration + extension mapping in `src/parse/Language.zig`
4. Write `queries/<language>.scm` with symbol capture patterns
5. Add test fixture

## Adding a Command

1. Create `src/commands/<name>.zig` with zig-clap params
2. Add to SubCommand enum in `src/main.zig`
3. Add dispatch case in main switch
4. Support `--format json` for tool integration
5. Add integration test

## File Naming

- `PascalCase.zig` for struct files (file-is-the-struct)
- `snake_case.zig` for non-struct modules
- `queries/<language>.scm` for tree-sitter queries

## Testing

- `zig build test` runs all tests
- Integration tests in `test/integration/`
- All tests use `std.testing.allocator` (auto leak detection)
- Test fixtures per language in `test/fixtures/`
