# Concurrency Advanced (Interruption, Supervision, FiberRef)

Use this guide when coordinating fibers beyond simple forking.

## Mental model

- Interruption is cooperative; attach cleanup with `Effect.onInterrupt`.
- Supervisors and scopes keep child fibers bound to a lifetime.
- `FiberRef` provides fiber-local state.

## Patterns

- Use `Effect.forkScoped` to tie a fiber to a scope.
- Use `Fiber.interrupt` and `Fiber.join` to manage lifetimes.
- Use `FiberRef.make` + `FiberRef.get`/`set` for context-like state.

## Walkthrough: fiber-local state

```ts
import * as Effect from "effect/Effect";
import * as FiberRef from "effect/FiberRef";

const program = Effect.gen(function* () {
  const ref = yield* FiberRef.make(0);
  yield* FiberRef.set(ref, 1);
  return yield* FiberRef.get(ref);
});
```

## Pitfalls

- Detaching fibers without a scope.
- Assuming interruption is preemptive.
