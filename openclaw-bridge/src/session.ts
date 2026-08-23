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
  AttachmentRecord,
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
  "assistant.activity.upsert",
  "assistant.activity.clear",
  "assistant.work.upsert",
  "assistant.attachment",
  "assistant.completed",
  "turn.error",
]);
const RELAY_RECEIPT_KINDS = new Set<FrameKind>([
  "turn.submit",
  "turn.accepted",
  "assistant.delta",
  "assistant.activity.upsert",
  "assistant.activity.clear",
  "assistant.work.upsert",
  "assistant.attachment",
  "assistant.completed",
  "turn.cancel",
  "turn.error",
]);
const MAX_ATTACHMENTS_PER_TURN = 8;
const MAX_ATTACHMENTS_PER_SESSION = 64;
const MAX_ATTACHMENT_BYTES_PER_TURN = 64 * 1_024 * 1_024;

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

type InternalAttachmentRequest = Omit<AttachmentRecord, "state">;

interface InternalAttachmentMutationRequest {
  attachmentId: string;
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
    if (
      request.method === "POST" &&
      url.pathname === "/internal/pairings/authorize"
    ) {
      return this.authorizeReplacementPairing(request);
    }
    if (request.method === "GET" && url.pathname === "/internal/status") {
      return this.connectionStatus(request);
    }
    if (request.method === "GET" && url.pathname === "/internal/connect") {
      const role = url.searchParams.get("role");
      if (role !== "client" && role !== "adapter") {
        return json({ error: "invalid_request" }, 400);
      }
      return this.connectWebSocket(request, role);
    }
    if (request.method === "POST" && url.pathname === "/internal/attachments/reserve") {
      return this.reserveAttachment(
        request,
        await request.json<InternalAttachmentRequest>(),
      );
    }
    if (request.method === "POST" && url.pathname === "/internal/attachments/commit") {
      return this.commitAttachment(
        request,
        await request.json<InternalAttachmentMutationRequest>(),
      );
    }
    if (request.method === "POST" && url.pathname === "/internal/attachments/abort") {
      return this.abortAttachment(
        request,
        await request.json<InternalAttachmentMutationRequest>(),
      );
    }
    const attachmentMatch = /^\/internal\/attachments\/([0-9a-f-]{36})$/.exec(url.pathname);
    if (request.method === "GET" && attachmentMatch?.[1] !== undefined) {
      return this.authorizeAttachmentDownload(request, attachmentMatch[1]);
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
    const expiredAttachmentIds = (record.attachments ?? [])
      .filter(
        (attachment) =>
          attachment.expiresAt <= now || attachment.state === "acknowledged",
      )
      .map((attachment) => attachment.attachmentId);
    if (expiredAttachmentIds.length > 0) {
      await this.deleteAttachmentBlobs(record.connectionId, expiredAttachmentIds);
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

  private async authorizeReplacementPairing(request: Request): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, record, "adapter"))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (record.activeTurns.length > 0) {
      return json({ error: "conversation_busy" }, 409);
    }
    return json({
      v: 1,
      adapterId: record.adapterId,
      gatewayLabel: record.gatewayLabel,
      accounts: record.accounts,
    });
  }

  private async connectionStatus(request: Request): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, record, "client"))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (this.hasExpiredActiveTurn(record, Date.now())) {
      await this.deleteSession("turn_expired");
      return json({ error: "not_found" }, 404);
    }
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

  private attachmentRequestValid(
    record: SessionRecord,
    value: InternalAttachmentRequest,
    now: number,
  ): boolean {
    return (
      typeof value.attachmentId === "string" &&
      typeof value.conversationId === "string" &&
      typeof value.turnId === "string" &&
      typeof value.fileName === "string" &&
      typeof value.mediaType === "string" &&
      Number.isSafeInteger(value.byteCount) &&
      value.byteCount >= 1 &&
      value.byteCount <= 32 * 1_024 * 1_024 &&
      typeof value.sha256 === "string" &&
      typeof value.downloadPath === "string" &&
      Number.isSafeInteger(value.createdAt) &&
      Number.isSafeInteger(value.expiresAt) &&
      value.createdAt <= now + 60_000 &&
      value.expiresAt > now &&
      value.expiresAt <= value.createdAt + 7 * 24 * 60 * 60 * 1_000 &&
      value.downloadPath ===
        `/v1/connectors/${record.connectionId}/attachments/${value.attachmentId}`
    );
  }

  private sameAttachment(
    left: AttachmentRecord,
    right: InternalAttachmentRequest,
  ): boolean {
    return (
      left.attachmentId === right.attachmentId &&
      left.conversationId === right.conversationId &&
      left.turnId === right.turnId &&
      left.fileName === right.fileName &&
      left.mediaType === right.mediaType &&
      left.byteCount === right.byteCount &&
      left.sha256 === right.sha256 &&
      left.downloadPath === right.downloadPath
    );
  }

  private async reserveAttachment(
    request: Request,
    value: InternalAttachmentRequest,
  ): Promise<Response> {
    const stored = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (stored === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, stored, "adapter"))) {
      return json({ error: "unauthorized" }, 401);
    }
    const now = Date.now();
    if (!this.attachmentRequestValid(stored, value, now)) {
      return json({ error: "invalid_request" }, 400);
    }
    const record = this.cleanup(stored, now);
    const existing = record.attachments?.find(
      (attachment) => attachment.attachmentId === value.attachmentId,
    );
    if (existing !== undefined) {
      if (!this.sameAttachment(existing, value)) return json({ error: "conflict" }, 409);
      return json({ attachment: existing, idempotent: true });
    }
    const active = record.activeTurns.find(
      (turn) =>
        turn.turnId === value.turnId && turn.conversationId === value.conversationId,
    );
    if (
      active?.accepted !== true ||
      !active.capabilities?.includes("attachments-v1")
    ) {
      return json({ error: "attachment_not_allowed" }, 409);
    }
    const turnAttachments = (record.attachments ?? []).filter(
      (attachment) => attachment.turnId === value.turnId,
    );
    if (
      (record.attachments?.length ?? 0) >= MAX_ATTACHMENTS_PER_SESSION ||
      turnAttachments.length >= MAX_ATTACHMENTS_PER_TURN ||
      turnAttachments.reduce((total, attachment) => total + attachment.byteCount, 0) +
        value.byteCount > MAX_ATTACHMENT_BYTES_PER_TURN
    ) {
      return json({ error: "attachment_limit" }, 413);
    }
    const attachment: AttachmentRecord = { ...value, state: "uploading" };
    const updated = {
      ...record,
      attachments: [...(record.attachments ?? []), attachment],
    };
    await this.persistSession(updated);
    await this.scheduleCleanup(updated);
    return json({ attachment }, 201);
  }

  private async commitAttachment(
    request: Request,
    value: InternalAttachmentMutationRequest,
  ): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, record, "adapter"))) {
      return json({ error: "unauthorized" }, 401);
    }
    const index = (record.attachments ?? []).findIndex(
      (attachment) => attachment.attachmentId === value.attachmentId,
    );
    const attachment = record.attachments?.[index];
    if (attachment === undefined) return json({ error: "not_found" }, 404);
    if (attachment.state === "announced" || attachment.state === "acknowledged") {
      return json({ attachment, idempotent: true });
    }
    const ready: AttachmentRecord = { ...attachment, state: "ready" };
    const updated = {
      ...record,
      attachments: (record.attachments ?? []).map((item, current) =>
        current === index ? ready : item,
      ),
    };
    await this.persistSession(updated);
    await this.scheduleCleanup(updated);
    return json({ attachment: ready });
  }

  private async abortAttachment(
    request: Request,
    value: InternalAttachmentMutationRequest,
  ): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, record, "adapter"))) {
      return json({ error: "unauthorized" }, 401);
    }
    const attachment = record.attachments?.find(
      (item) => item.attachmentId === value.attachmentId,
    );
    if (attachment?.state === "announced" || attachment?.state === "acknowledged") {
      return json({ error: "conflict" }, 409);
    }
    const updated = {
      ...record,
      attachments: (record.attachments ?? []).filter(
        (item) => item.attachmentId !== value.attachmentId,
      ),
    };
    await this.persistSession(updated);
    await this.scheduleCleanup(updated);
    return new Response(null, { status: 204 });
  }

  private async authorizeAttachmentDownload(
    request: Request,
    attachmentId: string,
  ): Promise<Response> {
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record === undefined) return json({ error: "not_found" }, 404);
    if (!(await this.authenticates(request, record, "client"))) {
      return json({ error: "unauthorized" }, 401);
    }
    const attachment = record.attachments?.find(
      (item) => item.attachmentId === attachmentId,
    );
    if (
      attachment === undefined ||
      attachment.state !== "announced" ||
      attachment.expiresAt <= Date.now()
    ) {
      return json({ error: "not_found" }, 404);
    }
    return json({ attachment });
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
      const acknowledgedAttachmentIds = role === "client"
        ? record.pending
            .filter(
              (pending) =>
                pending.from === "adapter" &&
                pending.seq <= ackSeq &&
                pending.kind === "assistant.attachment" &&
                pending.attachmentId !== undefined,
            )
            .map((pending) => pending.attachmentId as string)
        : [];
      record.pending = record.pending.filter(
        (pending) => !(pending.from === opposite(role) && pending.seq <= ackSeq),
      );
      if (acknowledgedAttachmentIds.length > 0) {
        const acknowledged = new Set(acknowledgedAttachmentIds);
        record.attachments = (record.attachments ?? []).map((attachment) =>
          acknowledged.has(attachment.attachmentId)
            ? { ...attachment, state: "acknowledged" }
            : attachment,
        );
      }
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
      if (acknowledgedAttachmentIds.length > 0) {
        const deleted = await this.deleteAttachmentBlobs(
          record.connectionId,
          acknowledgedAttachmentIds,
        );
        if (deleted.length > 0) {
          const removed = new Set(deleted);
          record.attachments = (record.attachments ?? []).filter(
            (attachment) => !removed.has(attachment.attachmentId),
          );
          await this.persistSession(record);
          await this.scheduleCleanup(record);
        }
      }
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

    const failedAttachmentIds = role === "adapter" && frame.kind === "turn.error"
      ? (record.attachments ?? [])
          .filter((attachment) => attachment.turnId === turnId)
          .map((attachment) => attachment.attachmentId)
      : [];
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
    record.pending = this.coalescePending(record.pending, role, frame);
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
      kind: frame.kind,
      ...(turnId === undefined ? {} : { turnId }),
      ...(frame.kind === "assistant.attachment"
        ? { attachmentId: frame.payload.attachmentId as string }
        : {}),
      ...(frame.kind === "assistant.work.upsert"
        ? { workStepId: frame.payload.stepId as string }
        : {}),
    });
    await this.persistSession(record);
    await this.scheduleCleanup(record);

    this.sendRelayReceipt(webSocket, record.connectionId, frame.seq, frame.messageId);
    this.sendToActiveRole(record, opposite(role), encodedFrame);
    if (failedAttachmentIds.length > 0) {
      await this.deleteAttachmentBlobs(record.connectionId, failedAttachmentIds);
    }
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

  private coalescePending(
    pending: SessionRecord["pending"],
    role: SocketRole,
    frame: ConnectorFrame,
  ): SessionRecord["pending"] {
    const turnId = frameTurnId(frame);
    if (role !== "adapter" || turnId === undefined) return pending;
    if (frame.kind === "assistant.delta") {
      return pending.filter(
        (item) =>
          item.from !== role ||
          item.kind !== "assistant.delta" ||
          item.turnId !== turnId,
      );
    }
    if (
      frame.kind === "assistant.activity.upsert" ||
      frame.kind === "assistant.activity.clear"
    ) {
      return pending.filter(
        (item) =>
          item.from !== role ||
          item.turnId !== turnId ||
          (item.kind !== "assistant.activity.upsert" &&
            item.kind !== "assistant.activity.clear"),
      );
    }
    if (frame.kind === "assistant.work.upsert") {
      const stepId = frame.payload.stepId as string;
      return pending.filter(
        (item) =>
          item.from !== role ||
          item.turnId !== turnId ||
          item.kind !== "assistant.work.upsert" ||
          item.workStepId !== stepId,
      );
    }
    return pending;
  }

  private attachmentStub(connectionId: string, attachmentId: string): DurableObjectStub {
    return this.env.ATTACHMENTS.get(
      this.env.ATTACHMENTS.idFromName(`${connectionId}:${attachmentId}`),
    );
  }

  private async deleteAttachmentBlobs(
    connectionId: string,
    attachmentIds: string[],
  ): Promise<string[]> {
    const deleted: string[] = [];
    for (const attachmentId of new Set(attachmentIds)) {
      try {
        const response = await this.attachmentStub(connectionId, attachmentId).fetch(
          "https://attachment.internal/internal/delete",
          { method: "DELETE" },
        );
        if (response.status === 204) deleted.push(attachmentId);
      } catch {
        // The attachment's own alarm is the bounded cleanup fallback.
      }
    }
    return deleted;
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
          {
            conversationId,
            turnId,
            startedAt: now,
            lastActivityAt: now,
            ...(Array.isArray(frame.payload.capabilities)
              ? {
                  capabilities: frame.payload.capabilities as NonNullable<
                    ActiveTurn["capabilities"]
                  >,
                }
              : {}),
          },
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
    if (
      frame.kind === "assistant.activity.upsert" ||
      frame.kind === "assistant.activity.clear"
    ) {
      if (active.accepted !== true) return "turn_not_accepted";
      if (!active.capabilities?.includes("activity-v1")) return "capability_not_negotiated";
      const revision = frame.payload.revision as number;
      if (revision <= (active.lastActivityRevision ?? 0)) return "revision_replay";
      return this.replaceTurn(record, activeIndex, {
        ...active,
        lastActivityRevision: revision,
        lastActivityAt: now,
      });
    }
    if (frame.kind === "assistant.work.upsert") {
      if (active.accepted !== true) return "turn_not_accepted";
      if (!active.capabilities?.includes("work-v1")) return "capability_not_negotiated";
      const revision = frame.payload.revision as number;
      if (revision <= (active.lastWorkRevision ?? 0)) return "revision_replay";
      return this.replaceTurn(record, activeIndex, {
        ...active,
        lastWorkRevision: revision,
        lastActivityAt: now,
      });
    }
    if (frame.kind === "assistant.attachment") {
      if (active.accepted !== true) return "turn_not_accepted";
      if (!active.capabilities?.includes("attachments-v1")) {
        return "capability_not_negotiated";
      }
      const attachmentId = frame.payload.attachmentId as string;
      const attachmentIndex = (record.attachments ?? []).findIndex(
        (item) => item.attachmentId === attachmentId,
      );
      const attachment = record.attachments?.[attachmentIndex];
      if (
        attachment === undefined ||
        attachment.state !== "ready" ||
        attachment.turnId !== turnId ||
        attachment.conversationId !== conversationId ||
        attachment.fileName !== frame.payload.fileName ||
        attachment.mediaType !== frame.payload.mediaType ||
        attachment.byteCount !== frame.payload.byteCount ||
        attachment.sha256 !== frame.payload.sha256 ||
        attachment.downloadPath !== frame.payload.downloadPath ||
        attachment.expiresAt !== frame.payload.expiresAt ||
        attachment.expiresAt <= now
      ) {
        return "attachment_mismatch";
      }
      return {
        ...this.replaceTurn(record, activeIndex, { ...active, lastActivityAt: now }),
        attachments: (record.attachments ?? []).map((item, index) =>
          index === attachmentIndex ? { ...item, state: "announced" } : item,
        ),
      };
    }
    if (frame.kind === "assistant.completed") {
      if (active.accepted !== true) return "turn_not_accepted";
      if (
        record.attachments?.some(
          (attachment) =>
            attachment.turnId === turnId &&
            attachment.state !== "announced" &&
            attachment.state !== "acknowledged",
        )
      ) {
        return "attachment_pending";
      }
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
        pending: record.pending.filter(
          (pending) =>
            pending.turnId !== turnId || pending.kind !== "assistant.attachment",
        ),
        attachments: (record.attachments ?? []).filter(
          (attachment) => attachment.turnId !== turnId,
        ),
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
      attachments: (record.attachments ?? []).filter(
        (attachment) => attachment.expiresAt > now,
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
      ...(record.attachments ?? []).map((attachment) =>
        attachment.state === "acknowledged"
          ? Math.min(attachment.expiresAt, Date.now() + 60_000)
          : attachment.expiresAt,
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
    const record = await this.ctx.storage.get<SessionRecord>(SESSION_KEY);
    if (record !== undefined && (record.attachments?.length ?? 0) > 0) {
      await this.deleteAttachmentBlobs(
        record.connectionId,
        (record.attachments ?? []).map((attachment) => attachment.attachmentId),
      );
    }
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
