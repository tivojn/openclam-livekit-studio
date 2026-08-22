import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadOutboundMediaFromUrl: vi.fn(),
  detectMime: vi.fn(),
  getAgentScopedMediaLocalRootsForSources: vi.fn(),
  extensionForMime: vi.fn(() => "png"),
}));

vi.mock("openclaw/plugin-sdk/outbound-media", () => ({
  loadOutboundMediaFromUrl: mocks.loadOutboundMediaFromUrl,
}));
vi.mock("openclaw/plugin-sdk/media-runtime", () => ({
  detectMime: mocks.detectMime,
  extensionForMime: mocks.extensionForMime,
  getAgentScopedMediaLocalRootsForSources: mocks.getAgentScopedMediaLocalRootsForSources,
}));

import { loadOpenClamMedia, MAX_ATTACHMENT_BYTES } from "../src/media.js";

describe("OpenClam official outbound media policy", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.extensionForMime.mockReturnValue("png");
    mocks.getAgentScopedMediaLocalRootsForSources.mockReturnValue(["/safe/agent/workspace"]);
    mocks.loadOutboundMediaFromUrl.mockResolvedValue({
      buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      contentType: "image/png",
      fileName: "/safe/agent/workspace/generated.png",
    });
    mocks.detectMime.mockResolvedValue("image/png");
  });

  it("loads through OpenClaw's agent-scoped allowlist and returns only a basename", async () => {
    const cfg = { agents: { defaults: { workspace: "/safe/agent/workspace" } } } as any;
    const source = "/safe/agent/workspace/generated.png";
    const loaded = await loadOpenClamMedia({ cfg, agentId: "ara", source });

    expect(mocks.getAgentScopedMediaLocalRootsForSources).toHaveBeenCalledWith({
      cfg,
      agentId: "ara",
      mediaSources: [source],
    });
    expect(mocks.loadOutboundMediaFromUrl).toHaveBeenCalledWith(source, {
      maxBytes: MAX_ATTACHMENT_BYTES,
      mediaLocalRoots: ["/safe/agent/workspace"],
    });
    expect(mocks.detectMime).toHaveBeenCalledWith(expect.objectContaining({
      buffer: expect.any(Buffer),
      headerMime: "image/png",
    }));
    expect(loaded.fileName).toBe("generated.png");
    expect(JSON.stringify(loaded)).not.toContain("/safe/agent/workspace");
  });

  it("fails closed for an unsupported detected type", async () => {
    mocks.detectMime.mockResolvedValue("application/x-executable");
    await expect(loadOpenClamMedia({
      cfg: {} as any,
      agentId: "ara",
      source: "/safe/agent/workspace/program.bin",
    })).rejects.toThrow("attachment_type_unsupported");
  });
});
