import { describe, expect, test } from "bun:test";

import { createWsHub, parseActionMessage } from "./ws.ts";

describe("server websocket hub", () => {
  test("parseActionMessage extracts action and cell", () => {
    expect(parseActionMessage('{"action":"plan","cell":8}')).toEqual({
      action: "plan",
      cell: 8,
    });

    expect(parseActionMessage('{"cell":2,"action":"commit"}')).toEqual({
      action: "commit",
      cell: 2,
    });

    expect(parseActionMessage('{"action":"build"}')).toBeNull();
    expect(parseActionMessage('{"action":"build","cell":-1}')).toBeNull();
    expect(parseActionMessage('{"action":"invalid","cell":1}')).toBeNull();
  });

  test("createWsHub broadcasts events to all clients", () => {
    const payloadsA: string[] = [];
    const payloadsB: string[] = [];

    const hub = createWsHub();
    const clientA = {
      send: (payload: string) => {
        payloadsA.push(payload);
      },
    };
    const clientB = {
      send: (payload: string) => {
        payloadsB.push(payload);
      },
    };

    hub.connect(clientA);
    hub.connect(clientB);

    hub.emit({
      type: "cell:state",
      cell: 3,
      state: "running",
    });

    expect(hub.size()).toBe(2);
    expect(payloadsA).toHaveLength(1);
    expect(payloadsB).toHaveLength(1);

    const event = JSON.parse(payloadsA[0] ?? "{}");
    expect(event).toEqual({
      type: "cell:state",
      cell: 3,
      state: "running",
    });

    hub.disconnect(clientA);
    hub.emit({
      type: "cell:error",
      cell: 3,
      error: "boom",
    });

    expect(payloadsA).toHaveLength(1);
    expect(payloadsB).toHaveLength(2);
  });
});
