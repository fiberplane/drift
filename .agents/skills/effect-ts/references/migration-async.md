# Migration from Promise/async

Use this guide when converting Promise or async/await code to Effect.

- Promises are eager and single-shot; Effects are lazy and can be re-run.
- Effects model errors, interruption, and structured concurrency explicitly.
- Replace async/await flows with `Effect.gen` for similar readability.
- Replace `Promise.all` with `Effect.all` and choose concurrency options.
- Run effects at the boundary with `Effect.runPromise` (or other run\* variants).

## Mental model

- A Promise _does_ work immediately; an Effect _describes_ work and runs at the edge.
- Effects carry typed errors and required dependencies.
- Migration is mostly mechanical: wrap Promise APIs, then rewrite control flow.

## Walkthrough: convert async/await to Effect.gen

1. Replace `async` functions with `Effect.gen` blocks.
2. Wrap Promise-returning APIs with `Effect.tryPromise` (or `Effect.promise` for non-throwing).
3. Use `Effect.all` for parallelism and set `concurrency` when needed.
4. Run the Effect at the app boundary with `Effect.runPromise`.

```ts
import * as Effect from "effect/Effect";

const fetchUser = (id: string) =>
  Effect.tryPromise({
    try: () => fetch(`/users/${id}`).then((r) => r.json()),
    catch: (cause) => new Error(String(cause)),
  });

const fetchTeam = (id: string) =>
  Effect.tryPromise({
    try: () => fetch(`/teams/${id}`).then((r) => r.json()),
    catch: (cause) => new Error(String(cause)),
  });

const program = Effect.gen(function* () {
  const [user, team] = yield* Effect.all([fetchUser("user-1"), fetchTeam("team-1")], {
    concurrency: 2,
  });

  return { user, team };
});
```

## Wiring guide

- Keep all `run*` calls at the boundary (CLI, server handler, test). Libraries should return Effects.
- Use typed errors for predictable recovery and retries.
- Prefer `Effect.gen` for sequential logic and `Effect.all`/`forEach` for parallelism.

## Pitfalls

- Calling `Effect.runPromise` inside library code (breaks composability).
- Losing error information by using `Effect.promise` where `Effect.tryPromise` is needed.
- Unbounded concurrency when replacing `Promise.all` without limits.

## Example

```ts
import * as Effect from "effect/Effect";

const program = Effect.async<number, never>((resume) => {
  resume(Effect.succeed(42));
});
```
