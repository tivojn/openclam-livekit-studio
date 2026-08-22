import { normalizeAccountId } from "openclaw/plugin-sdk/account-id";
import { buildJsonChannelConfigSchema } from "openclaw/plugin-sdk/channel-config-schema";
import { ACCOUNT_ID_PATTERN, IDENTIFIER_PATTERN, } from "./types.js";
const channelJsonSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
        enabled: { type: "boolean" },
        adapterId: { type: "string", format: "uuid" },
        gatewayLabel: { type: "string", minLength: 1, maxLength: 80 },
        bridgeUrl: { type: "string", format: "uri" },
        connectionId: { type: "string", format: "uuid" },
        adapterTokenFile: { type: "string", minLength: 1 },
        stateFile: { type: "string", minLength: 1 },
        defaultAccount: {
            type: "string",
            minLength: 1,
            maxLength: 64,
            pattern: "^[a-z0-9][a-z0-9_-]{0,63}$",
        },
        accounts: {
            type: "object",
            propertyNames: { pattern: "^[a-z0-9][a-z0-9_-]{0,63}$" },
            additionalProperties: {
                type: "object",
                additionalProperties: false,
                required: ["agentId", "displayName"],
                properties: {
                    enabled: { type: "boolean" },
                    agentId: {
                        type: "string",
                        minLength: 1,
                        maxLength: 64,
                        pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$",
                    },
                    displayName: { type: "string", minLength: 1, maxLength: 80 },
                },
            },
        },
    },
};
export const openClamPluginConfigSchema = buildJsonChannelConfigSchema(channelJsonSchema, { cacheKey: "openclam-channel-v1" });
export function getOpenClamConfig(cfg) {
    return (cfg.channels?.openclam ?? {});
}
export function listOpenClamAccountIds(cfg) {
    const configured = Object.keys(getOpenClamConfig(cfg).accounts ?? {}).filter((id) => ACCOUNT_ID_PATTERN.test(id));
    return configured.sort();
}
export function resolveDefaultOpenClamAccountId(cfg) {
    const section = getOpenClamConfig(cfg);
    if (section.defaultAccount && section.accounts?.[section.defaultAccount]) {
        return section.defaultAccount;
    }
    return listOpenClamAccountIds(cfg)[0] ?? "default";
}
export function resolveOpenClamAccount(cfg, rawAccountId) {
    const section = getOpenClamConfig(cfg);
    const accountId = rawAccountId
        ? normalizeAccountId(rawAccountId)
        : resolveDefaultOpenClamAccountId(cfg);
    const account = section.accounts?.[accountId];
    const enabled = section.enabled !== false && account?.enabled !== false;
    const bridgeUrl = section.bridgeUrl?.trim() ?? "";
    const connectionId = section.connectionId?.trim() ?? "";
    const adapterTokenFile = section.adapterTokenFile?.trim() ?? "";
    const stateFile = section.stateFile?.trim() ?? "";
    return {
        accountId,
        agentId: account?.agentId?.trim() ?? "",
        displayName: account?.displayName?.trim() ?? accountId,
        enabled,
        configured: Boolean(account && bridgeUrl && connectionId && adapterTokenFile && stateFile),
        bridgeUrl,
        connectionId,
        adapterTokenFile,
        stateFile,
    };
}
export function applyOpenClamAccountConfig(params) {
    const accountId = normalizeAccountId(params.accountId);
    const existing = getOpenClamConfig(params.cfg);
    const agentId = typeof params.input.userId === "string" ? params.input.userId.trim() : "";
    const displayName = typeof params.input.name === "string" ? params.input.name.trim() : accountId;
    if (!ACCOUNT_ID_PATTERN.test(accountId) || !IDENTIFIER_PATTERN.test(agentId)) {
        return params.cfg;
    }
    return {
        ...params.cfg,
        channels: {
            ...params.cfg.channels,
            openclam: {
                ...existing,
                enabled: true,
                accounts: {
                    ...existing.accounts,
                    [accountId]: {
                        ...existing.accounts?.[accountId],
                        enabled: true,
                        agentId,
                        displayName,
                    },
                },
            },
        },
    };
}
