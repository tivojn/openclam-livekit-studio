import { resolveOpenClamAccount } from "./config.js";
import { findOpenClamClient } from "./gateway.js";
import { loadOpenClamMedia } from "./media.js";
import { parseOpenClamTarget } from "./target.js";
function resolveTarget(params) {
    const target = parseOpenClamTarget(params.to ?? "");
    if (!target)
        return { ok: false, error: new Error("invalid_openclam_target") };
    if (params.cfg) {
        const account = resolveOpenClamAccount(params.cfg, params.accountId);
        if (!account.enabled ||
            !account.configured ||
            account.connectionId.toLowerCase() !== target.connectionId) {
            return { ok: false, error: new Error("openclam_target_not_paired") };
        }
    }
    return { ok: true, to: target.canonical };
}
export const openClamOutbound = {
    deliveryMode: "direct",
    resolveTarget,
    sendMedia: async (ctx) => {
        const target = parseOpenClamTarget(ctx.to);
        if (!target)
            throw new Error("invalid_openclam_target");
        if (!ctx.mediaUrl?.trim())
            throw new Error("openclam_media_missing");
        const account = resolveOpenClamAccount(ctx.cfg, ctx.accountId);
        if (!account.enabled ||
            !account.configured ||
            account.connectionId.toLowerCase() !== target.connectionId) {
            throw new Error("openclam_target_not_paired");
        }
        const client = findOpenClamClient(target.connectionId);
        if (!client)
            throw new Error("openclam_connection_inactive");
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
