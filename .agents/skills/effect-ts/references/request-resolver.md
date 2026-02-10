# Requests and Resolvers (Request / RequestResolver)

Use this guide when you need request batching, caching, or data loader patterns.

## Mental model

- A `Request<Success, Error>` describes a fetchable value.
- A `RequestResolver` batches and resolves many requests efficiently.
- `Effect.request` connects a request to a resolver.

## Patterns

- Define requests with `Request.TaggedClass` or `Request.tagged` constructors.
- Use `RequestResolver.fromEffect` for per-request effects.
- Use `RequestResolver.makeBatched` when you can batch queries.

## Walkthrough: single request resolver

```ts
import * as Effect from "effect/Effect";
import * as Request from "effect/Request";
import * as RequestResolver from "effect/RequestResolver";

class GetUser extends Request.TaggedClass("GetUser")<
  { readonly id: string; readonly name: string },
  "NotFound",
  { readonly id: string }
> {}

const resolver = RequestResolver.fromEffect((req: GetUser) =>
  req.id === "missing" ? Effect.fail("NotFound") : Effect.succeed({ id: req.id, name: "User" }),
);

const program = Effect.request(new GetUser({ id: "user-1" }), resolver);
```

## Wiring guide

- Use batched resolvers to collapse many requests into one DB/API call.
- Provide resolvers via layers if they need services.
- Keep request types small and serializable.

## Pitfalls

- Forgetting to resolve all requests inside a batch (causes query failures).
- Mixing unrelated requests in a single resolver.
- Doing expensive per-request work when a batch would do.
