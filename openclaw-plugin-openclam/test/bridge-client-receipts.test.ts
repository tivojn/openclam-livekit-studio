import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type WebSocket from "ws";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { OpenClamBridgeClient, type BridgeClientDependencies } from "../src/bridge-client.js";
import { initialAdapterState } from "../src/credentials.js";
import type { ConnectorFrame, ResolvedOpenClamAccount, WorkStep } from "../src/types.js";

type ReceiptPolicy = (frame: ConnectorFrame, socket: ReceiptSocket) => boolean;

class ReceiptSocket extends EventEmitter {
  readyState = 0;
  readonly sent: string[] = [];
  terminations = 0;

  constructor(readonly index: number, private readonly shouldPersist: ReceiptPolicy) {
    super();
  }

  open(): void {
    this.readyState = 1;
    this.emit("open");
  }

  send(encoded: string): void {
    if (this.readyState !== 1) throw new Error("not_open");
    this.sent.push(encoded);
    const frame = JSON.parse(encoded) as ConnectorFrame;
    if (frame.kind !== "ack" && frame.kind !== "heartbeat" && this.shouldPersist(frame, this)) {
      queueMicrotask(() => this.persist(frame));
    }
  }

  persist(frame: ConnectorFrame): void {
    this.receive(JSON.stringify({
      v: 1,
      kind: "relay.persisted",
      connectionId: frame.connectionId,
      payload: { senderSeq: frame.seq, messageId: frame.messageId },
    }));
  }

  receive(encoded: string): void {
    this.emit("message", Buffer.from(encoded), false);
  }

  ping(): void {}

  close(code = 1000): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close", code, Buffer.alloc(0));
  }

  terminate(): void {
    this.terminations += 1;
    this.close(1006);
  }

  frames(kind?: ConnectorFrame["kind"]): ConnectorFrame[] {
    const frames = this.sent.map((encoded) => JSON.parse(encoded) as ConnectorFrame);
    return kind === undefined ? frames : frames.filter((frame) => frame.kind === kind);
  }
}

const firstWork: WorkStep = {
  stepId: "first", category: "status", state: "running", title: "First step",
};
const secondWork: WorkStep = {
  stepId: "second", category: "status", state: "completed", title: "Second step",
};

function gate() {
  let resolve!: () => void;
  const promise = new Promise<void>((release) => { resolve = release; });
  return { promise, resolve };
}

async function waitForGateOrAbort(promise: Promise<void>, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return;
  let onAbort!: () => void;
  try {
    await Promise.race([
      promise,
      new Promise<void>((resolve) => {
        onAbort = resolve;
        signal.addEventListener("abort", onAbort, { once: true });
      }),
    ]);
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

const cleanups: Array<() => Promise<void>> = [];

async function startHarness(
  dispatchTurn: BridgeClientDependencies["dispatchTurn"],
  shouldPersist: ReceiptPolicy = () => true,
) {
  const connectionId = randomUUID();
  const conversationId = randomUUID();
  const turnId = randomUUID();
  let persisted = initialAdapterState(connectionId);
  const sockets: ReceiptSocket[] = [];
  const controller = new AbortController();
  const log = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
  const account: ResolvedOpenClamAccount = {
    accountId: "main", agentId: "main", displayName: "Main", enabled: true, configured: true,
    bridgeUrl: "https://bridge.example", connectionId,
    adapterTokenFile: "/unused/token", stateFile: "/unused/state",
  };
  const dispatch = vi.fn(dispatchTurn);
  const client = new OpenClamBridgeClient(
    connectionId, account.bridgeUrl, account.adapterTokenFile, account.stateFile,
    {
      readCredential: async () => "T".repeat(48),
      readState: async () => structuredClone(persisted),
      writeState: async (_path, state) => { persisted = structuredClone(state); },
      createSocket: () => {
        const socket = new ReceiptSocket(sockets.length, shouldPersist);
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
    getStatus: () => ({ accountId: "main" }), setStatus: vi.fn(), log,
  } as unknown as ChannelGatewayContext<ResolvedOpenClamAccount>);
  cleanups.push(async () => {
    controller.abort();
    await attached;
  });
  await vi.advanceTimersByTimeAsync(0);
  expect(sockets[0]?.readyState).toBe(1);
  const frame = (kind: "turn.submit" | "turn.cancel", seq: number) => JSON.stringify({
    v: 1, kind, connectionId, conversationId, seq,
    messageId: randomUUID(), sentAt: Date.now(),
    payload: kind === "turn.cancel" ? { turnId } : {
      turnId, accountId: "main", text: "Run the test",
      capabilities: ["work-v1", "activity-v1"],
    },
  });
  sockets[0].receive(frame("turn.submit", 1));
  await vi.advanceTimersByTimeAsync(0);
  return {
    client, sockets, turnId, dispatch, log,
    state: () => persisted,
    cancel: () => sockets.at(-1)!.receive(frame("turn.cancel", 2)),
    terminalFrames: () => sockets.flatMap((socket) => socket.frames()).filter(
      (candidate) => candidate.kind === "assistant.completed" || candidate.kind === "turn.error",
    ),
  };
}

describe("bounded relay receipts and terminal priority", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(async () => {
    try {
      for (const cleanup of cleanups.splice(0)) await cleanup();
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves healthy queued work and its revisions before the completed result", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("actual result");
    });
    const frames = h.sockets[0].frames();
    expect(frames.filter((frame) => frame.kind === "assistant.work.upsert").map(
      (frame) => [frame.payload.stepId, frame.payload.revision],
    )).toEqual([["first", 1], ["second", 2]]);
    expect(frames.at(-1)?.kind).toBe("assistant.completed");
    expect(h.state().completedTurnIds).toContain(h.turnId);
    expect(h.log.warn).not.toHaveBeenCalled();
  });

  it("retries identical work bytes on the same open socket and accepts one late receipt", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("actual result");
    }, (frame, socket) => frame.kind !== "assistant.work.upsert" ||
      frame.payload.stepId !== "first" || socket.frames().filter(
        (candidate) => candidate.messageId === frame.messageId,
      ).length > 1);
    const firstEncoded = h.sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "assistant.work.upsert")!;
    expect(h.terminalFrames()).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(h.sockets).toHaveLength(1);
    expect(h.sockets[0].sent.filter((encoded) => encoded === firstEncoded)).toHaveLength(2);
    expect(h.sockets[0].frames("assistant.work.upsert").map(
      (frame) => frame.payload.revision,
    )).toEqual([1, 1, 2]);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    h.sockets[0].persist(JSON.parse(firstEncoded) as ConnectorFrame);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.sockets[0].terminations).toBe(0);
  });

  it("finishes without Cancel when a work receipt is missing and more work is queued", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("model really completed");
    }, (frame) => frame.kind !== "assistant.work.upsert");
    expect(h.sockets[0].frames("assistant.work.upsert")).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1_999);
    expect(h.terminalFrames()).toHaveLength(0);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    await vi.advanceTimersByTimeAsync(1);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.terminalFrames()[0].payload.text).toBe("model really completed");
    expect(h.state().completedTurnIds).toContain(h.turnId);
    expect(h.log.warn).toHaveBeenCalledWith(expect.stringContaining("work_drain_receipt_timeout"));
    const lateWork = h.sockets[0].frames("assistant.work.upsert")[0];
    h.sockets[0].persist(lateWork);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.sockets).toHaveLength(1);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().activeTurns).toHaveLength(0);
    expect(h.sockets[0].frames("assistant.work.upsert").some(
      (frame) => frame.payload.stepId === "second",
    )).toBe(false);
  });

  it("uses one total work drain budget, not a fresh timeout for every step", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("actual result");
    }, (frame) => frame.kind !== "assistant.work.upsert");
    await vi.advanceTimersByTimeAsync(1_500);
    h.sockets[0].persist(h.sockets[0].frames("assistant.work.upsert")[0]);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.sockets[0].frames("assistant.work.upsert").at(-1)?.payload.stepId).toBe("second");
    await vi.advanceTimersByTimeAsync(499);
    expect(h.terminalFrames()).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(1);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });

  it("does not confuse the work deadline or Cancel with a persisted completed terminal", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("completed before Cancel");
    }, (frame) => frame.kind !== "assistant.work.upsert" && frame.kind !== "assistant.completed");
    await vi.advanceTimersByTimeAsync(2_000);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    expect(h.state().activeTurns[0]?.recoveryError?.code).toBe("connection_interrupted");
    h.cancel();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.terminalFrames()[0].kind).toBe("assistant.completed");
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    h.sockets[0].persist(h.terminalFrames()[0]);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.sockets).toHaveLength(1);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
  });

  it("cancels an unfinished model turn immediately despite a stuck work receipt", async () => {
    const h = await startHarness(async ({ sink, signal }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await waitForGateOrAbort(new Promise<void>(() => undefined), signal);
      throw new Error("aborted");
    }, (frame) => frame.kind !== "assistant.work.upsert" && frame.kind !== "turn.error");
    h.cancel();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.terminalFrames()[0].kind).toBe("turn.error");
    expect(h.terminalFrames()[0].payload).toMatchObject({ code: "cancelled", retryable: false });
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    h.sockets[0].persist(h.terminalFrames()[0]);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    expect(h.sockets[0].frames("assistant.completed")).toHaveLength(0);
  });

  it("Cancel releases an already completed turn's work drain without fabricating its terminal receipt", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("model completed before the cancel request");
    }, (frame) => frame.kind !== "assistant.work.upsert" && frame.kind !== "assistant.completed");
    await vi.advanceTimersByTimeAsync(100);
    expect(h.terminalFrames()).toHaveLength(0);
    h.cancel();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.terminalFrames()).toHaveLength(1);
    const terminal = h.terminalFrames()[0];
    expect(terminal.kind).toBe("assistant.completed");
    expect(terminal.payload.text).toBe("model completed before the cancel request");
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    expect(h.log.warn).not.toHaveBeenCalled();
    h.sockets[0].persist(terminal);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.sockets).toHaveLength(1);
  });

  it("reconnects after three unanswered transmissions and replays work without rerunning the model", async () => {
    const complete = gate();
    const h = await startHarness(async ({ sink, signal }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await waitForGateOrAbort(complete.promise, signal);
      await sink.completed("actual result");
    }, (frame, socket) => frame.kind !== "assistant.work.upsert" || socket.index > 0);
    const firstEncoded = h.sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "assistant.work.upsert")!;
    await vi.advanceTimersByTimeAsync(2_999);
    expect(h.sockets).toHaveLength(1);
    expect(h.sockets[0].readyState).toBe(1);
    expect(h.sockets[0].sent.filter((encoded) => encoded === firstEncoded)).toHaveLength(3);
    await vi.advanceTimersByTimeAsync(2);
    expect(h.sockets[0].terminations).toBe(1);
    expect(h.sockets[1]?.sent).toContain(firstEncoded);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(250);
    expect(h.sockets[1].frames("assistant.work.upsert").map(
      (frame) => frame.payload.revision,
    )).toEqual([1, 2]);
    complete.resolve();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });

  it("retains the exact terminal and recovery marker across watchdog reconnects until its real ACK", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.completed("must really persist");
    }, (frame) => frame.kind !== "assistant.completed");
    const encoded = h.sockets[0].sent.find((value) =>
      (JSON.parse(value) as ConnectorFrame).kind === "assistant.completed")!;
    await vi.advanceTimersByTimeAsync(3_001);
    expect(h.sockets[0].terminations).toBe(1);
    expect(h.sockets[1]?.sent).toContain(encoded);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    expect(h.state().activeTurns[0]?.recoveryError?.code).toBe("connection_interrupted");
    expect(new Set(h.terminalFrames().map((frame) => JSON.stringify(frame))).size).toBe(1);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
    h.sockets[1].persist(JSON.parse(encoded) as ConnectorFrame);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.sockets).toHaveLength(2);
  });

  it("replays uncertain work before the completed result after the shared drain budget expires", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.work!(firstWork);
      await sink.work!(secondWork);
      await sink.completed("actual result, not a timeout fallback");
    }, (frame, socket) => socket.index > 0 ||
      (frame.kind !== "assistant.work.upsert" && frame.kind !== "assistant.completed"));
    await vi.advanceTimersByTimeAsync(2_000);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    const work = h.sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "assistant.work.upsert")!;
    const terminal = h.sockets[0].sent.find((encoded) =>
      (JSON.parse(encoded) as ConnectorFrame).kind === "assistant.completed")!;
    await vi.advanceTimersByTimeAsync(1_001);
    expect(h.sockets).toHaveLength(2);
    expect(h.sockets[0].terminations).toBe(1);
    const replayed = h.sockets[1].sent.filter((encoded) => encoded === work || encoded === terminal);
    expect(replayed).toEqual([work, terminal]);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    expect(h.state().activeTurns).toHaveLength(0);
    expect(h.sockets.flatMap((socket) => socket.frames("assistant.work.upsert")).some(
      (frame) => frame.payload.stepId === "second",
    )).toBe(false);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.sockets).toHaveLength(2);
  });

  it("retires a missing activity receipt only after the actual terminal receipt", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.activity!("thinking");
      await sink.completed("actual result");
    }, (frame) => frame.kind !== "assistant.activity.upsert" && frame.kind !== "assistant.completed");
    expect(h.sockets[0].frames("assistant.activity.upsert")).toHaveLength(1);
    expect(h.terminalFrames()).toHaveLength(1);
    expect(h.state().completedTurnIds).not.toContain(h.turnId);
    await vi.advanceTimersByTimeAsync(1_000);
    expect(h.sockets[0].frames("assistant.activity.upsert")).toHaveLength(2);
    h.sockets[0].persist(h.terminalFrames()[0]);
    await vi.advanceTimersByTimeAsync(0);
    expect(h.state().completedTurnIds).toContain(h.turnId);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(h.sockets).toHaveLength(1);
    expect(h.sockets[0].terminations).toBe(0);
    expect(h.sockets[0].frames("assistant.activity.upsert")).toHaveLength(2);
  });

  it("does not execute a turn before its acceptance receipt even after the watchdog reconnects", async () => {
    const h = await startHarness(async ({ sink }) => {
      await sink.completed("accepted once");
    }, (frame, socket) => frame.kind !== "turn.accepted" || socket.index > 0);
    const encoded = h.sockets[0].sent.find((value) =>
      (JSON.parse(value) as ConnectorFrame).kind === "turn.accepted")!;
    expect(h.dispatch).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(2_999);
    expect(h.dispatch).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(2);
    expect(h.sockets[1]?.sent).toContain(encoded);
    expect(h.dispatch).toHaveBeenCalledTimes(1);
    expect(h.state().completedTurnIds).toContain(h.turnId);
  });
});
