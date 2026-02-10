# Concurrency (Fibers and Forking)

Use this guide when you need concurrent execution or background work.

- Effects run on fibers, which are lightweight virtual threads managed by the Effect runtime.
- `Effect.fork` starts an effect in a child fiber supervised by its parent.
- `Effect.forkDaemon` starts a global-scope fiber that is not supervised by a parent.
- `Effect.forkScoped` starts a child fiber tied to a local scope, independent of the parent.
- `Effect.forkIn` starts a child fiber in a specific scope for precise lifetime control.

## Mental model

- Concurrency is structured: forked work should be joined, interrupted, or scoped.
- Prefer high-level combinators (`Effect.all`, `Effect.forEach`) over manual fibers.
- Use scopes to prevent background tasks from leaking.

## Walkthrough: scoped background worker

1. Define a background task (loop, polling, or queue consumer).
2. Start it with `Effect.forkScoped` inside `Effect.scoped`.
3. When the scope closes, the fiber is interrupted automatically.

```ts
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";

const worker = Effect.succeed("tick").pipe(Effect.repeat(Schedule.spaced("1 second")));

const program = Effect.scoped(
  Effect.gen(function* () {
    yield* Effect.forkScoped(worker);
    return "worker running";
  }),
);
```

## Wiring guide

- Use `Effect.all` or `Effect.forEach` with `concurrency` for bounded parallelism.
- Use `Effect.forkScoped` inside Layers or `Effect.scoped` blocks for background services.
- Prefer `Fiber.join` to observe errors; use `Fiber.interrupt` for shutdown.

## Pitfalls

- Forking without join/interrupt (leaks fibers).
- Unbounded parallelism that overwhelms downstream systems.
- Ignoring interruptions for long-running effects.

## Example

```ts
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";

const program = Effect.gen(function* () {
  const fiber = yield* Effect.fork(Effect.succeed(1));
  return yield* Fiber.join(fiber);
});
```
