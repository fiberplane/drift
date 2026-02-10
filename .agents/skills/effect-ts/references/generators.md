# Generators (Effect.gen)

Use this guide when sequential logic would be clearer than pipelines.

## Mental model

- `Effect.gen` is async/await-style control flow for Effects.
- `yield*` extracts values from effects in order.
- The error channel short-circuits just like thrown errors in async/await.

## Patterns

- Prefer generators for multi-step workflows and branching.
- Keep small effects for each step and compose with `yield*`.
- Use `Effect.catchAll` or `Effect.catchTag` at the boundary for recovery.

## Walkthrough: sequential flow with branching

```ts
import * as Effect from "effect/Effect";

const lookup = (id: string) => (id === "guest" ? Effect.succeed({ id }) : Effect.fail("not found"));

const program = Effect.gen(function* () {
  const user = yield* lookup("guest");

  if (user.id === "guest") {
    return "welcome";
  }

  return "hello";
}).pipe(Effect.catchAll(() => Effect.succeed("fallback")));
```

## Pitfalls

- Nesting generators unnecessarily instead of extracting helpers.
- Throwing exceptions in generators instead of failing effects.
- Using `Effect.gen` when a simple pipeline is clearer.
