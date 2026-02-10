# Core Usage (Data Types and Combinators)

Use this guide for everyday Effect composition and common data types.

## Data types

- `Option` represents optional values with `Some` or `None`. Use when a value may be absent (replace null/undefined).
- `Either` represents a value that is `Right` (success) or `Left` (failure). Use for expected errors with typed failure cases.
- `Chunk` is an immutable, indexed collection for efficient sequences. Use for building collections without mutation.
- `Duration` is a typed time value for delays and schedules. Use with `Effect.sleep` and `Schedule` combinators.
- `Equal` defines structural equality for domain types. Use to compare values by content, not reference.

## Common combinators

- Use `Effect.map` to transform success values, `Effect.flatMap` to chain effects, and `Effect.tap` for side effects.
- Use `Effect.gen` for imperative-style composition with `yield*` syntax.
- Use `Effect.catchAll` or `Effect.match` to handle failures and branch on success vs error.
- Use `Effect.all` to gather multiple effects; specify `concurrency` options for parallel execution.
- Use `Effect.filterOrFail` and `Effect.filterOrElse` to refine values with failure handling.

## Guidance

- Keep effects lazy; build values first and run them at the edge with `Effect.runPromise` or `Effect.runFork`.
- Prefer small, composable effects over large monoliths.
- Use `Effect.gen` for complex workflows; use direct combinators for simple transformations.
- Handle expected errors with `Either` or `Effect.catchAll`; let defects propagate for unexpected failures.

## Example

```ts
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";
import * as Option from "effect/Option";
import * as Duration from "effect/Duration";

// Fetch user config with optional cache timeout
const fetchConfig = (userId: string) =>
  Effect.gen(function* () {
    const cached = yield* getCachedConfig(userId);

    if (Option.isSome(cached)) {
      return cached.value;
    }

    const result = yield* Effect.tryPromise({
      try: () => fetch(`/api/config/${userId}`).then((r) => r.json()),
      catch: (error) => ({ _tag: "FetchError" as const, error }),
    });

    yield* cacheConfig(userId, result).pipe(Effect.tap(() => Effect.sleep(Duration.seconds(60))));

    return result;
  });

// Handle errors with Either branching
const getConfigOrDefault = (userId: string) =>
  Effect.gen(function* () {
    const result = yield* Effect.either(fetchConfig(userId));

    return Either.match(result, {
      onLeft: () => ({ theme: "light", timeout: 30 }),
      onRight: (config) => config,
    });
  });
```
