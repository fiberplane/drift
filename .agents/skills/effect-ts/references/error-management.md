# Error Management (Expected vs Defects)

Use this guide when modeling failures in Effect.

## Mental model

- Expected errors are typed in the error channel and should be recoverable.
- Defects represent unexpected failures (bugs, invariants) and are not typed.
- Keep domain errors explicit and local; translate them at boundaries.

## Patterns

- Use `Data.TaggedError` for error ADTs you plan to discriminate with `catchTag`.
- Use `Data.Error` for simple typed error classes when tags aren't needed.
- Use `Effect.catchTag` to handle specific error variants.
- Use `Effect.match` or `Effect.catchAll` for centralized recovery.
- Use `Effect.orDie` to convert unrecoverable failures into defects.

## Walkthrough: typed domain errors and recovery

1. Define a small error ADT with tagged errors.
2. Fail with domain errors from business logic.
3. Recover with `catchTag` at the boundary.

```ts
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";

class NotFound extends Data.TaggedError("NotFound")<{ readonly id: string }> {}
class Unauthorized extends Data.TaggedError("Unauthorized")<{}> {}

const fetchUser = (id: string) => Effect.fail(new NotFound({ id }));

const program = fetchUser("user-1").pipe(
  Effect.catchTag("NotFound", () => Effect.succeed({ id: "guest" })),
  Effect.catchTag("Unauthorized", () => Effect.fail(new Unauthorized({}))),
);
```

## Pitfalls

- Throwing exceptions instead of returning typed failures.
- Collapsing all errors into `unknown` too early.
- Mixing expected errors and defects in the same recovery path.
