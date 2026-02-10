# Streams, Queues, PubSub, STM

Use this guide for streaming and message-passing patterns.

## Mental model

- Streams emit 0..N values over time.
- Queues provide backpressure and point-to-point messaging.
- STM provides composable atomic transactions.

## Patterns

- Use `Stream.fromQueue` to turn a queue into a stream.
- Use `Queue.bounded` for backpressure.
- Use `STM.commit` to run STM transactions.

## Walkthrough: queue to stream

```ts
import * as Effect from "effect/Effect";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";

const program = Effect.gen(function* () {
  const queue = yield* Queue.bounded<number>(10);
  yield* Queue.offer(queue, 1);
  yield* Queue.offer(queue, 2);

  const stream = Stream.fromQueue(queue);
  return yield* Stream.runCollect(stream.pipe(Stream.take(2)));
});
```

## Pitfalls

- Using unbounded queues when backpressure is needed.
- Forgetting to shut down queues in long-lived apps.
