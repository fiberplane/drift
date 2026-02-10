# Layer Patterns

Use this guide when wiring services and environments.

## Mental model

- Layers build dependency graphs and manage construction.
- Use `Layer.scoped` for resources with lifetimes.
- Provide layers at app boundaries and tests.

## Patterns

- Use `Layer.succeed` for pure values.
- Use `Layer.effect` or `Layer.scoped` for effectful acquisition.
- Combine with `Layer.merge` and provide with `Effect.provide`.

## Walkthrough: service + layer

```ts
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

class Greeter extends Effect.Service<Greeter>()("Greeter", {
  sync: () => ({ greet: (name: string) => `hi ${name}` }),
}) {}

const Live = Greeter.Default;

const program = Greeter.use((g) => g.greet("Ada")).pipe(Effect.provide(Live));
```

## Pitfalls

- Running effects in constructors instead of layers.
- Creating a fresh layer instance per use (breaks memoization).
