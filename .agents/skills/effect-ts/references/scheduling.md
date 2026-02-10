# Scheduling (Schedule, Repeat, Effect.schedule)

Use this guide when modeling repetition or time-based policies.

## Mental model

- A `Schedule` describes a policy for recurrence and delay.
- `Effect.repeat` runs once, then follows the schedule.
- `Effect.schedule` follows the schedule without the initial run.

## Patterns

- Use `Schedule.recurs(n)` to cap repetitions.
- Use `Schedule.spaced("1 second")` for fixed spacing.
- Combine schedules with `Schedule.jittered` and `Schedule.exponential` for backoff.

## Walkthrough: repeat with spacing and cap

```ts
import * as Effect from "effect/Effect";
import * as Schedule from "effect/Schedule";

const schedule = Schedule.spaced("1 second").pipe(Schedule.recurs(3));

const program = Effect.succeed("tick").pipe(Effect.repeat(schedule));
```

## Pitfalls

- Using `Effect.schedule` when you expect the initial run.
- Missing caps on retries/repeats.
- Forgetting jitter in high-concurrency retries.
