# Resource Management (Scope)

Use this guide when acquiring and releasing resources.

- `Scope` provides resource management for effects.
- Closing a scope releases all resources attached to it.
- Add finalizers to a scope to define cleanup logic.
- Prefer scoped acquisition for files, sockets, and other resources that must be released deterministically.

## Mental model

- `Scope` tracks acquired resources and runs finalizers in LIFO order.
- `Effect.acquireRelease` defines acquire + release; `Effect.scoped` runs it safely.
- Release runs on success, failure, or interruption; use the `exit` value to customize cleanup.
- Use `forkScoped` for background work that uses scoped resources.

## Walkthrough: manage a file-like resource

1. Acquire the resource in `Effect.acquireRelease`.
2. Provide a release action that always runs.
3. Use the resource inside `Effect.scoped` so cleanup is guaranteed.

```ts
import * as Effect from "effect/Effect";

const openFile = (path: string) => Effect.sync(() => ({ path }));
const closeFile = (file: { path: string }) => Effect.sync(() => undefined);

const program = Effect.scoped(
  Effect.gen(function* () {
    const file = yield* Effect.acquireRelease(openFile("/tmp/app.log"), (file, _exit) =>
      closeFile(file),
    );

    return file.path;
  }),
);
```

## Wiring guide

- Wrap resources in Layers using `Layer.scoped` so dependents never see raw handles.
- Use `Effect.scoped` around any block that allocates resources.
- When using concurrency, ensure fibers that touch scoped resources are created with `forkScoped`.

## Pitfalls

- Using a scoped resource after the scope closes.
- Forgetting to call `Effect.scoped` around `acquireRelease`.
- Finalizers that can fail silently (log or handle errors explicitly).

## Example

```ts
import * as Effect from "effect/Effect";

const program = Effect.acquireRelease(
  Effect.sync(() => "resource"),
  () => Effect.sync(() => undefined),
).pipe(Effect.scoped);
```
