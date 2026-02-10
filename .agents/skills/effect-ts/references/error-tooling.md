# Error Tooling (Cause and Sandboxing)

Use this guide when you need to inspect or manipulate failures.

## Mental model

- The error channel contains expected errors only.
- `Cause` captures expected failures, defects, and interruptions.
- Sandboxing exposes defects as `Cause` so you can inspect everything.

## Patterns

- Use `Effect.sandbox` to move defects into the error channel as `Cause`.
- Use `Effect.catchAllCause` to handle failures and defects together.
- Use `Cause.pretty` for diagnostics.
- Use `Effect.unsandbox` to restore defects after inspection.

## Walkthrough: inspect a defect

1. Sandbox the effect to capture defects.
2. Handle the `Cause` and render it for logging/metrics.

```ts
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";

const program = Effect.sync(() => {
  throw new Error("boom");
}).pipe(
  Effect.sandbox,
  Effect.catchAllCause((cause) => Effect.succeed(Cause.pretty(cause))),
);
```

## Pitfalls

- Dropping `Cause` information during recovery.
- Treating defects as recoverable business errors.
