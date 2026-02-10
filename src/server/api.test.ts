import { describe, expect, test } from "bun:test";

import { createActionPath, createApiRouter, parseActionPath } from "./api.ts";

describe("server api", () => {
  test("parseActionPath supports both route shapes", () => {
    expect(parseActionPath("/api/cells/7/plan")).toEqual({
      action: "plan",
      cell: 7,
    });

    expect(parseActionPath("/api/build/4")).toEqual({
      action: "build",
      cell: 4,
    });

    expect(createActionPath({ action: "commit", cell: 2 })).toBe("/api/cells/2/commit");
  });

  test("parseActionPath rejects invalid action payloads", () => {
    expect(parseActionPath("/api/cells/not-a-number/plan")).toBeNull();
    expect(parseActionPath("/api/cells/1/unknown")).toBeNull();
    expect(parseActionPath("/api/plan/-1")).toBeNull();
  });

  test("createApiRouter dispatches action requests and dag reads", () => {
    const executed: Array<{ readonly action: string; readonly cell: number }> = [];

    const router = createApiRouter({
      executeAction: (request) => {
        executed.push(request);
        return {
          accepted: true,
          message: "ok",
        };
      },
      readDag: () => [
        {
          index: 0,
          title: "Project",
          dependencies: [],
          dependents: [1],
          state: "clean",
          version: 1,
          artifactRef: null,
          artifact: null,
        },
      ],
    });

    const actionResponse = router(
      new Request("http://localhost/api/cells/3/build", {
        method: "POST",
      }),
    );

    expect(actionResponse.status).toBe(202);
    expect(executed).toEqual([
      {
        action: "build",
        cell: 3,
      },
    ]);

    const dagResponse = router(new Request("http://localhost/api/dag"));
    expect(dagResponse.status).toBe(200);

    const notFound = router(new Request("http://localhost/unknown"));
    expect(notFound.status).toBe(404);
  });
});
