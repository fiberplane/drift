# Database Configuration

`DatabaseConfig` defines the connection parameters:

- `host` / `port` — database server address
- `database` — target database name
- `maxConnections` — connection pool ceiling

Use `createPool` to initialize the pool from a config object.
