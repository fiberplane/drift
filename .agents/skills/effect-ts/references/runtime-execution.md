# Running Effects (Runtime Execution)

Use this guide when deciding how/where to run effects.

## Mental model

- Effects are descriptions; `run*` executes them.
- Keep `run*` calls at the edge (CLI entrypoints, server bootstrap, tests).
- Choose a runner based on sync/async and whether you need `Exit`.

## Patterns

- Use `Effect.runPromise` for async execution.
- Use `Effect.runSync` only for fully synchronous effects.
- Use `Effect.runFork` for background fibers.
- Use `Effect.runPromiseExit` / `Effect.runSyncExit` when you need `Exit`.

## Walkthrough: run and inspect Exit

```ts
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";

const program = Effect.fail("boom");

Effect.runPromiseExit(program).then((exit) =>
  Exit.match(exit, {
    onFailure: () => console.log("failed"),
    onSuccess: (value) => console.log(value),
  }),
);
```

## Pitfalls

- Calling `run*` in library code (breaks composability).
- Using `runSync` on async effects.
- Dropping `Exit` when you need failure details.
