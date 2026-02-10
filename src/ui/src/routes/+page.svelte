<script lang="ts">
  import Notebook from "../lib/components/Notebook.svelte";
  import { getWsUrl, sendCellAction, type ConnectionStatus } from "../lib/api-client.ts";
  import {
    applyServerEvent,
    createInitialNotebook,
    listStaleCellIndexes,
    listUncommittedCellIndexes,
    setActiveCell,
    updateCellInput,
    selectCellVersion,
    restoreCellVersion,
  } from "../lib/state/index.ts";
  import type {
    CellActionRequest,
    CellInputChange,
    CellVersionRestoreRequest,
    CellVersionSelectionChange,
    ToolbarActionRequest,
  } from "../lib/types.ts";
  import type { WsServerEvent } from "../lib/state/ws.svelte.ts";

  let notebook = $state(createInitialNotebook());
  let status = $state<ConnectionStatus>("connecting");
  let ws = $state<WebSocket | null>(null);
  let reconnectTimer = $state<ReturnType<typeof setTimeout> | null>(null);

  const connect = (): void => {
    status = "connecting";
    const socket = new WebSocket(getWsUrl());

    socket.onopen = () => {
      status = "connected";
      ws = socket;
    };

    socket.onmessage = (event) => {
      const parsed: WsServerEvent = JSON.parse(String(event.data));
      notebook = applyServerEvent(notebook, parsed);
    };

    socket.onclose = () => {
      status = "disconnected";
      ws = null;
      scheduleReconnect();
    };

    socket.onerror = () => {
      // onclose will fire after this
    };
  };

  const scheduleReconnect = (): void => {
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
    }
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, 2000);
  };

  $effect(() => {
    connect();
    return () => {
      if (reconnectTimer !== null) {
        clearTimeout(reconnectTimer);
      }
      if (ws !== null) {
        ws.close();
      }
    };
  });

  const handleCellAction = (request: CellActionRequest): void => {
    if (ws !== null) {
      sendCellAction(ws, request.action, request.cellIndex);
    }
  };

  const handleToolbarAction = (request: ToolbarActionRequest): void => {
    if (ws === null) return;

    if (request.action === "plan-all") {
      for (const cellIndex of listStaleCellIndexes(notebook)) {
        sendCellAction(ws, "plan", cellIndex);
      }
    }
    if (request.action === "build-all") {
      for (const cellIndex of listStaleCellIndexes(notebook)) {
        sendCellAction(ws, "build", cellIndex);
      }
    }
    if (request.action === "commit-all") {
      for (const cellIndex of listUncommittedCellIndexes(notebook)) {
        sendCellAction(ws, "commit", cellIndex);
      }
    }
  };

  const handleCellInput = (change: CellInputChange): void => {
    notebook = setActiveCell(notebook, change.cellIndex);
    notebook = updateCellInput(notebook, change.cellIndex, change.value);
  };

  const handleMinimapSelect = (cellIndex: number): void => {
    notebook = setActiveCell(notebook, cellIndex);
  };

  const handleVersionSelect = (change: CellVersionSelectionChange): void => {
    notebook = setActiveCell(notebook, change.cellIndex);
    notebook = selectCellVersion(notebook, change.cellIndex, change.version);
  };

  const handleVersionRestore = (request: CellVersionRestoreRequest): void => {
    notebook = setActiveCell(notebook, request.cellIndex);
    notebook = restoreCellVersion(notebook, request.cellIndex, request.version);
  };
</script>

<main>
  <div
    class="status-bar"
    class:connected={status === "connected"}
    class:disconnected={status === "disconnected"}
  >
    {#if status === "connecting"}
      Connecting to drift server…
    {:else if status === "connected"}
      Connected
    {:else}
      Disconnected — reconnecting…
    {/if}
  </div>

  <Notebook
    model={notebook}
    onCellAction={handleCellAction}
    onToolbarAction={handleToolbarAction}
    onCellInput={handleCellInput}
    onMinimapSelect={handleMinimapSelect}
    onVersionSelect={handleVersionSelect}
    onVersionRestore={handleVersionRestore}
  />
</main>

<style>
  main {
    display: grid;
    gap: 0;
    padding: 0;
    min-height: 100dvh;
    background: var(--bg-page);
  }

  .status-bar {
    text-align: center;
    padding: 0.35rem 1rem;
    font-family: var(--font-mono);
    font-size: 0.68rem;
    font-weight: 400;
    letter-spacing: 0.03em;
    background: var(--stale-bg);
    color: var(--stale);
    border-bottom: 1px solid var(--stale-border);
  }

  .status-bar.connected {
    background: var(--bg-page);
    color: var(--text-muted);
    border-bottom-color: var(--border-light);
  }

  .status-bar.disconnected {
    background: var(--error-bg);
    color: var(--error);
    border-bottom-color: var(--error-border);
  }
</style>
