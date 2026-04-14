export function login(username: string, password: string): string {
  if (password.length === 0) {
    throw new Error("password required");
  }
  if (username.length < 3) {
    throw new Error("username must be more than 3 chars");
  }
  return createSession(username);
}

function createSession(username: string): string {
  return `session_${username}_${Date.now()}`;
}
