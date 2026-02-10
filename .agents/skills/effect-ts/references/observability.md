# Observability (Logging, Metrics, Tracing)

Use this guide when instrumenting Effect programs.

## Mental model

- Logs are structured events with levels and annotations.
- Metrics capture counts, gauges, and timings.
- Tracing uses spans to measure work across systems.

## Patterns

- Use `Effect.logInfo`/`logError` for explicit levels.
- Use `Effect.annotateLogs` and `Effect.annotateSpans` for context.
- Use `Effect.withSpan` to wrap traced work.

## Walkthrough: log + span

```ts
import * as Effect from "effect/Effect";

const program = Effect.logInfo("start").pipe(
  Effect.annotateLogs({ requestId: "req-1" }),
  Effect.withSpan("handleRequest"),
);
```

## Pitfalls

- Logging secrets without redaction.
- Creating spans without providing a tracer layer.
