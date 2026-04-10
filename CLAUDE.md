# CLAUDE.md

@.fp/FP_CLAUDE.md

## Stack

- Language: Zig 0.15.2
- C interop: tree-sitter (vendor/tree-sitter + vendor/zig-tree-sitter, parsed on demand)
- Grammars: lazy zig build deps (not vendored)
- CLI: zig-clap 0.11.0
- VCS: shell out to git (jj support disabled until jj-native forges exist)
- Hashing: std.hash.XxHash3 for content comparison

## Architecture

drift binds markdown docs to code and lints for staleness. No daemon, no index, no cache. Every `drift lint` run is stateless: read docs, parse referenced files on demand, hash symbols, extract and check markdown links, query VCS, report.

Reference: docs/DESIGN.md, docs/DECISIONS.md, docs/CLI.md, docs/RELEASING.md

## Zig Conventions

- Two arenas per command: `run_arena` for command-lifetime data, `scratch_arena` for per-item temporaries (reset between iterations). GPA only in `main()`. See docs/DECISIONS.md §12.
- Stack buffers for fixed-width formatting (fingerprint hex, small `bufPrint` targets)
- Only OS/C resources get explicit `deinit()` — arena-backed data structs do not own memory
- DebugAllocator in Debug builds for leak detection
- File-is-the-struct pattern (Ghostty convention)
- No `anyerror` in public APIs — explicit error sets
- `zig fmt` enforced
- All tests use `std.testing.allocator`

## Code Patterns

- Explicit error sets, no `anyerror` in public signatures
- Tagged unions for VCS dispatch (Git | Jj)
- Comptime string maps for language detection (extension → grammar)
- Shell out for VCS operations via `std.process.Child`
- Tree-sitter queries loaded from `src/queries/<language>.scm` at comptime

## Adding a Language

1. Add grammar dependency to `build.zig.zon`
2. Add grammar compilation to `build.zig` grammars array
3. Add extern declaration + extension mapping in `src/parse/Language.zig`
4. Write `src/queries/<language>.scm` with symbol capture patterns
5. Add test fixture

Markdown is a supported language with a two-grammar architecture: block grammar for document structure (`section`, `atx_heading`) and inline grammar for link extraction (`inline_link`). Both grammars are separate `ts.Language` instances compiled from `tree-sitter-markdown`.

## Adding a Command

1. Create `src/commands/<name>.zig` with a `pub fn run(...)` entry point
2. Add clap params and SubCommand variant in `src/main.zig`
3. Add dispatch case in main switch, calling `<name>.run(...)`
4. Support `--format json` for tool integration
5. Add integration test

## File Naming

- `PascalCase.zig` for struct files (file-is-the-struct)
- `snake_case.zig` for non-struct modules
- `src/queries/<language>.scm` for tree-sitter queries

## Testing

- `zig build test` runs all tests
- Integration tests in `test/integration/`
- All tests use `std.testing.allocator` (auto leak detection)
- Test fixtures per language in `test/fixtures/`
