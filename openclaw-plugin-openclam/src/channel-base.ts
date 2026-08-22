import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import {
  applyOpenClamAccountConfig,
  getOpenClamConfig,
  listOpenClamAccountIds,
  openClamPluginConfigSchema,
  resolveDefaultOpenClamAccountId,
  resolveOpenClamAccount,
} from "./config.js";
import type { OpenClamCoreConfig, ResolvedOpenClamAccount } from "./types.js";

type OpenClamBase = Pick<
  ChannelPlugin<ResolvedOpenClamAccount>,
  "id" | "meta" | "capabilities" | "reload" | "configSchema" | "config" | "setup" | "status"
>;

export function createOpenClamChannelBase(): OpenClamBase {
  return {
    id: "openclam",
    meta: {
      id: "openclam",
      label: "OpenClam",
      selectionLabel: "OpenClam (paired iPhone)",
      detailLabel: "OpenClam",
      docsPath: "/channels/openclam",
      docsLabel: "openclam",
      blurb: "Connect paired OpenClam avatars to OpenClaw agents.",
      markdownCapable: true,
      forceAccountBinding: true,
    },
    capabilities: {
      chatTypes: ["direct"],
      blockStreaming: true,
    },
    reload: { configPrefixes: ["channels.openclam", "bindings"] },
    configSchema: openClamPluginConfigSchema,
    config: {
      listAccountIds: listOpenClamAccountIds,
      resolveAccount: resolveOpenClamAccount,
      defaultAccountId: resolveDefaultOpenClamAccountId,
      isEnabled: (account) => account.enabled,
      isConfigured: (account) => account.configured,
      disabledReason: () => "OpenClam is disabled for this avatar account.",
      unconfiguredReason: () => "Run `openclaw openclam pair` before starting this channel.",
      inspectAccount: (cfg, accountId) => {
        const account = resolveOpenClamAccount(cfg, accountId);
        return {
          enabled: account.enabled,
          configured: account.configured,
          tokenStatus: account.adapterTokenFile ? "file" : "missing",
          connectionId: account.connectionId || undefined,
          agentId: account.agentId || undefined,
        };
      },
      describeAccount: (account) => ({
        accountId: account.accountId,
        name: account.displayName,
        enabled: account.enabled,
        configured: account.configured,
        baseUrl: account.bridgeUrl,
        credentialSource: account.adapterTokenFile ? "file" : "missing",
      }),
      setAccountEnabled: ({ cfg, accountId, enabled }) => {
        const current = getOpenClamConfig(cfg);
        const account = current.accounts?.[accountId];
        if (!account) return cfg;
        return {
          ...cfg,
          channels: {
            ...cfg.channels,
            openclam: {
              ...current,
              accounts: {
                ...current.accounts,
                [accountId]: { ...account, enabled },
              },
            },
          },
        } as OpenClawConfig;
      },
      deleteAccount: ({ cfg, accountId }) => {
        const current = getOpenClamConfig(cfg);
        const accounts = { ...current.accounts };
        delete accounts[accountId];
        return {
          ...cfg,
          channels: {
            ...cfg.channels,
            openclam: { ...current, accounts },
          },
        } as OpenClawConfig;
      },
      hasConfiguredState: ({ cfg }) => listOpenClamAccountIds(cfg).some((accountId) =>
        resolveOpenClamAccount(cfg, accountId).configured,
      ),
    },
    setup: {
      resolveAccountId: ({ cfg, accountId }) => accountId ?? resolveDefaultOpenClamAccountId(cfg),
      resolveBindingAccountId: ({ accountId }) => accountId,
      applyAccountConfig: ({ cfg, accountId, input }) =>
        applyOpenClamAccountConfig({ cfg, accountId, input: input as Record<string, unknown> }),
      validateInput: ({ accountId, input }) => {
        const agentId = typeof input.userId === "string" ? input.userId.trim() : "";
        if (!accountId.trim()) return "An OpenClam account ID is required.";
        if (!agentId) return "Choose an OpenClaw agent, or use `openclaw openclam pair`.";
        return null;
      },
    },
    status: {
      defaultRuntime: {
        accountId: "default",
        running: false,
        connected: false,
      },
      buildChannelSummary: ({ account, snapshot }) => ({
        accountId: account.accountId,
        agentId: account.agentId,
        displayName: account.displayName,
        configured: account.configured,
        connected: snapshot.connected === true,
      }),
      buildAccountSnapshot: ({ account }) => ({
        accountId: account.accountId,
        name: account.displayName,
        enabled: account.enabled,
        configured: account.configured,
        baseUrl: account.bridgeUrl,
        credentialSource: account.adapterTokenFile ? "file" : "missing",
      }),
    },
  };
}
export function configuredOpenClamAccounts(cfg: OpenClawConfig): ResolvedOpenClamAccount[] {
  return listOpenClamAccountIds(cfg).map((accountId) =>
    resolveOpenClamAccount(cfg as OpenClamCoreConfig, accountId),
  );
}
