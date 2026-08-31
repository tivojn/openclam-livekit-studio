import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  findOpenClamClient: vi.fn(),
  loadOpenClamMedia: vi.fn(),
  deliverMediaToActiveConversation: vi.fn(),
  deliverTextToActiveConversation: vi.fn(),
}));

vi.mock("../src/gateway.js", () => ({
  findOpenClamClient: mocks.findOpenClamClient,
}));
vi.mock("../src/media.js", () => ({
  loadOpenClamMedia: mocks.loadOpenClamMedia,
}));

import { openClamOutbound } from "../src/outbound.js";
import { openClamMessaging, parseOpenClamTarget } from "../src/target.js";

const connectionId = "11111111-1111-4111-8111-111111111111";
const conversationId = "22222222-2222-4222-8222-222222222222";
const target = `openclam:${connectionId}:${conversationId}`;
const config = {
  channels: {
    openclam: {
      bridgeUrl: "https://bridge.example",
      connectionId,
      adapterTokenFile: "/private/token",
      stateFile: "/private/state",
      defaultAccount: "main",
      accounts: {
        main: { agentId: "main", displayName: "Main" },
      },
    },
  },
} as any;

describe("OpenClam outbound messages", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.findOpenClamClient.mockReturnValue({
      deliverMediaToActiveConversation: mocks.deliverMediaToActiveConversation,
      deliverTextToActiveConversation: mocks.deliverTextToActiveConversation,
    });
    mocks.deliverTextToActiveConversation.mockResolvedValue({
      messageId: "55555555-5555-4555-8555-555555555555", conversationId,
    });
    mocks.loadOpenClamMedia.mockResolvedValue({
      fileName: "movie.mp4",
      mediaType: "video/mp4",
      buffer: Buffer.from("video"),
    });
    mocks.deliverMediaToActiveConversation.mockResolvedValue({
      attachmentId: "33333333-3333-4333-8333-333333333333",
      fileName: "movie.mp4",
      mediaType: "video/mp4",
      byteCount: 5,
      sha256: "a".repeat(64),
      downloadPath: "/v1/connectors/attachment",
      expiresAt: Date.now() + 60_000,
    });
  });

  it("normalizes the current paired conversation and resolves it as a direct target", async () => {
    expect(parseOpenClamTarget(target)).toMatchObject({
      connectionId,
      conversationId,
      canonical: `${connectionId}:${conversationId}`,
    });
    expect(openClamMessaging.normalizeTarget?.(target)).toBe(
      `${connectionId}:${conversationId}`,
    );
    expect(openClamMessaging.targetResolver?.looksLikeId?.(target)).toBe(true);
    await expect(openClamMessaging.targetResolver?.resolveTarget?.({
      cfg: config,
      accountId: "main",
      input: target,
      normalized: `${connectionId}:${conversationId}`,
      preferredKind: "user",
    })).resolves.toMatchObject({
      to: `${connectionId}:${conversationId}`,
      kind: "user",
      source: "normalized",
    });
  });

  it("loads a generated file through host-approved media access and delivers one attachment", async () => {
    const mediaAccess = {
      localRoots: ["/safe/PinkCherryStudio/output/video"],
      readFile: vi.fn(),
    };
    const result = await openClamOutbound.sendMedia?.({
      cfg: config,
      to: `${connectionId}:${conversationId}`,
      text: "Finished video",
      mediaUrl: "/safe/PinkCherryStudio/output/video/movie.mp4",
      accountId: "main",
      mediaAccess,
    });

    expect(mocks.loadOpenClamMedia).toHaveBeenCalledWith(expect.objectContaining({
      cfg: config,
      agentId: "main",
      source: "/safe/PinkCherryStudio/output/video/movie.mp4",
      mediaAccess,
    }));
    expect(mocks.deliverMediaToActiveConversation).toHaveBeenCalledWith(expect.objectContaining({
      accountId: "main",
      conversationId,
      source: "/safe/PinkCherryStudio/output/video/movie.mp4",
      caption: "Finished video",
      attachment: expect.objectContaining({ mediaType: "video/mp4" }),
    }));
    expect(result).toMatchObject({
      channel: "openclam",
      messageId: "33333333-3333-4333-8333-333333333333",
      conversationId,
    });
  });

  it("routes text through the real active-turn sender and returns its persisted event ID", async () => {
    const onPlatformSendDispatch = vi.fn(async () => {});
    const result = await openClamOutbound.sendText!({
      cfg: config, to: target, text: "The video is ready", accountId: "main",
      replyToId: "current-turn", deliveryQueueId: "host-intent-1", onPlatformSendDispatch,
    });
    expect(openClamOutbound.deliveryMode).toBe("direct");
    expect(mocks.deliverTextToActiveConversation).toHaveBeenCalledExactlyOnceWith({
      accountId: "main", conversationId, text: "The video is ready",
      replyToId: "current-turn", deliveryId: "host-intent-1", onPlatformSendDispatch,
    });
    expect(result).toEqual({
      channel: "openclam", messageId: "55555555-5555-4555-8555-555555555555", conversationId,
    });
    expect(mocks.loadOpenClamMedia).not.toHaveBeenCalled();
    expect(onPlatformSendDispatch).not.toHaveBeenCalled(); // The bridge invokes it at dispatch.
  });

  it("does not fabricate successful text delivery when the receipt is uncertain", async () => {
    mocks.deliverTextToActiveConversation.mockRejectedValue(
      new Error("openclam_text_delivery_unconfirmed"),
    );
    await expect(openClamOutbound.sendText!({
      cfg: config, to: target, text: "Update", accountId: "main",
    })).rejects.toThrow("openclam_text_delivery_unconfirmed");
  });

  it("rejects text sends outside the paired enabled account or without a live client", async () => {
    for (const [to, cfg, error] of [
      ["random-user", config, "invalid_openclam_target"],
      [`44444444-4444-4444-8444-444444444444:${conversationId}`, config,
        "openclam_target_not_paired"],
      [target, { channels: { openclam: { ...config.channels.openclam, enabled: false } } },
        "openclam_target_not_paired"],
    ] as const) {
      await expect(openClamOutbound.sendText!({
        cfg, to, text: "Update", accountId: "main",
      })).rejects.toThrow(error);
    }
    mocks.findOpenClamClient.mockReturnValue(undefined);
    await expect(openClamOutbound.sendText!({
      cfg: config, to: target, text: "Update", accountId: "main",
    })).rejects.toThrow("openclam_connection_inactive");
    expect(mocks.deliverTextToActiveConversation).not.toHaveBeenCalled();
  });

  it("does not silently redirect a thread or bypass approved media loading through text", async () => {
    await expect(openClamOutbound.sendText!({
      cfg: config, to: target, text: "Update", threadId: "another-thread",
    })).rejects.toThrow("openclam_threads_unsupported");
    await expect(openClamOutbound.sendText!({
      cfg: config, to: target, text: "Update", mediaUrl: "/private/secret.pdf",
    })).rejects.toThrow("openclam_media_requires_sender");
    expect(mocks.deliverTextToActiveConversation).not.toHaveBeenCalled();
    expect(mocks.loadOpenClamMedia).not.toHaveBeenCalled();
  });

  it("fails closed for malformed, unpaired, or inactive destinations", async () => {
    await expect(openClamOutbound.sendMedia?.({
      cfg: config,
      to: "not-a-conversation",
      text: "",
      mediaUrl: "/safe/movie.mp4",
      accountId: "main",
    })).rejects.toThrow("invalid_openclam_target");

    const otherConnection = "44444444-4444-4444-8444-444444444444";
    await expect(openClamOutbound.sendMedia?.({
      cfg: config,
      to: `${otherConnection}:${conversationId}`,
      text: "",
      mediaUrl: "/safe/movie.mp4",
      accountId: "main",
    })).rejects.toThrow("openclam_target_not_paired");

    mocks.findOpenClamClient.mockReturnValue(undefined);
    await expect(openClamOutbound.sendMedia?.({
      cfg: config,
      to: `${connectionId}:${conversationId}`,
      text: "",
      mediaUrl: "/safe/movie.mp4",
      accountId: "main",
    })).rejects.toThrow("openclam_connection_inactive");
  });

  it("does not resolve or deliver through a disabled OpenClam account", async () => {
    const disabled = structuredClone(config);
    disabled.channels.openclam.accounts.main.enabled = false;
    await expect(openClamMessaging.targetResolver?.resolveTarget?.({
      cfg: disabled,
      accountId: "main",
      input: target,
      normalized: `${connectionId}:${conversationId}`,
      preferredKind: "user",
    })).resolves.toBeNull();
    await expect(openClamOutbound.sendMedia?.({
      cfg: disabled,
      to: `${connectionId}:${conversationId}`,
      text: "Finished video",
      mediaUrl: "/safe/movie.mp4",
      accountId: "main",
    })).rejects.toThrow("openclam_target_not_paired");
  });
});
