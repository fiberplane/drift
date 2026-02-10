# Configuration Advanced

Use this guide when config needs structure, secrets, or test overrides.

## Mental model

- Nest config to keep naming consistent across providers.
- Redact secrets so they can be logged safely.
- Providers can be swapped per scope for tests.

## Patterns

- Use `Config.nested` to model trees.
- Use `Config.redacted` for secrets.
- Use `ConfigProvider.fromMap` for tests.

## Walkthrough: nested config with redacted secret

```ts
import * as Config from "effect/Config";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";

const DatabaseConfig = Config.all({
  url: Config.string("URL"),
  password: Config.redacted("PASSWORD"),
}).pipe(Config.nested("DB"));

const provider = ConfigProvider.fromMap(
  new Map([
    ["DB.URL", "postgres://localhost/app"],
    ["DB.PASSWORD", "secret"],
  ]),
);

const program = provider.load(DatabaseConfig).pipe(
  Effect.map((config) => ({
    url: config.url,
    password: config.password,
  })),
);
```

## Pitfalls

- Logging secrets without redaction.
- Mixing nested and flat keys inconsistently.
