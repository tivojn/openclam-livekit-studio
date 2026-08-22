import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import { resolveInboundRouteEnvelopeBuilderWithRuntime } from "openclaw/plugin-sdk/inbound-envelope";
import { MAX_TEXT_LENGTH, truncateUnicode } from "./protocol.js";
import { getOpenClamRuntime } from "./runtime.js";
import type { ResolvedOpenClamAccount, TurnSubmitFrame } from "./types.js";

export type OpenClamReplySink = {
  partial: (text: string) => Promise<void>;
  completed: (text: string) => Promise<void>;
};

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

export async function dispatchOpenClamTurn(params: {
  ctx: ChannelGatewayContext<ResolvedOpenClamAccount>;
  frame: TurnSubmitFrame;
  signal: AbortSignal;
  sink: OpenClamReplySink;
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
        const delivered = payload?.text?.trim() ?? "";
        if (delivered) {
          finalObserved = truncateUnicode(
            mergeFinalText(finalObserved, delivered),
            MAX_TEXT_LENGTH,
          );
        }
      },
      onError: () => {
        // The caller emits one safe turn.error; provider errors and text stay out of logs.
      },
    },
    replyOptions: {
      abortSignal: params.signal,
      onPartialReply: async (payload) => {
        const next = mergeObservedText(observed, payload.text ?? "", payload.delta);
        if (next === observed) return;
        observed = truncateUnicode(next, MAX_TEXT_LENGTH);
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

  const completed = truncateUnicode((finalObserved || observed).trim(), MAX_TEXT_LENGTH);
  if (!completed) throw new Error("empty_reply");
  await params.sink.completed(completed);
}
