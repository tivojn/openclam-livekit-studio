import WebSocket from "ws";
import { OpenClamAttachmentUploadError, uploadOpenClamAttachment, } from "./attachment-upload.js";
import { readAdapterCredential, readAdapterState, writeAdapterState, } from "./credentials.js";
import { dispatchOpenClamTurn } from "./inbound.js";
import { MAX_ATTACHMENTS_PER_TURN, MAX_ATTACHMENT_BYTES_PER_TURN, } from "./media.js";
import { createFrame, encodeFrame, encodeFrameWithTextBudget, MAX_TEXT_LENGTH, parseBridgeInbound, safeTurnErrorPayload, truncateUnicode, } from "./protocol.js";
import { redactPrivatePathReferences, rememberMediaReplacement, replaceExactMediaReferences, } from "./privacy.js";
const defaultDependencies = {
    readCredential: readAdapterCredential,
    readState: readAdapterState,
    writeState: writeAdapterState,
    createSocket: (url, options) => new WebSocket(url, options),
    dispatchTurn: dispatchOpenClamTurn,
    reconnectDelay: (attempt) => Math.min(30_000, 500 * 2 ** Math.min(attempt, 6)),
    uploadAttachment: uploadOpenClamAttachment,
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
// Retry the same event, not a new sequence/revision. A still-open socket must
// not conceal a missing durable receipt indefinitely.
const RELAY_RECEIPT_INTERVAL_MS = 1_000;
const MAX_RELAY_TRANSMISSIONS_PER_SOCKET = 3;
// Progress is useful, but cannot own an unbounded barrier ahead of the result.
// This is one budget for the entire drain, not one timeout per queued step.
const WORK_DRAIN_BUDGET_MS = 2_000;
const OUTBOUND_TEXT_RECEIPT_BUDGET_MS = 10_000;
const MAX_OUTBOUND_TEXT_DELIVERIES = 32;
function mergeVisibleText(current, incoming) {
    const trimmed = incoming.trim();
    if (!current)
        return trimmed;
    if (!trimmed || current === trimmed || current.endsWith(trimmed))
        return current;
    if (trimmed.startsWith(current) || trimmed.endsWith(current))
        return trimmed;
    // A normal final may repeat one of several tool-sent blocks rather than the
    // entire cumulative reply. Keep every distinct block, without displaying
    // that exact text a second time. Do not attempt semantic/fuzzy deduplication.
    const incomingBlocks = new Set(trimmed.split(/\n\s*\n/));
    const previous = current.split(/\n\s*\n/).filter((block) => !incomingBlocks.has(block));
    return [...previous, trimmed].join("\n\n");
}
async function waitForTextReceipt(receipt) {
    let timer;
    try {
        return await Promise.race([
            receipt,
            new Promise((_resolve, reject) => {
                timer = setTimeout(() => reject(new Error("openclam_text_delivery_unconfirmed")), OUTBOUND_TEXT_RECEIPT_BUDGET_MS);
            }),
        ]);
    }
    finally {
        if (timer)
            clearTimeout(timer);
    }
}
function buildEventsUrl(bridgeUrl, connectionId) {
    const base = new URL(bridgeUrl);
    if (base.username || base.password || base.search || base.hash || base.pathname !== "/") {
        throw new Error("invalid_bridge_url");
    }
    const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(base.hostname);
    if (base.protocol === "https:")
        base.protocol = "wss:";
    else if (base.protocol === "http:" && local)
        base.protocol = "ws:";
    else
        throw new Error("invalid_bridge_url");
    base.pathname = `/v1/adapters/${connectionId}/events`;
    base.search = "";
    base.hash = "";
    return base.toString();
}
function waitForAbort(signal) {
    if (signal.aborted)
        return Promise.resolve();
    return new Promise((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
}
function abortableDelay(milliseconds, signal) {
    if (signal.aborted)
        return Promise.resolve();
    return new Promise((resolve) => {
        const timer = setTimeout(resolve, milliseconds);
        signal.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve();
        }, { once: true });
    });
}
function socketText(data, isBinary) {
    if (isBinary)
        throw new Error("binary_frame_rejected");
    if (typeof data === "string")
        return data;
    if (Array.isArray(data))
        return Buffer.concat(data).toString("utf8");
    if (Buffer.isBuffer(data))
        return data.toString("utf8");
    return Buffer.from(new Uint8Array(data)).toString("utf8");
}
export class OpenClamBridgeClient {
    connectionId;
    bridgeUrl;
    tokenFile;
    stateFile;
    accounts = new Map();
    activeTurns = new Map();
    lifecycle = new AbortController();
    outboundQueue = [];
    relayOutbox = new Map();
    turnTasks = new Set();
    deltaTasks = new Set();
    activityTasks = new Set();
    workTasks = new Set();
    deps;
    state;
    token = "";
    socket;
    runTask;
    stateTask = Promise.resolve();
    inboundTask = Promise.resolve();
    recoveryTask = Promise.resolve();
    reconnectAttempts = 0;
    constructor(connectionId, bridgeUrl, tokenFile, stateFile, dependencies = {}) {
        this.connectionId = connectionId;
        this.bridgeUrl = bridgeUrl;
        this.tokenFile = tokenFile;
        this.stateFile = stateFile;
        this.deps = { ...defaultDependencies, ...dependencies };
    }
    get accountCount() {
        return this.accounts.size;
    }
    async deliverTextToActiveConversation(params) {
        const active = [...this.activeTurns.values()].find((candidate) => candidate.frame.conversationId === params.conversationId &&
            candidate.frame.payload.accountId === params.accountId);
        if (!active || active.terminal || active.controller.signal.aborted) {
            throw new Error("openclam_conversation_inactive");
        }
        if (params.replyToId?.trim() && params.replyToId !== active.frame.payload.turnId) {
            throw new Error("openclam_reply_not_current_turn");
        }
        const text = redactPrivatePathReferences(params.text).trim();
        if (!text)
            throw new Error("openclam_text_missing");
        if (truncateUnicode(text, MAX_TEXT_LENGTH) !== text) {
            throw new Error("openclam_text_too_large");
        }
        // Retries within this live turn reuse the same durable event. Without a
        // host delivery intent, identical text is the bounded per-turn identity.
        const key = params.deliveryId?.trim() ? `id:${params.deliveryId.trim()}` : `text:${text}`;
        const existing = active.textDeliveries.get(key);
        if (existing) {
            if (existing.text !== text)
                throw new Error("openclam_text_delivery_conflict");
            return await waitForTextReceipt(existing.receipt);
        }
        if (active.textDeliveries.size >= MAX_OUTBOUND_TEXT_DELIVERIES) {
            throw new Error("openclam_text_delivery_limit");
        }
        const receipt = this.deliverActiveText(active, text, params.onPlatformSendDispatch);
        active.textDeliveries.set(key, { text, receipt });
        // A timeout is explicitly uncertain, never a fake successful send. The
        // unchanged event stays in the relay outbox until ACK, cancel or an actual
        // terminal receipt. Retrying this identity can await that same event.
        return await waitForTextReceipt(receipt);
    }
    async deliverActiveText(active, text, onPlatformSendDispatch) {
        if (onPlatformSendDispatch)
            await onPlatformSendDispatch();
        const reservation = await this.sequenceText(active, async () => {
            if (active.terminal || active.controller.signal.aborted || this.lifecycle.signal.aborted) {
                throw new Error("openclam_conversation_inactive");
            }
            const outboundText = mergeVisibleText(active.outboundText, text);
            const visibleText = mergeVisibleText(outboundText, active.replyText);
            if (truncateUnicode(visibleText, MAX_TEXT_LENGTH) !== visibleText) {
                throw new Error("openclam_text_too_large");
            }
            let frame;
            let release;
            const reserved = new Promise((resolve) => { release = resolve; });
            const revision = active.revision + 1;
            const persisted = this.sendAwaitingRelayPersistence("assistant.delta", { turnId: active.frame.payload.turnId, revision, text: visibleText }, active.frame.conversationId, undefined, AbortSignal.any([active.controller.signal, active.telemetryController.signal]), (created) => {
                frame = created;
                active.revision = revision;
                active.outboundText = outboundText;
                active.lastDeltaText = visibleText;
                active.lastDeltaAt = Date.now();
                const latest = mergeVisibleText(outboundText, active.replyText);
                active.pendingDelta = latest === visibleText ? undefined : latest;
                release();
            });
            void persisted.then(release, release);
            // Serialize only revision/sequence reservation, never a missing ACK.
            await reserved;
            return { frame, persisted };
        });
        const persisted = await reservation.persisted;
        if (!persisted || !reservation.frame || active.controller.signal.aborted) {
            throw new Error("openclam_text_delivery_unconfirmed");
        }
        return {
            messageId: reservation.frame.messageId,
            conversationId: active.frame.conversationId,
        };
    }
    sequenceText(active, work) {
        const task = active.textSequence.then(work);
        active.textSequence = task.then(() => undefined, () => undefined);
        return task;
    }
    async deliverMediaToActiveConversation(params) {
        const active = [...this.activeTurns.values()].find((candidate) => candidate.frame.conversationId === params.conversationId &&
            candidate.frame.payload.accountId === params.accountId);
        if (!active || active.terminal || active.controller.signal.aborted) {
            throw new Error("openclam_conversation_inactive");
        }
        const source = params.source.trim();
        const caption = params.caption?.trim();
        if (caption) {
            const replacements = new Map();
            if (source)
                rememberMediaReplacement(replacements, source, params.attachment.fileName);
            active.attachmentCaption = truncateUnicode(redactPrivatePathReferences(replaceExactMediaReferences(caption, replacements)), MAX_TEXT_LENGTH);
        }
        const existing = source ? active.attachmentsBySource.get(source) : undefined;
        if (existing)
            return existing;
        const pending = source ? active.attachmentsInFlight.get(source) : undefined;
        if (pending)
            return await pending;
        const task = this.deliverAttachment(active, params.attachment);
        if (source)
            active.attachmentsInFlight.set(source, task);
        try {
            const uploaded = await task;
            if (source)
                active.attachmentsBySource.set(source, uploaded);
            return uploaded;
        }
        finally {
            if (source && active.attachmentsInFlight.get(source) === task) {
                active.attachmentsInFlight.delete(source);
            }
        }
    }
    async attach(ctx) {
        const account = ctx.account;
        if (account.connectionId !== this.connectionId ||
            account.bridgeUrl !== this.bridgeUrl ||
            account.adapterTokenFile !== this.tokenFile ||
            account.stateFile !== this.stateFile) {
            throw new Error("inconsistent_gateway_connection");
        }
        const existing = this.accounts.get(account.accountId);
        if (existing && existing !== ctx)
            throw new Error("duplicate_openclam_account");
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
        }
        finally {
            this.accounts.delete(account.accountId);
            this.setAccountStatus(ctx, { running: false, connected: false });
            if (this.accounts.size === 0)
                await this.stop();
        }
    }
    async stop() {
        if (!this.lifecycle.signal.aborted)
            this.lifecycle.abort();
        this.socket?.close(1000, "shutdown");
        await this.runTask?.catch(() => undefined);
        await this.inboundTask.catch(() => undefined);
        for (const active of this.activeTurns.values()) {
            if (active.deltaTimer)
                clearTimeout(active.deltaTimer);
            if (active.activityTimer)
                clearTimeout(active.activityTimer);
            if (active.workTimer)
                clearTimeout(active.workTimer);
            active.controller.abort();
        }
        for (const pending of this.relayOutbox.values())
            pending.resolve(false);
        this.relayOutbox.clear();
        await Promise.all([...this.turnTasks]);
        await Promise.all([...this.deltaTasks]);
        await Promise.all([...this.activityTasks]);
        await Promise.all([...this.workTasks]);
        await this.recoveryTask.catch(() => undefined);
        await this.stateTask.catch(() => undefined);
    }
    async ensureStarted() {
        if (!this.state) {
            this.token = await this.deps.readCredential(this.tokenFile);
            this.state = await this.deps.readState(this.stateFile, this.connectionId);
        }
        if (!this.runTask)
            this.runTask = this.runLoop();
    }
    async runLoop() {
        while (!this.lifecycle.signal.aborted) {
            try {
                await this.connectOnce();
            }
            catch {
                this.log("warn", "connection_attempt_failed");
            }
            if (this.lifecycle.signal.aborted)
                break;
            this.reconnectAttempts += 1;
            this.updateAllStatuses({
                connected: false,
                reconnectAttempts: this.reconnectAttempts,
            });
            await abortableDelay(this.deps.reconnectDelay(this.reconnectAttempts), this.lifecycle.signal);
        }
    }
    async connectOnce() {
        const url = buildEventsUrl(this.bridgeUrl, this.connectionId);
        const socket = this.deps.createSocket(url, {
            headers: { Authorization: `Bearer ${this.token}` },
            maxPayload: 65_536,
            followRedirects: false,
            handshakeTimeout: 15_000,
        });
        this.socket = socket;
        await new Promise((resolve, reject) => {
            let opened = false;
            let heartbeat;
            const cleanup = () => {
                if (heartbeat)
                    clearInterval(heartbeat);
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
                this.detach(this.send("heartbeat", { lastReceivedSeq: this.requireState().lastReceivedSeq }, undefined, undefined, false), "heartbeat_failed");
                this.detach(this.flushActiveDeltas(), "delta_flush_failed");
                this.flushActiveActivities();
                this.flushActiveWork();
                this.detach(this.recoverInterruptedTurns(), "recovery_failed");
                heartbeat = setInterval(() => {
                    if (socket.readyState === WebSocket.OPEN)
                        socket.ping();
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
                if (this.socket === socket)
                    this.socket = undefined;
                for (const pending of this.relayOutbox.values()) {
                    if (pending.transmittedSocket === socket && pending.receiptTimer) {
                        clearTimeout(pending.receiptTimer);
                        pending.receiptTimer = undefined;
                    }
                }
                for (const active of this.activeTurns.values()) {
                    if (active.deltaTimer)
                        clearTimeout(active.deltaTimer);
                    active.deltaTimer = undefined;
                    if (active.activityTimer)
                        clearTimeout(active.activityTimer);
                    active.activityTimer = undefined;
                    if (active.workTimer)
                        clearTimeout(active.workTimer);
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
    async handleMessage(raw) {
        if (this.lifecycle.signal.aborted)
            return;
        const frame = parseBridgeInbound(raw, this.connectionId);
        if (frame.kind === "relay.persisted") {
            const pending = this.relayOutbox.get(frame.payload.messageId);
            if (pending === undefined)
                return;
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
    async acceptTurn(frame) {
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
        const activeForConversation = [...this.activeTurns.values()].find((active) => active.frame.conversationId === frame.conversationId);
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
        const active = {
            frame,
            controller: new AbortController(),
            telemetryController: new AbortController(),
            revision: 0,
            terminal: false,
            terminalPersisted: false,
            lastDeltaText: "",
            lastDeltaAt: 0,
            deltaCount: 0,
            replyText: "",
            outboundText: "",
            textSequence: Promise.resolve(),
            textDeliveries: new Map(),
            activityRevision: 0,
            activityCount: 0,
            lastActivityFrameAt: 0,
            workRevision: 0,
            workCount: 0,
            workStepIds: new Set(),
            pendingWork: new Map(),
            lastWork: new Map(),
            lastWorkFrameAt: 0,
            attachmentCount: 0,
            attachmentBytes: 0,
            attachmentsBySource: new Map(),
            attachmentsInFlight: new Map(),
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
        active.acceptanceTask = this.sendAwaitingRelayPersistence("turn.accepted", { turnId }, frame.conversationId, frame.seq, active.controller.signal);
        const task = this.runAcceptedTurn(ctx, active);
        this.turnTasks.add(task);
        void task.then(() => this.turnTasks.delete(task), () => this.turnTasks.delete(task));
    }
    async runAcceptedTurn(ctx, active) {
        try {
            const accepted = await active.acceptanceTask;
            if (!accepted) {
                if (active.terminalTask) {
                    active.terminalPersisted = await active.terminalTask;
                    this.activeTurns.delete(active.frame.payload.turnId);
                    if (active.terminalPersisted)
                        await this.finishTurn(active.frame.payload.turnId);
                }
                return;
            }
            if (active.terminal || active.controller.signal.aborted) {
                if (active.terminalTask) {
                    active.terminalPersisted = await active.terminalTask;
                    this.activeTurns.delete(active.frame.payload.turnId);
                    if (active.terminalPersisted)
                        await this.finishTurn(active.frame.payload.turnId);
                }
                return;
            }
            await this.runTurn(ctx, active);
        }
        catch {
            this.log("warn", "turn_acceptance_failed");
        }
    }
    async rejectTurn(frame, recoveryError) {
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
    async runTurn(ctx, active) {
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
                        if (active.terminal || active.controller.signal.aborted)
                            return;
                        await this.offerDelta(active, truncateUnicode(text, MAX_TEXT_LENGTH));
                    },
                    attachment: async (attachment) => {
                        if (active.terminal || active.controller.signal.aborted)
                            return;
                        await this.deliverAttachment(active, attachment);
                    },
                    completed: async (text) => {
                        if (active.terminal || active.controller.signal.aborted)
                            return;
                        active.terminalPersisted = await this.beginTerminal(active, "assistant.completed", { turnId: frame.payload.turnId, text: truncateUnicode(text, MAX_TEXT_LENGTH) }, {
                            code: "connection_interrupted",
                            message: "The connection closed before this reply could be delivered. Please try again.",
                            retryable: true,
                        });
                    },
                },
            });
            if (!active.terminal)
                throw new Error("empty_reply");
        }
        catch (error) {
            if (!active.terminal) {
                const code = error instanceof Error ? error.message : "agent_failed";
                if (code === "agent_mapping_changed") {
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code,
                        message: "This agent mapping changed. Pair OpenClam again.",
                        retryable: false,
                    }), {
                        code,
                        message: "This agent mapping changed. Pair OpenClam again.",
                        retryable: false,
                    });
                }
                else if (code === "sensitive_media_unsupported") {
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code,
                        message: "Sensitive live-only media cannot be saved in OpenClam.",
                        retryable: false,
                    }), {
                        code,
                        message: "Sensitive live-only media cannot be saved in OpenClam.",
                        retryable: false,
                    });
                }
                else if (code === "attachment_limit" ||
                    code === "attachment_size_invalid" ||
                    code === "attachment_type_unsupported") {
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code,
                        message: "This generated file cannot be delivered to OpenClam.",
                        retryable: false,
                    }), {
                        code,
                        message: "This generated file cannot be delivered to OpenClam.",
                        retryable: false,
                    });
                }
                else if (code === "attachment_upload_failed" ||
                    code === "invalid_attachment_response" ||
                    code === "attachment_delivery_failed") {
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code: "attachment_delivery_failed",
                        message: "The generated file could not be delivered. Please try again.",
                        retryable: true,
                    }), {
                        code: "attachment_delivery_failed",
                        message: "The generated file could not be delivered. Please try again.",
                        retryable: true,
                    });
                }
                else if (code === "empty_reply" &&
                    !active.controller.signal.aborted &&
                    (active.attachmentCount > 0 || active.outboundText)) {
                    const fallback = active.outboundText || active.attachmentCaption ||
                        `Created ${active.attachmentCount} ${active.attachmentCount === 1 ? "file" : "files"}.`;
                    active.terminalPersisted = await this.beginTerminal(active, "assistant.completed", { turnId: frame.payload.turnId, text: truncateUnicode(fallback, MAX_TEXT_LENGTH) }, {
                        code: "connection_interrupted",
                        message: "The connection closed before this reply could be delivered. Please try again.",
                        retryable: true,
                    });
                }
                else if (active.controller.signal.aborted) {
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code: "cancelled",
                        message: "The turn was cancelled.",
                        retryable: false,
                    }), {
                        code: "cancelled",
                        message: "The turn was cancelled.",
                        retryable: false,
                    });
                }
                else {
                    const safeCode = code === "empty_reply" ? "empty_reply" : "agent_failed";
                    active.terminalPersisted = await this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                        turnId: frame.payload.turnId,
                        code: safeCode,
                        message: "OpenClaw could not complete this reply.",
                        retryable: true,
                    }), {
                        code: safeCode,
                        message: "OpenClaw could not complete this reply.",
                        retryable: true,
                    });
                }
            }
        }
        finally {
            this.clearDeltaTimer(active);
            this.clearActivityTimer(active);
            this.clearWorkTimer(active);
            if (active.terminalTask) {
                active.terminalPersisted = await active.terminalTask;
            }
            this.activeTurns.delete(frame.payload.turnId);
            if (active.terminalPersisted)
                await this.finishTurn(frame.payload.turnId);
            else if (this.socket?.readyState === WebSocket.OPEN) {
                this.detach(this.recoverInterruptedTurns(), "recovery_failed");
            }
        }
    }
    async cancelTurn(frame) {
        const turnId = String(frame.payload.turnId);
        const active = this.activeTurns.get(turnId);
        if (active) {
            if (active.frame.conversationId !== frame.conversationId)
                return;
            if (!active.terminal) {
                void this.beginTerminal(active, "turn.error", safeTurnErrorPayload({
                    turnId,
                    code: "cancelled",
                    message: "The turn was cancelled.",
                    retryable: false,
                }), {
                    code: "cancelled",
                    message: "The turn was cancelled.",
                    retryable: false,
                });
                active.controller.abort();
            }
            else
                active.controller.abort();
            return;
        }
        if (!this.requireState().completedTurnIds.includes(turnId)) {
            await this.mutateState((state) => {
                const existing = state.activeTurns.find((turn) => turn.turnId === turnId && turn.conversationId === frame.conversationId);
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
    async finishTurn(turnId) {
        await this.mutateState((state) => {
            state.activeTurns = state.activeTurns.filter((turn) => turn.turnId !== turnId);
            state.completedTurnIds = [
                ...state.completedTurnIds.filter((id) => id !== turnId),
                turnId,
            ].slice(-256);
        });
    }
    async markRecoveryError(active, error) {
        await this.mutateState((state) => {
            const turn = state.activeTurns.find((candidate) => candidate.turnId === active.frame.payload.turnId);
            if (turn) {
                turn.recoveryExpiresAt = Date.now() + RECOVERY_MARKER_TTL_MS;
                turn.recoveryError = error;
            }
        });
    }
    beginTerminal(active, kind, payload, recoveryError) {
        if (active.terminalTask)
            return active.terminalTask;
        active.terminal = true;
        this.clearDeltaTimer(active);
        active.terminalTask = (async () => {
            await active.textSequence;
            await this.drainWork(active);
            await this.markRecoveryError(active, recoveryError);
            const persisted = await this.sendAwaitingRelayPersistence(kind, kind === "assistant.completed" && active.outboundText
                ? { ...payload, text: truncateUnicode(mergeVisibleText(active.outboundText, String(payload.text ?? "")), MAX_TEXT_LENGTH) }
                : payload, active.frame.conversationId);
            if (persisted) {
                // Only a real terminal receipt supersedes uncertain progress events.
                // Until then they retain their exact bytes in the reconnect outbox.
                active.telemetryController.abort();
                this.clearActivityTimer(active);
                this.clearWorkTimer(active);
                active.pendingWork.clear();
            }
            return persisted;
        })().catch(() => {
            this.log("warn", "terminal_delivery_failed");
            return false;
        });
        return active.terminalTask;
    }
    recoverInterruptedTurns() {
        this.recoveryTask = this.recoveryTask.catch(() => undefined).then(async () => {
            const interrupted = [...this.requireState().activeTurns];
            for (const turn of interrupted) {
                if (this.activeTurns.has(turn.turnId))
                    continue;
                if (this.lifecycle.signal.aborted)
                    return;
                if (turn.recoveryError !== undefined &&
                    turn.recoveryExpiresAt !== undefined &&
                    turn.recoveryExpiresAt <= Date.now()) {
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
                const persisted = await this.sendAwaitingRelayPersistence("turn.error", safeTurnErrorPayload({
                    turnId: turn.turnId,
                    ...recovery,
                }), turn.conversationId);
                if (!persisted)
                    return;
                await this.finishTurn(turn.turnId);
            }
        });
        return this.recoveryTask;
    }
    clearDeltaTimer(active) {
        if (active.deltaTimer)
            clearTimeout(active.deltaTimer);
        active.deltaTimer = undefined;
        active.pendingDelta = undefined;
    }
    supports(active, capability) {
        return active.frame.payload.capabilities?.includes(capability) === true;
    }
    clearActivityTimer(active) {
        if (active.activityTimer)
            clearTimeout(active.activityTimer);
        active.activityTimer = undefined;
        active.pendingActivityStatus = undefined;
    }
    async offerActivity(active, status) {
        if (!this.supports(active, "activity-v1") ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
            status === active.pendingActivityStatus ||
            (active.pendingActivityStatus === undefined && status === active.lastActivityStatus)) {
            return;
        }
        active.pendingActivityStatus = status;
        this.scheduleActivity(active);
    }
    scheduleActivity(active) {
        if (this.lifecycle.signal.aborted ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
            active.pendingActivityStatus === undefined ||
            active.activityTimer ||
            active.activityTask ||
            this.socket?.readyState !== WebSocket.OPEN) {
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
    flushActivity(active) {
        if (active.activityTask)
            return active.activityTask;
        const task = this.performActivityFlush(active);
        active.activityTask = task;
        this.activityTasks.add(task);
        const settled = () => {
            if (active.activityTask === task)
                active.activityTask = undefined;
            this.activityTasks.delete(task);
            if (active.pendingActivityStatus !== undefined)
                this.scheduleActivity(active);
        };
        void task.then(settled, settled);
        return task;
    }
    async performActivityFlush(active) {
        if (this.lifecycle.signal.aborted ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.activityCount >= MAX_ACTIVITY_FRAMES_PER_TURN ||
            this.socket?.readyState !== WebSocket.OPEN) {
            return;
        }
        const status = active.pendingActivityStatus;
        if (status === undefined)
            return;
        active.pendingActivityStatus = undefined;
        const revision = active.activityRevision + 1;
        const persisted = await this.sendAwaitingRelayPersistence(status === null ? "assistant.activity.clear" : "assistant.activity.upsert", status === null
            ? { turnId: active.frame.payload.turnId, revision }
            : { turnId: active.frame.payload.turnId, revision, status }, active.frame.conversationId, undefined, AbortSignal.any([active.controller.signal, active.telemetryController.signal]));
        if (persisted) {
            active.activityRevision = revision;
            active.activityCount += 1;
            active.lastActivityStatus = status;
            active.lastActivityFrameAt = Date.now();
        }
        else if (!active.terminal && !active.controller.signal.aborted) {
            active.pendingActivityStatus ??= status;
        }
    }
    flushActiveActivities() {
        for (const active of this.activeTurns.values()) {
            this.scheduleActivity(active);
        }
    }
    clearWorkTimer(active) {
        if (active.workTimer)
            clearTimeout(active.workTimer);
        active.workTimer = undefined;
    }
    offerWork(active, step) {
        if (!this.supports(active, "work-v1") ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.workCount >= MAX_WORK_FRAMES_PER_TURN) {
            return;
        }
        if (!active.workStepIds.has(step.stepId)) {
            if (active.workStepIds.size >= MAX_WORK_STEPS_PER_TURN)
                return;
            active.workStepIds.add(step.stepId);
        }
        const encoded = JSON.stringify(step);
        if (active.lastWork.get(step.stepId) === encoded)
            return;
        active.pendingWork.set(step.stepId, step);
        this.scheduleWork(active);
    }
    scheduleWork(active) {
        if (this.lifecycle.signal.aborted ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.pendingWork.size === 0 ||
            active.workCount >= MAX_WORK_FRAMES_PER_TURN ||
            active.workTimer ||
            active.workTask ||
            this.socket?.readyState !== WebSocket.OPEN) {
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
    flushWork(active, force = false) {
        if (active.workTask)
            return active.workTask;
        const task = this.performWorkFlush(active, force);
        active.workTask = task;
        this.workTasks.add(task);
        const settled = () => {
            if (active.workTask === task)
                active.workTask = undefined;
            this.workTasks.delete(task);
            if (!active.terminal && active.pendingWork.size > 0)
                this.scheduleWork(active);
        };
        void task.then(settled, settled);
        return task;
    }
    async performWorkFlush(active, force) {
        if (this.lifecycle.signal.aborted ||
            (!force && active.terminal) ||
            active.controller.signal.aborted ||
            active.pendingWork.size === 0 ||
            active.workCount >= MAX_WORK_FRAMES_PER_TURN ||
            this.socket?.readyState !== WebSocket.OPEN) {
            return;
        }
        const next = active.pendingWork.entries().next().value;
        if (!next)
            return;
        const [stepId, step] = next;
        active.pendingWork.delete(stepId);
        const revision = active.workRevision + 1;
        const persisted = await this.sendAwaitingRelayPersistence("assistant.work.upsert", { turnId: active.frame.payload.turnId, revision, ...step }, active.frame.conversationId, undefined, AbortSignal.any([active.controller.signal, active.telemetryController.signal]));
        if (persisted) {
            active.workRevision = revision;
            active.workCount += 1;
            active.lastWork.set(stepId, JSON.stringify(step));
            active.lastWorkFrameAt = Date.now();
        }
        else if (!active.terminal && !active.controller.signal.aborted) {
            active.pendingWork.set(stepId, step);
        }
    }
    async drainWork(active) {
        this.clearWorkTimer(active);
        let timer;
        const deadline = new Promise((resolve) => {
            timer = setTimeout(() => resolve(false), WORK_DRAIN_BUDGET_MS);
        });
        try {
            while (active.pendingWork.size > 0 &&
                active.workCount < MAX_WORK_FRAMES_PER_TURN &&
                this.socket?.readyState === WebSocket.OPEN &&
                !active.controller.signal.aborted) {
                const flushed = await Promise.race([
                    this.flushWork(active, true).then(() => true),
                    deadline,
                ]);
                if (!flushed) {
                    this.log("warn", "work_drain_receipt_timeout");
                    return;
                }
            }
        }
        finally {
            if (timer)
                clearTimeout(timer);
        }
    }
    flushActiveWork() {
        for (const active of this.activeTurns.values())
            this.scheduleWork(active);
    }
    async deliverAttachment(active, attachment) {
        if (!this.supports(active, "attachments-v1")) {
            throw new Error("attachment_delivery_failed");
        }
        if (active.attachmentCount >= MAX_ATTACHMENTS_PER_TURN ||
            active.attachmentBytes + attachment.buffer.byteLength > MAX_ATTACHMENT_BYTES_PER_TURN) {
            throw new Error("attachment_limit");
        }
        active.attachmentCount += 1;
        active.attachmentBytes += attachment.buffer.byteLength;
        const frame = active.frame;
        try {
            const uploaded = await this.deps.uploadAttachment({
                bridgeUrl: this.bridgeUrl,
                connectionId: this.connectionId,
                token: this.token,
                conversationId: frame.conversationId,
                turnId: frame.payload.turnId,
                attachment,
                signal: active.controller.signal,
            });
            const persisted = await this.sendAwaitingRelayPersistence("assistant.attachment", {
                turnId: frame.payload.turnId,
                attachmentId: uploaded.attachmentId,
                fileName: uploaded.fileName,
                mediaType: uploaded.mediaType,
                byteCount: uploaded.byteCount,
                sha256: uploaded.sha256,
                downloadPath: uploaded.downloadPath,
                expiresAt: uploaded.expiresAt,
            }, frame.conversationId, undefined, active.controller.signal);
            if (!persisted)
                throw new Error("attachment_delivery_failed");
            return uploaded;
        }
        catch (error) {
            active.attachmentCount -= 1;
            active.attachmentBytes -= attachment.buffer.byteLength;
            const reason = error instanceof Error ? error.message : "attachment_delivery_failed";
            const diagnostic = error instanceof OpenClamAttachmentUploadError
                ? ` diagnostic=${error.diagnostic}`
                : "";
            this.log("warn", `attachment_delivery_failed reason=${reason}${diagnostic}`);
            throw error;
        }
    }
    async offerDelta(active, text) {
        if (!text || active.terminal || active.controller.signal.aborted)
            return;
        active.replyText = text;
        text = mergeVisibleText(active.outboundText, text);
        if (!text ||
            text === active.pendingDelta ||
            text === active.lastDeltaText ||
            active.terminal ||
            active.controller.signal.aborted) {
            return;
        }
        active.pendingDelta = text;
        await this.scheduleDelta(active);
    }
    async scheduleDelta(active) {
        if (this.lifecycle.signal.aborted ||
            active.deltaCount >= MAX_DELTA_FRAMES_PER_TURN ||
            this.socket?.readyState !== WebSocket.OPEN ||
            active.deltaTimer ||
            active.deltaFlushTask) {
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
    flushDelta(active) {
        if (active.deltaFlushTask)
            return active.deltaFlushTask;
        const task = this.performDeltaFlush(active);
        active.deltaFlushTask = task;
        this.deltaTasks.add(task);
        const settled = () => {
            if (active.deltaFlushTask === task)
                active.deltaFlushTask = undefined;
            this.deltaTasks.delete(task);
            if (active.pendingDelta === active.lastDeltaText)
                active.pendingDelta = undefined;
            if (active.pendingDelta) {
                this.detach(this.scheduleDelta(active), "delta_flush_failed");
            }
        };
        void task.then(settled, settled);
        return task;
    }
    async performDeltaFlush(active) {
        await this.sequenceText(active, () => this.transmitDelta(active));
    }
    async transmitDelta(active) {
        if (this.lifecycle.signal.aborted ||
            active.terminal ||
            active.controller.signal.aborted ||
            active.deltaCount >= MAX_DELTA_FRAMES_PER_TURN ||
            this.socket?.readyState !== WebSocket.OPEN) {
            return;
        }
        if (!active.pendingDelta)
            return;
        const text = mergeVisibleText(active.outboundText, active.replyText);
        active.pendingDelta = undefined;
        if (!text || text === active.lastDeltaText)
            return;
        const revision = active.revision + 1;
        let delivered = false;
        try {
            delivered = await this.send("assistant.delta", { turnId: active.frame.payload.turnId, revision, text }, active.frame.conversationId, undefined, false);
        }
        catch (error) {
            active.pendingDelta ??= text;
            throw error;
        }
        if (delivered) {
            active.revision = revision;
            active.deltaCount += 1;
            active.lastDeltaText = text;
            active.lastDeltaAt = Date.now();
        }
        else {
            active.pendingDelta ??= text;
        }
    }
    async flushActiveDeltas() {
        for (const active of this.activeTurns.values()) {
            await this.flushDelta(active);
        }
    }
    async sendAck(receivedSeq) {
        await this.send("ack", { ackSeq: receivedSeq }, undefined, receivedSeq);
    }
    async sendAwaitingRelayPersistence(kind, payload, conversationId, replyTo, signal, onReserved) {
        if (this.lifecycle.signal.aborted || signal?.aborted)
            return false;
        let frame;
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
        if (this.lifecycle.signal.aborted || signal?.aborted)
            return false;
        const created = frame;
        const prepared = kind === "assistant.completed"
            ? encodeFrameWithTextBudget(created, "text")
            : kind === "turn.error"
                ? encodeFrameWithTextBudget(created, "message")
                : { frame: created, encoded: encodeFrame(created) };
        const reserved = prepared.frame;
        const encoded = prepared.encoded;
        onReserved?.(reserved);
        return new Promise((resolve) => {
            let settled = false;
            let onAbort = () => undefined;
            const finish = (persisted) => {
                if (settled)
                    return;
                settled = true;
                if (pending.receiptTimer)
                    clearTimeout(pending.receiptTimer);
                pending.receiptTimer = undefined;
                signal?.removeEventListener("abort", onAbort);
                resolve(persisted);
            };
            const pending = {
                frame: reserved,
                encoded,
                resolve: finish,
                transmissions: 0,
            };
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
            this.transmitRelayFrame(pending);
        });
    }
    async send(kind, payload, conversationId, replyTo, queueWhenOffline = true) {
        const socketBeforeReservation = this.socket;
        if (!queueWhenOffline && socketBeforeReservation?.readyState !== WebSocket.OPEN)
            return false;
        let frame;
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
        const created = frame;
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
            }
            catch {
                socket.close(1011, "send_failed");
                if (!queueWhenOffline)
                    return false;
            }
        }
        if (!queueWhenOffline)
            return false;
        this.enqueueFrame({ encoded, kind, seq: outbound.seq });
        return false;
    }
    transmit(socket, encoded) {
        if (socket.readyState !== WebSocket.OPEN)
            return false;
        try {
            socket.send(encoded);
            this.updateAllStatuses({ lastOutboundAt: Date.now() });
            return true;
        }
        catch {
            socket.close(1011, "send_failed");
            return false;
        }
    }
    transmitRelayFrame(pending) {
        const socket = this.socket;
        if (this.lifecycle.signal.aborted ||
            this.relayOutbox.get(pending.frame.messageId) !== pending ||
            socket?.readyState !== WebSocket.OPEN)
            return false;
        if (pending.receiptTimer)
            clearTimeout(pending.receiptTimer);
        pending.receiptTimer = undefined;
        if (pending.transmittedSocket !== socket) {
            pending.transmittedSocket = socket;
            pending.transmissions = 0;
        }
        if (!this.transmit(socket, pending.encoded))
            return false;
        pending.transmissions += 1;
        pending.receiptTimer = setTimeout(() => {
            pending.receiptTimer = undefined;
            if (this.lifecycle.signal.aborted ||
                this.relayOutbox.get(pending.frame.messageId) !== pending ||
                this.socket !== socket ||
                socket.readyState !== WebSocket.OPEN)
                return;
            if (pending.transmissions >= MAX_RELAY_TRANSMISSIONS_PER_SOCKET) {
                this.log("warn", `relay_receipt_timeout kind=${pending.frame.kind}`);
                // A graceful close can itself wait for the unresponsive peer. Force
                // reconnect without retiring the pairing or resolving a false success.
                // flushPendingTransmissions replays the original events in seq order.
                socket.terminate();
                return;
            }
            this.transmitRelayFrame(pending);
        }, RELAY_RECEIPT_INTERVAL_MS);
        return true;
    }
    enqueueFrame(frame) {
        const droppable = (candidate) => candidate.kind === "heartbeat" || candidate.kind === "assistant.delta" || candidate.kind === "ack";
        if (this.outboundQueue.length >= MAX_OUTBOUND_QUEUE) {
            const index = this.outboundQueue.findIndex(droppable);
            if (index >= 0)
                this.outboundQueue.splice(index, 1);
            else {
                this.log("warn", "outbound_queue_full");
                return;
            }
        }
        this.outboundQueue.push(frame);
    }
    flushPendingTransmissions() {
        const socket = this.socket;
        if (!socket || socket.readyState !== WebSocket.OPEN)
            return;
        const pending = [
            ...this.outboundQueue.map((frame) => ({ type: "queued", frame })),
            ...[...this.relayOutbox.values()].map((frame) => ({ type: "relay", frame })),
        ].sort((left, right) => {
            const leftSeq = left.type === "queued" ? left.frame.seq : left.frame.frame.seq;
            const rightSeq = right.type === "queued" ? right.frame.seq : right.frame.frame.seq;
            return leftSeq - rightSeq;
        });
        for (const item of pending) {
            if (socket.readyState !== WebSocket.OPEN)
                break;
            const transmitted = item.type === "relay"
                ? this.transmitRelayFrame(item.frame)
                : this.transmit(socket, item.frame.encoded);
            if (!transmitted)
                break;
            if (item.type === "queued") {
                const index = this.outboundQueue.indexOf(item.frame);
                if (index >= 0)
                    this.outboundQueue.splice(index, 1);
            }
        }
    }
    mutateState(mutator) {
        const task = this.stateTask.then(async () => {
            const state = this.requireState();
            mutator(state);
            await this.deps.writeState(this.stateFile, state);
        });
        this.stateTask = task.catch(() => undefined);
        return task;
    }
    requireState() {
        if (!this.state)
            throw new Error("adapter_state_unavailable");
        return this.state;
    }
    updateAllStatuses(patch) {
        for (const ctx of this.accounts.values())
            this.setAccountStatus(ctx, patch);
    }
    setAccountStatus(ctx, patch) {
        ctx.setStatus({ ...ctx.getStatus(), accountId: ctx.account.accountId, ...patch });
    }
    detach(task, event) {
        void task.catch(() => this.log("warn", event));
    }
    retireConnection(event) {
        this.log("warn", event);
        this.updateAllStatuses({ connected: false, running: false, configured: false });
        for (const active of this.activeTurns.values())
            active.controller.abort();
        if (!this.lifecycle.signal.aborted)
            this.lifecycle.abort();
    }
    log(level, event) {
        const sink = this.accounts.values().next().value?.log;
        sink?.[level](`[openclam] ${event} connection=${this.connectionId}`);
    }
}
