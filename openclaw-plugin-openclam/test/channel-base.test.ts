import { describe, expect, it } from "vitest";
import { createOpenClamChannelBase } from "../src/channel-base.js";
import { resolveOpenClamAccount } from "../src/config.js";

const config = {
  channels: {
    openclam: {
      enabled: true,
      bridgeUrl: "https://bridge.example",
      connectionId: "11111111-1111-4111-8111-111111111111",
      adapterTokenFile: "/private/adapter-token",
      stateFile: "/private/adapter-state.json",
      defaultAccount: "ara",
      accounts: {
        ara: { agentId: "ara", displayName: "Ara" },
        zed: { agentId: "writer", displayName: "Writer" },
      },
    },
  },
} as any;

describe("OpenClam channel status", () => {
  it("projects the live gateway runtime into account and channel status", async () => {
    const plugin = createOpenClamChannelBase();
    const account = resolveOpenClamAccount(config, "ara");
    const inspectedAccount = {
      accountId: account.accountId,
      agentId: account.agentId,
      enabled: account.enabled,
      configured: account.configured,
      tokenStatus: "file",
    } as any;
    const snapshot = await plugin.status?.buildAccountSnapshot?.({
      account: inspectedAccount,
      cfg: config,
      runtime: {
        accountId: "ara",
        running: true,
        connected: true,
        lastStartAt: 1234,
        lastStopAt: null,
        lastError: null,
        reconnectAttempts: 0,
      },
      probe: undefined,
      audit: undefined,
    });

    expect(snapshot).toMatchObject({
      accountId: "ara",
      name: "Ara",
      enabled: true,
      configured: true,
      baseUrl: "https://bridge.example",
      credentialSource: "file",
      running: true,
      connected: true,
      lastStartAt: 1234,
      lastStopAt: null,
      lastError: null,
      reconnectAttempts: 0,
    });
    expect(JSON.stringify(snapshot)).not.toContain("/private/adapter-token");

    expect(
      plugin.status?.buildChannelSummary?.({
        account,
        cfg: config,
        defaultAccountId: "ara",
        snapshot: snapshot!,
      }),
    ).toMatchObject({
      accountId: "ara",
      configured: true,
      connected: true,
    });
  });

  it("preserves a non-default account through inspection and status projection", async () => {
    const plugin = createOpenClamChannelBase();
    const snapshots = await Promise.all(["ara", "zed"].map(async (accountId) => {
      const inspected = await plugin.config.inspectAccount?.(config, accountId);
      return await plugin.status?.buildAccountSnapshot?.({
        account: inspected as any,
        cfg: config,
        runtime: {
          accountId,
          running: true,
          connected: true,
          lastStartAt: 1234,
          lastStopAt: null,
          lastError: null,
        },
        probe: undefined,
        audit: undefined,
      });
    }));

    expect(snapshots).toMatchObject([
      { accountId: "ara", name: "Ara", connected: true },
      { accountId: "zed", name: "Writer", connected: true },
    ]);
  });

  it("instructs the agent to return generated files through automatic attachment promotion", () => {
    const hints = createOpenClamChannelBase().agentPrompt?.messageToolHints?.({
      cfg: config,
      accountId: "ara",
    }) ?? [];
    expect(hints.join(" ")).toContain("local Markdown file links");
    expect(hints.join(" ")).toContain("do not use the message tool");
  });
});
