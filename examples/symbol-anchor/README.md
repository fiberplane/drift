# Symbol Anchor Example

Demonstrates symbol-level anchors where drift tracks a specific named symbol
rather than the whole file. The relink gate shows the symbol body when refusing.

## Setup

```bash
drift link examples/symbol-anchor/doc.md examples/symbol-anchor/config.ts#DatabaseConfig
drift link examples/symbol-anchor/doc.md examples/symbol-anchor/config.ts#createPool
```

## Trigger the gate

Change the `DatabaseConfig` interface without updating the doc:

```bash
# Add a new field — the doc now omits it
sed -i '' 's/maxConnections: number;/maxConnections: number;\n  ssl: boolean;/' examples/symbol-anchor/config.ts

# Relink refused — prints the doc section AND the current DatabaseConfig body
drift link examples/symbol-anchor/doc.md
```

The output shows both sides so you can see what's out of sync: the doc lists
4 fields but the code now has 5.
