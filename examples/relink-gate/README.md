# Relink Gate Example

Demonstrates `drift link` refusing to restamp when the doc hasn't been updated.

## Setup

```bash
drift link examples/relink-gate/doc.md examples/relink-gate/auth.ts#login
```

## Trigger the gate

Change the code without updating the doc:

```bash
# Add a rate-limit check to login — the doc now lies about what login does
sed -i '' 's/return createSession(username);/if (rateLimited(username)) throw new Error("rate limited");\n  return createSession(username);/' examples/relink-gate/auth.ts

# Try to relink — refused because doc.md wasn't updated
drift link examples/relink-gate/doc.md
```

Expected output: drift prints the doc section and current code, then refuses.

## Fix it

Either update `doc.md` to mention rate limiting, then relink:

```bash
drift link examples/relink-gate/doc.md
```

Or confirm the doc is still accurate:

```bash
drift link examples/relink-gate/doc.md --doc-is-still-accurate
```
