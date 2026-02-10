# Configuration (Config and ConfigProvider)

Use this guide when loading or validating runtime configuration.

## Mental model

- `Config` describes structure and types.
- A `ConfigProvider` supplies values (env by default).
- Config is loaded by running effects.

## Patterns

- Use `Config.all` to build structured config.
- Use `Config.withDefault` for optional values.
- Use `ConfigProvider.fromEnv` or `fromMap` for overrides.

## Walkthrough: structured config from env

```ts
import * as Config from "effect/Config";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";

const AppConfig = Config.all({
  host: Config.string("HOST"),
  port: Config.port("PORT").pipe(Config.withDefault(3000)),
  timeout: Config.duration("TIMEOUT").pipe(Config.withDefault("30 seconds")),
});

const provider = ConfigProvider.fromEnv();

const program = provider
  .load(AppConfig)
  .pipe(Effect.tap((config) => Effect.log(`host=${config.host}`)));
```

## Pitfalls

- Reading config inside libraries instead of at startup.
- Using untyped strings for structured config.
- Expecting `withDefault` to cover parse errors (it only applies when the value is missing).
- Nested keys depend on provider delimiters (configure `fromEnv`/`fromMap` accordingly).
