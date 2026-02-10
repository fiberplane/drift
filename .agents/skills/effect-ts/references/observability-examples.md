# Observability Examples (Config and Exporters)

Use this guide for concrete setup details.

## Logging example

```ts
import * as Effect from "effect/Effect";
import * as Logger from "effect/Logger";
import * as LogLevel from "effect/LogLevel";

const program = Effect.logInfo("hello").pipe(
  Effect.provide(Logger.replace(Logger.defaultLogger, Logger.prettyLogger)),
  Logger.withMinimumLogLevel(LogLevel.Info),
);
```

## Metrics example

```ts
import * as Effect from "effect/Effect";
import * as Metric from "effect/Metric";

const counter = Metric.counter("requests");

const program = Effect.succeed(1).pipe(Metric.increment(counter));
```

## Tracing example (OpenTelemetry)

```ts
import * as Effect from "effect/Effect";
import * as OtlpTracer from "@effect/opentelemetry/OtlpTracer";

const program = OtlpTracer.make({
  url: "http://localhost:4318/v1/traces",
  resource: { serviceName: "my-service" },
}).pipe(Effect.scoped);
```
