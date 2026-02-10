import type { BuildArtifact, CellState } from "../core/execution-engine.ts";
import type { ActionRequest, ServerAction } from "./api.ts";

export interface DagCellSnapshot {
  readonly index: number;
  readonly title: string;
  readonly dependencies: ReadonlyArray<number>;
  readonly dependents: ReadonlyArray<number>;
  readonly state: CellState;
  readonly version: number;
  readonly artifactRef: string | null;
  readonly artifact: BuildArtifact | null;
}

export type ServerEvent =
  | {
      readonly type: "cell:state";
      readonly cell: number;
      readonly state: CellState;
    }
  | {
      readonly type: "cell:token";
      readonly cell: number;
      readonly token: string;
    }
  | {
      readonly type: "cell:complete";
      readonly cell: number;
      readonly action: ServerAction;
      readonly artifact: BuildArtifact | null;
    }
  | {
      readonly type: "cell:error";
      readonly cell: number;
      readonly error: string;
    }
  | {
      readonly type: "dag:updated";
      readonly cells: ReadonlyArray<DagCellSnapshot>;
    };

export interface WsClient {
  readonly send: (payload: string) => void;
}

export interface WsHub {
  readonly connect: (client: WsClient) => void;
  readonly disconnect: (client: WsClient) => void;
  readonly emit: (event: ServerEvent) => void;
  readonly size: () => number;
}

export const encodeServerEvent = (event: ServerEvent): string => JSON.stringify(event);

export const createWsHub = (): WsHub => {
  const clients = new Set<WsClient>();

  return {
    connect: (client) => {
      clients.add(client);
    },
    disconnect: (client) => {
      clients.delete(client);
    },
    emit: (event) => {
      const encoded = encodeServerEvent(event);
      for (const client of clients) {
        client.send(encoded);
      }
    },
    size: () => clients.size,
  };
};

export const parseActionMessage = (raw: string): ActionRequest | null => {
  const actionMatch = raw.match(/"action"\s*:\s*"(plan|build|commit)"/u);
  if (actionMatch === null) {
    return null;
  }

  const action = parseAction(actionMatch[1]);
  if (action === null) {
    return null;
  }

  const cellMatch = raw.match(/"cell"\s*:\s*(-?\d+)/u);
  if (cellMatch === null) {
    return null;
  }

  const cellRaw = cellMatch[1];
  if (cellRaw === undefined) {
    return null;
  }

  const cell = Number.parseInt(cellRaw, 10);
  if (!Number.isFinite(cell) || cell < 0) {
    return null;
  }

  return {
    action,
    cell,
  };
};

export const toEventLogLine = (event: ServerEvent): string => {
  switch (event.type) {
    case "cell:state":
      return `${event.type} [cell ${event.cell}] ${event.state}`;
    case "cell:token":
      return `${event.type} [cell ${event.cell}] ${event.token}`;
    case "cell:complete":
      return `${event.type} [cell ${event.cell}] ${event.action}`;
    case "cell:error":
      return `${event.type} [cell ${event.cell}] ${event.error}`;
    case "dag:updated":
      return `${event.type} [cells ${event.cells.length}]`;
  }
};

const parseAction = (value: string | undefined): ServerAction | null => {
  switch (value) {
    case "plan":
      return "plan";
    case "build":
      return "build";
    case "commit":
      return "commit";
    default:
      return null;
  }
};
