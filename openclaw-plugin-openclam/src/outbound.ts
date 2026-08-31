import type { ChannelOutboundAdapter } from "openclaw/plugin-sdk/channel-runtime";
import { resolveOpenClamAccount } from "./config.js";
import { findOpenClamClient } from "./gateway.js";
import { loadOpenClamMedia } from "./media.js";
import { parseOpenClamTarget } from "./target.js";

function resolveTarget(params: {
  cfg?: Parameters<NonNullable<ChannelOutboundAdapter["resolveTarget"]>>[0]["cfg"];
  to?: string;
  accountId?: string | null;
}): { ok: true; to: string } | { ok: false; error: Error } {
  const target = parseOpenClamTarget(params.to ?? "");
  if (!target) return { ok: false, error: new Error("invalid_openclam_target") };
  if (params.cfg) {
    const account = resolveOpenClamAccount(params.cfg, params.accountId);
    if (
      !account.enabled ||
      !account.configured ||
      account.connectionId.toLowerCase() !== target.connectionId
    ) {
      return { ok: false, error: new Error("openclam_target_not_paired") };
    }
  }
  return { ok: true, to: target.canonical };
}

export const openClamOutbound: ChannelOutboundAdapter = {
  deliveryMode: "direct",
  resolveTarget,
  sendText: async (ctx) => {
    const target = parseOpenClamTarget(ctx.to);
    if (!target) throw new Error("invalid_openclam_target");
    const account = resolveOpenClamAccount(ctx.cfg, ctx.accountId);
    if (
      !account.enabled ||
      !account.configured ||
      account.connectionId.toLowerCase() !== target.connectionId
    ) {
      throw new Error("openclam_target_not_paired");
    }
    // This direct channel has one reply per active conversation, not arbitrary
    // remote threads. Media must still use the host-approved media loader below.
    if (ctx.threadId != null && String(ctx.threadId).trim()) {
      throw new Error("openclam_threads_unsupported");
    }
    if (ctx.mediaUrl?.trim()) throw new Error("openclam_media_requires_sender");
    const client = findOpenClamClient(target.connectionId);
    if (!client) throw new Error("openclam_connection_inactive");
    const delivered = await client.deliverTextToActiveConversation({
      accountId: account.accountId,
      conversationId: target.conversationId,
      text: ctx.text,
      replyToId: ctx.replyToId,
      deliveryId: ctx.deliveryQueueId,
      onPlatformSendDispatch: ctx.onPlatformSendDispatch,
    });
    return { channel: "openclam", ...delivered };
  },
  sendMedia: async (ctx) => {
    const target = parseOpenClamTarget(ctx.to);
    if (!target) throw new Error("invalid_openclam_target");
    if (!ctx.mediaUrl?.trim()) throw new Error("openclam_media_missing");
    const account = resolveOpenClamAccount(ctx.cfg, ctx.accountId);
    if (
      !account.enabled ||
      !account.configured ||
      account.connectionId.toLowerCase() !== target.connectionId
    ) {
      throw new Error("openclam_target_not_paired");
    }
    const client = findOpenClamClient(target.connectionId);
    if (!client) throw new Error("openclam_connection_inactive");
    const source = ctx.mediaUrl.trim();
    const attachment = await loadOpenClamMedia({
      cfg: ctx.cfg,
      agentId: account.agentId,
      source,
      mediaAccess: ctx.mediaAccess,
      mediaLocalRoots: ctx.mediaLocalRoots,
      mediaReadFile: ctx.mediaReadFile,
    });
    const uploaded = await client.deliverMediaToActiveConversation({
      accountId: account.accountId,
      conversationId: target.conversationId,
      source,
      caption: ctx.text,
      attachment,
    });
    return {
      channel: "openclam",
      messageId: uploaded.attachmentId,
      conversationId: target.conversationId,
    };
  },
};
