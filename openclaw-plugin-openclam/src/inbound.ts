import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import { resolveInboundRouteEnvelopeBuilderWithRuntime } from "openclaw/plugin-sdk/inbound-envelope";
import { MAX_TEXT_LENGTH, truncateUnicode } from "./protocol.js";
import {
  loadOpenClamMedia,
  MAX_ATTACHMENT_BYTES_PER_TURN,
  MAX_ATTACHMENTS_PER_TURN,
  uniqueMediaSources,
} from "./media.js";
import { getOpenClamRuntime } from "./runtime.js";
import type {
  ActivityStatus,
  OpenClamAttachmentUpload,
  ResolvedOpenClamAccount,
  TurnSubmitFrame,
} from "./types.js";

export type OpenClamReplySink = {
  partial: (text: string) => Promise<void>;
  activity: (status: ActivityStatus) => Promise<void>;
  clearActivity: () => Promise<void>;
  attachment: (attachment: OpenClamAttachmentUpload) => Promise<void>;
  completed: (text: string) => Promise<void>;
};

const HIDDEN_REPLY_KEYS = [
  "isReasoning",
  "isCommentary",
  "isStatusNotice",
  "isCompactionNotice",
  "isFallbackNotice",
] as const;

function toolActivity(name?: string): ActivityStatus {
  const normalized = name?.toLowerCase() ?? "";
  if (/(search|browser|web|query)/u.test(normalized)) return "searching";
  if (/(read|find|list|view|inspect|open)/u.test(normalized)) return "reading";
  if (/(edit|write|patch|replace|update)/u.test(normalized)) return "editing";
  if (/(image|video|audio|media|render|selfie|photo)/u.test(normalized)) {
    return "creating_media";
  }
  if (/(file|document|pdf|ppt|slide|sheet|archive|export)/u.test(normalized)) {
    return "preparing_files";
  }
  return "running_action";
}

function mergeObservedText(current: string, incoming: string, delta?: string): string {
  if (!incoming) return current;
  if (!current || incoming.startsWith(current) || incoming.length >= current.length) {
    return incoming;
  }
  if (delta && !current.endsWith(delta)) return `${current}${delta}`;
  return current;
}

function mergeFinalText(current: string, incoming: string): string {
  const trimmed = incoming.trim();
  if (!trimmed) return current;
  if (!current) return trimmed;
  if (trimmed === current || trimmed.startsWith(current)) return trimmed;
  if (current.endsWith(trimmed)) return current;
  return `${current}\n\n${trimmed}`;
}

function replaceExactMediaReferences(
  text: string,
  replacements: ReadonlyMap<string, string>,
): string {
  let safe = text;
  for (const [source, replacement] of replacements) {
    if (source) safe = safe.split(source).join(replacement);
  }
  return safe;
}

function containsPrivatePathReference(text: string): boolean {
  return /(?:file:\/\/|(?:^|[^A-Za-z0-9_])[A-Za-z]:[\\/]|\\\\[^\s\\]+\\[^\s\\]+|(?:^|[^A-Za-z0-9_./-])\/(?!\/)[^\s)\]}>]+)/u
    .test(text);
}

function redactPrivatePathReferences(text: string): string {
  return text
    .replace(
      /file:\/\/[^\s)\]}>]+/gu,
      "attached file",
    )
    .replace(
      /(^|[^A-Za-z0-9_])[A-Za-z]:[\\/][^\s)\]}>]+/gu,
      (_match, prefix: string) => `${prefix}attached file`,
    )
    .replace(/\\\\[^\s\\]+\\[^\s)\]}>]+/gu, "attached file")
    .replace(
      /(^|[^A-Za-z0-9_./-])\/(?!\/)[^\s)\]}>]+/gu,
      (_match, prefix: string) => `${prefix}attached file`,
    );
}

function rememberMediaReplacement(
  replacements: Map<string, string>,
  source: string,
  replacement: string,
): void {
  replacements.set(source, replacement);
  try {
    const parsed = new URL(source);
    if (parsed.protocol === "file:") {
      replacements.set(decodeURIComponent(parsed.pathname), replacement);
    }
  } catch {
    // Non-URL local media references are already stored exactly above.
  }
}

export async function dispatchOpenClamTurn(params: {
  ctx: ChannelGatewayContext<ResolvedOpenClamAccount>;
  frame: TurnSubmitFrame;
  signal: AbortSignal;
  sink: OpenClamReplySink;
  loadMedia?: typeof loadOpenClamMedia;
}): Promise<void> {
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
    sessionStore: (params.ctx.cfg as OpenClawConfig).session?.store,
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
  let deliveryFailure: "sensitive_media_unsupported" | "upstream_reply_error" | undefined;
  const stagedAttachments: OpenClamAttachmentUpload[] = [];
  const deliveredSources = new Set<string>();
  const mediaReferenceReplacements = new Map<string, string>();
  const supportsAttachments = frame.payload.capabilities?.includes("attachments-v1") === true;
  const loadMedia = params.loadMedia ?? loadOpenClamMedia;
  await channelRuntime.inbound.dispatchReply({
    cfg: params.ctx.cfg,
    channel: "openclam",
    accountId: account.accountId,
    agentId: route.agentId,
    routeSessionKey: route.sessionKey,
    storePath,
    ctxPayload,
    recordInboundSession: channelRuntime.session.recordInboundSession,
    dispatchReplyWithBufferedBlockDispatcher:
      channelRuntime.reply.dispatchReplyWithBufferedBlockDispatcher,
    delivery: {
      deliver: async (payload) => {
        if (deliveryFailure !== undefined) throw new Error(deliveryFailure);
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
        if (
          HIDDEN_REPLY_KEYS.some((key) => payload?.[key] === true) ||
          payload?.ttsSupplement !== undefined
        ) {
          return;
        }
        const sources = uniqueMediaSources(payload?.mediaUrl, payload?.mediaUrls)
          .filter((source) => !deliveredSources.has(source));
        const delivered = payload?.text?.trim() ?? "";
        if (delivered) {
          finalObserved = truncateUnicode(
            mergeFinalText(finalObserved, delivered),
            MAX_TEXT_LENGTH,
          );
        }
        if (sources.length === 0) return;
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
      onReplyStart: async () => params.sink.activity("thinking"),
      onPlanUpdate: async () => params.sink.activity("planning"),
      onToolStart: async (payload) => params.sink.activity(toolActivity(payload.name)),
      onItemEvent: async (payload) => {
        const status = `${payload.status ?? ""} ${payload.phase ?? ""}`.toLowerCase();
        await params.sink.activity(
          status.includes("approval") || status.includes("waiting")
            ? "waiting_for_approval"
            : toolActivity(payload.name ?? payload.kind),
        );
      },
      onApprovalEvent: async () => params.sink.activity("waiting_for_approval"),
      onCommandOutput: async () => params.sink.activity("running_action"),
      onPatchSummary: async () => params.sink.activity("editing"),
      onCompactionStart: async () => params.sink.activity("thinking"),
      onCompactionEnd: async () => params.sink.activity("finalizing"),
      onAssistantMessageStart: async () => params.sink.activity("finalizing"),
      onPartialReply: async (payload) => {
        const partial = payload as typeof payload & Record<string, unknown>;
        if (
          deliveryFailure !== undefined ||
          partial.isError === true ||
          partial.sensitiveMedia === true ||
          HIDDEN_REPLY_KEYS.some((key) => partial[key] === true) ||
          partial.ttsSupplement !== undefined
        ) {
          return;
        }
        for (const source of uniqueMediaSources(undefined, payload.mediaUrls)) {
          rememberMediaReplacement(mediaReferenceReplacements, source, "attached file");
        }
        const next = replaceExactMediaReferences(
          mergeObservedText(observed, payload.text ?? "", payload.delta),
          mediaReferenceReplacements,
        );
        if (next === observed) return;
        observed = truncateUnicode(next, MAX_TEXT_LENGTH);
        if (containsPrivatePathReference(observed)) return;
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

  if (deliveryFailure !== undefined) throw new Error(deliveryFailure);

  for (const attachment of stagedAttachments) {
    await params.sink.activity("preparing_files");
    await params.sink.attachment(attachment);
  }

  let completedBase = redactPrivatePathReferences(
    replaceExactMediaReferences(finalObserved || observed, mediaReferenceReplacements),
  );
  if (legacyMediaOmitted) {
    completedBase = mergeFinalText(completedBase, "Update OpenClam to receive this file.");
  }
  const fallback = attachmentCount > 0
    ? `Created ${attachmentCount} ${attachmentCount === 1 ? "file" : "files"}.`
    : "";
  const completed = truncateUnicode((completedBase || fallback).trim(), MAX_TEXT_LENGTH);
  if (!completed) throw new Error("empty_reply");
  await params.sink.completed(completed);
}
