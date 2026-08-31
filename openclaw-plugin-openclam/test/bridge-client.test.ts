import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type WebSocket from "ws";
import { describe, expect, it, vi } from "vitest";
import { OpenClamBridgeClient } from "../src/bridge-client.js";
import { initialAdapterState } from "../src/credentials.js";
import type { ConnectorFrame, ResolvedOpenClamAccount } from "../src/types.js";

class FakeSocket extends EventEmitter {
  readyState = 0;
  readonly sent: string[] = [];
  autoPersist = true;

  open(): void {
    this.readyState = 1;
    this.emit("open");
  }

  send(value: string): void {
    if (this.readyState !== 1) throw new Error("not_open");
    this.sent.push(value);
    const frame = JSON.parse(value) as ConnectorFrame;
    if (
      this.autoPersist &&
      frame.kind !== "ack" &&
      frame.kind !== "heartbeat"
    ) {
      queueMicrotask(() => {
        this.receive(JSON.stringify({
          v: 1,
          kind: "relay.persisted",
          connectionId: frame.connectionId,
          payload: { senderSeq: frame.seq, messageId: frame.messageId },
        }));
      });
    }
  }

  ping(): void {
    if (this.readyState !== 1) throw new Error("not_open");
  }

  receive(value: string): void {
    this.emit("message", Buffer.from(value, "utf8"), false);
  }

  close(code = 1000): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close", code, Buffer.alloc(0));
  }

  terminate(): void {
    this.close(1006);
  }
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("test_timeout");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function decode(socket: FakeSocket): ConnectorFrame[] {
  return socket.sent.map((encoded) => JSON.parse(encoded) as ConnectorFrame);
}

describe("OpenClam bridge client", () => {
  it("acks, streams cumulative text, completes once, ignores a replay, and reconnects with increasing seq", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    let dispatchCount = 0;
    const controller = new AbortController();
    let status: Record<string, unknown> = { accountId: "ara" };
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => status,
      setStatus: (next: Record<string, unknown>) => {
        status = next;
      },
      log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          sockets.push(socket);
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: async ({ sink }) => {
          dispatchCount += 1;
          await sink.partial("Hel");
          await sink.partial("Hello");
          await sink.completed("Hello");
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => sockets.length === 1 && sockets[0].readyState === 1);
    const submit = JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Hello there" },
    });
    sockets[0].receive(submit);
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    expect(dispatchCount).toBe(1);
    const deltas = decode(sockets[0]).filter((frame) => frame.kind === "assistant.delta");
    expect(deltas.length).toBeGreaterThanOrEqual(1);
    expect(deltas.length).toBeLessThanOrEqual(2);
    expect(deltas[0].payload.text).toBe("Hel");
    expect(decode(sockets[0]).filter((frame) => frame.kind === "assistant.completed")).toHaveLength(1);

    sockets[0].close(1006);
    await waitFor(() => sockets.length === 2 && sockets[1].readyState === 1);
    sockets[1].receive(submit);
    await waitFor(() => decode(sockets[1]).some((frame) => frame.kind === "ack"));
    expect(dispatchCount).toBe(1);
    const allSeq = sockets.flatMap(decode).map((frame) => frame.seq);
    expect(new Set(allSeq).size).toBe(allSeq.length);
    expect(allSeq).toEqual([...allSeq].sort((left, right) => left - right));
    expect(persisted.completedTurnIds).toContain(turnId);

    controller.abort();
    await attached;
    expect(status.connected).toBe(false);
  });

  it("replays the exact acceptance and waits for its durable receipt before executing once", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    let dispatchCount = 0;
    const controller = new AbortController();
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          socket.autoPersist = false;
          sockets.push(socket);
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: async ({ sink }) => {
          dispatchCount += 1;
          await sink.completed("accepted exactly once");
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => sockets[0]?.readyState === 1);
    const submit = JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Wait for the relay" },
    });
    sockets[0].receive(submit);
    await waitFor(() => decode(sockets[0]).some((frame) => frame.kind === "turn.accepted"));
    const firstAcceptance = sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "turn.accepted"
    );
    expect(firstAcceptance).toBeDefined();
    expect(dispatchCount).toBe(0);

    sockets[0].close(1006);
    await waitFor(() => sockets[1]?.readyState === 1);
    await waitFor(() => sockets[1].sent.includes(firstAcceptance ?? ""));
    sockets[1].receive(submit);
    expect(dispatchCount).toBe(0);

    const acceptance = JSON.parse(firstAcceptance ?? "") as ConnectorFrame;
    sockets[1].receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: acceptance.seq, messageId: acceptance.messageId },
    }));
    await waitFor(() => dispatchCount === 1);
    await waitFor(() => decode(sockets[1]).some((frame) => frame.kind === "assistant.completed"));
    const terminal = decode(sockets[1]).find((frame) => frame.kind === "assistant.completed");
    expect(terminal).toBeDefined();
    sockets[1].receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: terminal?.seq, messageId: terminal?.messageId },
    }));
    await waitFor(() => persisted.completedTurnIds.includes(turnId));

    sockets[1].receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: acceptance.seq, messageId: acceptance.messageId },
    }));
    sockets[1].close(1006);
    await waitFor(() => sockets[2]?.readyState === 1);
    await waitFor(() => decode(sockets[2]).some((frame) => frame.kind === "heartbeat"));
    expect(decode(sockets[2]).filter((frame) => frame.kind === "turn.accepted")).toHaveLength(0);
    expect(dispatchCount).toBe(1);

    controller.abort();
    await attached;
  });

  it("waits for a delayed aborted run before stop returns and a replacement advances state", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    let releaseOldRun!: () => void;
    let reportAbort!: () => void;
    const oldRunReleased = new Promise<void>((resolve) => {
      releaseOldRun = resolve;
    });
    const abortObserved = new Promise<void>((resolve) => {
      reportAbort = resolve;
    });
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const makeContext = (controller: AbortController) => ({
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);

    const firstSocket = new FakeSocket();
    const firstController = new AbortController();
    let firstStopped = false;
    let firstWriteAfterStop = false;
    const firstClient = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          if (firstStopped) firstWriteAfterStop = true;
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => firstSocket.open());
          return firstSocket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: async ({ signal, sink }) => {
          await new Promise<void>((resolve) => signal.addEventListener("abort", () => {
            reportAbort();
            resolve();
          }, { once: true }));
          await oldRunReleased;
          await sink.completed("must not write after stop");
        },
      },
    );
    const firstAttached = firstClient.attach(makeContext(firstController));
    await waitFor(() => firstSocket.readyState === 1);
    firstSocket.receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Delay shutdown" },
    }));
    await waitFor(() => decode(firstSocket).some((frame) => frame.kind === "turn.accepted"));

    let stopResolved = false;
    firstController.abort();
    const stopping = firstAttached.then(() => {
      stopResolved = true;
      firstStopped = true;
    });
    await abortObserved;
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(stopResolved).toBe(false);
    releaseOldRun();
    await stopping;
    const nextSeqAfterFirstStop = persisted.nextSeq;

    const secondSocket = new FakeSocket();
    const secondController = new AbortController();
    const replacementDispatch = vi.fn(async () => undefined);
    const secondClient = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => secondSocket.open());
          return secondSocket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: replacementDispatch,
      },
    );
    const secondAttached = secondClient.attach(makeContext(secondController));
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    const nextSeqAfterReplacement = persisted.nextSeq;
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(firstWriteAfterStop).toBe(false);
    expect(nextSeqAfterReplacement).toBeGreaterThan(nextSeqAfterFirstStop);
    expect(persisted.nextSeq).toBeGreaterThanOrEqual(nextSeqAfterReplacement);
    expect(replacementDispatch).not.toHaveBeenCalled();

    secondController.abort();
    await secondAttached;
  });

  it("stops reconnecting and aborts the active run when the connector is retired", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    let abortCount = 0;
    let reportDispatchStarted!: () => void;
    const dispatchStarted = new Promise<void>((resolve) => {
      reportDispatchStarted = resolve;
    });
    let status: Record<string, unknown> = { accountId: "ara" };
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          sockets.push(socket);
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: async ({ signal }) => {
          reportDispatchStarted();
          await new Promise<void>((resolve) => signal.addEventListener("abort", () => {
            abortCount += 1;
            resolve();
          }, { once: true }));
        },
      },
    );
    const attached = client.attach({
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: new AbortController().signal,
      getStatus: () => status,
      setStatus: (next: Record<string, unknown>) => {
        status = next;
      },
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
    await waitFor(() => sockets[0]?.readyState === 1);
    sockets[0].receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Retire while running" },
    }));
    await dispatchStarted;
    sockets[0].close(4003);
    await attached;
    expect(abortCount).toBe(1);
    expect(sockets).toHaveLength(1);
    expect(status).toMatchObject({ connected: false, running: false, configured: false });
  });

  it("treats a 404 WebSocket handshake as terminal instead of reconnecting", async () => {
    const connectionId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          sockets.push(socket);
          queueMicrotask(() => socket.emit("unexpected-response", {}, { statusCode: 404 }));
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: vi.fn(async () => undefined),
      },
    );
    const attached = client.attach({
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: new AbortController().signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
    await attached;
    expect(sockets).toHaveLength(1);
  });

  it("turn.cancel aborts the run and emits one terminal cancellation", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const socket = new FakeSocket();
    const controller = new AbortController();
    let abortCount = 0;
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 1_000,
        dispatchTurn: async ({ signal }) => {
          await new Promise<void>((resolve) => signal.addEventListener("abort", () => {
            abortCount += 1;
            resolve();
          }, { once: true }));
          throw Object.assign(new Error("aborted"), { name: "AbortError" });
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => socket.readyState === 1);
    socket.receive(
      JSON.stringify({
        v: 1,
        kind: "turn.submit",
        connectionId,
        conversationId,
        messageId: randomUUID(),
        seq: 1,
        sentAt: Date.now(),
        payload: { turnId, accountId: "ara", text: "Keep working" },
      }),
    );
    await waitFor(() => decode(socket).some((frame) => frame.kind === "turn.accepted"));
    socket.receive(
      JSON.stringify({
        v: 1,
        kind: "turn.cancel",
        connectionId,
        conversationId: randomUUID(),
        messageId: randomUUID(),
        seq: 2,
        sentAt: Date.now(),
        payload: { turnId },
      }),
    );
    await waitFor(() =>
      decode(socket).some((frame) => frame.kind === "ack" && frame.payload.ackSeq === 2)
    );
    expect(abortCount).toBe(0);
    expect(
      decode(socket).filter(
        (frame) => frame.kind === "turn.error" || frame.kind === "assistant.completed",
      ),
    ).toHaveLength(0);
    socket.receive(
      JSON.stringify({
        v: 1,
        kind: "turn.cancel",
        connectionId,
        conversationId,
        messageId: randomUUID(),
        seq: 3,
        sentAt: Date.now(),
        payload: { turnId },
      }),
    );
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    const terminals = decode(socket).filter(
      (frame) => frame.kind === "turn.error" || frame.kind === "assistant.completed",
    );
    expect(terminals).toHaveLength(1);
    expect(terminals[0].payload).toMatchObject({ code: "cancelled", retryable: false });
    expect(abortCount).toBe(1);
    expect(persisted.completedTurnIds).toContain(turnId);
    controller.abort();
    await attached;
  });

  it("fits CJK and emoji partials and finals within the full UTF-8 frame budget", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const socket = new FakeSocket();
    const controller = new AbortController();
    const multilingual = "你好🙂\"\\\n".repeat(12_000);
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: async ({ sink }) => {
          await sink.partial(multilingual);
          await sink.completed(multilingual);
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => socket.readyState === 1);
    socket.receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "请回答🙂" },
    }));
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    for (const encoded of socket.sent.filter((value) => {
      const kind = (JSON.parse(value) as ConnectorFrame).kind;
      return kind === "assistant.delta" || kind === "assistant.completed";
    })) {
      expect(Buffer.byteLength(encoded, "utf8")).toBeLessThanOrEqual(65_536);
      const text = String((JSON.parse(encoded) as ConnectorFrame).payload.text);
      expect(text.length).toBeGreaterThan(0);
      expect(multilingual.startsWith(text)).toBe(true);
      expect(/[\uD800-\uDBFF]$/u.test(text)).toBe(false);
    }
    expect(decode(socket).filter((frame) => frame.kind === "assistant.delta")).toHaveLength(1);
    expect(decode(socket).filter((frame) => frame.kind === "assistant.completed")).toHaveLength(1);

    controller.abort();
    await attached;
  });

  it("serializes overlapping delta flushes and emits the newest cumulative revision", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const socket = new FakeSocket();
    const controller = new AbortController();
    let blockNextWrite = false;
    let releaseWrite!: () => void;
    let reportWriteStarted!: () => void;
    let reportNewestOffered!: () => void;
    let releaseCompletion!: () => void;
    const writeRelease = new Promise<void>((resolve) => {
      releaseWrite = resolve;
    });
    const writeStarted = new Promise<void>((resolve) => {
      reportWriteStarted = resolve;
    });
    const newestOffered = new Promise<void>((resolve) => {
      reportNewestOffered = resolve;
    });
    const completionRelease = new Promise<void>((resolve) => {
      releaseCompletion = resolve;
    });
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          if (blockNextWrite) {
            blockNextWrite = false;
            reportWriteStarted();
            await writeRelease;
          }
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: async ({ sink }) => {
          blockNextWrite = true;
          const first = sink.partial("First");
          await writeStarted;
          await sink.partial("Latest");
          reportNewestOffered();
          await first;
          await completionRelease;
          await sink.completed("Latest");
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => socket.readyState === 1);
    socket.receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Stream without duplicate revisions" },
    }));
    await newestOffered;
    expect(decode(socket).filter((frame) => frame.kind === "assistant.delta")).toHaveLength(0);
    releaseWrite();
    await waitFor(() =>
      decode(socket).filter((frame) => frame.kind === "assistant.delta").length === 2
    );
    const deltas = decode(socket).filter((frame) => frame.kind === "assistant.delta");
    expect(deltas.map((frame) => frame.payload.revision)).toEqual([1, 2]);
    expect(deltas.map((frame) => frame.payload.text)).toEqual(["First", "Latest"]);
    releaseCompletion();
    await waitFor(() => persisted.completedTurnIds.includes(turnId));

    controller.abort();
    await attached;
  });

  it("coalesces a burst while the phone is offline and keeps the queue bounded", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    const controller = new AbortController();
    let releaseOffline!: () => void;
    let offlineBurstDone!: () => void;
    let releaseCompletion!: () => void;
    const offline = new Promise<void>((resolve) => {
      releaseOffline = resolve;
    });
    const burstDone = new Promise<void>((resolve) => {
      offlineBurstDone = resolve;
    });
    const completion = new Promise<void>((resolve) => {
      releaseCompletion = resolve;
    });
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          sockets.push(socket);
          if (sockets.length === 1) queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: async ({ sink }) => {
          await sink.partial("start");
          await offline;
          for (let index = 0; index < 400; index += 1) {
            await sink.partial(`chunk-${index}`);
          }
          offlineBurstDone();
          await completion;
          await sink.completed("final answer");
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => sockets[0]?.readyState === 1);
    sockets[0].receive(
      JSON.stringify({
        v: 1,
        kind: "turn.submit",
        connectionId,
        conversationId,
        messageId: randomUUID(),
        seq: 1,
        sentAt: Date.now(),
        payload: { turnId, accountId: "ara", text: "Stream slowly" },
      }),
    );
    await waitFor(() => decode(sockets[0]).some((frame) => frame.kind === "assistant.delta"));
    sockets[0].close(1006);
    await waitFor(() => sockets.length === 2);
    releaseOffline();
    await burstDone;
    sockets[1].open();
    await waitFor(() =>
      decode(sockets[1]).some(
        (frame) => frame.kind === "assistant.delta" && frame.payload.text === "chunk-399",
      ),
    );
    releaseCompletion();
    await waitFor(() => decode(sockets[1]).some((frame) => frame.kind === "assistant.completed"));
    const allDeltas = sockets.flatMap(decode).filter((frame) => frame.kind === "assistant.delta");
    expect(allDeltas.length).toBeLessThanOrEqual(12);
    expect(
      decode(sockets[1]).find((frame) => frame.kind === "assistant.completed")?.payload.text,
    ).toBe("final answer");
    controller.abort();
    await attached;
  });

  it("replays the exact terminal bytes until the relay confirms durable persistence", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const sockets: FakeSocket[] = [];
    let dispatchCount = 0;
    const controller = new AbortController();
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const ctx = {
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>;
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          const socket = new FakeSocket();
          socket.autoPersist = false;
          sockets.push(socket);
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 0,
        dispatchTurn: async ({ sink }) => {
          dispatchCount += 1;
          await sink.completed("relay-confirmed answer");
        },
      },
    );
    const attached = client.attach(ctx);
    await waitFor(() => sockets[0]?.readyState === 1);
    sockets[0].receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: { turnId, accountId: "ara", text: "Do not lose the final" },
    }));
    await waitFor(() => decode(sockets[0]).some((frame) => frame.kind === "turn.accepted"));
    const accepted = decode(sockets[0]).find((frame) => frame.kind === "turn.accepted") as ConnectorFrame;
    sockets[0].receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: accepted.seq, messageId: accepted.messageId },
    }));
    await waitFor(() =>
      decode(sockets[0]).some((frame) => frame.kind === "assistant.completed") &&
      persisted.activeTurns[0]?.recoveryError?.code === "connection_interrupted"
    );
    const firstTerminal = sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "assistant.completed"
    );
    expect(firstTerminal).toBeDefined();
    expect(persisted.completedTurnIds).not.toContain(turnId);

    sockets[0].close(1006);
    await waitFor(() => sockets[1]?.readyState === 1);
    await waitFor(() => sockets[1].sent.includes(firstTerminal ?? ""));
    expect(dispatchCount).toBe(1);

    const terminal = JSON.parse(firstTerminal ?? "") as ConnectorFrame;
    sockets[1].receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: terminal.seq, messageId: terminal.messageId },
    }));
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    expect(persisted.activeTurns).toHaveLength(0);

    controller.abort();
    await attached;
  });

  it("drops an expired terminal recovery marker without sending a stale relay frame", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    persisted.activeTurns = [{
      turnId,
      conversationId,
      accountId: "ara",
      recoveryExpiresAt: Date.now() - 1,
      recoveryError: {
        code: "connection_interrupted",
        message: "The connection closed before this reply could be delivered. Please try again.",
        retryable: true,
      },
    }];
    const socket = new FakeSocket();
    const controller = new AbortController();
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: vi.fn(async () => undefined),
      },
    );
    const attached = client.attach({
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    expect(decode(socket).filter((frame) => frame.kind === "turn.error")).toHaveLength(0);
    expect(persisted.activeTurns).toHaveLength(0);

    controller.abort();
    await attached;
  });

  it("retains a transcript-free marker when the process stops before a terminal receipt", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    let finishDispatch!: () => void;
    const finish = new Promise<void>((resolve) => {
      finishDispatch = resolve;
    });
    const account: ResolvedOpenClamAccount = {
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    const makeContext = (controller: AbortController) => ({
      cfg: {},
      accountId: "ara",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "ara" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);

    const firstSocket = new FakeSocket();
    firstSocket.autoPersist = false;
    const firstController = new AbortController();
    const firstClient = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => firstSocket.open());
          return firstSocket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: async ({ sink }) => {
          await sink.partial("working");
          await finish;
          await sink.completed("finished but disconnected");
        },
      },
    );
    const firstAttached = firstClient.attach(makeContext(firstController));
    await waitFor(() => firstSocket.readyState === 1);
    firstSocket.receive(
      JSON.stringify({
        v: 1,
        kind: "turn.submit",
        connectionId,
        conversationId,
        messageId: randomUUID(),
        seq: 1,
        sentAt: Date.now(),
        payload: { turnId, accountId: "ara", text: "Complete after disconnect" },
      }),
    );
    await waitFor(() => decode(firstSocket).some((frame) => frame.kind === "turn.accepted"));
    const accepted = decode(firstSocket).find((frame) => frame.kind === "turn.accepted") as ConnectorFrame;
    firstSocket.receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId,
      payload: { senderSeq: accepted.seq, messageId: accepted.messageId },
    }));
    await waitFor(() => decode(firstSocket).some((frame) => frame.kind === "assistant.delta"));
    finishDispatch();
    await waitFor(() =>
      decode(firstSocket).some((frame) => frame.kind === "assistant.completed") &&
      persisted.activeTurns[0]?.recoveryError?.code === "connection_interrupted"
    );
    expect(persisted.completedTurnIds).not.toContain(turnId);
    firstController.abort();
    await firstAttached;

    const secondSocket = new FakeSocket();
    const secondController = new AbortController();
    const secondClient = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => secondSocket.open());
          return secondSocket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        dispatchTurn: vi.fn(async () => undefined),
      },
    );
    const secondAttached = secondClient.attach(makeContext(secondController));
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    const recovery = decode(secondSocket).find((frame) => frame.kind === "turn.error");
    expect(recovery?.payload).toMatchObject({
      turnId,
      code: "connection_interrupted",
      retryable: true,
    });
    expect(persisted.completedTurnIds).toContain(turnId);
    expect(persisted.activeTurns).toHaveLength(0);
    secondController.abort();
    await secondAttached;
  });

  it("capability-gates activity and persists attachment metadata before the terminal", async () => {
    async function run(capabilities?: Array<"activity-v1" | "attachments-v1">) {
      const connectionId = randomUUID();
      const conversationId = randomUUID();
      const turnId = randomUUID();
      const attachmentId = randomUUID();
      let persisted = initialAdapterState(connectionId);
      const socket = new FakeSocket();
      const controller = new AbortController();
      const account: ResolvedOpenClamAccount = {
        accountId: "ara",
        agentId: "research",
        displayName: "Ara",
        enabled: true,
        configured: true,
        bridgeUrl: "https://bridge.example",
        connectionId,
        adapterTokenFile: "/private/token",
        stateFile: "/private/state",
      };
      const uploadAttachment = vi.fn(async () => ({
        v: 1,
        attachmentId,
        fileName: "ara.png",
        mediaType: "image/png",
        byteCount: 8,
        sha256: "a".repeat(64),
        downloadPath: `/v1/connectors/${connectionId}/attachments/${attachmentId}`,
        expiresAt: Date.now() + 60_000,
      }));
      const client = new OpenClamBridgeClient(
        connectionId,
        account.bridgeUrl,
        account.adapterTokenFile,
        account.stateFile,
        {
          readCredential: async () => "T".repeat(48),
          readState: async () => structuredClone(persisted),
          writeState: async (_path, next) => {
            persisted = structuredClone(next);
          },
          createSocket: () => {
            queueMicrotask(() => socket.open());
            return socket as unknown as WebSocket;
          },
          reconnectDelay: () => 60_000,
          uploadAttachment,
          dispatchTurn: async ({ sink }) => {
            await sink.activity("preparing_files");
            if (capabilities?.includes("attachments-v1")) {
              await sink.attachment({
                fileName: "ara.png",
                mediaType: "image/png",
                buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              });
            }
            await sink.completed(capabilities?.includes("attachments-v1")
              ? "Created 1 file."
              : "Legacy answer");
          },
        },
      );
      const attached = client.attach({
        cfg: {},
        accountId: "ara",
        account,
        abortSignal: controller.signal,
        getStatus: () => ({ accountId: "ara" }),
        setStatus: vi.fn(),
      } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
      await waitFor(() => socket.readyState === 1);
      socket.receive(JSON.stringify({
        v: 1,
        kind: "turn.submit",
        connectionId,
        conversationId,
        messageId: randomUUID(),
        seq: 1,
        sentAt: Date.now(),
        payload: {
          turnId,
          accountId: "ara",
          text: "Create a file",
          ...(capabilities === undefined ? {} : { capabilities }),
        },
      }));
      await waitFor(() => persisted.completedTurnIds.includes(turnId));
      const frames = decode(socket);
      controller.abort();
      await attached;
      return { frames, uploadAttachment };
    }

    const capable = await run(["activity-v1", "attachments-v1"]);
    const kinds = capable.frames.map((frame) => frame.kind);
    expect(kinds).toContain("assistant.activity.upsert");
    expect(kinds.indexOf("assistant.attachment")).toBeGreaterThan(-1);
    expect(kinds.indexOf("assistant.attachment")).toBeLessThan(
      kinds.indexOf("assistant.completed"),
    );
    expect(capable.uploadAttachment).toHaveBeenCalledTimes(1);
    const attachmentFrame = capable.frames.find((frame) =>
      frame.kind === "assistant.attachment"
    );
    expect(attachmentFrame?.payload).toMatchObject({
      turnId: expect.any(String),
      attachmentId: expect.any(String),
      fileName: "ara.png",
      mediaType: "image/png",
      byteCount: 8,
      sha256: "a".repeat(64),
    });
    expect(Object.keys(attachmentFrame?.payload ?? {}).sort()).toEqual([
      "attachmentId",
      "byteCount",
      "downloadPath",
      "expiresAt",
      "fileName",
      "mediaType",
      "sha256",
      "turnId",
    ]);
    expect(attachmentFrame?.payload).not.toHaveProperty("v");
    expect(JSON.stringify(capable.frames)).not.toContain("/private/");
    expect(JSON.stringify(capable.frames)).not.toContain("file://");

    const legacy = await run();
    expect(legacy.frames.filter((frame) =>
      frame.kind === "assistant.activity.upsert" ||
      frame.kind === "assistant.activity.clear" ||
      frame.kind === "assistant.attachment"
    )).toHaveLength(0);
    expect(legacy.uploadAttachment).not.toHaveBeenCalled();
  });

  it("delivers a message-tool file once and completes a media-only turn after the attachment", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    const attachmentId = randomUUID();
    let persisted = initialAdapterState(connectionId);
    const socket = new FakeSocket();
    const controller = new AbortController();
    let releaseTurn!: () => void;
    const holdTurn = new Promise<void>((resolve) => {
      releaseTurn = resolve;
    });
    const account: ResolvedOpenClamAccount = {
      accountId: "main",
      agentId: "main",
      displayName: "Main",
      enabled: true,
      configured: true,
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
    };
    let releaseUpload!: () => void;
    const holdUpload = new Promise<void>((resolve) => {
      releaseUpload = resolve;
    });
    const uploadAttachment = vi.fn(async () => {
      await holdUpload;
      return {
        v: 1 as const,
        attachmentId,
        fileName: "movie.mp4",
        mediaType: "video/mp4",
        byteCount: 5,
        sha256: "a".repeat(64),
        downloadPath: `/v1/connectors/${connectionId}/attachments/${attachmentId}`,
        expiresAt: Date.now() + 60_000,
      };
    });
    const client = new OpenClamBridgeClient(
      connectionId,
      account.bridgeUrl,
      account.adapterTokenFile,
      account.stateFile,
      {
        readCredential: async () => "T".repeat(48),
        readState: async () => structuredClone(persisted),
        writeState: async (_path, next) => {
          persisted = structuredClone(next);
        },
        createSocket: () => {
          queueMicrotask(() => socket.open());
          return socket as unknown as WebSocket;
        },
        reconnectDelay: () => 60_000,
        uploadAttachment,
        dispatchTurn: async () => {
          await holdTurn;
        },
      },
    );
    const attached = client.attach({
      cfg: {},
      accountId: "main",
      account,
      abortSignal: controller.signal,
      getStatus: () => ({ accountId: "main" }),
      setStatus: vi.fn(),
    } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
    await waitFor(() => socket.readyState === 1);
    socket.receive(JSON.stringify({
      v: 1,
      kind: "turn.submit",
      connectionId,
      conversationId,
      messageId: randomUUID(),
      seq: 1,
      sentAt: Date.now(),
      payload: {
        turnId,
        accountId: "main",
        text: "Create a video",
        capabilities: ["attachments-v1"],
      },
    }));
    await waitFor(() => decode(socket).some((frame) => frame.kind === "turn.accepted"));

    const firstTask = client.deliverMediaToActiveConversation({
      accountId: "main",
      conversationId,
      source: "/safe/movie.mp4",
      caption: "Finished at /safe/movie.mp4; notes at /private/notes.txt",
      attachment: {
        fileName: "movie.mp4",
        mediaType: "video/mp4",
        buffer: Buffer.from("video"),
      },
    });
    const duplicateTask = client.deliverMediaToActiveConversation({
      accountId: "main",
      conversationId,
      source: "/safe/movie.mp4",
      caption: "Finished at /safe/movie.mp4; notes at /private/notes.txt",
      attachment: {
        fileName: "movie.mp4",
        mediaType: "video/mp4",
        buffer: Buffer.from("video"),
      },
    });
    await waitFor(() => uploadAttachment.mock.calls.length === 1);
    releaseUpload();
    const [first, duplicate] = await Promise.all([firstTask, duplicateTask]);
    expect(duplicate.attachmentId).toBe(first.attachmentId);
    expect(uploadAttachment).toHaveBeenCalledTimes(1);

    releaseTurn();
    await waitFor(() => persisted.completedTurnIds.includes(turnId));
    const frames = decode(socket);
    expect(frames.filter((frame) => frame.kind === "assistant.attachment")).toHaveLength(1);
    expect(frames.findIndex((frame) => frame.kind === "assistant.attachment")).toBeLessThan(
      frames.findIndex((frame) => frame.kind === "assistant.completed"),
    );
    expect(frames.find((frame) => frame.kind === "assistant.completed")?.payload).toMatchObject({
      turnId,
      text: "Finished at movie.mp4; notes at attached file",
    });
    expect(JSON.stringify(frames)).not.toContain("/safe/");
    expect(JSON.stringify(frames)).not.toContain("/private/");

    controller.abort();
    await attached;
  });
});
