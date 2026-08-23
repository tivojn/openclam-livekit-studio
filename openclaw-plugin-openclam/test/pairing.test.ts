import { randomUUID } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import {
  pairOpenClam,
  replaceOpenClamDevicePairing,
  selectPairingAccounts,
} from "../src/pairing.js";

const bootstrapToken = "B".repeat(48);
const adapterToken = "A".repeat(48);

function baseConfig() {
  return {
    agents: {
      list: [
        { id: "main", name: "Main" },
        { id: "research", name: "Research" },
      ],
    },
    bindings: [{ agentId: "other", match: { channel: "signal" } }],
  } as any;
}

describe("OpenClam pairing", () => {
  it("advertises the agent identity name without changing account or agent IDs", () => {
    const cfg = {
      agents: {
        list: [{ id: "ara", name: "ara", identity: { name: "Ara" } }],
      },
    } as any;

    expect(selectPairingAccounts(cfg, { mappings: ["Ara=ara"] })).toEqual([
      { accountId: "ara", agentId: "ara", displayName: "Ara" },
    ]);
  });

  it("does not split an emoji at the pairing display-name boundary", () => {
    const cfg = {
      agents: {
        list: [{ id: "ara", identity: { name: `${"A".repeat(79)}🙂B` } }],
      },
    } as any;

    const [account] = selectPairingAccounts(cfg, { agents: ["ara"] });
    expect(Array.from(account?.displayName ?? "")).toHaveLength(80);
    expect(account?.displayName.endsWith("🙂")).toBe(true);
    expect(/[\uD800-\uDBFF]$/u.test(account?.displayName ?? "")).toBe(false);
  });

  it("normalizes account separators and rejects collisions after normalization", () => {
    expect(
      selectPairingAccounts(baseConfig(), { mappings: ["research.avatar=research"] }),
    ).toEqual([
      { accountId: "research-avatar", agentId: "research", displayName: "Research" },
    ]);
    expect(() =>
      selectPairingAccounts(baseConfig(), {
        mappings: ["Research.Avatar=research", "research-avatar=main"],
      }),
    ).toThrow('OpenClam account "research-avatar" is duplicated');
  });

  it("selects explicit account-to-agent mappings", () => {
    expect(
      selectPairingAccounts(baseConfig(), {
        agents: ["main"],
        mappings: ["ara=research"],
      }),
    ).toEqual([
      { accountId: "main", agentId: "main", displayName: "Main" },
      { accountId: "ara", agentId: "research", displayName: "Research" },
    ]);
  });

  it("stores only role credentials, writes standard bindings, and never persists the bootstrap token", async () => {
    const connectionId = randomUUID();
    const gatewayLabel = `${"G".repeat(79)}🙂Z`;
    const events: string[] = [];
    let writtenConfig: any;
    const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
      events.push(`fetch:${init?.method}`);
      expect((init?.headers as Record<string, string>).Authorization).toBe(`Bearer ${bootstrapToken}`);
      const request = JSON.parse(String(init?.body));
      expect(request.accounts).toEqual([
        { accountId: "ara", agentId: "research", displayName: "Research" },
      ]);
      expect(Array.from(String(request.gatewayLabel))).toHaveLength(80);
      expect(String(request.gatewayLabel).endsWith("🙂")).toBe(true);
      return Response.json(
        {
          v: 1,
          pairingId: randomUUID(),
          connectionId,
          code: "OC-2345-6789-ABCD",
          expiresAt: Date.now() + 300_000,
          adapterToken,
        },
        { status: 201 },
      );
    });
    const mutateConfig = vi.fn(async ({ mutate }: any) => {
      events.push("config");
      writtenConfig = structuredClone(baseConfig());
      await mutate(writtenConfig);
      return {} as any;
    });

    const result = await pairOpenClam(
      baseConfig(),
      {
        bridgeUrl: "https://bridge.example",
        mappings: ["Ara=research"],
        defaultAccount: "Ara",
        credentialDirectory: "/private/openclam-test",
      },
      {
        fetch: fetchMock as any,
        mutateConfig: mutateConfig as any,
        writeCredential: vi.fn(async (_path, token) => {
          events.push("credential");
          expect(token).toBe(adapterToken);
        }),
        writeState: vi.fn(async () => {
          events.push("state");
        }),
        environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
        nowHostname: () => gatewayLabel,
      },
    );

    expect(result.code).toBe("OC-2345-6789-ABCD");
    expect(result.gatewayLabel.endsWith("🙂")).toBe(true);
    expect(events).toEqual(["fetch:POST", "credential", "state", "config"]);
    expect(writtenConfig.channels.openclam.accounts.ara.agentId).toBe("research");
    expect(writtenConfig.channels.openclam.defaultAccount).toBe("ara");
    expect(writtenConfig.bindings).toContainEqual({
      agentId: "research",
      match: { channel: "openclam", accountId: "ara" },
    });
    expect(JSON.stringify(writtenConfig)).not.toContain(bootstrapToken);
    expect(JSON.stringify(writtenConfig)).not.toContain(adapterToken);
  });

  it("requires old connection revocation before committing the replacement config", async () => {
    const oldConnectionId = randomUUID();
    const newConnectionId = randomUUID();
    const oldToken = "O".repeat(48);
    const events: string[] = [];
    const cfg = {
      ...baseConfig(),
      channels: {
        openclam: {
          adapterId: randomUUID(),
          bridgeUrl: "https://bridge.example",
          connectionId: oldConnectionId,
          adapterTokenFile: "/private/old-token",
          stateFile: "/private/old-state",
          accounts: { main: { agentId: "main", displayName: "Main" } },
        },
      },
    } as any;
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      events.push(`fetch:${init?.method}`);
      if (init?.method === "DELETE") {
        expect(url).toContain(oldConnectionId);
        expect((init.headers as Record<string, string>).Authorization).toBe(`Bearer ${oldToken}`);
        return new Response(null, { status: 204 });
      }
      return Response.json(
        {
          v: 1,
          pairingId: randomUUID(),
          connectionId: newConnectionId,
          code: "OC-CDEF-GHJK-MNPQ",
          expiresAt: Date.now() + 300_000,
          adapterToken,
        },
        { status: 201 },
      );
    });

    const result = await pairOpenClam(
      cfg,
      {
        bridgeUrl: "https://bridge.example",
        replace: true,
        credentialDirectory: "/private/openclam-test",
      },
      {
        fetch: fetchMock as any,
        mutateConfig: vi.fn(async ({ mutate }: any) => {
          events.push("config");
          await mutate(structuredClone(cfg));
          return {} as any;
        }) as any,
        writeCredential: vi.fn(async () => {
          events.push("credential");
        }),
        writeState: vi.fn(async () => {
          events.push("state");
        }),
        readCredential: vi.fn(async () => oldToken),
        environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
        nowHostname: () => "gateway-test",
      },
    );

    expect(result.oldConnectionRevoked).toBe(true);
    expect(events).toEqual(["fetch:POST", "credential", "state", "fetch:DELETE", "config"]);
  });

  it("creates an iPhone code from the existing adapter credential and atomically rotates config", async () => {
    const oldConnectionId = randomUUID();
    const newConnectionId = randomUUID();
    const oldToken = "O".repeat(48);
    const events: string[] = [];
    let committed: any;
    const cfg = {
      ...baseConfig(),
      channels: {
        openclam: {
          enabled: true,
          adapterId: randomUUID(),
          gatewayLabel: "OpenClam Mac",
          bridgeUrl: "https://bridge.example",
          connectionId: oldConnectionId,
          adapterTokenFile: "/private/old-token",
          stateFile: "/private/old-state",
          defaultAccount: "main",
          accounts: {
            main: { enabled: true, agentId: "main", displayName: "Main" },
            research: { enabled: true, agentId: "research", displayName: "Research" },
          },
        },
      },
    } as any;
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      events.push(`${init?.method}:${url}`);
      if (init?.method === "POST") {
        expect(url).toBe(
          `https://bridge.example/v1/adapters/${oldConnectionId}/pairings`,
        );
        expect((init.headers as Record<string, string>).Authorization).toBe(
          `Bearer ${oldToken}`,
        );
        expect(init.body).toBeUndefined();
        return Response.json(
          {
            v: 1,
            pairingId: randomUUID(),
            connectionId: newConnectionId,
            code: "OC-CDEF-GHJK-MNPQ",
            expiresAt: Date.now() + 600_000,
            adapterToken,
          },
          { status: 201 },
        );
      }
      expect(url).toBe(`https://bridge.example/v1/connectors/${oldConnectionId}`);
      expect((init?.headers as Record<string, string>).Authorization).toBe(
        `Bearer ${oldToken}`,
      );
      return new Response(null, { status: 204 });
    });
    const result = await replaceOpenClamDevicePairing(
      cfg,
      { credentialDirectory: "/private/openclam-test" },
      {
        fetch: fetchMock as any,
        readCredential: vi.fn(async () => oldToken),
        writeCredential: vi.fn(async (_path, token) => {
          expect(token).toBe(adapterToken);
          events.push("credential");
        }),
        writeState: vi.fn(async (_path, state) => {
          expect(state.connectionId).toBe(newConnectionId);
          events.push("state");
        }),
        mutateConfig: vi.fn(async ({ mutate }: any) => {
          committed = structuredClone(cfg);
          await mutate(committed);
          events.push("config");
          return {} as any;
        }) as any,
      },
    );

    expect(result.code).toBe("OC-CDEF-GHJK-MNPQ");
    expect(result.oldConnectionRevoked).toBe(true);
    expect(result.accounts.map((account) => account.accountId)).toEqual([
      "main",
      "research",
    ]);
    expect(events).toEqual([
      `POST:https://bridge.example/v1/adapters/${oldConnectionId}/pairings`,
      "credential",
      "state",
      `DELETE:https://bridge.example/v1/connectors/${oldConnectionId}`,
      "config",
    ]);
    expect(committed.channels.openclam.connectionId).toBe(newConnectionId);
    expect(committed.channels.openclam.defaultAccount).toBe("main");
    expect(committed.bindings).toEqual(cfg.bindings);
  });

  it("keeps the existing config and fails when old revocation has no positive response", async () => {
    const oldConnectionId = randomUUID();
    const newConnectionId = randomUUID();
    const oldToken = "O".repeat(48);
    const events: string[] = [];
    const cfg = {
      ...baseConfig(),
      channels: {
        openclam: {
          adapterId: randomUUID(),
          bridgeUrl: "https://bridge.example",
          connectionId: oldConnectionId,
          adapterTokenFile: "/private/old-token",
          stateFile: "/private/old-state",
          accounts: { main: { agentId: "main", displayName: "Main" } },
        },
      },
    } as any;
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      events.push(`${init?.method}:${url}`);
      if (init?.method === "POST") {
        return Response.json(
          {
            v: 1,
            pairingId: randomUUID(),
            connectionId: newConnectionId,
            code: "OC-CDEF-GHJK-MNPQ",
            expiresAt: Date.now() + 300_000,
            adapterToken,
          },
          { status: 201 },
        );
      }
      if (url.endsWith(oldConnectionId)) throw new Error("network_unavailable");
      expect(url).toContain(newConnectionId);
      expect((init?.headers as Record<string, string>).Authorization).toBe(`Bearer ${adapterToken}`);
      return new Response(null, { status: 204 });
    });
    const mutateConfig = vi.fn();

    await expect(
      pairOpenClam(
        cfg,
        {
          bridgeUrl: "https://bridge.example",
          replace: true,
          credentialDirectory: "/private/openclam-test",
        },
        {
          fetch: fetchMock as any,
          mutateConfig: mutateConfig as any,
          writeCredential: vi.fn(async () => {
            events.push("credential:new");
          }),
          writeState: vi.fn(async () => {
            events.push("state:new");
          }),
          readCredential: vi.fn(async () => oldToken),
          environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
          nowHostname: () => "gateway-test",
        },
      ),
    ).rejects.toThrow("previous connection could not be revoked");

    expect(mutateConfig).not.toHaveBeenCalled();
    expect(cfg.channels.openclam.connectionId).toBe(oldConnectionId);
    expect(cfg.channels.openclam.adapterTokenFile).toBe("/private/old-token");
    expect(events).toEqual([
      "POST:https://bridge.example/v1/pairings",
      "credential:new",
      "state:new",
      `DELETE:https://bridge.example/v1/connectors/${oldConnectionId}`,
      `DELETE:https://bridge.example/v1/connectors/${newConnectionId}`,
    ]);
  });

  it("does not revoke the working old connection when a new local write fails", async () => {
    const oldConnectionId = randomUUID();
    const newConnectionId = randomUUID();
    const oldToken = "O".repeat(48);
    const events: string[] = [];
    const cfg = {
      ...baseConfig(),
      channels: {
        openclam: {
          adapterId: randomUUID(),
          bridgeUrl: "https://bridge.example",
          connectionId: oldConnectionId,
          adapterTokenFile: "/private/old-token",
          stateFile: "/private/old-state",
          accounts: { main: { agentId: "main", displayName: "Main" } },
        },
      },
    } as any;
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      events.push(`${init?.method}:${url}`);
      if (init?.method === "POST") {
        return Response.json(
          {
            v: 1,
            pairingId: randomUUID(),
            connectionId: newConnectionId,
            code: "OC-CDEF-GHJK-MNPQ",
            expiresAt: Date.now() + 300_000,
            adapterToken,
          },
          { status: 201 },
        );
      }
      expect(url).toContain(newConnectionId);
      return new Response(null, { status: 204 });
    });
    const mutateConfig = vi.fn();

    await expect(
      pairOpenClam(
        cfg,
        {
          bridgeUrl: "https://bridge.example",
          replace: true,
          credentialDirectory: "/private/openclam-test",
        },
        {
          fetch: fetchMock as any,
          mutateConfig: mutateConfig as any,
          writeCredential: vi.fn(async () => {
            events.push("credential:new");
          }),
          writeState: vi.fn(async () => {
            events.push("state:new");
            throw new Error("state_write_failed");
          }),
          readCredential: vi.fn(async () => oldToken),
          environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
          nowHostname: () => "gateway-test",
        },
      ),
    ).rejects.toThrow("state_write_failed");

    expect(mutateConfig).not.toHaveBeenCalled();
    expect(events).toEqual([
      "POST:https://bridge.example/v1/pairings",
      "credential:new",
      "state:new",
      `DELETE:https://bridge.example/v1/connectors/${newConnectionId}`,
    ]);
    expect(events.join("\n")).not.toContain(oldConnectionId);
  });

  it("rejects a non-root bridge URL before creating a pairing", async () => {
    const fetchMock = vi.fn();
    await expect(
      pairOpenClam(
        baseConfig(),
        { bridgeUrl: "https://bridge.example/some/path" },
        {
          fetch: fetchMock as any,
          environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
        },
      ),
    ).rejects.toThrow("root origin");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("validates the default account before creating or writing a connection", async () => {
    const fetchMock = vi.fn();
    const writeCredential = vi.fn();
    await expect(
      pairOpenClam(
        baseConfig(),
        {
          bridgeUrl: "https://bridge.example",
          mappings: ["ara=research"],
          defaultAccount: "missing",
        },
        {
          fetch: fetchMock as any,
          writeCredential: writeCredential as any,
          environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
        },
      ),
    ).rejects.toThrow('Default account "missing"');
    expect(fetchMock).not.toHaveBeenCalled();
    expect(writeCredential).not.toHaveBeenCalled();
  });

  it("revokes the new connection if the local config transaction fails", async () => {
    const connectionId = randomUUID();
    const events: string[] = [];
    const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
      events.push(`${init?.method}:${url}`);
      if (init?.method === "DELETE") {
        expect((init.headers as Record<string, string>).Authorization).toBe(`Bearer ${adapterToken}`);
        return new Response(null, { status: 204 });
      }
      return Response.json(
        {
          v: 1,
          pairingId: randomUUID(),
          connectionId,
          code: "OC-2345-6789-ABCD",
          expiresAt: Date.now() + 300_000,
          adapterToken,
        },
        { status: 201 },
      );
    });
    await expect(
      pairOpenClam(
        baseConfig(),
        { bridgeUrl: "https://bridge.example", credentialDirectory: "/private/openclam-test" },
        {
          fetch: fetchMock as any,
          writeCredential: vi.fn(async () => undefined),
          writeState: vi.fn(async () => undefined),
          mutateConfig: vi.fn(async () => {
            throw new Error("config_write_failed");
          }) as any,
          environment: { OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN: bootstrapToken },
        },
      ),
    ).rejects.toThrow("config_write_failed");
    expect(events).toEqual([
      "POST:https://bridge.example/v1/pairings",
      `DELETE:https://bridge.example/v1/connectors/${connectionId}`,
    ]);
  });
});
