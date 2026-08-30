import type { ChannelMessagingAdapter } from "openclaw/plugin-sdk/channel-runtime";
import { resolveOpenClamAccount } from "./config.js";
import { UUID_PATTERN } from "./types.js";

export type OpenClamTarget = {
  connectionId: string;
  conversationId: string;
  canonical: string;
};

export function parseOpenClamTarget(raw: string): OpenClamTarget | undefined {
  const trimmed = raw.trim();
  const withoutPrefix = trimmed.toLowerCase().startsWith("openclam:")
    ? trimmed.slice("openclam:".length)
    : trimmed;
  const parts = withoutPrefix.split(":");
  if (parts.length !== 2) return undefined;
  const [connectionId, conversationId] = parts.map((part) => part.toLowerCase());
  if (!connectionId || !conversationId) return undefined;
  if (!UUID_PATTERN.test(connectionId) || !UUID_PATTERN.test(conversationId)) return undefined;
  return {
    connectionId,
    conversationId,
    canonical: `${connectionId}:${conversationId}`,
  };
}

export const openClamMessaging: ChannelMessagingAdapter = {
  targetPrefixes: ["openclam"],
  normalizeTarget: (raw) => parseOpenClamTarget(raw)?.canonical,
  inferTargetChatType: ({ to }) => parseOpenClamTarget(to) ? "direct" : undefined,
  targetResolver: {
    looksLikeId: (raw, normalized) => Boolean(
      parseOpenClamTarget(normalized ?? raw),
    ),
    hint: "<paired-iPhone-conversation>",
    resolveTarget: async ({ cfg, accountId, input, normalized }) => {
      const target = parseOpenClamTarget(normalized) ?? parseOpenClamTarget(input);
      if (!target) return null;
      const account = resolveOpenClamAccount(cfg, accountId);
      if (
        !account.enabled ||
        !account.configured ||
        account.connectionId.toLowerCase() !== target.connectionId
      ) {
        return null;
      }
      return {
        to: target.canonical,
        kind: "user",
        display: "paired iPhone conversation",
        source: "normalized",
      };
    },
  },
};
