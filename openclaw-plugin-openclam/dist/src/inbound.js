import { resolveInboundRouteEnvelopeBuilderWithRuntime } from "openclaw/plugin-sdk/inbound-envelope";
import { MAX_TEXT_LENGTH, truncateUnicode } from "./protocol.js";
import { loadOpenClamMedia, MAX_ATTACHMENT_BYTES_PER_TURN, MAX_ATTACHMENTS_PER_TURN, uniqueMediaSources, } from "./media.js";
import { getOpenClamRuntime } from "./runtime.js";
import { sanitizeWorkStep, sanitizeWorkText, workState, workStepId } from "./work-sanitizer.js";
async function emitWork(sink, step) {
    if (!sink.work)
        return;
    const safe = sanitizeWorkStep(step);
    if (safe)
        await sink.work(safe);
}
function safeToolTitle(name) {
    const safe = sanitizeWorkText(name, 80);
    return safe ? `Using ${safe}` : "Using a tool";
}
const HIDDEN_REPLY_KEYS = [
    "isReasoning",
    "isCommentary",
    "isStatusNotice",
    "isCompactionNotice",
    "isFallbackNotice",
];
function toolActivity(name) {
    const normalized = name?.toLowerCase() ?? "";
    if (/(search|browser|web|query)/u.test(normalized))
        return "searching";
    if (/(read|find|list|view|inspect|open)/u.test(normalized))
        return "reading";
    if (/(edit|write|patch|replace|update)/u.test(normalized))
        return "editing";
    if (/(image|video|audio|media|render|selfie|photo)/u.test(normalized)) {
        return "creating_media";
    }
    if (/(file|document|pdf|ppt|slide|sheet|archive|export)/u.test(normalized)) {
        return "preparing_files";
    }
    return "running_action";
}
function mergeObservedText(current, incoming, delta) {
    if (!incoming)
        return current;
    if (!current || incoming.startsWith(current) || incoming.length >= current.length) {
        return incoming;
    }
    if (delta && !current.endsWith(delta))
        return `${current}${delta}`;
    return current;
}
function mergeFinalText(current, incoming) {
    const trimmed = incoming.trim();
    if (!trimmed)
        return current;
    if (!current)
        return trimmed;
    if (trimmed === current || trimmed.startsWith(current))
        return trimmed;
    if (current.endsWith(trimmed))
        return current;
    return `${current}\n\n${trimmed}`;
}
function replaceExactMediaReferences(text, replacements) {
    let safe = text;
    for (const [source, replacement] of replacements) {
        if (source)
            safe = safe.split(source).join(replacement);
    }
    return safe;
}
function containsPrivatePathReference(text) {
    return /(?:file:\/\/|(?:^|[^A-Za-z0-9_])[A-Za-z]:[\\/]|\\\\[^\s\\]+\\[^\s\\]+|(?:^|[^A-Za-z0-9_./-])\/(?!\/)[^\s)\]}>]+)/u
        .test(text);
}
function redactPrivatePathReferences(text) {
    return text
        .replace(/file:\/\/[^\s)\]}>]+/gu, "attached file")
        .replace(/(^|[^A-Za-z0-9_])[A-Za-z]:[\\/][^\s)\]}>]+/gu, (_match, prefix) => `${prefix}attached file`)
        .replace(/\\\\[^\s\\]+\\[^\s)\]}>]+/gu, "attached file")
        .replace(/(^|[^A-Za-z0-9_./-])\/(?!\/)[^\s)\]}>]+/gu, (_match, prefix) => `${prefix}attached file`);
}
function rememberMediaReplacement(replacements, source, replacement) {
    replacements.set(source, replacement);
    try {
        const parsed = new URL(source);
        if (parsed.protocol === "file:") {
            replacements.set(decodeURIComponent(parsed.pathname), replacement);
        }
    }
    catch {
        // Non-URL local media references are already stored exactly above.
    }
}
export async function dispatchOpenClamTurn(params) {
    const channelRuntime = getOpenClamRuntime().channel;
    const account = params.ctx.account;
    const frame = params.frame;
    const conversationId = frame.conversationId;
    const text = frame.payload.text;
    const peerId = `${account.connectionId}:${conversationId}`;
    const { route, buildEnvelope } = resolveInboundRouteEnvelopeBuilderWithRuntime({
        cfg: params.ctx.cfg,
        channel: "openclam",
        accountId: account.accountId,
        peer: { kind: "direct", id: peerId },
        runtime: channelRuntime,
        sessionStore: params.ctx.cfg.session?.store,
    });
    if (route.agentId !== account.agentId) {
        throw new Error("agent_mapping_changed");
    }
    const { storePath, body } = buildEnvelope({
        channel: "OpenClam",
        from: account.displayName,
        timestamp: frame.sentAt,
        body: text,
    });
    const target = `openclam:${peerId}`;
    const ctxPayload = channelRuntime.reply.finalizeInboundContext({
        Body: body,
        BodyForAgent: text,
        RawBody: text,
        CommandBody: text,
        From: target,
        To: target,
        SessionKey: route.sessionKey,
        AccountId: route.accountId ?? account.accountId,
        ChatType: "direct",
        ConversationLabel: `OpenClam · ${account.displayName}`,
        SenderName: "OpenClam user",
        SenderId: account.connectionId,
        Provider: "openclam",
        Surface: "openclam",
        MessageSid: frame.payload.turnId,
        MessageSidFull: frame.payload.turnId,
        Timestamp: frame.sentAt,
        OriginatingChannel: "openclam",
        OriginatingTo: target,
        CommandAuthorized: false,
    });
    let observed = "";
    let finalObserved = "";
    let attachmentCount = 0;
    let attachmentBytes = 0;
    let legacyMediaOmitted = false;
    let deliveryFailure;
    const stagedAttachments = [];
    const deliveredSources = new Set();
    const mediaReferenceReplacements = new Map();
    const supportsAttachments = frame.payload.capabilities?.includes("attachments-v1") === true;
    const loadMedia = params.loadMedia ?? loadOpenClamMedia;
    await params.sink.activity("thinking");
    await emitWork(params.sink, {
        stepId: "reasoning",
        category: "reasoning_summary",
        state: "running",
        title: "Understanding the request",
    });
    await channelRuntime.inbound.dispatchReply({
        cfg: params.ctx.cfg,
        channel: "openclam",
        accountId: account.accountId,
        agentId: route.agentId,
        routeSessionKey: route.sessionKey,
        storePath,
        ctxPayload,
        recordInboundSession: channelRuntime.session.recordInboundSession,
        dispatchReplyWithBufferedBlockDispatcher: channelRuntime.reply.dispatchReplyWithBufferedBlockDispatcher,
        delivery: {
            deliver: async (payload) => {
                if (deliveryFailure !== undefined)
                    throw new Error(deliveryFailure);
                if (payload?.isError === true) {
                    deliveryFailure = "upstream_reply_error";
                    stagedAttachments.length = 0;
                    throw new Error(deliveryFailure);
                }
                if (payload?.sensitiveMedia === true) {
                    deliveryFailure = "sensitive_media_unsupported";
                    stagedAttachments.length = 0;
                    throw new Error(deliveryFailure);
                }
                if (HIDDEN_REPLY_KEYS.some((key) => payload?.[key] === true) ||
                    payload?.ttsSupplement !== undefined) {
                    return;
                }
                const sources = uniqueMediaSources(payload?.mediaUrl, payload?.mediaUrls)
                    .filter((source) => !deliveredSources.has(source));
                const delivered = payload?.text?.trim() ?? "";
                if (delivered) {
                    finalObserved = truncateUnicode(mergeFinalText(finalObserved, delivered), MAX_TEXT_LENGTH);
                }
                if (sources.length === 0)
                    return;
                if (!supportsAttachments) {
                    legacyMediaOmitted = true;
                    for (const source of sources) {
                        deliveredSources.add(source);
                        rememberMediaReplacement(mediaReferenceReplacements, source, "attached file");
                    }
                    return;
                }
                for (const source of sources) {
                    if (attachmentCount >= MAX_ATTACHMENTS_PER_TURN) {
                        throw new Error("attachment_limit");
                    }
                    await params.sink.activity("preparing_files");
                    const attachment = await loadMedia({
                        cfg: params.ctx.cfg,
                        agentId: route.agentId,
                        source,
                    });
                    if (attachmentBytes + attachment.buffer.byteLength > MAX_ATTACHMENT_BYTES_PER_TURN) {
                        throw new Error("attachment_limit");
                    }
                    stagedAttachments.push(attachment);
                    deliveredSources.add(source);
                    rememberMediaReplacement(mediaReferenceReplacements, source, attachment.fileName);
                    attachmentCount += 1;
                    attachmentBytes += attachment.buffer.byteLength;
                }
            },
            onError: () => {
                // The caller emits one safe turn.error; provider errors and text stay out of logs.
            },
        },
        replyOptions: {
            abortSignal: params.signal,
            suppressDefaultToolProgressMessages: true,
            allowToolLifecycleWhenProgressHidden: true,
            forceToolResultProgress: true,
            onReplyStart: async () => {
                await params.sink.activity("thinking");
                await emitWork(params.sink, {
                    stepId: "reasoning",
                    category: "reasoning_summary",
                    state: "running",
                    title: "Understanding the request",
                });
            },
            onPlanUpdate: async (payload) => {
                await params.sink.activity("planning");
                const steps = Array.isArray(payload.steps)
                    ? payload.steps.map((step) => sanitizeWorkText(step, 180)).filter(Boolean).join(" · ")
                    : undefined;
                await emitWork(params.sink, {
                    stepId: "plan",
                    category: "plan",
                    state: workState(payload.phase),
                    title: sanitizeWorkText(payload.title, 120) ?? "Planning the work",
                    detail: steps,
                });
            },
            onToolStart: async (payload) => {
                await params.sink.activity(toolActivity(payload.name));
                await emitWork(params.sink, {
                    stepId: workStepId("tool", payload.toolCallId, payload.itemId, payload.name),
                    category: "tool",
                    state: workState(payload.phase),
                    title: safeToolTitle(payload.name),
                    tool: sanitizeWorkText(payload.name, 80),
                    detail: "OpenClaw started this tool. Arguments stay private.",
                });
            },
            onItemEvent: async (payload) => {
                const status = `${payload.status ?? ""} ${payload.phase ?? ""}`.toLowerCase();
                await params.sink.activity(status.includes("approval") || status.includes("waiting")
                    ? "waiting_for_approval"
                    : toolActivity(payload.name ?? payload.kind));
                await emitWork(params.sink, {
                    stepId: workStepId("tool", payload.toolCallId, payload.itemId, payload.name, payload.kind),
                    category: status.includes("approval") ? "approval" : "tool",
                    state: workState(payload.status, payload.phase),
                    title: sanitizeWorkText(payload.title, 120)
                        ?? safeToolTitle(payload.name ?? payload.kind),
                    tool: sanitizeWorkText(payload.name ?? payload.kind, 80),
                    detail: sanitizeWorkText(payload.summary ?? payload.progressText, 1_000),
                });
            },
            onApprovalEvent: async (payload) => {
                await params.sink.activity("waiting_for_approval");
                await emitWork(params.sink, {
                    stepId: workStepId("approval", payload.approvalId, payload.toolCallId, payload.itemId),
                    category: "approval",
                    state: workState(payload.status ?? "waiting", payload.phase),
                    title: sanitizeWorkText(payload.title, 120) ?? "Approval needed on the OpenClaw host",
                    detail: sanitizeWorkText(payload.reason ?? payload.message, 1_000),
                });
            },
            onCommandOutput: async (payload) => {
                await params.sink.activity("running_action");
                await emitWork(params.sink, {
                    stepId: workStepId("command", payload.toolCallId, payload.itemId, payload.name),
                    category: "command",
                    state: workState(payload.status, payload.phase),
                    title: sanitizeWorkText(payload.title, 120) ?? "Running a command",
                    tool: sanitizeWorkText(payload.name, 80),
                    detail: "Command output stays private on the OpenClaw host.",
                });
            },
            onPatchSummary: async (payload) => {
                await params.sink.activity("editing");
                const counts = [
                    Number.isFinite(payload.added) ? `${payload.added} added` : "",
                    Number.isFinite(payload.modified) ? `${payload.modified} modified` : "",
                    Number.isFinite(payload.deleted) ? `${payload.deleted} deleted` : "",
                ].filter(Boolean).join(" · ");
                await emitWork(params.sink, {
                    stepId: workStepId("patch", payload.toolCallId, payload.itemId, payload.name),
                    category: "file",
                    state: workState(payload.phase ?? "completed"),
                    title: sanitizeWorkText(payload.title, 120) ?? "Updated files",
                    detail: sanitizeWorkText(payload.summary, 1_000) ?? counts,
                    tool: sanitizeWorkText(payload.name, 80),
                });
            },
            onCompactionStart: async () => {
                await params.sink.activity("thinking");
                await emitWork(params.sink, {
                    stepId: "context",
                    category: "status",
                    state: "running",
                    title: "Organizing the session context",
                });
            },
            onCompactionEnd: async () => {
                await params.sink.activity("finalizing");
                await emitWork(params.sink, {
                    stepId: "context",
                    category: "status",
                    state: "completed",
                    title: "Session context organized",
                });
            },
            onAssistantMessageStart: async () => {
                await params.sink.activity("finalizing");
                await emitWork(params.sink, {
                    stepId: "response",
                    category: "status",
                    state: "running",
                    title: "Preparing the response",
                });
            },
            onPartialReply: async (payload) => {
                const partial = payload;
                if (deliveryFailure !== undefined ||
                    partial.isError === true ||
                    partial.sensitiveMedia === true ||
                    HIDDEN_REPLY_KEYS.some((key) => partial[key] === true) ||
                    partial.ttsSupplement !== undefined) {
                    return;
                }
                for (const source of uniqueMediaSources(undefined, payload.mediaUrls)) {
                    rememberMediaReplacement(mediaReferenceReplacements, source, "attached file");
                }
                const next = replaceExactMediaReferences(mergeObservedText(observed, payload.text ?? "", payload.delta), mediaReferenceReplacements);
                if (next === observed)
                    return;
                observed = truncateUnicode(next, MAX_TEXT_LENGTH);
                if (containsPrivatePathReference(observed))
                    return;
                await params.sink.clearActivity();
                await params.sink.partial(observed);
            },
        },
        replyPipeline: {},
        record: {
            onRecordError: (error) => {
                throw error instanceof Error ? error : new Error("session_record_failed");
            },
        },
    });
    if (deliveryFailure !== undefined)
        throw new Error(deliveryFailure);
    await emitWork(params.sink, {
        stepId: "reasoning",
        category: "reasoning_summary",
        state: "completed",
        title: "Understanding the request",
    });
    await params.sink.activity("finalizing");
    await emitWork(params.sink, {
        stepId: "response",
        category: "status",
        state: "completed",
        title: "Preparing the response",
    });
    for (const attachment of stagedAttachments) {
        await params.sink.activity("preparing_files");
        await params.sink.attachment(attachment);
    }
    let completedBase = redactPrivatePathReferences(replaceExactMediaReferences(finalObserved || observed, mediaReferenceReplacements));
    if (legacyMediaOmitted) {
        completedBase = mergeFinalText(completedBase, "Update OpenClam to receive this file.");
    }
    const fallback = attachmentCount > 0
        ? `Created ${attachmentCount} ${attachmentCount === 1 ? "file" : "files"}.`
        : "";
    const completed = truncateUnicode((completedBase || fallback).trim(), MAX_TEXT_LENGTH);
    if (!completed)
        throw new Error("empty_reply");
    await params.sink.completed(completed);
}
