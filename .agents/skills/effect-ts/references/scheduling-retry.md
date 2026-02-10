# Scheduling and Retry

Use this guide when you need repetition, backoff, or retry policies.

- A `Schedule` describes a recurring policy and can produce output values.
- Use `Effect.repeat` to repeat on success; use `Effect.schedule` to only follow the schedule without an initial run.
- Use `Effect.retry` to retry failures according to a schedule.
- Compose schedules for backoff, jitter, or rate limiting.
- Choose `repeat` for success-based recurrence and `retry` for failure-based recovery.

## Mental model

- `Schedule` is a policy that decides _when_ to try again and _how many_ times.
- `repeat` is for success recurrence; `retry` is for failure recovery.
- Add jitter and caps to avoid synchronized retry storms.

## Walkthrough: retry an API call with backoff

1. Wrap the async call with `Effect.tryPromise` so failures are typed.
2. Build a schedule with exponential backoff and jitter.
3. Cap the number of retries.
4. Apply `Effect.retry` and return a single success or a final failure.

```ts
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";

class HttpError extends Data.Error<{ readonly message: string }> {}

const fetchUser = (id: string) =>
  Effect.tryPromise({
    try: async () => {
      const response = await fetch(`/users/${id}`);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      return response.json();
    },
    catch: (cause) => new HttpError({ message: String(cause) }),
  });

// recurs(3) = 3 retries (4 total attempts)
const retryPolicy = Schedule.exponential("100 millis", 1.5).pipe(
  Schedule.jittered,
  Schedule.recurs(3),
);

const program = fetchUser("user-1").pipe(Effect.retry(retryPolicy));
```

## Wiring guide

- Make retry policy configurable (base delay, factor, max attempts).
- Use `Schedule.while`/`until` to retry only on transient errors.
- Apply backoff at the edge (HTTP, DB, messaging) and avoid stacking multiple retries.

## Pitfalls

- Retrying non-idempotent operations without a dedupe token.
- Unbounded retries with no cap or backoff.
- Missing jitter when many workers retry at once.
- Retrying defects (thrown exceptions) without converting them to typed failures.

## Example

```ts
import * as Effect from "effect/Effect";
import { pipe } from "effect/Function";
import * as Ref from "effect/Ref";
import * as Schedule from "effect/Schedule";

const program = Effect.gen(function* () {
  const counter = yield* Ref.make(0);
  const attempt = pipe(
    Ref.updateAndGet(counter, (n) => n + 1),
    Effect.flatMap((n) => (n >= 3 ? Effect.succeed(n) : Effect.fail(new Error(`attempt ${n}`)))),
  );

  // first run + 2 retries = 3 total attempts
  yield* attempt.pipe(Effect.retry(Schedule.recurs(2)));
});
```
