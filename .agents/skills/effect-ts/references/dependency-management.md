# Dependency Management (Services, Context, Layers)

Use this guide when modeling dependencies and wiring services.

- **Service**: a dependency represented by a TypeScript interface.
- **Tag**: a typed identifier that points to a service instance.
- **Context**: a map of tags to concrete service implementations.
- **Layer**: the abstraction for constructing services and managing their dependencies during construction.

## Patterns

- Define services via `Context.Tag` when you want a custom shape.
- Use `Effect.Service` for the common pattern where you want a service class plus an auto-generated tag, accessors, and a default layer.
- Use `Layer.succeed` for pure values and `Layer.effect`/`Layer.scoped` when construction is effectful.
- Keep construction concerns (resource acquisition, config, wiring) inside layers so service interfaces stay clean.
- Compose layers with `Layer.merge`/`Layer.provide` to build dependency graphs and provide the environment at program startup.

## Example

```ts
import * as Effect from "effect/Effect";
import * as Context from "effect/Context";
import * as Layer from "effect/Layer";

interface Config {
  readonly prefix: string;
}

const Config = Context.Tag<Config>("Config");

class Greeter extends Effect.Service<Greeter>()("Greeter", {
  effect: Effect.gen(function* () {
    const config = yield* Config;
    return {
      greet: (name: string) => `${config.prefix} ${name}`,
    };
  }),
}) {}

const Live = Layer.merge(Layer.succeed(Config, { prefix: "PRE" }), Greeter.Default);

const program = Greeter.use((g) => g.greet("Ada")).pipe(Effect.provide(Live));
```
