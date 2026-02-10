import type { CellAction } from "./types.ts";

export type ConnectionStatus = "connecting" | "connected" | "disconnected";

export const getApiBaseUrl = (): string => {
  // When served from same origin (proxied), use relative. Otherwise dev fallback.
  if (typeof window !== "undefined" && window.location.port !== "3000") {
    return "";
  }
  return "http://localhost:4747";
};

export const getWsUrl = (): string => {
  const base = getApiBaseUrl();
  if (base === "") {
    const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    return `${protocol}//${window.location.host}/ws`;
  }
  return "ws://localhost:4747/ws";
};

export const sendCellAction = (ws: WebSocket, action: CellAction, cell: number): void => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action, cell }));
  }
};

export const fetchDag = (
  baseUrl: string,
  onResult: (json: unknown) => void,
  onError: (message: string) => void,
): void => {
  fetch(`${baseUrl}/api/dag`)
    .then((response) => {
      if (!response.ok) {
        onError(`HTTP ${response.status}`);
        return;
      }
      return response.json();
    })
    .then((json) => {
      if (json !== undefined) {
        onResult(json);
      }
    })
    .catch((error: unknown) => {
      const message = error instanceof Error ? error.message : "Unknown fetch error";
      onError(message);
    });
};
