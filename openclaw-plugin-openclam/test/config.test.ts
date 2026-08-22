import { describe, expect, it } from "vitest";
import {
  listOpenClamAccountIds,
  resolveDefaultOpenClamAccountId,
  resolveOpenClamAccount,
} from "../src/config.js";

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
        zed: { agentId: "writer", displayName: "Writer" },
        ara: { agentId: "research", displayName: "Ara" },
      },
    },
  },
} as any;

describe("OpenClam channel config", () => {
  it("resolves sorted account IDs and the explicit default", () => {
    expect(listOpenClamAccountIds(config)).toEqual(["ara", "zed"]);
    expect(resolveDefaultOpenClamAccountId(config)).toBe("ara");
  });

  it("resolves one account without materializing the adapter token", () => {
    const account = resolveOpenClamAccount(config, "ara");
    expect(account).toMatchObject({
      accountId: "ara",
      agentId: "research",
      displayName: "Ara",
      configured: true,
      enabled: true,
    });
    expect(JSON.stringify(account)).not.toContain("Bearer");
  });
});
