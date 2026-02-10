# Testing (TestClock)

Use this guide when tests depend on time.

## Mental model

- `TestClock` controls time in tests.
- Adjusting the clock triggers scheduled effects.

## Patterns

- Fork the effect under test, then adjust time.
- Provide `TestContext.TestContext` to enable TestClock.

## Walkthrough: test a delay

```ts
import * as Effect from "effect/Effect";
import * as TestClock from "effect/TestClock";
import * as TestContext from "effect/TestContext";

const program = Effect.gen(function* () {
  yield* Effect.sleep("5 minutes");
  return "done";
});

const test = Effect.gen(function* () {
  const fiber = yield* Effect.fork(program);
  yield* TestClock.adjust("5 minutes");
  return yield* fiber.await;
}).pipe(Effect.provide(TestContext.TestContext));
```

## Pitfalls

- Forgetting to provide `TestContext.TestContext`.
- Adjusting the clock without forking the effect.
