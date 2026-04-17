# Concurrency

drift uses Zig 0.16's `std.Io` interface throughout. Every file read, subprocess spawn, and path resolution flows through an `Io` instance threaded from `std.process.Init` in `main` down through `CommandContext` to every command.

This design makes it straightforward to parallelize CPU- and I/O-bound work without changing the control flow of individual functions. The work below is all implemented in `src/commands/lint.zig`.

## Layer 1: per-doc parallelism (`Io.Group`)

`drift check` wraps the per-doc loop in `src/commands/lint.zig` in an `Io.Group`. Each doc's binding checks (file read → tree-sitter parse → hash → optional `git log` for blame) run as independent tasks on the thread pool backing `Io.Threaded`.

Key design constraints:

- **Task-local `CommandContext`.** Each task builds its own `std.heap.ArenaAllocator` (child of `run_arena`) so `ctx.scratch()` / `ctx.resetScratch()` inside `checkBinding` continue to work unchanged.
- **Task-local `FileCache`.** `std.StringHashMap` is not thread-safe. Each task gets its own cache. Docs rarely share files across each other, so the lost hit rate is small and not worth a mutex.
- **Pre-allocated result slots.** `results: []?DocCheckResult` is allocated once from `run_arena`. Tasks write their own slot; the main thread merges in doc-order (docs are already sorted by `discoverDocGroups`) so output stays deterministic.
- **Error handling.** `Io.Group.async` tasks cannot propagate errors back to the caller. A `checkOneDoc` wrapper catches errors and stores them as `error_message: ?[]const u8` on the result. The main thread prints and translates to `error.LintCheckFailed` during merge.

## Layer 2: per-binding parallel blame (`io.async`)

`checkBinding` is CPU-bound (tree-sitter parse + fingerprint). It no longer shells out to `git log` for blame; instead it reports `.result = .stale, .reason_code = .changed_after_baseline` with `blame = null`. A second phase inside `checkOneDocInner` iterates over the anchor rows, and for each `changed_after_baseline` entry fires `io.async(vcs.getLatestBlameInfo, …)`, collecting the futures. A follow-up loop awaits each future and fills in the blame info.

Two properties matter:

- **No wasted work on fresh anchors.** Blame queries are only fired after we know a binding is stale, so the common case (all anchors fresh) pays nothing extra. An earlier proposal to fire blame *speculatively* before the staleness check was rejected because `git log -1` is ~20 ms — more than the ~5 ms staleness check — so speculation would slow down the common case.
- **Scales with stale count.** A doc with 5 stale anchors previously ran 5 sequential `git log` calls (~100 ms). Now they execute concurrently on the thread pool (~25 ms on a 4-core machine).

Subprocess buffers for blame queries use `run_arena` (thread-safe, lives until the run ends) rather than the task-local scratch arena, because the task-local scratch is reset between bindings in phase 1 and the blame futures outlive that reset.

## Layer 3: per-link parallel existence checks (`Io.Group`)

`checkDocLinks` previously walked each markdown link serially, doing `realPathFileAlloc` + `accessAbsolute` per link. Now each link is a task in a per-doc `Io.Group`; results fill a pre-allocated `?JsonLinkRow` slot array that's stable across parallel writes. After `group.await`, slots are appended to `out` in doc-order so output is deterministic.

For docs with dense cross-links this collapses N sequential stats into a single pool round-trip.

**Note on `Io.Batch`.** An earlier proposal used `Io.Batch`, which is the lower-level primitive below `Io.Group`. As of Zig 0.16, `Io.Batch.Operation` only supports `file_read_streaming`, `file_write_streaming`, `device_io_control`, and `net_receive` — no stat/access operation. If stdlib adds one, link checks could migrate to `Io.Batch` for better coalescing under `Io.Uring` specifically. On `Io.Threaded` (current backend) `Io.Group` is functionally equivalent.

## Layer 4: overlapped startup (`io.async`)

At the top of `lint.run`, `discoverDocGroups` (shells out to `git ls-files`) and `vcs.getRepoIdentity` (shells out to `git remote get-url origin`) are both independent subprocess calls. `getRepoIdentity` is now spawned as an `io.async` future before `discoverDocGroups` runs; the two `git` processes execute in parallel and we await the identity right after ls-files returns.

Saves a few ms per run. Small absolute win, but free — both calls are already `io`-aware.

## Measurements

Benchmarks via `hyperfine --warmup 3 --runs 20+` on an M-series Mac, `-Doptimize=ReleaseSafe` builds at the three points: sequential (main before #24), layer 1 only (main after #24), all four layers (after #26).

### Small repo — drift itself (10 docs, 19 anchors, ~6 links)

Fresh steady-state (no stale anchors):

| Variant | Mean | vs sequential |
|---|---:|---:|
| sequential | 64.6 ± 2.4 ms | 1.00× |
| layer 1 only | 34.6 ± 3.4 ms | 1.87× |
| layers 1-4 | 26.4 ± 1.5 ms | **2.45×** |

All 19 anchors forced stale (worst-case blame load):

| Variant | Mean | vs sequential |
|---|---:|---:|
| sequential | ~280 ms | 1.00× |
| layer 1 only | 103.3 ± 3.2 ms | ~2.7× |
| layers 1-4 | 78.3 ± 12.7 ms | **~3.6×** |

### Large repo — nocturne monorepo (247 docs, 107 anchors)

Fresh steady-state:

| Variant | Mean | vs sequential |
|---|---:|---:|
| sequential | 1.426 ± 0.036 s | 1.00× |
| layer 1 only | 468.6 ± 65.0 ms | 3.04× |
| layers 1-4 | 424.3 ± 35.0 ms | **3.36×** |

All 107 anchors forced stale:

| Variant | Mean | vs sequential |
|---|---:|---:|
| sequential | 2.876 ± 0.053 s | 1.00× |
| layer 1 only | 914.7 ± 132.8 ms | 3.14× |
| layers 1-4 | 672.1 ± 26.9 ms | **4.28×** |

### Reading the numbers

- **Layer 1 is the largest win** and scales with doc count: 1.87× on a 10-doc repo, 3.04× on a 247-doc repo.
- **Layer 2 (parallel blame) is a 1.32–1.36× multiplier when many anchors are stale** (`git log` runs serialize inside a doc before layer 2, parallelize after). On fresh runs it costs nothing because blame is only fired once staleness is confirmed — not speculatively.
- **Layer 3 (parallel link checks)** fires independently of staleness; on drift's repo with 6 links it's in the noise, on nocturne with 112 links it accounts for part of the 1.1× on top of layer 1 in the fresh case.
- **Layer 4 (overlapped startup)** saves one `git remote` subprocess latency (~10–20 ms) and is free.

Combined, on the large-repo stale worst case, the pipeline went from **2.88 s to 672 ms (4.28×)**.

## What not to parallelize

- **Writes to `stdout_w` / `stderr_w`.** The writers are single-threaded and the output order matters. All user-facing output happens on the main thread, after `group.await`.
- **`stderr` from inside tasks.** Errors are stored on the result and printed centrally — do not call `stderr_w.print(...)` from a task.
- **VCS spawn storms.** `Io.Threaded` bounds the thread pool, so we're unlikely to overload `git` — but if future work fans out to hundreds of concurrent `git log` calls, revisit this.

## Backends

All of the above runs unchanged on any `Io` implementation. Today drift uses `Io.Threaded` (the only feature-complete backend in 0.16). `Io.Uring` (Linux), `Io.Kqueue` (BSD/macOS), and `Io.Dispatch` (macOS) are proof-of-concept in 0.16 and will become interesting for layer 3 specifically once `Io.Batch` grows a stat operation.

## Proposed but not implemented

**Rework `GitCatFile` with `Io.Group`.** `src/vcs.zig` keeps a persistent `git cat-file --batch` process alive to avoid spawn overhead for historical file reads. Running request submission and response parsing as two concurrent tasks inside an `Io.Group` would let the next request go out while the current response is still being read — useful only if we shift to a use case that issues many queries, which today we don't.
