# HTTP Client (@effect/platform)

Use this guide when making outbound HTTP requests.

## Mental model

- `HttpClient` is a service provided by a platform layer (Fetch, Node, Bun).
- Requests are built with `HttpClientRequest` and executed with `HttpClient.execute`.
- Non-2xx responses are not failures unless you filter status codes explicitly.

## Patterns

- Build requests with `HttpClientRequest.get/post` and set headers/body.
- Validate status with `HttpClientResponse.filterStatusOk` (or `HttpClient.filterStatusOk` on a client).
- Decode JSON with `HttpClientResponse.schemaBodyJson`.
- Retry with `Effect.retry` and a capped `Schedule`.

## Walkthrough: GET + status check + decode

```ts
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";
import * as Schema from "effect/Schema";
import * as HttpClient from "@effect/platform/HttpClient";
import * as HttpClientRequest from "@effect/platform/HttpClientRequest";
import * as HttpClientResponse from "@effect/platform/HttpClientResponse";

const User = Schema.Struct({
  id: Schema.Number,
  name: Schema.String,
});

const request = HttpClientRequest.get("https://api.example.com/users/1");

const program = HttpClient.execute(request).pipe(
  Effect.flatMap(HttpClientResponse.filterStatusOk),
  Effect.flatMap(HttpClientResponse.schemaBodyJson(User)),
  Effect.retry(Schedule.exponential("100 millis").pipe(Schedule.jittered, Schedule.recurs(2))),
);
```

## Wiring guide

- Provide a platform client layer such as `FetchHttpClient.layer` (web) or a Node/Bun client layer.
- Apply retries only to idempotent requests.
- Keep decoding at the boundary and return typed values to the rest of the app.

## Pitfalls

- Treating non-2xx responses as success (use status filters).
- Retrying non-idempotent requests without a dedupe token.
- Missing a platform client layer in the environment.
