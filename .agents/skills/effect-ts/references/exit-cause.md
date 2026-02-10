# Exit and Cause

Use this guide when you need to inspect or report effect results.

## Mental model

- `Exit` is the result of running an effect: `Success` or `Failure`.
- A `Failure` contains a `Cause`, which captures failures, defects, and interruptions.
- Use `Exit`/`Cause` for diagnostics or reporting where you need full result data.

## Patterns

- Use `Effect.exit` to turn failures into `Exit` values.
- Use `Exit.isFailure` / `Exit.isSuccess` to branch.
- Use `Cause.pretty` to render structured failures.

## Walkthrough: render a failure cause

```ts
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";

const program = Effect.fail("boom").pipe(
  Effect.exit,
  Effect.map((exit) => (Exit.isFailure(exit) ? Cause.pretty(exit.cause) : "ok")),
);
```

## Pitfalls

- Using `Exit` when `Either` is sufficient for business logic.
- Ignoring interruptions when reporting failures.
