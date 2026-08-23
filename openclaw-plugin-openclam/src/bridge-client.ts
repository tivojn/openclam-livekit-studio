import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import WebSocket, { type ClientOptions, type RawData } from "ws";
import { uploadOpenClamAttachment } from "./attachment-upload.js";
import {
  readAdapterCredential,
  readAdapterState,
  writeAdapterState,
} from "./credentials.js";
import { dispatchOpenClamTurn } from "./inbound.js";
import {
  createFrame,
  encodeFrame,
  encodeFrameWithTextBudget,
  MAX_TEXT_LENGTH,
  parseBridgeInbound,
  safeTurnErrorPayload,
  truncateUnicode,
} from "./protocol.js";
import type {
  AdapterState,
  ActivityStatus,
  ClientFrame,
  ConnectorFrame,
  FrameKind,
  OpenClamAttachmentUpload,
  ResolvedOpenClamAccount,
  TurnSubmitFrame,
  WorkStep,
} from "./types.js";

type AccountContext = ChannelGatewayContext<ResolvedOpenClamAccount>;

export type BridgeClientDependencies = {
  readCredential: typeof readAdapterCredential;
  readState: typeof readAdapterState;
  writeState: typeof writeAdapterState;
  createSocket: (url: string, options: ClientOptions) => WebSocket;
  dispatchTurn: typeof dispatchOpenClamTurn;
  reconnectDelay: (attempt: number) => number;
  uploadAttachment: typeof uploadOpenClamAttachment;
};

const defaultDependencies: BridgeClientDependencies = {
  readCredential: readAdapterCredential,
  readState: readAdapterState,
  writeState: writeAdapterState,
  createSocket: (url, options) => new WebSocket(url, options),
  dispatchTurn: dispatchOpenClamTurn,
  reconnectDelay: (attempt) => Math.min(30_000, 500 * 2 ** Math.min(attempt, 6)),
  uploadAttachment: uploadOpenClamAttachment,
};

type ActiveTurn = {
  frame: TurnSubmitFrame;
  controller: AbortController;
  acceptanceTask?: Promise<boolean>;
  revision: number;
  terminal: boolean;
  terminalPersisted: boolean;
  terminalTask?: Promise<boolean>;
  pendingDelta?: string;
  lastDeltaText: string;
  deltaTimer?: NodeJS.Timeout;
  deltaFlushTask?: Promise<void>;
  lastDeltaAt: number;
  deltaCount: number;
  activityRevision: number;
  activityCount: number;
  lastActivityStatus?: ActivityStatus | null;
  pendingActivityStatus?: ActivityStatus | null;
  activityTimer?: NodeJS.Timeout;
  activityTask?: Promise<void>;
  lastActivityFrameAt: number;
  workRevision: number;
  workCount: number;
  workStepIds: Set<string>;
  pendingWork: Map<string, WorkStep>;
  lastWork: Map<string, string>;
  workTimer?: NodeJS.Timeout;
  workTask?: Promise<void>;
  lastWorkFrameAt: number;
};

type QueuedFrame = {
  encoded: string;
  kind: FrameKind;
  seq: number;
};

type PendingRelayFrame = {
  frame: ConnectorFrame;
  encoded: string;
  resolve: (persisted: boolean) => void;
};

type SafeRecoveryError = {
  code: string;
  message: string;
  retryable: boolean;
};

const DELTA_INTERVAL_MS = 200;
const MAX_DELTA_FRAMES_PER_TURN = 12;
const MAX_OUTBOUND_QUEUE = 64;
const MAX_ACTIVE_TURNS = 8;
const RECOVERY_MARKER_TTL_MS = 15 * 60 * 1_000;
const ACTIVITY_INTERVAL_MS = 750;
const MAX_ACTIVITY_FRAMES_PER_TURN = 32;
const WORK_INTERVAL_MS = 250;
const MAX_WORK_STEPS_PER_TURN = 12;
const MAX_WORK_FRAMES_PER_TURN = 64;

function buildEventsUrl(bridgeUrl: string, connectionId: string): string {
  const base = new URL(bridgeUrl);
  if (base.username || base.password || base.search || base.hash || base.pathname !== "/") {
    throw new Error("invalid_bridge_url");
  }
  const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(base.hostname);
  if (base.protocol === "https:") base.protocol = "wss:";
  else if (base.protocol === "http:" && local) base.protocol = "ws:";
  else throw new Error("invalid_bridge_url");
  base.pathname = `/v1/adapters/${connectionId}/events`;
  base.search = "";
  base.hash = "";
  return base.toString();
}

function waitForAbort(signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
}

function abortableDelay(milliseconds: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });
}

function socketText(data: RawData, isBinary: boolean): string {
  if (isBinary) throw new Error("binary_frame_rejected");
  if (typeof data === "string") return data;
  if (Array.isArray(data)) return Buffer.concat(data).toString("utf8");
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  return Buffer.from(new Uint8Array(data)).toString("utf8");
}

export class OpenClamBridgeClient {
  private readonly accounts = new Map<string, AccountContext>();
  private readonly activeTurns = new Map<string, ActiveTurn>();
  private readonly lifecycle = new AbortController();
  private readonly outboundQueue: QueuedFrame[] = [];
  private readonly relayOutbox = new Map<string, PendingRelayFrame>();
  private readonly turnTasks = new Set<Promise<void>>();
  private readonly deltaTasks = new Set<Promise<void>>();
  private readonly activityTasks = new Set<Promise<void>>();
  private readonly workTasks = new Set<Promise<void>>();
  private readonly deps: BridgeClientDependencies;
  private state?: AdapterState;
  private token = "";
  private socket?: WebSocket;
  private runTask?: Promise<void>;
  private stateTask: Promise<void> = Promise.resolve();
  private inboundTask: Promise<void> = Promise.resolve();
  private recoveryTask: Promise<void> = Promise.resolve();
  private reconnectAttempts = 0;

  constructor(
    readonly connectionId: string,
    private readonly bridgeUrl: string,
    private readonly tokenFile: string,
    private readonly stateFile: string,
    dependencies: Partial<BridgeClientDependencies> = {},
  ) {
    this.deps = { ...defaultDependencies, ...dependencies };
  }

  get accountCount(): number {
    return this.accounts.size;
  }

  async attach(ctx: AccountContext): Promise<void> {
    const account = ctx.account;
    if (
      account.connectionId !== this.connectionId ||
      account.bridgeUrl !== this.bridgeUrl ||
      account.adapterTokenFile !== this.tokenFile ||
      account.stateFile !== this.stateFile
    ) {
      throw new Error("inconsistent_gateway_connection");
    }
    const existing = this.accounts.get(account.accountId);
    if (existing && existing !== ctx) throw new Error("duplicate_openclam_account");
    this.accounts.set(account.accountId, ctx);
    try {
      await this.ensureStarted();
      this.setAccountStatus(ctx, { running: true, configured: true });
      if (this.socket?.readyState === WebSocket.OPEN) {
        this.detach(this.recoverInterruptedTurns(), "recovery_failed");
      }
      await Promise.race([
        waitForAbort(ctx.abortSignal),
        waitForAbort(this.lifecycle.signal),
      ]);
    } finally {
      this.accounts.delete(account.accountId);
      this.setAccountStatus(ctx, { running: false, connected: false });
      if (this.accounts.size === 0) await this.stop();
    }
  }

  async stop(): Promise<void> {
    if (!this.lifecycle.signal.aborted) this.lifecycle.abort();
    this.socket?.close(1000, "shutdown");
    await this.runTask?.catch(() => undefined);
    await this.inboundTask.catch(() => undefined);
    for (const active of this.activeTurns.values()) {
      if (active.deltaTimer) clearTimeout(active.deltaTimer);
      if (active.activityTimer) clearTimeout(active.activityTimer);
      if (active.workTimer) clearTimeout(active.workTimer);
      active.controller.abort();
    }
    for (const pending of this.relayOutbox.values()) pending.resolve(false);
    this.relayOutbox.clear();
    await Promise.all([...this.turnTasks]);
    await Promise.all([...this.deltaTasks]);
    await Promise.all([...this.activityTasks]);
    await Promise.all([...this.workTasks]);
    await this.recoveryTask.catch(() => undefined);
    await this.stateTask.catch(() => undefined);
  }

  private async ensureStarted(): Promise<void> {
    if (!this.state) {
      this.token = await this.deps.readCredential(this.tokenFile);
      this.state = await this.deps.readState(this.stateFile, this.connectionId);
    }
    if (!this.runTask) this.runTask = this.runLoop();
  }

  private async runLoop(): Promise<void> {
    while (!this.lifecycle.signal.aborted) {
      try {
        await this.connectOnce();
      } catch {
        this.log("warn", "connection_attempt_failed");
      }
      if (this.lifecycle.signal.aborted) break;
      this.reconnectAttempts += 1;
      this.updateAllStatuses({
        connected: false,
        reconnectAttempts: this.reconnectAttempts,
      });
      await abortableDelay(this.deps.reconnectDelay(this.reconnectAttempts), this.lifecycle.signal);
    }
  }

  private async connectOnce(): Promise<void> {
    const url = buildEventsUrl(this.bridgeUrl, this.connectionId);
    const socket = this.deps.createSocket(url, {
      headers: { Authorization: `Bearer ${this.token}` },
      maxPayload: 65_536,
      followRedirects: false,
      handshakeTimeout: 15_000,
    });
    this.socket = socket;
    await new Promise<void>((resolve, reject) => {
      let opened = false;
      let heartbeat: NodeJS.Timeout | undefined;
      const cleanup = () => {
        if (heartbeat) clearInterval(heartbeat);
        this.lifecycle.signal.removeEventListener("abort", onAbort);
      };
      const onAbort = () => socket.close(1000, "shutdown");
      this.lifecycle.signal.addEventListener("abort", onAbort, { once: true });
      socket.once("open", () => {
        opened = true;
        this.reconnectAttempts = 0;
        this.updateAllStatuses({
          connected: true,
          reconnectAttempts: 0,
          lastConnectedAt: Date.now(),
        });
        this.log("info", "connected");
        this.flushPendingTransmissions();
        this.detach(
          this.send(
            "heartbeat",
            { lastReceivedSeq: this.requireState().lastReceivedSeq },
            undefined,
            undefined,
            false,
          ),
          "heartbeat_failed",
        );
        this.detach(this.flushActiveDeltas(), "delta_flush_failed");
        this.flushActiveActivities();
        this.flushActiveWork();
        this.detach(this.recoverInterruptedTurns(), "recovery_failed");
        heartbeat = setInterval(() => {
          if (socket.readyState === WebSocket.OPEN) socket.ping();
        }, 30_000);
      });
      socket.on("message", (data, isBinary) => {
        this.inboundTask = this.inboundTask
          .then(async () => this.handleMessage(socketText(data, isBinary)))
          .catch(() => {
            this.log("warn", "inbound_frame_rejected");
            socket.close(1008, "invalid_frame");
          });
      });
      socket.once("unexpected-response", (_request, response) => {
        cleanup();
        this.log("warn", `handshake_rejected status=${response.statusCode}`);
        if (response.statusCode === 401 || response.statusCode === 404) {
          this.retireConnection("connection_retired");
        }
        reject(new Error("handshake_rejected"));
      });
      socket.once("error", () => {
        if (!opened) {
          cleanup();
          reject(new Error("socket_error"));
        }
      });
      socket.once("close", (code) => {
        cleanup();
        if (this.socket === socket) this.socket = undefined;
        for (const active of this.activeTurns.values()) {
          if (active.deltaTimer) clearTimeout(active.deltaTimer);
          active.deltaTimer = undefined;
          if (active.activityTimer) clearTimeout(active.activityTimer);
          active.activityTimer = undefined;
          if (active.workTimer) clearTimeout(active.workTimer);
          active.workTimer = undefined;
        }
        this.updateAllStatuses({ connected: false, lastDisconnect: { at: Date.now(), status: code } });
        this.log("info", `disconnected code=${code}`);
        if (code === 1008 || code === 4003) {
          this.retireConnection("connection_retired");
        }
        resolve();
      });
    });
  }

  private async handleMessage(raw: string): Promise<void> {
    if (this.lifecycle.signal.aborted) return;
    const frame = parseBridgeInbound(raw, this.connectionId);
    if (frame.kind === "relay.persisted") {
      const pending = this.relayOutbox.get(frame.payload.messageId);
      if (pending === undefined) return;
      if (pending.frame.seq !== frame.payload.senderSeq) {
        throw new Error("invalid_relay_receipt");
      }
      this.relayOutbox.delete(frame.payload.messageId);
      pending.resolve(true);
      return;
    }
    const state = this.requireState();
    if (frame.seq <= state.lastReceivedSeq) {
      await this.sendAck(frame.seq);
      return;
    }
    if (frame.kind === "heartbeat") {
      await this.mutateState((next) => {
        next.lastReceivedSeq = frame.seq;
      });
      await this.sendAck(frame.seq);
      return;
    }
    if (frame.kind === "turn.cancel") {
      await this.mutateState((next) => {
        next.lastReceivedSeq = frame.seq;
      });
      await this.sendAck(frame.seq);
      await this.cancelTurn(frame);
      return;
    }
    await this.acceptTurn(frame);
  }

  private async acceptTurn(frame: TurnSubmitFrame): Promise<void> {
    const turnId = frame.payload.turnId;
    const state = this.requireState();
    if (state.completedTurnIds.includes(turnId)) {
      await this.mutateState((next) => {
        next.lastReceivedSeq = frame.seq;
      });
      await this.sendAck(frame.seq);
      return;
    }
    if (this.activeTurns.has(turnId) || state.activeTurns.some((turn) => turn.turnId === turnId)) {
      await this.mutateState((next) => {
        next.lastReceivedSeq = frame.seq;
      });
      await this.sendAck(frame.seq);
      this.detach(this.recoverInterruptedTurns(), "recovery_failed");
      return;
    }
    const ctx = this.accounts.get(frame.payload.accountId);
    if (!ctx) {
      await this.rejectTurn(frame, {
        code: "invalid_account",
        message: "This OpenClam avatar is not available.",
        retryable: false,
      });
      return;
    }
    const activeForConversation = [...this.activeTurns.values()].find(
      (active) => active.frame.conversationId === frame.conversationId,
    );
    if (activeForConversation) {
      await this.rejectTurn(frame, {
        code: "conversation_busy",
        message: "Wait for the current reply to finish.",
        retryable: true,
      });
      return;
    }
    if (this.activeTurns.size >= MAX_ACTIVE_TURNS) {
      await this.rejectTurn(frame, {
        code: "adapter_busy",
        message: "OpenClaw is handling too many replies. Please try again.",
        retryable: true,
      });
      return;
    }

    const active: ActiveTurn = {
      frame,
      controller: new AbortController(),
      revision: 0,
      terminal: false,
      terminalPersisted: false,
      lastDeltaText: "",
      lastDeltaAt: 0,
      deltaCount: 0,
      activityRevision: 0,
      activityCount: 0,
      lastActivityFrameAt: 0,
      workRevision: 0,
      workCount: 0,
      workStepIds: new Set(),
      pendingWork: new Map(),
      lastWork: new Map(),
      lastWorkFrameAt: 0,
    };
    this.activeTurns.set(turnId, active);
    await this.mutateState((next) => {
      next.lastReceivedSeq = frame.seq;
      next.activeTurns = [
        ...next.activeTurns.filter((item) => item.turnId !== turnId),
        {
          turnId,
          conversationId: frame.conversationId,
          accountId: frame.payload.accountId,
        },
      ];
    });
    await this.sendAck(frame.seq);
    active.acceptanceTask = this.sendAwaitingRelayPersistence(
      "turn.accepted",
      { turnId },
      frame.conversationId,
      frame.seq,
      active.controller.signal,
    );
    const task = this.runAcceptedTurn(ctx, active);
    this.turnTasks.add(task);
    void task.then(
      () => this.turnTasks.delete(task),
      () => this.turnTasks.delete(task),
    );
  }

  private async runAcceptedTurn(ctx: AccountContext, active: ActiveTurn): Promise<void> {
    try {
      const accepted = await active.acceptanceTask;
      if (!accepted) {
        if (active.terminalTask) {
          active.terminalPersisted = await active.terminalTask;
          this.activeTurns.delete(active.frame.payload.turnId);
          if (active.terminalPersisted) await this.finishTurn(active.frame.payload.turnId);
        }
        return;
      }
      if (active.terminal || active.controller.signal.aborted) {
        if (active.terminalTask) {
          active.terminalPersisted = await active.terminalTask;
          this.activeTurns.delete(active.frame.payload.turnId);
          if (active.terminalPersisted) await this.finishTurn(active.frame.payload.turnId);
        }
        return;
      }
      await this.runTurn(ctx, active);
    } catch {
      this.log("warn", "turn_acceptance_failed");
    }
  }

  private async rejectTurn(
    frame: TurnSubmitFrame,
    recoveryError: SafeRecoveryError,
  ): Promise<void> {
    await this.mutateState((state) => {
      state.lastReceivedSeq = frame.seq;
      state.activeTurns = [
        ...state.activeTurns.filter((turn) => turn.turnId !== frame.payload.turnId),
        {
          turnId: frame.payload.turnId,
          conversationId: frame.conversationId,
          accountId: frame.payload.accountId,
          recoveryExpiresAt: Date.now() + RECOVERY_MARKER_TTL_MS,
          recoveryError,
        },
      ];
    });
    await this.sendAck(frame.seq);
    this.detach(this.recoverInterruptedTurns(), "recovery_failed");
  }

  private async runTurn(ctx: AccountContext, active: ActiveTurn): Promise<void> {
    const frame = active.frame;
    try {
      await this.deps.dispatchTurn({
        ctx,
        frame,
        signal: active.controller.signal,
        sink: {
          activity: async (status) => {
            await this.offerActivity(active, status);
          },
          clearActivity: async () => {
            await this.offerActivity(active, null);
          },
          work: async (step) => {
            this.offerWork(active, step);
          },
          partial: async (text) => {
            if (active.terminal || active.controller.signal.aborted) return;
            await this.offerDelta(active, truncateUnicode(text, MAX_TEXT_LENGTH));
          },
          attachment: async (attachment) => {
            if (active.terminal || active.controller.signal.aborted) return;
            await this.deliverAttachment(active, attachment);
          },
          completed: async (text) => {
            if (active.terminal || active.controller.signal.aborted) return;
            active.terminalPersisted = await this.beginTerminal(
              active,
              "assistant.completed",
              { turnId: frame.payload.turnId, text: truncateUnicode(text, MAX_TEXT_LENGTH) },
              {
                code: "connection_interrupted",
                message: "The connection closed before this reply could be delivered. Please try again.",
                retryable: true,
              },
            );
          },
        },
      });
      if (!active.terminal) throw new Error("empty_reply");
    } catch (error) {
      if (!active.terminal) {
        const code = error instanceof Error ? error.message : "agent_failed";
        if (code === "agent_mapping_changed") {
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code,
              message: "This agent mapping changed. Pair OpenClam again.",
              retryable: false,
            }),
            {
              code,
              message: "This agent mapping changed. Pair OpenClam again.",
              retryable: false,
            },
          );
        } else if (code === "sensitive_media_unsupported") {
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code,
              message: "Sensitive live-only media cannot be saved in OpenClam.",
              retryable: false,
            }),
            {
              code,
              message: "Sensitive live-only media cannot be saved in OpenClam.",
              retryable: false,
            },
          );
        } else if (
          code === "attachment_limit" ||
          code === "attachment_size_invalid" ||
          code === "attachment_type_unsupported"
        ) {
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code,
              message: "This generated file cannot be delivered to OpenClam.",
              retryable: false,
            }),
            {
              code,
              message: "This generated file cannot be delivered to OpenClam.",
              retryable: false,
            },
          );
        } else if (
          code === "attachment_upload_failed" ||
          code === "invalid_attachment_response" ||
          code === "attachment_delivery_failed"
        ) {
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code: "attachment_delivery_failed",
              message: "The generated file could not be delivered. Please try again.",
              retryable: true,
            }),
            {
              code: "attachment_delivery_failed",
              message: "The generated file could not be delivered. Please try again.",
              retryable: true,
            },
          );
        } else if (active.controller.signal.aborted) {
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code: "cancelled",
              message: "The turn was cancelled.",
              retryable: false,
            }),
            {
              code: "cancelled",
              message: "The turn was cancelled.",
              retryable: false,
            },
          );
        } else {
          const safeCode = code === "empty_reply" ? "empty_reply" : "agent_failed";
          active.terminalPersisted = await this.beginTerminal(
            active,
            "turn.error",
            safeTurnErrorPayload({
              turnId: frame.payload.turnId,
              code: safeCode,
              message: "OpenClaw could not complete this reply.",
              retryable: true,
            }),
            {
              code: safeCode,
              message: "OpenClaw could not complete this reply.",
              retryable: true,
            },
          );
        }
      }
    } finally {
      this.clearDeltaTimer(active);
      this.clearActivityTimer(active);
      this.clearWorkTimer(active);
      if (active.terminalTask) {
        active.terminalPersisted = await active.terminalTask;
      }
      this.activeTurns.delete(frame.payload.turnId);
      if (active.terminalPersisted) await this.finishTurn(frame.payload.turnId);
      else if (this.socket?.readyState === WebSocket.OPEN) {
        this.detach(this.recoverInterruptedTurns(), "recovery_failed");
      }
    }
  }

  private async cancelTurn(frame: ClientFrame & { kind: "turn.cancel" }): Promise<void> {
    const turnId = String(frame.payload.turnId);
    const active = this.activeTurns.get(turnId);
    if (active) {
      if (active.frame.conversationId !== frame.conversationId) return;
      if (!active.terminal) {
        void this.beginTerminal(
          active,
          "turn.error",
          safeTurnErrorPayload({
            turnId,
            code: "cancelled",
            message: "The turn was cancelled.",
            retryable: false,
          }),
          {
            code: "cancelled",
            message: "The turn was cancelled.",
            retryable: false,
          },
        );
        active.controller.abort();
      } else active.controller.abort();
      return;
    }
    if (!this.requireState().completedTurnIds.includes(turnId)) {
      await this.mutateState((state) => {
        const existing = state.activeTurns.find(
          (turn) => turn.turnId === turnId && turn.conversationId === frame.conversationId,
        );
        if (existing) {
          existing.recoveryExpiresAt = Date.now() + RECOVERY_MARKER_TTL_MS;
          existing.recoveryError = {
            code: "cancelled",
            message: "The turn was cancelled.",
            retryable: false,
          };
        }
      });
      this.detach(this.recoverInterruptedTurns(), "recovery_failed");
    }
  }

  private async finishTurn(turnId: string): Promise<void> {
    await this.mutateState((state) => {
      state.activeTurns = state.activeTurns.filter((turn) => turn.turnId !== turnId);
      state.completedTurnIds = [
        ...state.completedTurnIds.filter((id) => id !== turnId),
        turnId,
      ].slice(-256);
    });
  }

  private async markRecoveryError(active: ActiveTurn, error: SafeRecoveryError): Promise<void> {
    await this.mutateState((state) => {
      const turn = state.activeTurns.find((candidate) => candidate.turnId === active.frame.payload.turnId);
      if (turn) {
        turn.recoveryExpiresAt = Date.now() + RECOVERY_MARKER_TTL_MS;
        turn.recoveryError = error;
      }
    });
  }

  private beginTerminal(
    active: ActiveTurn,
    kind: "assistant.completed" | "turn.error",
    payload: Record<string, unknown>,
    recoveryError: SafeRecoveryError,
  ): Promise<boolean> {
    if (active.terminalTask) return active.terminalTask;
    active.terminal = true;
    this.clearDeltaTimer(active);
    active.terminalTask = (async () => {
      await this.drainWork(active);
      await this.markRecoveryError(active, recoveryError);
      return this.sendAwaitingRelayPersistence(
        kind,
        payload,
        active.frame.conversationId,
      );
    })().catch(() => {
      this.log("warn", "terminal_delivery_failed");
      return false;
    });
    return active.terminalTask;
  }

  private recoverInterruptedTurns(): Promise<void> {
    this.recoveryTask = this.recoveryTask.catch(() => undefined).then(async () => {
      const interrupted = [...this.requireState().activeTurns];
      for (const turn of interrupted) {
        if (this.activeTurns.has(turn.turnId)) continue;
        if (this.lifecycle.signal.aborted) return;
        if (
          turn.recoveryError !== undefined &&
          turn.recoveryExpiresAt !== undefined &&
          turn.recoveryExpiresAt <= Date.now()
        ) {
          await this.finishTurn(turn.turnId);
          continue;
        }
        const recovery = turn.recoveryError ?? {
          code: "adapter_restarted",
          message: "OpenClaw restarted during this reply. Please try again.",
          retryable: true,
        };
        if (turn.recoveryError === undefined || turn.recoveryExpiresAt === undefined) {
          await this.mutateState((state) => {
            const pending = state.activeTurns.find((candidate) => candidate.turnId === turn.turnId);
            if (pending) {
              pending.recoveryError = recovery;
              pending.recoveryExpiresAt = Date.now() + RECOVERY_MARKER_TTL_MS;
            }
          });
        }
        const persisted = await this.sendAwaitingRelayPersistence(
          "turn.error",
          safeTurnErrorPayload({
            turnId: turn.turnId,
            ...recovery,
          }),
          turn.conversationId,
        );
        if (!persisted) return;
        await this.finishTurn(turn.turnId);
      }
    });
    return this.recoveryTask;
  }

  private clearDeltaTimer(active: ActiveTurn): void {
    if (active.deltaTimer) clearTimeout(active.deltaTimer);
    active.deltaTimer = undefined;
    active.pendingDelta = undefined;
  }

  private supports(
    active: ActiveTurn,
    capability: "activity-v1" | "attachments-v1" | "work-v1",
  ): boolean {
    return active.frame.payload.capabilities?.includes(capability) === true;
  }

  private clearActivityTimer(active: ActiveTurn): void {
    if (active.activityTimer) clearTimeout(active.activityTimer);
    active.activityTimer = undefined;
    active.pendingActivityStatus = undefined;
  }

  private async offerActivity(
    active: ActiveTurn,
    status: ActivityStatus | null,
  ): Promise<void> {
    if (
      !this.supports(active, "activity-v1") ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
      status === active.pendingActivityStatus ||
      (active.pendingActivityStatus === undefined && status === active.lastActivityStatus)
    ) {
      return;
    }
    active.pendingActivityStatus = status;
    this.scheduleActivity(active);
  }

  private scheduleActivity(active: ActiveTurn): void {
    if (
      this.lifecycle.signal.aborted ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
      active.pendingActivityStatus === undefined ||
      active.activityTimer ||
      active.activityTask ||
      this.socket?.readyState !== WebSocket.OPEN
    ) {
      return;
    }
    const remaining = ACTIVITY_INTERVAL_MS - (Date.now() - active.lastActivityFrameAt);
    if (remaining <= 0) {
      this.detach(this.flushActivity(active), "activity_flush_failed");
      return;
    }
    active.activityTimer = setTimeout(() => {
      active.activityTimer = undefined;
      this.detach(this.flushActivity(active), "activity_flush_failed");
    }, remaining);
  }

  private flushActivity(active: ActiveTurn): Promise<void> {
    if (active.activityTask) return active.activityTask;
    const task = this.performActivityFlush(active);
    active.activityTask = task;
    this.activityTasks.add(task);
    const settled = () => {
      if (active.activityTask === task) active.activityTask = undefined;
      this.activityTasks.delete(task);
      if (active.pendingActivityStatus !== undefined) this.scheduleActivity(active);
    };
    void task.then(settled, settled);
    return task;
  }

  private async performActivityFlush(active: ActiveTurn): Promise<void> {
    if (
      this.lifecycle.signal.aborted ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
      this.socket?.readyState !== WebSocket.OPEN
    ) {
      return;
    }
    const status = active.pendingActivityStatus;
    if (status === undefined) return;
    active.pendingActivityStatus = undefined;
    const revision = active.activityRevision + 1;
    const persisted = await this.sendAwaitingRelayPersistence(
      status === null ? "assistant.activity.clear" : "assistant.activity.upsert",
      status === null
        ? { turnId: active.frame.payload.turnId, revision }
        : { turnId: active.frame.payload.turnId, revision, status },
      active.frame.conversationId,
      undefined,
      active.controller.signal,
    );
    if (persisted) {
      active.activityRevision = revision;
      active.activityCount += 1;
      active.lastActivityStatus = status;
      active.lastActivityFrameAt = Date.now();
    } else if (!active.terminal && !active.controller.signal.aborted) {
      active.pendingActivityStatus ??= status;
    }
  }

  private flushActiveActivities(): void {
    for (const active of this.activeTurns.values()) {
      this.scheduleActivity(active);
    }
  }

  private clearWorkTimer(active: ActiveTurn): void {
    if (active.workTimer) clearTimeout(active.workTimer);
    active.workTimer = undefined;
  }

  private offerWork(active: ActiveTurn, step: WorkStep): void {
    if (
      !this.supports(active, "work-v1") ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.workCount >= MAX_WORK_FRAMES_PER_TURN
    ) {
      return;
    }
    if (!active.workStepIds.has(step.stepId)) {
      if (active.workStepIds.size >= MAX_WORK_STEPS_PER_TURN) return;
      active.workStepIds.add(step.stepId);
    }
    const encoded = JSON.stringify(step);
    if (active.lastWork.get(step.stepId) === encoded) return;
    active.pendingWork.set(step.stepId, step);
    this.scheduleWork(active);
  }

  private scheduleWork(active: ActiveTurn): void {
    if (
      this.lifecycle.signal.aborted ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.pendingWork.size === 0 ||
      active.workCount >= MAX_WORK_FRAMES_PER_TURN ||
      active.workTimer ||
      active.workTask ||
      this.socket?.readyState !== WebSocket.OPEN
    ) {
      return;
    }
    const remaining = WORK_INTERVAL_MS - (Date.now() - active.lastWorkFrameAt);
    if (remaining <= 0) {
      this.detach(this.flushWork(active), "work_flush_failed");
      return;
    }
    active.workTimer = setTimeout(() => {
      active.workTimer = undefined;
      this.detach(this.flushWork(active), "work_flush_failed");
    }, remaining);
  }

  private flushWork(active: ActiveTurn, force = false): Promise<void> {
    if (active.workTask) return active.workTask;
    const task = this.performWorkFlush(active, force);
    active.workTask = task;
    this.workTasks.add(task);
    const settled = () => {
      if (active.workTask === task) active.workTask = undefined;
      this.workTasks.delete(task);
      if (!active.terminal && active.pendingWork.size > 0) this.scheduleWork(active);
    };
    void task.then(settled, settled);
    return task;
  }

  private async performWorkFlush(active: ActiveTurn, force: boolean): Promise<void> {
    if (
      this.lifecycle.signal.aborted ||
      (!force && active.terminal) ||
      active.controller.signal.aborted ||
      active.pendingWork.size === 0 ||
      active.workCount >= MAX_WORK_FRAMES_PER_TURN ||
      this.socket?.readyState !== WebSocket.OPEN
    ) {
      return;
    }
    const next = active.pendingWork.entries().next().value as [string, WorkStep] | undefined;
    if (!next) return;
    const [stepId, step] = next;
    active.pendingWork.delete(stepId);
    const revision = active.workRevision + 1;
    const persisted = await this.sendAwaitingRelayPersistence(
      "assistant.work.upsert",
      { turnId: active.frame.payload.turnId, revision, ...step },
      active.frame.conversationId,
      undefined,
      active.controller.signal,
    );
    if (persisted) {
      active.workRevision = revision;
      active.workCount += 1;
      active.lastWork.set(stepId, JSON.stringify(step));
      active.lastWorkFrameAt = Date.now();
    } else if (!active.controller.signal.aborted) {
      active.pendingWork.set(stepId, step);
    }
  }

  private async drainWork(active: ActiveTurn): Promise<void> {
    this.clearWorkTimer(active);
    while (
      active.pendingWork.size > 0 &&
      active.workCount < MAX_WORK_FRAMES_PER_TURN &&
      this.socket?.readyState === WebSocket.OPEN &&
      !active.controller.signal.aborted
    ) {
      await this.flushWork(active, true);
    }
  }

  private flushActiveWork(): void {
    for (const active of this.activeTurns.values()) this.scheduleWork(active);
  }

  private async deliverAttachment(
    active: ActiveTurn,
    attachment: OpenClamAttachmentUpload,
  ): Promise<void> {
    if (!this.supports(active, "attachments-v1")) {
      throw new Error("attachment_delivery_failed");
    }
    const frame = active.frame;
    const uploaded = await this.deps.uploadAttachment({
      bridgeUrl: this.bridgeUrl,
      connectionId: this.connectionId,
      token: this.token,
      conversationId: frame.conversationId,
      turnId: frame.payload.turnId,
      attachment,
      signal: active.controller.signal,
    });
    const persisted = await this.sendAwaitingRelayPersistence(
      "assistant.attachment",
      {
        turnId: frame.payload.turnId,
        attachmentId: uploaded.attachmentId,
        fileName: uploaded.fileName,
        mediaType: uploaded.mediaType,
        byteCount: uploaded.byteCount,
        sha256: uploaded.sha256,
        downloadPath: uploaded.downloadPath,
        expiresAt: uploaded.expiresAt,
      },
      frame.conversationId,
      undefined,
      active.controller.signal,
    );
    if (!persisted) throw new Error("attachment_delivery_failed");
  }

  private async offerDelta(active: ActiveTurn, text: string): Promise<void> {
    if (
      !text ||
      text === active.pendingDelta ||
      text === active.lastDeltaText ||
      active.terminal ||
      active.controller.signal.aborted
    ) {
      return;
    }
    active.pendingDelta = text;
    await this.scheduleDelta(active);
  }

  private async scheduleDelta(active: ActiveTurn): Promise<void> {
    if (
      this.lifecycle.signal.aborted ||
      active.deltaCount >= MAX_DELTA_FRAMES_PER_TURN ||
      this.socket?.readyState !== WebSocket.OPEN ||
      active.deltaTimer ||
      active.deltaFlushTask
    ) {
      return;
    }
    const remaining = DELTA_INTERVAL_MS - (Date.now() - active.lastDeltaAt);
    if (remaining <= 0) {
      await this.flushDelta(active);
      return;
    }
    active.deltaTimer = setTimeout(() => {
      active.deltaTimer = undefined;
      this.detach(this.flushDelta(active), "delta_flush_failed");
    }, remaining);
  }

  private flushDelta(active: ActiveTurn): Promise<void> {
    if (active.deltaFlushTask) return active.deltaFlushTask;
    const task = this.performDeltaFlush(active);
    active.deltaFlushTask = task;
    this.deltaTasks.add(task);
    const settled = () => {
      if (active.deltaFlushTask === task) active.deltaFlushTask = undefined;
      this.deltaTasks.delete(task);
      if (active.pendingDelta === active.lastDeltaText) active.pendingDelta = undefined;
      if (active.pendingDelta) {
        this.detach(this.scheduleDelta(active), "delta_flush_failed");
      }
    };
    void task.then(settled, settled);
    return task;
  }

  private async performDeltaFlush(active: ActiveTurn): Promise<void> {
    if (
      this.lifecycle.signal.aborted ||
      active.terminal ||
      active.controller.signal.aborted ||
      active.deltaCount >= MAX_DELTA_FRAMES_PER_TURN ||
      this.socket?.readyState !== WebSocket.OPEN
    ) {
      return;
    }
    const text = active.pendingDelta;
    if (!text) return;
    active.pendingDelta = undefined;
    const revision = active.revision + 1;
    let delivered = false;
    try {
      delivered = await this.send(
        "assistant.delta",
        { turnId: active.frame.payload.turnId, revision, text },
        active.frame.conversationId,
        undefined,
        false,
      );
    } catch (error) {
      active.pendingDelta ??= text;
      throw error;
    }
    if (delivered) {
      active.revision = revision;
      active.deltaCount += 1;
      active.lastDeltaText = text;
      active.lastDeltaAt = Date.now();
    } else {
      active.pendingDelta ??= text;
    }
  }

  private async flushActiveDeltas(): Promise<void> {
    for (const active of this.activeTurns.values()) {
      await this.flushDelta(active);
    }
  }

  private async sendAck(receivedSeq: number): Promise<void> {
    await this.send("ack", { ackSeq: receivedSeq }, undefined, receivedSeq);
  }

  private async sendAwaitingRelayPersistence(
    kind:
      | "turn.accepted"
      | "assistant.activity.upsert"
      | "assistant.activity.clear"
      | "assistant.work.upsert"
      | "assistant.attachment"
      | "assistant.completed"
      | "turn.error",
    payload: Record<string, unknown>,
    conversationId: string,
    replyTo?: number,
    signal?: AbortSignal,
  ): Promise<boolean> {
    if (this.lifecycle.signal.aborted || signal?.aborted) return false;
    let frame: ConnectorFrame | undefined;
    await this.mutateState((state) => {
      frame = createFrame({
        kind,
        connectionId: this.connectionId,
        seq: state.nextSeq,
        conversationId,
        replyTo,
        payload,
      });
      state.nextSeq += 1;
    });
    if (this.lifecycle.signal.aborted || signal?.aborted) return false;
    const created = frame as ConnectorFrame;
    const prepared = kind === "assistant.completed"
      ? encodeFrameWithTextBudget(created, "text")
      : kind === "turn.error"
        ? encodeFrameWithTextBudget(created, "message")
        : { frame: created, encoded: encodeFrame(created) };
    const reserved = prepared.frame;
    const encoded = prepared.encoded;
    return new Promise<boolean>((resolve) => {
      let settled = false;
      let onAbort = () => undefined;
      const finish = (persisted: boolean) => {
        if (settled) return;
        settled = true;
        signal?.removeEventListener("abort", onAbort);
        resolve(persisted);
      };
      const pending: PendingRelayFrame = { frame: reserved, encoded, resolve: finish };
      onAbort = () => {
        if (this.relayOutbox.get(reserved.messageId) === pending) {
          this.relayOutbox.delete(reserved.messageId);
        }
        finish(false);
      };
      this.relayOutbox.set(reserved.messageId, pending);
      signal?.addEventListener("abort", onAbort, { once: true });
      if (signal?.aborted) {
        onAbort();
        return;
      }
      const socket = this.socket;
      if (socket?.readyState === WebSocket.OPEN) {
        this.transmit(socket, encoded);
      }
    });
  }

  private async send(
    kind: FrameKind,
    payload: Record<string, unknown>,
    conversationId?: string,
    replyTo?: number,
    queueWhenOffline = true,
  ): Promise<boolean> {
    const socketBeforeReservation = this.socket;
    if (!queueWhenOffline && socketBeforeReservation?.readyState !== WebSocket.OPEN) return false;
    let frame: ConnectorFrame | undefined;
    await this.mutateState((state) => {
      frame = createFrame({
        kind,
        connectionId: this.connectionId,
        seq: state.nextSeq,
        conversationId,
        replyTo,
        payload,
      });
      state.nextSeq += 1;
    });
    const created = frame as ConnectorFrame;
    const prepared = kind === "assistant.delta"
      ? encodeFrameWithTextBudget(created, "text")
      : { frame: created, encoded: encodeFrame(created) };
    const outbound = prepared.frame;
    const encoded = prepared.encoded;
    const socket = this.socket;
    if (socket?.readyState === WebSocket.OPEN) {
      try {
        socket.send(encoded);
        this.updateAllStatuses({ lastOutboundAt: Date.now() });
        return true;
      } catch {
        socket.close(1011, "send_failed");
        if (!queueWhenOffline) return false;
      }
    }
    if (!queueWhenOffline) return false;
    this.enqueueFrame({ encoded, kind, seq: outbound.seq });
    return false;
  }

  private transmit(socket: WebSocket, encoded: string): boolean {
    if (socket.readyState !== WebSocket.OPEN) return false;
    try {
      socket.send(encoded);
      this.updateAllStatuses({ lastOutboundAt: Date.now() });
      return true;
    } catch {
      socket.close(1011, "send_failed");
      return false;
    }
  }

  private enqueueFrame(frame: QueuedFrame): void {
    const droppable = (candidate: QueuedFrame) =>
      candidate.kind === "heartbeat" || candidate.kind === "assistant.delta" || candidate.kind === "ack";
    if (this.outboundQueue.length >= MAX_OUTBOUND_QUEUE) {
      const index = this.outboundQueue.findIndex(droppable);
      if (index >= 0) this.outboundQueue.splice(index, 1);
      else {
        this.log("warn", "outbound_queue_full");
        return;
      }
    }
    this.outboundQueue.push(frame);
  }

  private flushPendingTransmissions(): void {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    const pending = [
      ...this.outboundQueue.map((frame) => ({ type: "queued" as const, frame })),
      ...[...this.relayOutbox.values()].map((frame) => ({ type: "relay" as const, frame })),
    ].sort((left, right) => {
      const leftSeq = left.type === "queued" ? left.frame.seq : left.frame.frame.seq;
      const rightSeq = right.type === "queued" ? right.frame.seq : right.frame.frame.seq;
      return leftSeq - rightSeq;
    });
    for (const item of pending) {
      if (socket.readyState !== WebSocket.OPEN) break;
      if (!this.transmit(socket, item.frame.encoded)) break;
      if (item.type === "queued") {
        const index = this.outboundQueue.indexOf(item.frame);
        if (index >= 0) this.outboundQueue.splice(index, 1);
      }
    }
  }

  private mutateState(mutator: (state: AdapterState) => void): Promise<void> {
    const task = this.stateTask.then(async () => {
      const state = this.requireState();
      mutator(state);
      await this.deps.writeState(this.stateFile, state);
    });
    this.stateTask = task.catch(() => undefined);
    return task;
  }

  private requireState(): AdapterState {
    if (!this.state) throw new Error("adapter_state_unavailable");
    return this.state;
  }

  private updateAllStatuses(patch: Record<string, unknown>): void {
    for (const ctx of this.accounts.values()) this.setAccountStatus(ctx, patch);
  }

  private setAccountStatus(ctx: AccountContext, patch: Record<string, unknown>): void {
    ctx.setStatus({ ...ctx.getStatus(), accountId: ctx.account.accountId, ...patch });
  }

  private detach(task: Promise<unknown>, event: string): void {
    void task.catch(() => this.log("warn", event));
  }

  private retireConnection(event: string): void {
    this.log("warn", event);
    this.updateAllStatuses({ connected: false, running: false, configured: false });
    for (const active of this.activeTurns.values()) active.controller.abort();
    if (!this.lifecycle.signal.aborted) this.lifecycle.abort();
  }

  private log(level: "info" | "warn", event: string): void {
    const sink = this.accounts.values().next().value?.log;
    sink?.[level](`[openclam] ${event} connection=${this.connectionId}`);
  }
}
