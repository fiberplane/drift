export interface DatabaseConfig {
  host: string;
  port: number;
  database: string;
  maxConnections: number;
}

export interface CacheConfig {
  ttlSeconds: number;
  maxEntries: number;
}

export function createPool(config: DatabaseConfig): void {
  console.log(`Connecting to ${config.host}:${config.port}/${config.database}`);
}
