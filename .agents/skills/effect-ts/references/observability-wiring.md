# Observability Wiring (Layers and Runtime)

Use this guide when wiring logging, metrics, or tracing into an app.

## Patterns

- Provide loggers at the edge.
- Provide tracing layers before running effects.
- Keep exporters in layers.

## Walkthrough: tracing layer

```ts
import * as Effect from "effect/Effect";
import * as NodeSdk from "@effect/opentelemetry/NodeSdk";
import { InMemorySpanExporter, SimpleSpanProcessor } from "@opentelemetry/sdk-trace-base";

const TracingLive = NodeSdk.layer(
  Effect.sync(() => ({
    resource: { serviceName: "app" },
    spanProcessor: [new SimpleSpanProcessor(new InMemorySpanExporter())],
  })),
);

const program = Effect.withSpan("work")(Effect.void).pipe(Effect.provide(TracingLive));
```
