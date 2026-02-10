# Troubleshooting (Common Errors and Fixes)

Use this guide when a task fails or produces confusing runtime behavior.

## Common issues

- Effect never runs: missing `run*` at the edge.
- Missing services: provide required layers.
- Async used with `runSync`: yields AsyncFiberException.
- Fiber leaks: fork without scope/join.

## Diagnostics

- Inspect the effect type `Effect<A, E, R>`.
- Use `Effect.sandbox` + `Cause.pretty` to see defects.
- Use `Effect.tap`/`Effect.log` to observe intermediate values.

## Example

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
