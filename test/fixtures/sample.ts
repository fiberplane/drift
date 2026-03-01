export interface AuthConfig {
  secret: string;
  expiry: number;
}

export function verifyToken(token: string): boolean {
  return token.length > 0;
}

export function createSession(config: AuthConfig): string {
  return config.secret;
}
