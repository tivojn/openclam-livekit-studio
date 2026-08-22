import { DurableObject } from "cloudflare:workers";
import {
  decryptPendingFrame,
  encryptPendingFrame,
  secureEqual,
  sha256Hex,
  tokenVerifier,
} from "./crypto";
import { HttpError } from "./errors";
import type {
  AccountDescriptor,
  ActiveTurn,
  ConnectorFrame,
  FrameKind,
  RelayPersistedReceipt,
  SessionRecord,
  SocketRole,
} from "./types";
import {
  bearerToken,
  FRAME_LIMIT_BYTES,
  parseConnectorFrame,
} from "./validation";

const SESSION_KEY = "session";
const MAX_SEEN_MESSAGES_PER_ROLE = 512;
const CLIENT_KINDS = new Set([
  "ack",
  "heartbeat",
  "turn.submit",
  "turn.cancel",
]);
const ADAPTER_KINDS = new Set([
  "ack",
  "heartbeat",
  "turn.accepted",
  "assistant.delta",
  "assistant.completed",
  "turn.error",
]);
const RELAY_RECEIPT_KINDS = new Set<FrameKind>([
  "turn.submit",
  "turn.accepted",
  "assistant.delta",
  "assistant.completed",
  "turn.cancel",
  "turn.error",
]);

interface InternalCreateRequest {
  connectionId: string;
  adapterId: string;
  gatewayLabel: string;
  accounts: AccountDescriptor[];
  adapterTokenVerifier: string;
  createdAt: number;
  unpairedCleanupAt: number;
}

interface InternalActivateRequest {
  connectionId: string;
  clientTokenVerifier: string;
  installationVerifier: string;
  pairedAt: number;
}

interface InternalExpireRequest {
  connectionId: string;
  unpairedCleanupAt: number;
  now: number;
}

interface SocketAttachment {
  v: 1;
  role: SocketRole;
  socketId: string;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function pendingTtlMilliseconds(env: Env): number {
  const seconds = Number(env.PENDING_FRAME_TTL_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 30 || seconds > 3_600) {
    throw new Error("invalid_pending_frame_ttl");
  }
  return seconds * 1_000;
}

function activeTurnIdleTtlMilliseconds(env: Env): number {
  const seconds = Number(env.ACTIVE_TURN_IDLE_TTL_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 30 || seconds > 3_600) {
    throw new Error("invalid_active_turn_idle_ttl");
  }
  return seconds * 1_000;
}

function activeTurnMaxDurationMilliseconds(env: Env): number {
  const seconds = Number(env.ACTIVE_TURN_MAX_DURATION_SECONDS);
  const idleSeconds = Number(env.ACTIVE_TURN_IDLE_TTL_SECONDS);
  if (
    !Number.isInteger(seconds) ||
    seconds < 60 ||
    seconds > 86_400 ||
    !Number.isInteger(idleSeconds) ||
    seconds < idleSeconds
  ) {
    throw new Error("invalid_active_turn_max_duration");
  }
  return seconds * 1_000;
}

function maxPendingFrames(env: Env): number {
  const value = Number(env.MAX_PENDING_FRAMES);
  if (!Number.isInteger(value) || value < 1 || value > 16) {
    throw new Error("invalid_max_pending_frames");
  }
  return value;
}

function expectedSocketId(record: SessionRecord, role: SocketRole): string | undefined {
  return role === "client"
    ? record.activeClientSocketId
    : record.activeAdapterSocketId;
}

function opposite(role: SocketRole): SocketRole {
  return role === "client" ? "adapter" : "client";
}

function frameTurnId(frame: ConnectorFrame): string | undefined {
  const value = frame.payload.turnId;
  return typeof value === "string" ? value : undefined;
}

function relayReceipt(
  connectionId: string,
  senderSeq: number,
  messageId: string,
): RelayPersistedReceipt {
  return {
    v: 1,
    kind: "relay.persisted",
    connectionId,
    payload: { senderSeq, messageId },
  };
}

export class ConnectorSession extends DurableObject<Env> {
  private operationQueue: Promise<void> = Promise.resolve();

  override fetch(request: Request): Promise<Response> {
    return this.enqueue(() => this.route(request));
  }

  override alarm(): Promise<void> {
    return this.enqueue(() => this.handleAlarm(Date.now()));
  }

  override async webSocketMessage(
    webSocket: WebSocket,
    message: string | ArrayBuffer,
  ): Promise<void> {
    try {
      await this.enqueue(() => this.handleWebSocketMessage(webSocket, message));
    } catch {
      this.close(webSocket, 1011, "unavailable");
    }
  }

  override async webSocketClose(
    _webSocket: WebSocket,
    _code: number,
    _reason: string,
    _wasClean: boolean,
  ): Promise<void> {
    // Connection identity is persisted and replaced on the next authenticated
    // upgrade. No chat content or transient error is recorded on close.
  }

  override async webSocketError(_webSocket: WebSocket, _error: unknown): Promise<void> {
    // Errors are intentionally content-free and not logged.
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operationQueue.then(operation);
    this.operationQueue = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/internal/create") {
      return this.create(await request.json<InternalCreateRequest>());
    }
    if (request.method === "POST" && url.pathname === "/internal/activate") {
      return this.activate(await request.json<InternalActivateRequest>());
    }
    if (request.method === "POST" && url.pathname === "/internal/expire") {
      return this.expire(await request.json<InternalExpireRequest>());
    }
    if (request.method === "GET" && url.pathname === "/internal/connect") {
      const role = url.searchParams.get("role");
      if (role !== "client" && role !== "adapter") {
        return json({ error: "invalid_request" }, 400);
      }
      return this.connectWebSocket(request, role);
    }
    if (request.method === "DELETE" && url.pathname === "/internal/delete") {
      return this.revoke(request);
    }
    return json({ error: "not_found" }, 404);
  }

  private async handleAlarm(now: number): Promise<void> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return;
    if (
      record.clientTokenVerifier === undefined &&
      record.unpairedCleanupAt <= now
    ) {
      await this.deleteSession("pairing_expired");
      return;
    }
    if (this.hasExpiredActiveTurn(record, now)) {
      await this.deleteSession("turn_expired");
      return;
    }
    const cleaned = this.cleanup(record, now);
    await this.persistSession(cleaned);
    await this.scheduleCleanup(cleaned);
  }

  private async create(value: InternalCreateRequest): Promise<Response> {
    if (await this.ctx.storage.get(SESSION_KEY)) {
      return json({ error: "connector_exists" }, 409);
    }
    const record: SessionRecord = {
      v: 1,
      connectionId: value.connectionId,
      adapterId: value.adapterId,
      gatewayLabel: value.gatewayLabel,
      accounts: value.accounts,
      adapterTokenVerifier: value.adapterTokenVerifier,
      createdAt: value.createdAt,
      unpairedCleanupAt: value.unpairedCleanupAt,
      highestClientSeq: 0,
      highestAdapterSeq: 0,
      acknowledgedClientSeq: 0,
      acknowledgedAdapterSeq: 0,
      pending: [],
      seenClient: [],
      seenAdapter: [],
      activeTurns: [],
      settledTurns: [],
    };
    await this.persistSession(record);
    await this.scheduleCleanup(record);
    return json({ created: true }, 201);
  }

  private async activate(value: InternalActivateRequest): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (
      record === undefined ||
      record.connectionId !== value.connectionId
    ) {
      return json({ error: "not_found" }, 404);
    }
    if (record.clientTokenVerifier !== undefined) {
      const sameInstallation =
        record.installationVerifier === value.installationVerifier;
      const sameCredential = await secureEqual(
        record.clientTokenVerifier,
        value.clientTokenVerifier,
      );
      if (sameInstallation && sameCredential) {
        return json({ activated: true, idempotent: true });
      }
      return json({ error: "pairing_consumed" }, 409);
    }
    const activated: SessionRecord = {
      ...record,
      clientTokenVerifier: value.clientTokenVerifier,
      installationVerifier: value.installationVerifier,
      pairedAt: value.pairedAt,
    };
    await this.persistSession(activated);
    await this.scheduleCleanup(activated);
    return json({ activated: true });
  }

  private async expire(value: InternalExpireRequest): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (
      record.connectionId !== value.connectionId ||
      record.clientTokenVerifier !== undefined ||
      record.unpairedCleanupAt !== value.unpairedCleanupAt ||
      record.unpairedCleanupAt > value.now
    ) {
      return json({ error: "not_expired" }, 409);
    }
    await this.deleteSession("pairing_expired");
    return new Response(null, { status: 204 });
  }

  private async connectWebSocket(
    request: Request,
    role: SocketRole,
  ): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "invalid_request" }, 426);
    }
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) {
      return json({ error: "not_found" }, 404);
    }
    if (!(await this.authenticates(request, record, role))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (this.hasExpiredActiveTurn(record, Date.now())) {
      await this.deleteSession("turn_expired");
      return json({ error: "not_found" }, 404);
    }

    const socketId = crypto.randomUUID();
    const activeKey = role === "client"
      ? "activeClientSocketId"
      : "activeAdapterSocketId";
    const updated: SessionRecord = { ...this.cleanup(record, Date.now()), [activeKey]: socketId };
    await this.persistSession(updated);

    for (const existing of this.ctx.getWebSockets(role)) {
      try {
        existing.close(4001, "replaced");
      } catch {
        // A concurrently closed socket needs no further action.
      }
    }

    const replayFrames: string[] = [];
    try {
      for (const pending of updated.pending
        .filter((frame) => frame.from === opposite(role))
        .sort((left, right) => left.seq - right.seq)) {
        replayFrames.push(
          await decryptPendingFrame(
            pending.encrypted,
            this.env.PENDING_EVENT_KEK_B64,
            updated.connectionId,
            pending.from,
            pending.seq,
          ),
        );
      }
    } catch {
      return json({ error: "unavailable" }, 503);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    server.serializeAttachment({ v: 1, role, socketId } satisfies SocketAttachment);
    this.ctx.acceptWebSocket(server, [role]);

    for (const encoded of replayFrames) {
      try {
        server.send(encoded);
      } catch {
        break;
      }
    }
    await this.scheduleCleanup(updated);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async revoke(request: Request): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) {
      return json({ error: "not_found" }, 404);
    }
    const authenticated =
      (await this.authenticates(request, record, "client")) ||
      (await this.authenticates(request, record, "adapter"));
    if (!authenticated) return json({ error: "unauthorized" }, 401);

    await this.deleteSession("revoked");
    return new Response(null, { status: 204 });
  }

  private async authenticates(
    request: Request,
    record: SessionRecord,
    role: SocketRole,
  ): Promise<boolean> {
    const token = bearerToken(request);
    const expected = role === "client"
      ? record.clientTokenVerifier
      : record.adapterTokenVerifier;
    if (token === null || expected === undefined) return false;
    const candidate = await tokenVerifier(
      token,
      this.env.TOKEN_VERIFIER_PEPPER,
      role,
      record.connectionId,
    );
    return secureEqual(candidate, expected);
  }

  private async handleWebSocketMessage(
    webSocket: WebSocket,
    message: string | ArrayBuffer,
  ): Promise<void> {
    const attachment = webSocket.deserializeAttachment() as SocketAttachment | null;
    if (
      attachment === null ||
      attachment.v !== 1 ||
      (attachment.role !== "client" && attachment.role !== "adapter")
    ) {
      this.close(webSocket, 1008, "invalid_socket");
      return;
    }
    if (typeof message !== "string") {
      this.close(webSocket, 1003, "text_only");
      return;
    }
    if (new TextEncoder().encode(message).byteLength > FRAME_LIMIT_BYTES) {
      this.close(webSocket, 1009, "frame_too_large");
      return;
    }

    let frame: ConnectorFrame;
    try {
      frame = parseConnectorFrame(JSON.parse(message));
    } catch {
      this.close(webSocket, 1008, "invalid_frame");
      return;
    }

    const stored = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (stored === undefined) {
      this.close(webSocket, 4003, "revoked");
      return;
    }
    const role = attachment.role;
    if (expectedSocketId(stored, role) !== attachment.socketId) {
      this.close(webSocket, 4001, "replaced");
      return;
    }
    if (frame.connectionId !== stored.connectionId || !this.kindAllowed(role, frame)) {
      this.close(webSocket, 1008, "invalid_frame");
      return;
    }

    const now = Date.now();
    if (this.hasExpiredActiveTurn(stored, now)) {
      await this.deleteSession("turn_expired");
      return;
    }
    let record = this.cleanup(stored, now);
    const digest = await sha256Hex(message);
    const highest = role === "client"
      ? record.highestClientSeq
      : record.highestAdapterSeq;
    const seen = role === "client" ? record.seenClient : record.seenAdapter;
    const exactReplay = seen.find(
      (entry) => entry.seq === frame.seq && entry.messageId === frame.messageId,
    );
    if (
      exactReplay !== undefined &&
      exactReplay.digest === digest &&
      exactReplay.kind === frame.kind &&
      RELAY_RECEIPT_KINDS.has(frame.kind)
    ) {
      this.sendRelayReceipt(webSocket, record.connectionId, frame.seq, frame.messageId);
      return;
    }
    if (
      frame.seq <= highest ||
      seen.some((entry) => entry.messageId === frame.messageId)
    ) {
      this.close(webSocket, 1008, "replay_rejected");
      return;
    }

    if (frame.kind === "ack") {
      const ackSeq = frame.payload.ackSeq as number;
      const oppositeHighest = role === "client"
        ? record.highestAdapterSeq
        : record.highestClientSeq;
      if (ackSeq > oppositeHighest) {
        this.close(webSocket, 1008, "invalid_ack");
        return;
      }
      record = this.recordInbound(record, role, frame, digest, now);
      record.pending = record.pending.filter(
        (pending) => !(pending.from === opposite(role) && pending.seq <= ackSeq),
      );
      if (role === "client") {
        record.acknowledgedAdapterSeq = Math.max(
          record.acknowledgedAdapterSeq,
          ackSeq,
        );
      } else {
        record.acknowledgedClientSeq = Math.max(
          record.acknowledgedClientSeq,
          ackSeq,
        );
      }
      await this.persistSession(record);
      await this.scheduleCleanup(record);
      return;
    }

    const turnId = frameTurnId(frame);
    const redundantTerminal =
      role === "adapter" &&
      frame.kind === "turn.error" &&
      turnId !== undefined &&
      record.settledTurns?.some(
        (turn) => turn.turnId === turnId && turn.conversationId === frame.conversationId,
      ) === true;
    if (redundantTerminal) {
      record = this.recordInbound(record, role, frame, digest, now);
      await this.persistSession(record);
      await this.scheduleCleanup(record);
      this.sendRelayReceipt(webSocket, record.connectionId, frame.seq, frame.messageId);
      return;
    }

    const lifecycle = this.applyTurnLifecycle(record, role, frame, now);
    if (typeof lifecycle === "string") {
      this.close(webSocket, 1008, lifecycle);
      return;
    }
    record = this.recordInbound(lifecycle, role, frame, digest, now);
    const encodedFrame = JSON.stringify(frame);
    if (frame.kind === "heartbeat") {
      await this.persistSession(record);
      await this.scheduleCleanup(record);
      this.sendToActiveRole(record, opposite(role), encodedFrame);
      return;
    }
    if (record.pending.length >= maxPendingFrames(this.env)) {
      this.close(webSocket, 1013, "pending_limit");
      return;
    }
    const encrypted = await encryptPendingFrame(
      encodedFrame,
      this.env.PENDING_EVENT_KEK_B64,
      record.connectionId,
      role,
      frame.seq,
    );
    record.pending.push({
      from: role,
      seq: frame.seq,
      messageId: frame.messageId,
      encrypted,
      expiresAt: now + pendingTtlMilliseconds(this.env),
    });
    await this.persistSession(record);
    await this.scheduleCleanup(record);

    this.sendRelayReceipt(webSocket, record.connectionId, frame.seq, frame.messageId);
    this.sendToActiveRole(record, opposite(role), encodedFrame);
  }

  private sendRelayReceipt(
    socket: WebSocket,
    connectionId: string,
    senderSeq: number,
    messageId: string,
  ): void {
    try {
      socket.send(JSON.stringify(relayReceipt(connectionId, senderSeq, messageId)));
    } catch {
      // Durable seen metadata replays the receipt on reconnect.
    }
  }

  private sendToActiveRole(
    record: SessionRecord,
    role: SocketRole,
    encodedFrame: string,
  ): void {
    const activeSocketId = expectedSocketId(record, role);
    if (activeSocketId === undefined) return;
    for (const recipient of this.ctx.getWebSockets(role)) {
      const attachment = recipient.deserializeAttachment() as SocketAttachment | null;
      if (attachment?.socketId !== activeSocketId || attachment.role !== role) continue;
      try {
        recipient.send(encodedFrame);
      } catch {
        // The durable pending copy will be replayed on reconnect.
      }
    }
  }

  private kindAllowed(role: SocketRole, frame: ConnectorFrame): boolean {
    return (role === "client" ? CLIENT_KINDS : ADAPTER_KINDS).has(frame.kind);
  }

  private recordInbound(
    record: SessionRecord,
    role: SocketRole,
    frame: ConnectorFrame,
    digest: string,
    now: number,
  ): SessionRecord {
    const seenEntry = {
      seq: frame.seq,
      messageId: frame.messageId,
      digest,
      kind: frame.kind,
      expiresAt: now + pendingTtlMilliseconds(this.env),
    };
    if (role === "client") {
      return {
        ...record,
        highestClientSeq: frame.seq,
        seenClient: [...record.seenClient, seenEntry].slice(
          -MAX_SEEN_MESSAGES_PER_ROLE,
        ),
      };
    }
    return {
      ...record,
      highestAdapterSeq: frame.seq,
      seenAdapter: [...record.seenAdapter, seenEntry].slice(
        -MAX_SEEN_MESSAGES_PER_ROLE,
      ),
    };
  }

  private applyTurnLifecycle(
    record: SessionRecord,
    role: SocketRole,
    frame: ConnectorFrame,
    now: number,
  ): SessionRecord | string {
    if (frame.kind === "heartbeat") return record;
    const conversationId = frame.conversationId;
    const turnId = frameTurnId(frame);
    if (conversationId === undefined || turnId === undefined) return "invalid_turn";
    const activeIndex = record.activeTurns.findIndex(
      (turn) => turn.conversationId === conversationId,
    );
    const active = record.activeTurns[activeIndex];

    if (role === "client" && frame.kind === "turn.submit") {
      if (record.settledTurns?.some((turn) => turn.turnId === turnId)) {
        return "duplicate_turn";
      }
      if (record.activeTurns.some((turn) => turn.turnId === turnId)) {
        return "duplicate_turn";
      }
      if (active !== undefined) {
        return "conversation_busy";
      }
      const accountId = frame.payload.accountId as string;
      if (!record.accounts.some((account) => account.accountId === accountId)) {
        return "account_not_allowed";
      }
      return {
        ...record,
        activeTurns: [
          ...record.activeTurns,
          { conversationId, turnId, startedAt: now, lastActivityAt: now },
        ],
      };
    }

    if (role === "client" && frame.kind === "turn.cancel") {
      const activeByTurn = record.activeTurns.find((turn) => turn.turnId === turnId);
      if (activeByTurn !== undefined && activeByTurn.conversationId !== conversationId) {
        return "turn_mismatch";
      }
      if (active !== undefined && active.turnId !== turnId) return "turn_mismatch";
      return record;
    }

    if (active === undefined || active.turnId !== turnId) return "turn_mismatch";
    if (frame.kind === "turn.accepted") {
      if (active.accepted === true) return "duplicate_accept";
      return this.replaceTurn(record, activeIndex, {
        ...active,
        accepted: true,
        lastActivityAt: now,
      });
    }
    if (frame.kind === "assistant.delta") {
      if (active.accepted !== true) return "turn_not_accepted";
      const revision = frame.payload.revision as number;
      if (revision <= (active.lastRevision ?? 0)) return "revision_replay";
      return this.replaceTurn(record, activeIndex, {
        ...active,
        lastRevision: revision,
        lastActivityAt: now,
      });
    }
    if (frame.kind === "assistant.completed") {
      if (active.accepted !== true) return "turn_not_accepted";
      return {
        ...record,
        activeTurns: record.activeTurns.filter((_, index) => index !== activeIndex),
        settledTurns: [
          ...(record.settledTurns ?? []).filter((turn) => turn.turnId !== turnId),
          { conversationId, turnId, settledAt: now },
        ],
      };
    }
    if (frame.kind === "turn.error") {
      return {
        ...record,
        activeTurns: record.activeTurns.filter((_, index) => index !== activeIndex),
        settledTurns: [
          ...(record.settledTurns ?? []).filter((turn) => turn.turnId !== turnId),
          { conversationId, turnId, settledAt: now },
        ],
      };
    }
    return "invalid_turn";
  }

  private replaceTurn(
    record: SessionRecord,
    index: number,
    turn: ActiveTurn,
  ): SessionRecord {
    return {
      ...record,
      activeTurns: record.activeTurns.map((value, current) =>
        current === index ? turn : value
      ),
    };
  }

  private cleanup(record: SessionRecord, now: number): SessionRecord {
    return {
      ...record,
      pending: record.pending.filter((frame) => frame.expiresAt > now),
      seenClient: record.seenClient.filter((entry) => entry.expiresAt > now),
      seenAdapter: record.seenAdapter.filter((entry) => entry.expiresAt > now),
      settledTurns: (record.settledTurns ?? []).filter(
        (turn) => turn.settledAt + pendingTtlMilliseconds(this.env) > now,
      ),
    };
  }

  private async scheduleCleanup(record: SessionRecord): Promise<void> {
    const timestamps = [
      ...(record.clientTokenVerifier === undefined
        ? [record.unpairedCleanupAt]
        : []),
      ...record.pending.map((frame) => frame.expiresAt),
      ...record.seenClient.map((entry) => entry.expiresAt),
      ...record.seenAdapter.map((entry) => entry.expiresAt),
      ...record.activeTurns.map(
        (turn) => this.activeTurnDeadline(turn),
      ),
      ...(record.settledTurns ?? []).map(
        (turn) => turn.settledAt + pendingTtlMilliseconds(this.env),
      ),
    ];
    if (timestamps.length === 0) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    await this.ctx.storage.setAlarm(Math.min(...timestamps));
  }

  private activeTurnDeadline(turn: ActiveTurn): number {
    return Math.min(
      turn.startedAt + activeTurnMaxDurationMilliseconds(this.env),
      (turn.lastActivityAt ?? turn.startedAt) + activeTurnIdleTtlMilliseconds(this.env),
    );
  }

  private hasExpiredActiveTurn(record: SessionRecord, now: number): boolean {
    return record.activeTurns.some((turn) => this.activeTurnDeadline(turn) <= now);
  }

  private async deleteSession(
    reason: "pairing_expired" | "revoked" | "turn_expired",
  ): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    for (const socket of this.ctx.getWebSockets()) {
      try {
        socket.close(4003, reason);
      } catch {
        // A concurrently closed socket needs no further action.
      }
    }
  }

  private async persistSession(record: SessionRecord): Promise<void> {
    await this.ctx.storage.put(SESSION_KEY, record);
  }

  private close(webSocket: WebSocket, code: number, reason: string): void {
    try {
      webSocket.close(code, reason);
    } catch {
      // A concurrently closed socket needs no further action.
    }
  }
}
