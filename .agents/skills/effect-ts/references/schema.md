# Effect Schema

Use this guide when you need validation, parsing, or encoding.

## Mental model

- Schemas describe structure and transformations.
- `decode` validates and transforms input to a typed value.
- `encode` converts typed values to an encoded representation.

## Patterns

- Use `Schema.Struct` for objects.
- Use `Schema.NumberFromString` to parse string inputs.
- Use `Schema.decode` for Effect-based decoding.

## Walkthrough: decode and encode

```ts
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";

const User = Schema.Struct({
  id: Schema.NumberFromString,
  name: Schema.String,
});

const decode = Schema.decode(User);
const encode = Schema.encode(User);

const program = Effect.gen(function* () {
  const user = yield* decode({ id: "1", name: "Ada" });
  return yield* encode(user);
});
```

## Pitfalls

- Using sync decoders for async schemas.
- Skipping schema-based validation at boundaries.
