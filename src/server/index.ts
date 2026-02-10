import { Buffer } from "node:buffer";

import { Either } from "effect";

import { runCommitCommand } from "../cli/commit.ts";
import { runPlanCommand } from "../cli/plan.ts";
import { loadProject, type DriftCellRecord } from "../cli/project-store.ts";
import { runRunCommand } from "../cli/run.ts";
import type { CliContext } from "../cli/types.ts";
import { createApiRouter, type ActionRequest, type ActionResponse } from "./api.ts";
import { watchDriftCells } from "./watcher.ts";
import {
  createWsHub,
  encodeServerEvent,
  parseActionMessage,
  type DagCellSnapshot,
  type WsClient,
} from "./ws.ts";
import homepage from "../ui/index.html";

export * from "./api.ts";
export * from "./watcher.ts";
export * from "./ws.ts";

export interface StartedDriftServer {
  readonly host: string;
  readonly port: number;
  readonly stop: () => void;
  readonly runAction: (request: ActionRequest) => ActionResponse;
  readonly readDag: () => ReadonlyArray<DagCellSnapshot>;
}

export const startDriftEditServer = (args: {
  readonly host: string;
  readonly port: number;
  readonly cwd?: string;
}): StartedDriftServer => {
  const rootDir = args.cwd ?? process.cwd();
  const wsHub = createWsHub();
  const runningCells = new Set<number>();

  const readDag = (): ReadonlyArray<DagCellSnapshot> => {
    const projectResult = loadProject(rootDir);
    if (Either.isLeft(projectResult)) {
      return [];
    }

    return projectResult.right.cells.map(toDagCellSnapshot);
  };

  const runAction = (request: ActionRequest): ActionResponse => {
    if (runningCells.has(request.cell)) {
      return {
        accepted: false,
        message: `Cell ${request.cell} is already running.`,
      };
    }

    runningCells.add(request.cell);
    wsHub.emit({
      type: "cell:state",
      cell: request.cell,
      state: "running",
    });

    const errors: string[] = [];

    const exitCode = runActionCommand({
      request,
      context: createStreamingContext({
        cwd: rootDir,
        onToken: (token) => {
          if (token.trim() === "") {
            return;
          }

          wsHub.emit({
            type: "cell:token",
            cell: request.cell,
            token,
          });
        },
        onError: (line) => {
          errors.push(line);

          if (line.trim() === "") {
            return;
          }

          wsHub.emit({
            type: "cell:token",
            cell: request.cell,
            token: line,
          });
        },
      }),
    });

    const dagCells = readDag();
    runningCells.delete(request.cell);

    if (exitCode !== 0) {
      const message =
        errors[errors.length - 1] ?? `${request.action} failed for cell ${request.cell}.`;

      wsHub.emit({
        type: "cell:state",
        cell: request.cell,
        state: "error",
      });
      wsHub.emit({
        type: "cell:error",
        cell: request.cell,
        error: message,
      });
      wsHub.emit({
        type: "dag:updated",
        cells: dagCells,
      });

      return {
        accepted: false,
        message,
      };
    }

    const completedCell = dagCells.find((cell) => cell.index === request.cell);

    wsHub.emit({
      type: "cell:state",
      cell: request.cell,
      state: completedCell?.state ?? "clean",
    });
    wsHub.emit({
      type: "cell:complete",
      cell: request.cell,
      action: request.action,
      artifact: completedCell?.artifact ?? null,
    });
    wsHub.emit({
      type: "dag:updated",
      cells: dagCells,
    });

    return {
      accepted: true,
      message: `${request.action} completed for cell ${request.cell}.`,
    };
  };

  const apiRouter = createApiRouter({
    executeAction: runAction,
    readDag,
  });

  const clients = new WeakMap<object, WsClient>();

  const watcher = watchDriftCells({
    rootDir,
    onReload: () => {
      wsHub.emit({
        type: "dag:updated",
        cells: readDag(),
      });
    },
  });

  const server = Bun.serve({
    hostname: args.host,
    port: args.port,
    development: true,
    routes: {
      "/": homepage,
    },
    fetch: (request, serverRef) => {
      const url = new URL(request.url);
      if (url.pathname === "/ws") {
        if (serverRef.upgrade(request)) {
          return;
        }

        return new Response("WebSocket upgrade failed.", { status: 400 });
      }

      return apiRouter(request);
    },
    websocket: {
      open: (socket) => {
        const client: WsClient = {
          send: (payload) => {
            socket.send(payload);
          },
        };

        clients.set(socket, client);
        wsHub.connect(client);

        client.send(
          encodeServerEvent({
            type: "dag:updated",
            cells: readDag(),
          }),
        );
      },
      close: (socket) => {
        const client = clients.get(socket);
        if (client === undefined) {
          return;
        }

        wsHub.disconnect(client);
        clients.delete(socket);
      },
      message: (socket, message) => {
        const raw = decodeSocketMessage(message);
        const request = parseActionMessage(raw);

        if (request === null) {
          socket.send(
            encodeServerEvent({
              type: "cell:error",
              cell: 0,
              error:
                'Invalid WebSocket payload. Expected JSON object: {"action":"plan|build|commit","cell":N}.',
            }),
          );
          return;
        }

        runAction(request);
      },
    },
  });

  return {
    host: args.host,
    port: server.port ?? args.port,
    stop: () => {
      watcher.close();
      server.stop(true);
    },
    runAction,
    readDag,
  };
};

export const startEditServer = startDriftEditServer;

const runActionCommand = (args: {
  readonly request: ActionRequest;
  readonly context: CliContext;
}): number => {
  const cellArg = String(args.request.cell);

  switch (args.request.action) {
    case "plan":
      return runPlanCommand([cellArg], args.context);
    case "build":
      return runRunCommand([cellArg], args.context);
    case "commit":
      return runCommitCommand([cellArg], args.context);
  }
};

const createStreamingContext = (args: {
  readonly cwd: string;
  readonly onToken: (token: string) => void;
  readonly onError: (line: string) => void;
}): CliContext => ({
  cwd: args.cwd,
  now: () => new Date(),
  writeLine: (line) => {
    args.onToken(line);
  },
  writeError: (line) => {
    args.onError(line);
  },
});

const toDagCellSnapshot = (cell: DriftCellRecord): DagCellSnapshot => ({
  index: cell.index,
  title: cell.title,
  dependencies: cell.dependencies,
  dependents: cell.dependents,
  state: cell.state,
  content: cell.content,
  version: cell.version,
  versions: cell.versions.map((version) => ({
    version: version.version,
    content: version.content,
  })),
  artifactRef: cell.artifactRef,
  artifact: cell.artifact,
});

const decodeSocketMessage = (message: string | Buffer | ArrayBuffer | Uint8Array): string => {
  if (typeof message === "string") {
    return message;
  }

  if (message instanceof Buffer) {
    return message.toString("utf8");
  }

  if (message instanceof ArrayBuffer) {
    return Buffer.from(message).toString("utf8");
  }

  return Buffer.from(message).toString("utf8");
};

if (import.meta.main) {
  startDriftEditServer({
    host: "localhost",
    port: 4747,
    cwd: process.cwd(),
  });
}
