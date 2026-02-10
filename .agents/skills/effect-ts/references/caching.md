# Caching (Cache, cached, cachedFunction)

Use this guide when memoizing effects or sharing computed values.

## Mental model

- `Effect.cached` memoizes a single effect result.
- `Effect.cachedFunction` memoizes a function of effects by input.
- `Cache` offers explicit storage with TTL and capacity policies.

## Patterns

- Use `Effect.cached` for a single expensive effect.
- Use `Effect.cachedFunction` for memoizing lookups by key.
- Use `Cache.make` for shared caches with TTL or size limits.

## Walkthrough: memoize a function

```ts
import * as Effect from "effect/Effect";
import * as Random from "effect/Random";

const program = Effect.gen(function* () {
  const fetchValue = (id: string) =>
    Random.nextIntBetween(1, 100).pipe(Effect.map((n) => ({ id, n })));

  const cachedFetch = yield* Effect.cachedFunction(fetchValue);

  const first = yield* cachedFetch("user-1");
  const second = yield* cachedFetch("user-1");

  return [first, second];
});
```

## Wiring guide

- Use TTL caches for volatile data; use size caps for unbounded key spaces.
- Expose caches as services via layers if many modules need them.
- Invalidate or refresh caches at boundaries (config change, deploy, etc.).

## Pitfalls

- Caching non-deterministic effects without an explicit strategy.
- Unbounded cache growth with high-cardinality keys.
- Forgetting to handle cache invalidation or TTLs.
