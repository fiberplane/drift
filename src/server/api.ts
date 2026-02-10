import type { DagCellSnapshot } from "./ws.ts";

export type ServerAction = "plan" | "build" | "commit";

export interface ActionRequest {
  readonly action: ServerAction;
  readonly cell: number;
}

export interface ActionResponse {
  readonly accepted: boolean;
  readonly message: string;
}

export interface ApiRouterDependencies {
  readonly executeAction: (request: ActionRequest) => ActionResponse;
  readonly readDag: () => ReadonlyArray<DagCellSnapshot>;
}

export const acknowledgeAction = (request: ActionRequest): ActionResponse => ({
  accepted: true,
  message: `${request.action} scheduled for cell ${request.cell}`,
});

export const createActionPath = (request: ActionRequest): string =>
  `/api/cells/${request.cell}/${request.action}`;

export const parseActionPath = (pathname: string): ActionRequest | null => {
  const segments = pathname.split("/").filter((segment) => segment !== "");

  if (segments.length === 4 && segments[0] === "api" && segments[1] === "cells") {
    return parseActionRequest({
      actionRaw: segments[3],
      cellRaw: segments[2],
    });
  }

  if (segments.length === 3 && segments[0] === "api") {
    return parseActionRequest({
      actionRaw: segments[1],
      cellRaw: segments[2],
    });
  }

  return null;
};

export const createApiRouter =
  (dependencies: ApiRouterDependencies) =>
  (request: Request): Response => {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return textResponse(
        "drift edit server is running. Use POST /api/cells/:cell/(plan|build|commit), GET /api/dag, and WebSocket /ws.",
      );
    }

    if (request.method === "GET" && url.pathname === "/health") {
      return jsonResponse({ ok: true });
    }

    if (request.method === "GET" && url.pathname === "/api/dag") {
      return jsonResponse({
        cells: dependencies.readDag(),
      });
    }

    if (request.method === "POST") {
      const actionRequest = parseActionPath(url.pathname);
      if (actionRequest !== null) {
        const result = dependencies.executeAction(actionRequest);
        return jsonResponse(result, result.accepted ? 202 : 400);
      }
    }

    return jsonResponse({ error: "Not found" }, 404);
  };

const parseActionRequest = (args: {
  readonly actionRaw: string | undefined;
  readonly cellRaw: string | undefined;
}): ActionRequest | null => {
  const action = parseAction(args.actionRaw);
  if (action === null) {
    return null;
  }

  const cell = parseCellIndex(args.cellRaw);
  if (cell === null) {
    return null;
  }

  return {
    action,
    cell,
  };
};

const parseAction = (actionRaw: string | undefined): ServerAction | null => {
  switch (actionRaw) {
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

const parseCellIndex = (cellRaw: string | undefined): number | null => {
  if (cellRaw === undefined || cellRaw.trim() === "") {
    return null;
  }

  const parsed = Number.parseInt(cellRaw, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }

  return parsed;
};

const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
    },
  });

const textResponse = (body: string, status = 200): Response =>
  new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
    },
  });
