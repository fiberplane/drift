# Testing Stack (Beyond TestClock)

Use this guide when tests need more than time control.

## Mental model

- Test services are provided via `TestContext`.
- Use `TestServices` helpers to swap live services.

## Patterns

- Use `TestServices.provideWithLive` when mixing live and test services.
- Use `TestServices.live` to run an effect with live services.

## Walkthrough: provide live services

```ts
import * as Effect from "effect/Effect";
import * as TestServices from "effect/TestServices";

const program = Effect.succeed("ok");

const test = TestServices.provideWithLive(program, (live) => live);
```

## Pitfalls

- Forgetting to use `TestContext` in test environments.
