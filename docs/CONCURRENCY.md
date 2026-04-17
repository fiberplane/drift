# Concurrency

drift uses Zig 0.16's `std.Io` interface throughout. Every file read, subprocess spawn, and path resolution flows through an `Io` instance threaded from `std.process.Init` in `main` down through `CommandContext` to every command.

This design makes it straightforward to parallelize CPU- and I/O-bound work without changing the control flow of individual functions. Below is what's done today and what remains as viable follow-up.

## Implemented: per-doc parallelism (`Io.Group`)

`drift check` wraps the per-doc loop in `src/commands/lint.zig` in an `Io.Group`. Each doc's binding checks (file read → tree-sitter parse → hash → optional `git log` for blame) run as independent tasks on the thread pool backing `Io.Threaded`.

Key design constraints:

- **Task-local `CommandContext`.** Each task builds its own `std.heap.ArenaAllocator` (child of `run_arena`) so `ctx.scratch()` / `ctx.resetScratch()` inside `checkBinding`, `checkDocLinks`, and `classifyRelativeLink` continue to work unchanged.
- **Task-local `FileCache`.** `std.StringHashMap` is not thread-safe. Each task gets its own cache. Docs rarely share files across each other, so the lost hit rate is small and not worth a mutex.
- **Pre-allocated result slots.** `results: []?DocCheckResult` is allocated once from `run_arena`. Tasks write their own slot; the main thread merges in doc-order (docs are already sorted by `discoverDocGroups`) so output stays deterministic.
- **Error handling.** `Io.Group.async` tasks cannot propagate errors back to the caller. A `checkOneDoc` wrapper catches errors and stores them as `error_message: ?[]const u8` on the result. The main thread prints and translates to `error.LintCheckFailed` during merge.

Local measurement on the drift repo itself: ~0.40 s → ~0.14 s (≈3×).

## Proposed: speculative blame via `io.async`

When a binding turns stale, `checkBinding` shells out to `git log` for blame info (`vcs.getLatestBlameInfo`). Today this is serial inside each task. Starting the blame query speculatively *before* the fingerprint comparison finishes removes its latency from the stale path:

```zig
var blame_future = io.async(vcs.getLatestBlameInfo, .{ ... });
defer if (blame_future.cancel(io)) |_| {} else |_| {};

// ... compute fingerprint ...
if (is_fresh) return .{ .result = .fresh, ... };  // cancel fires on defer
const blame = try blame_future.await(io);
return .{ .result = .stale, .blame = blame, ... };
```

`io.async` is infallible on `Io.Threaded` (it runs inline on `Io.failing`), so the code reads the same on both backends. Cost: wasted work on fresh anchors. A `git log -1` against a single path is cheap; the tradeoff favours the stale path since that's what blocks the user.

## Proposed: `Io.Batch` for link-existence checks

`checkDocLinks` in `src/commands/lint.zig` resolves each markdown link in a doc one at a time and calls `pathExists` (`accessAbsolute`) on each target. For docs with dense cross-links this is many sequential stat syscalls.

`Io.Batch` is the low-level batching primitive (one layer below `Io.Group`) and supports stat-style operations:

```zig
var batch: Io.Batch = .init;
for (parsed.links.items) |link| batch.stat(io, absolute);
try batch.await(io);
```

On Linux with `Io.Uring` this becomes a single submission; on `Io.Threaded` it falls back to parallel thread-pool stats. Modest win on dense docs, larger win under `Io.Uring` once that backend stabilizes.

## Proposed: overlap startup shell-outs

At the top of `lint.run`, `discoverDocGroups` calls `git ls-files` and `getRepoIdentity` calls `git remote get-url origin` back-to-back. Both take separate allocators and are trivially independent:

```zig
var identity_future = io.async(vcs.getRepoIdentity, .{ ctx.run_arena, ctx.scratch(), cwd_path });
var doc_groups = try discoverDocGroups(...);
const repo_identity = identity_future.await(io) catch null;
```

Saves a few ms per run. Small absolute win, but free — both calls are already `io`-aware.

## Proposed: rework `GitCatFile` with `Io.Group`

`GitCatFile` (`src/vcs.zig`) keeps a persistent `git cat-file --batch` process alive to avoid spawn overhead for historical file reads. Today request/response is synchronous. Running request submission and response parsing as two concurrent tasks inside an `Io.Group` would let the next request go out while the current response is still being read — useful only if we shift to a use case that issues many queries, which today we don't.

Noting it as a shape that 0.16 now permits; not a priority.

## What not to parallelize

- **Writes to `stdout_w` / `stderr_w`.** The writers are single-threaded and the output order matters. All user-facing output happens on the main thread, after `group.await`.
- **`stderr` from inside tasks.** Errors are stored on the result and printed centrally — do not call `stderr_w.print(...)` from a task.
- **VCS spawn storms.** `Io.Threaded` bounds the thread pool, so we're unlikely to overload `git` — but if future work fans out to hundreds of concurrent `git log` calls, revisit this.

## Backends

All of the above runs unchanged on any `Io` implementation. Today drift uses `Io.Threaded` (the only feature-complete backend in 0.16). `Io.Uring` (Linux), `Io.Kqueue` (BSD/macOS), and `Io.Dispatch` (macOS) are proof-of-concept in 0.16 and will become interesting for `Io.Batch` work once they stabilize.
