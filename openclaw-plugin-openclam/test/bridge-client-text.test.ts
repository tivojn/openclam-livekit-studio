import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { OpenClamBridgeClient, type BridgeClientDependencies } from "../src/bridge-client.js";
import { initialAdapterState } from "../src/credentials.js";
import type { ConnectorFrame, ResolvedOpenClamAccount } from "../src/types.js";

type ReceiptPolicy = (frame: ConnectorFrame, socket: TextSocket) => boolean;
type Sink = Parameters<BridgeClientDependencies["dispatchTurn"]>[0]["sink"];

class TextSocket extends EventEmitter {
  readyState = 0;
  readonly sent: string[] = [];
  constructor(readonly index: number, private readonly receipts: ReceiptPolicy) { super(); }
  open(): void { this.readyState = 1; this.emit("open"); }
  send(encoded: string): void {
    if (this.readyState !== 1) throw new Error("not_open");
    this.sent.push(encoded);
    const frame = JSON.parse(encoded) as ConnectorFrame;
    if (frame.kind !== "ack" && frame.kind !== "heartbeat" && this.receipts(frame, this)) {
      queueMicrotask(() => this.persist(frame));
    }
  }
  persist(frame: ConnectorFrame): void {
    this.receive({ v: 1, kind: "relay.persisted", connectionId: frame.connectionId,
      payload: { senderSeq: frame.seq, messageId: frame.messageId } });
  }
  receive(frame: unknown): void { this.emit("message", Buffer.from(JSON.stringify(frame)), false); }
  ping(): void {}
  close(code = 1000): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close", code, Buffer.alloc(0));
  }
  terminate(): void { this.close(1006); }
  frames(kind: ConnectorFrame["kind"]): ConnectorFrame[] {
    return this.sent.map((text) => JSON.parse(text) as ConnectorFrame).filter((f) => f.kind === kind);
  }
}

const cleanups: Array<() => Promise<void>> = [];

async function startHarness(receipts: ReceiptPolicy = () => true) {
  const connectionId = randomUUID();
  const conversationId = randomUUID();
  const turnId = randomUUID();
  const controller = new AbortController();
  let persisted = initialAdapterState(connectionId);
  let sink!: Sink;
  let release!: () => void;
  const hold = new Promise<void>((resolve) => { release = resolve; });
  const sockets: TextSocket[] = [];
  const account: ResolvedOpenClamAccount = {
    accountId: "main", agentId: "main", displayName: "Main", enabled: true, configured: true,
    bridgeUrl: "https://bridge.example", connectionId,
    adapterTokenFile: "/unused/token", stateFile: "/unused/state",
  };
  const dispatch = vi.fn(async (params: Parameters<BridgeClientDependencies["dispatchTurn"]>[0]) => {
    sink = params.sink;
    let onAbort!: () => void;
    try {
      await Promise.race([hold, new Promise<void>((resolve) => {
        onAbort = resolve;
        if (params.signal.aborted) resolve();
        else params.signal.addEventListener("abort", onAbort, { once: true });
      })]);
    } finally {
      params.signal.removeEventListener("abort", onAbort);
    }
  });
  const client = new OpenClamBridgeClient(
    connectionId, account.bridgeUrl, account.adapterTokenFile, account.stateFile, {
      readCredential: async () => "T".repeat(48),
      readState: async () => structuredClone(persisted),
      writeState: async (_path, state) => { persisted = structuredClone(state); },
      createSocket: () => {
        const socket = new TextSocket(sockets.length, receipts);
        sockets.push(socket);
        queueMicrotask(() => socket.open());
        return socket as unknown as WebSocket;
      },
      reconnectDelay: () => 0,
      dispatchTurn: dispatch,
      uploadAttachment: vi.fn(async () => { throw new Error("unexpected_upload"); }),
    },
  );
  const attached = client.attach({
    cfg: {}, accountId: "main", account, abortSignal: controller.signal,
    getStatus: () => ({ accountId: "main" }), setStatus: vi.fn(),
    log: { info: vi.fn(), warn: vi.fn(), error: vi.fn() },
  } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
  cleanups.push(async () => { controller.abort(); release(); await attached; });
  await vi.advanceTimersByTimeAsync(0);
  sockets[0].receive({
    v: 1, kind: "turn.submit", connectionId, conversationId, seq: 1,
    messageId: randomUUID(), sentAt: Date.now(),
    payload: { turnId, accountId: "main", text: "Run the test", capabilities: ["work-v1"] },
  });
  await vi.advanceTimersByTimeAsync(0);
  expect(dispatch).toHaveBeenCalledTimes(1);
  return {
    client, sockets, sink, release, conversationId, turnId, dispatch,
    send: (text: string, rest: Partial<Parameters<typeof client.deliverTextToActiveConversation>[0]> = {}) =>
      client.deliverTextToActiveConversation({ accountId: "main", conversationId, text, ...rest }),
    cancel: () => sockets.at(-1)!.receive({
      v: 1, kind: "turn.cancel", connectionId, conversationId, seq: 2,
      messageId: randomUUID(), sentAt: Date.now(), payload: { turnId },
    }),
    state: () => persisted,
    frames: (kind: ConnectorFrame["kind"]) => sockets.flatMap((socket) => socket.frames(kind)),
  };
}

async function settle<T>(promise: Promise<T>): Promise<T> {
  await vi.advanceTimersByTimeAsync(0);
  return await promise;
}

describe("paired active-turn outbound text", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(async () => {
    try {
      for (const cleanup of cleanups.splice(0)) await cleanup();
      expect(vi.getTimerCount()).toBe(0);
    } finally { vi.useRealTimers(); }
  });

  it("acknowledges the actual persisted delta without finishing the running task", async () => {
    const h = await startHarness((frame) => frame.kind !== "assistant.delta");
    const promise = h.send("Video ready", { replyToId: h.turnId });
    let settled = false;
    void promise.then(() => { settled = true; });
    await vi.advanceTimersByTimeAsync(0);
    const frame = h.frames("assistant.delta")[0];
    expect(frame.payload).toMatchObject({ turnId: h.turnId, revision: 1, text: "Video ready" });
    expect(settled).toBe(false);
    expect(h.frames("assistant.completed")).toHaveLength(0);
    h.sockets[0].persist(frame);
    expect(await settle(promise)).toEqual({ messageId: frame.messageId, conversationId: h.conversationId });
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    await settle(h.sink.completed("A different final answer"));
    h.release();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.frames("assistant.completed")[0].payload.text).toBe("Video ready\n\nA different final answer");
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });

  it("preserves tool text through later streaming and does not duplicate an identical final", async () => {
    const h = await startHarness();
    await settle(h.sink.partial("Checking"));
    await settle(h.send("Video ready"));
    await h.sink.partial("The file is now ready");
    await vi.advanceTimersByTimeAsync(200);
    expect(h.frames("assistant.delta").map((f) => f.payload.text)).toEqual([
      "Checking", "Video ready\n\nChecking", "Video ready\n\nThe file is now ready",
    ]);
    expect(h.frames("assistant.delta").map((f) => f.payload.revision)).toEqual([1, 2, 3]);
    await settle(h.sink.completed("Video ready"));
    expect(h.frames("assistant.completed")[0].payload.text).toBe("Video ready");
  });

  it("does not duplicate tool text contained in an expanded final answer", async () => {
    const h = await startHarness();
    await settle(h.send("Video ready"));
    await settle(h.sink.completed("Video ready\n\nHere are the details."));
    expect(h.frames("assistant.completed")[0].payload.text)
      .toBe("Video ready\n\nHere are the details.");
  });

  it("retains multiple tool updates without duplicating an earlier block repeated by the final", async () => {
    const h = await startHarness();
    await settle(h.send("Video ready"));
    await settle(h.send("Download available"));
    await settle(h.sink.completed("Video ready\n\nFinal details"));
    expect(h.frames("assistant.completed")[0].payload.text)
      .toBe("Download available\n\nVideo ready\n\nFinal details");
  });

  it("completes a tool-only NO_REPLY run using its delivered text, not an empty-reply error", async () => {
    const h = await startHarness();
    await settle(h.send("The finished video is attached."));
    h.release();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.frames("turn.error")).toHaveLength(0);
    expect(h.frames("assistant.completed")[0].payload.text).toBe("The finished video is attached.");
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });

  it("retries the identical event across reconnect and returns one event ID for concurrent retries", async () => {
    const h = await startHarness((frame, socket) => frame.kind !== "assistant.delta" || socket.index > 0);
    const first = h.send("Video ready", { deliveryId: "intent-1" });
    const duplicate = h.send("Video ready", { deliveryId: "intent-1" });
    await vi.advanceTimersByTimeAsync(3_001);
    const [one, two] = await Promise.all([first, duplicate]);
    const transmissions = h.frames("assistant.delta");
    expect(h.sockets).toHaveLength(2);
    expect(transmissions.length).toBeGreaterThan(1);
    expect(new Set(transmissions.map((frame) => JSON.stringify(frame))).size).toBe(1);
    expect(one).toEqual(two);
    expect(one.messageId).toBe(transmissions[0].messageId);
    expect(await settle(h.send("Video ready", { deliveryId: "intent-1" }))).toEqual(one);
    expect(h.frames("assistant.delta")).toHaveLength(transmissions.length);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
  });

  it("bounds a missing-receipt caller but retains the same uncertain event for a later retry", async () => {
    const h = await startHarness((frame) => frame.kind !== "assistant.delta");
    const timedOut = expect(h.send("Video ready", { deliveryId: "intent-1" }))
      .rejects.toThrow("openclam_text_delivery_unconfirmed");
    await vi.advanceTimersByTimeAsync(10_000);
    await timedOut;
    expect(h.frames("assistant.completed")).toHaveLength(0);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    const same = h.send("Video ready", { deliveryId: "intent-1" });
    const frame = h.frames("assistant.delta")[0];
    h.sockets.at(-1)!.persist(frame);
    expect(await settle(same)).toEqual({ messageId: frame.messageId, conversationId: h.conversationId });
    expect(new Set(h.frames("assistant.delta").map((f) => f.messageId)).size).toBe(1);
  });

  it("does not deadlock completion behind a missing text receipt or fabricate text success", async () => {
    const h = await startHarness((frame) => frame.kind !== "assistant.delta");
    const unconfirmed = expect(h.send("Video ready"))
      .rejects.toThrow("openclam_text_delivery_unconfirmed");
    await vi.advanceTimersByTimeAsync(0);
    await settle(h.sink.completed("Final details"));
    await unconfirmed;
    expect(h.frames("assistant.completed")).toHaveLength(1);
    expect(h.frames("assistant.completed")[0].payload.text).toBe("Video ready\n\nFinal details");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.frames("assistant.delta")).toHaveLength(1);
    expect(h.sockets).toHaveLength(1);
  });

  it("cancel releases an unacknowledged sender without succeeding or selecting completion", async () => {
    const h = await startHarness((frame) => frame.kind !== "assistant.delta");
    const unconfirmed = expect(h.send("Video ready"))
      .rejects.toThrow("openclam_text_delivery_unconfirmed");
    await vi.advanceTimersByTimeAsync(0);
    const late = h.frames("assistant.delta")[0];
    h.cancel();
    await vi.advanceTimersByTimeAsync(0);
    await unconfirmed;
    h.sockets.at(-1)!.persist(late);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(h.frames("assistant.completed")).toHaveLength(0);
    expect(h.frames("turn.error")).toHaveLength(1);
    expect(h.frames("turn.error")[0].payload.code).toBe("cancelled");
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });

  it("serializes concurrent text reservations and stream flushes without reusing revisions", async () => {
    const h = await startHarness();
    const first = h.send("First update", { deliveryId: "first" });
    const stream = h.sink.partial("Model partial");
    const second = h.send("Second update", { deliveryId: "second" });
    await vi.advanceTimersByTimeAsync(200);
    await Promise.all([first, stream, second]);
    const frames = h.frames("assistant.delta");
    const revisions = frames.map((frame) => frame.payload.revision);
    expect(new Set(revisions).size).toBe(revisions.length);
    expect(revisions).toEqual([...revisions].sort((a, b) => Number(a) - Number(b)));
    expect(frames.at(-1)?.payload.text).toBe("First update\n\nSecond update\n\nModel partial");
    await settle(h.sink.completed("Final answer"));
    expect(h.frames("assistant.completed")[0].payload.text)
      .toBe("First update\n\nSecond update\n\nFinal answer");
  });

  it("rejects inactive, cross-account/conversation and stale reply targets before dispatch", async () => {
    const h = await startHarness();
    const hook = vi.fn(async () => {});
    for (const params of [{ accountId: "other" }, { conversationId: randomUUID() }]) {
      await expect(h.send("Update", { ...params, onPlatformSendDispatch: hook }))
        .rejects.toThrow("openclam_conversation_inactive");
    }
    await expect(h.send("Update", { replyToId: randomUUID(), onPlatformSendDispatch: hook }))
      .rejects.toThrow("openclam_reply_not_current_turn");
    await settle(h.sink.completed("Normal final"));
    await expect(h.send("Too late", { onPlatformSendDispatch: hook }))
      .rejects.toThrow("openclam_conversation_inactive");
    expect(hook).not.toHaveBeenCalled();
    expect(h.frames("assistant.delta")).toHaveLength(0);
    expect(h.frames("assistant.completed")[0].payload.text).toBe("Normal final");
  });

  it("deduplicates repeated tool text and rejects conflicting host identities", async () => {
    const h = await startHarness();
    const hook = vi.fn(async () => {});
    const one = await settle(h.send("Update", { deliveryId: "intent", onPlatformSendDispatch: hook }));
    expect(await settle(h.send("Update", { deliveryId: "intent", onPlatformSendDispatch: hook }))).toEqual(one);
    await expect(h.send("Different update", { deliveryId: "intent" }))
      .rejects.toThrow("openclam_text_delivery_conflict");
    expect(hook).toHaveBeenCalledTimes(1);
    expect(h.frames("assistant.delta")).toHaveLength(1);
    await settle(h.send("Another"));
    await settle(h.send("Another"));
    expect(h.frames("assistant.delta")).toHaveLength(2);
  });

  it("redacts private paths and refuses empty or oversized text rather than reporting truncated success", async () => {
    const h = await startHarness();
    await expect(h.send("  ")).rejects.toThrow("openclam_text_missing");
    await expect(h.send("x".repeat(32_001))).rejects.toThrow("openclam_text_too_large");
    const oversized = expect(h.send("界".repeat(24_000))).rejects.toThrow("frame_too_large");
    await vi.advanceTimersByTimeAsync(0);
    await oversized;
    expect(h.frames("assistant.delta")).toHaveLength(0);
    await settle(h.send("File: /Users/example/private/movie.mp4"));
    expect(String(h.frames("assistant.delta")[0].payload.text)).not.toContain("/Users/");
  });

  it("does not let a blocked host dispatch hook hold terminal completion open", async () => {
    const h = await startHarness();
    let releaseHook!: () => void;
    const hook = new Promise<void>((resolve) => { releaseHook = resolve; });
    const blocked = expect(h.send("Never sent", { onPlatformSendDispatch: () => hook }))
      .rejects.toThrow("openclam_conversation_inactive");
    await settle(h.sink.completed("Real final"));
    expect(h.frames("assistant.completed")).toHaveLength(1);
    expect(h.frames("assistant.completed")[0].payload.text).toBe("Real final");
    releaseHook();
    await vi.advanceTimersByTimeAsync(0);
    await blocked;
    expect(h.frames("assistant.delta")).toHaveLength(0);
  });
});
