import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join } from "node:path";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  findOpenClamClient: vi.fn(), deliverText: vi.fn(), deliverMedia: vi.fn(), loadMedia: vi.fn(),
}));
vi.mock("../src/gateway.js", () => ({ findOpenClamClient: mocks.findOpenClamClient }));
vi.mock("../src/media.js", () => ({ loadOpenClamMedia: mocks.loadMedia }));

import { createOpenClamChannelBase } from "../src/channel-base.js";
import { openClamOutbound } from "../src/outbound.js";

// Exercise the actual pinned host SDK, not a duplicate of its availability
// predicate. The registry is process-local and every send uses an explicit
// fixture config. No real gateway, credential, account or network is touched.
const sdkDist = fileURLToPath(new URL("../node_modules/openclaw/dist/", import.meta.url));
type HostFunction = (...args: any[]) => any;
let makeRegistry: HostFunction;
let setRegistry: HostFunction;
let resetRegistry: HostFunction;
let supportsDelivery: HostFunction;
let makeRuntimeSend: HostFunction;
const connectionId = "11111111-1111-4111-8111-111111111111";
const conversationId = "22222222-2222-4222-8222-222222222222";
const target = `openclam:${connectionId}:${conversationId}`;
const cfg = {
  channels: { openclam: {
    bridgeUrl: "https://bridge.example", connectionId,
    adapterTokenFile: "/unused/token", stateFile: "/unused/state", defaultAccount: "main",
    accounts: { main: { agentId: "main", displayName: "Main" } },
  } },
};

async function loadChunk(prefix: string, marker: string): Promise<Record<string, unknown>> {
  const candidates = (await readdir(sdkDist)).filter((name) => name.startsWith(prefix) && name.endsWith(".js"));
  for (const candidate of candidates) {
    const path = join(sdkDist, candidate);
    if ((await readFile(path, "utf8")).includes(marker)) return await import(pathToFileURL(path).href);
  }
  throw new Error(`Pinned host chunk missing: ${marker}`);
}

function named(module: Record<string, unknown>, name: string): HostFunction {
  const found = Object.values(module).find((value) => typeof value === "function" && value.name === name);
  if (typeof found !== "function") throw new Error(`Pinned host export missing: ${name}`);
  return found as HostFunction;
}

function activate(outbound: typeof openClamOutbound): void {
  const registry = makeRegistry();
  registry.channels.push({ plugin: { ...createOpenClamChannelBase(), outbound } });
  setRegistry(registry, "openclam-offline-test");
}

describe("OpenClaw host SDK outbound eligibility", () => {
  beforeAll(async () => {
    const registry = await loadChunk("runtime-", "function resetPluginRuntimeStateForTest(");
    makeRegistry = named(registry, "createEmptyPluginRegistry");
    setRegistry = named(registry, "setActivePluginRegistry");
    resetRegistry = named(registry, "resetPluginRuntimeStateForTest");
    supportsDelivery = named(await loadChunk("deliver-", "function resolveOutboundDurableFinalDeliverySupport("),
      "resolveOutboundDurableFinalDeliverySupport");
    makeRuntimeSend = named(await loadChunk("channel-outbound-send-", "function createChannelOutboundRuntimeSend("),
      "createChannelOutboundRuntimeSend");
  }, 30_000);
  afterAll(() => resetRegistry?.());
  beforeEach(() => {
    vi.clearAllMocks();
    resetRegistry();
    mocks.findOpenClamClient.mockReturnValue({
      deliverTextToActiveConversation: mocks.deliverText,
      deliverMediaToActiveConversation: mocks.deliverMedia,
    });
    mocks.deliverText.mockResolvedValue({ messageId: "text-relay-receipt", conversationId });
    mocks.deliverMedia.mockResolvedValue({ attachmentId: "media-relay-receipt" });
    mocks.loadMedia.mockResolvedValue({ fileName: "movie.mp4", mediaType: "video/mp4", buffer: Buffer.from("video") });
  });

  it("reproduces the old sendMedia-only missing-handler failure in the real SDK", async () => {
    activate({ ...openClamOutbound, sendText: undefined });
    await expect(supportsDelivery({ channel: "openclam", cfg }))
      .resolves.toEqual({ ok: false, reason: "missing_outbound_handler" });
    const runtime = makeRuntimeSend({ channelId: "openclam", unavailableMessage: "Channel unavailable" });
    await expect(runtime.sendMessage(target, "Update", { cfg, accountId: "main" }))
      .rejects.toThrow("Channel unavailable");
    expect(mocks.deliverText).not.toHaveBeenCalled();
  });

  it("activates a genuine direct text handler and sends through the paired bridge contract", async () => {
    activate(openClamOutbound);
    await expect(supportsDelivery({ channel: "openclam", cfg })).resolves.toEqual({ ok: true });
    const runtime = makeRuntimeSend({ channelId: "openclam", unavailableMessage: "Channel unavailable" });
    await expect(runtime.sendMessage(target, "Update", { cfg, accountId: "main", replyToId: "current-turn" }))
      .resolves.toEqual({ channel: "openclam", messageId: "text-relay-receipt", conversationId });
    expect(mocks.deliverText).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
      accountId: "main", conversationId, text: "Update", replyToId: "current-turn",
    }));
    expect(openClamOutbound.deliveryMode).toBe("direct");
  });

  it("keeps host-approved media delivery separate once the channel is eligible", async () => {
    activate(openClamOutbound);
    const mediaAccess = { localRoots: ["/safe"], readFile: vi.fn() };
    const runtime = makeRuntimeSend({ channelId: "openclam", unavailableMessage: "Channel unavailable" });
    await expect(runtime.sendMessage(target, "Finished", {
      cfg, accountId: "main", mediaUrl: "/safe/movie.mp4", mediaAccess,
    })).resolves.toEqual({ channel: "openclam", messageId: "media-relay-receipt", conversationId });
    expect(mocks.loadMedia).toHaveBeenCalledWith(expect.objectContaining({ cfg, mediaAccess, source: "/safe/movie.mp4" }));
    expect(mocks.deliverMedia).toHaveBeenCalledTimes(1);
    expect(mocks.deliverText).not.toHaveBeenCalled();
  });

  it("does not advertise unsupported cross-restart unknown-send reconciliation", async () => {
    activate(openClamOutbound);
    await expect(supportsDelivery({ channel: "openclam", cfg, requirements: { reconcileUnknownSend: true } }))
      .resolves.toEqual({ ok: false, reason: "capability_mismatch", capability: "reconcileUnknownSend" });
  });
});
