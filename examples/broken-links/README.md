# Broken Links Example

Demonstrates `drift check` detecting broken markdown links.

## Setup

No lockfile binding needed — broken link detection works on any markdown file
discovered by `drift check`.

## Run

```bash
drift check
```

Expected output: `doc.md` reports 3 `BROKEN` links:

- `./stripe-guide.md` — doesn't exist
- `../docs/payment-arch.md` — doesn't exist
- `./errors.md` — doesn't exist

The two links under "Working links" point to files in the relink-gate example
and should pass.
