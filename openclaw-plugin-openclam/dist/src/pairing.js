import { randomUUID } from "node:crypto";
import { hostname } from "node:os";
import { join, resolve } from "node:path";
import { normalizeAccountId } from "openclaw/plugin-sdk/account-id";
import { mutateConfigFile } from "openclaw/plugin-sdk/config-mutation";
import { resolveDefaultAgentId } from "openclaw/plugin-sdk/config-runtime";
import { resolveStateDir } from "openclaw/plugin-sdk/state-paths";
import { defaultCredentialPaths, initialAdapterState, readAdapterCredential, writeAdapterCredential, writeAdapterState, } from "./credentials.js";
import { getOpenClamConfig } from "./config.js";
import { parseCreatePairingResponse, truncateUnicode } from "./protocol.js";
import { ACCOUNT_ID_PATTERN, IDENTIFIER_PATTERN, UUID_PATTERN, } from "./types.js";
const defaultDependencies = {
    fetch,
    mutateConfig: mutateConfigFile,
    writeCredential: writeAdapterCredential,
    writeState: writeAdapterState,
    readCredential: readAdapterCredential,
    nowHostname: hostname,
    environment: process.env,
};
function normalizeBridgeUrl(raw, allowInsecureLocalhost) {
    const url = new URL(raw);
    if (url.username || url.password || url.search || url.hash) {
        throw new Error("Bridge URL must not contain credentials, query parameters, or a fragment.");
    }
    const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(url.hostname);
    if (url.protocol !== "https:" && !(allowInsecureLocalhost && local && url.protocol === "http:")) {
        throw new Error("Bridge URL must use HTTPS. HTTP is allowed only for an explicitly enabled localhost test.");
    }
    if (url.pathname !== "/") {
        throw new Error("Bridge URL must be a root origin without a path.");
    }
    return url.origin;
}
function configuredAgents(cfg) {
    const map = new Map();
    const list = cfg.agents?.list;
    if (Array.isArray(list)) {
        for (const candidate of list) {
            const id = typeof candidate?.id === "string" ? candidate.id.trim() : "";
            if (!IDENTIFIER_PATTERN.test(id))
                continue;
            const identityName = typeof candidate?.identity?.name === "string"
                ? candidate.identity.name.trim()
                : "";
            const configuredName = typeof candidate?.name === "string" ? candidate.name.trim() : "";
            const name = truncateUnicode(identityName || configuredName || id, 80);
            map.set(id, name);
        }
    }
    if (map.size === 0) {
        const fallback = resolveDefaultAgentId(cfg);
        if (IDENTIFIER_PATTERN.test(fallback))
            map.set(fallback, fallback);
    }
    return map;
}
function canonicalAccountId(raw) {
    const trimmed = raw.trim();
    if (!IDENTIFIER_PATTERN.test(trimmed)) {
        throw new Error(`Invalid OpenClam account ID "${raw}".`);
    }
    const normalized = normalizeAccountId(trimmed);
    if (!ACCOUNT_ID_PATTERN.test(normalized)) {
        throw new Error(`Invalid OpenClam account ID "${raw}".`);
    }
    return normalized;
}
function parseMapping(raw) {
    const separator = raw.indexOf("=");
    if (separator <= 0 || separator === raw.length - 1) {
        throw new Error(`Invalid mapping "${raw}"; use accountId=agentId.`);
    }
    const rawAccountId = raw.slice(0, separator).trim();
    const agentId = raw.slice(separator + 1).trim();
    if (!IDENTIFIER_PATTERN.test(agentId)) {
        throw new Error(`Invalid mapping "${raw}"; IDs may use letters, numbers, dot, underscore, colon, and hyphen.`);
    }
    return { accountId: canonicalAccountId(rawAccountId), agentId };
}
export function selectPairingAccounts(cfg, options) {
    const available = configuredAgents(cfg);
    const selected = new Map();
    const add = (rawAccountId, agentId) => {
        const accountId = canonicalAccountId(rawAccountId);
        const displayName = available.get(agentId);
        if (!displayName)
            throw new Error(`OpenClaw agent "${agentId}" is not configured.`);
        if (selected.has(accountId))
            throw new Error(`OpenClam account "${accountId}" is duplicated.`);
        selected.set(accountId, { accountId, agentId, displayName });
    };
    for (const agentId of options.agents ?? []) {
        const normalized = agentId.trim();
        if (!IDENTIFIER_PATTERN.test(normalized))
            throw new Error(`Invalid agent ID "${agentId}".`);
        add(normalized, normalized);
    }
    for (const raw of options.mappings ?? []) {
        const mapping = parseMapping(raw);
        add(mapping.accountId, mapping.agentId);
    }
    if (selected.size === 0) {
        for (const [agentId, displayName] of available) {
            const accountId = canonicalAccountId(agentId);
            if (selected.has(accountId)) {
                throw new Error(`OpenClam account "${accountId}" is duplicated after normalization.`);
            }
            selected.set(accountId, { accountId, agentId, displayName });
        }
    }
    const accounts = [...selected.values()];
    if (accounts.length === 0)
        throw new Error("No configured OpenClaw agents were found.");
    if (accounts.length > 32)
        throw new Error("A pairing can advertise at most 32 OpenClaw agents.");
    return accounts;
}
async function readSafeErrorCode(response) {
    try {
        const value = (await response.json());
        if (typeof value.error === "string")
            return value.error;
        if (typeof value.error?.code === "string")
            return value.error.code;
    }
    catch {
        // HTTP status remains the only diagnostic; response bodies are never echoed.
    }
    return `http_${response.status}`;
}
async function createPairing(deps, bridgeUrl, bootstrapToken, request) {
    const response = await deps.fetch(`${bridgeUrl}/v1/pairings`, {
        method: "POST",
        redirect: "error",
        headers: {
            Authorization: `Bearer ${bootstrapToken}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify(request),
        signal: AbortSignal.timeout(15_000),
    });
    if (!response.ok)
        throw new Error(`OpenClam pairing failed (${await readSafeErrorCode(response)}).`);
    return parseCreatePairingResponse(await response.json());
}
async function revokeConnection(deps, bridgeUrl, connectionId, adapterToken) {
    const response = await deps.fetch(`${bridgeUrl}/v1/connectors/${connectionId}`, {
        method: "DELETE",
        redirect: "error",
        headers: { Authorization: `Bearer ${adapterToken}` },
        signal: AbortSignal.timeout(15_000),
    });
    return response.status === 204 || response.status === 404;
}
export async function pairOpenClam(cfg, options, dependencies = {}) {
    const deps = { ...defaultDependencies, ...dependencies };
    const existing = getOpenClamConfig(cfg);
    if (existing.connectionId && !options.replace) {
        throw new Error("OpenClam is already paired. Use --replace to create and switch to a new connection.");
    }
    const bridgeUrl = normalizeBridgeUrl(options.bridgeUrl, options.allowInsecureLocalhost === true);
    const envName = options.bootstrapSecretEnv?.trim() || "OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN";
    if (!/^[A-Z_][A-Z0-9_]*$/u.test(envName))
        throw new Error("Invalid bootstrap secret environment variable name.");
    const bootstrapToken = deps.environment[envName]?.trim();
    if (!bootstrapToken)
        throw new Error(`Set ${envName} before creating an OpenClam pairing.`);
    const accounts = selectPairingAccounts(cfg, options);
    const defaultAccount = options.defaultAccount?.trim()
        ? canonicalAccountId(options.defaultAccount)
        : accounts[0].accountId;
    if (!accounts.some((account) => account.accountId === defaultAccount)) {
        throw new Error(`Default account "${defaultAccount}" is not part of this pairing.`);
    }
    const gatewayLabel = truncateUnicode(options.gatewayLabel?.trim() || deps.nowHostname(), 80);
    if (!gatewayLabel)
        throw new Error("Gateway label is required.");
    const adapterId = existing.adapterId && UUID_PATTERN.test(existing.adapterId)
        ? existing.adapterId
        : randomUUID();
    let replacement = null;
    if (options.replace && existing.connectionId) {
        if (!UUID_PATTERN.test(existing.connectionId) ||
            !existing.bridgeUrl?.trim() ||
            !existing.adapterTokenFile?.trim()) {
            throw new Error("The existing OpenClam pairing cannot be replaced safely because its revocation metadata is incomplete.");
        }
        replacement = {
            bridgeUrl: normalizeBridgeUrl(existing.bridgeUrl, options.allowInsecureLocalhost === true),
            connectionId: existing.connectionId,
            adapterToken: await deps.readCredential(existing.adapterTokenFile),
        };
    }
    const response = await createPairing(deps, bridgeUrl, bootstrapToken, {
        v: 1,
        adapterId,
        gatewayLabel,
        accounts,
    });
    const credentialDirectory = options.credentialDirectory
        ? resolve(options.credentialDirectory, response.connectionId)
        : join(resolveStateDir(), "credentials", "openclam", response.connectionId);
    const defaults = defaultCredentialPaths(response.connectionId);
    const adapterTokenFile = options.credentialDirectory
        ? join(credentialDirectory, "adapter-token")
        : defaults.adapterTokenFile;
    const stateFile = options.credentialDirectory
        ? join(credentialDirectory, "adapter-state.json")
        : defaults.stateFile;
    const revokeNewConnection = async () => {
        try {
            await revokeConnection(deps, bridgeUrl, response.connectionId, response.adapterToken);
        }
        catch {
            // The one-time client pairing expires even if this cleanup request cannot reach the bridge.
        }
    };
    try {
        await deps.writeCredential(adapterTokenFile, response.adapterToken);
        await deps.writeState(stateFile, initialAdapterState(response.connectionId));
    }
    catch (error) {
        await revokeNewConnection();
        throw error;
    }
    let oldConnectionRevoked = null;
    if (replacement) {
        let revoked = false;
        try {
            revoked = await revokeConnection(deps, replacement.bridgeUrl, replacement.connectionId, replacement.adapterToken);
        }
        catch {
            // A missing positive bridge response is not sufficient to commit a replacement.
        }
        if (!revoked) {
            await revokeNewConnection();
            throw new Error("OpenClam replacement stopped because the previous connection could not be revoked. The existing configuration was not changed.");
        }
        oldConnectionRevoked = true;
    }
    try {
        await deps.mutateConfig({
            mutate: (draft) => {
                const mutable = draft;
                mutable.channels ??= {};
                mutable.channels.openclam = {
                    enabled: true,
                    adapterId,
                    gatewayLabel,
                    bridgeUrl,
                    connectionId: response.connectionId,
                    adapterTokenFile,
                    stateFile,
                    defaultAccount,
                    accounts: Object.fromEntries(accounts.map((account) => [
                        account.accountId,
                        { enabled: true, agentId: account.agentId, displayName: account.displayName },
                    ])),
                };
                const bindings = Array.isArray(mutable.bindings) ? mutable.bindings : [];
                mutable.bindings = [
                    ...bindings.filter((binding) => binding.match?.channel !== "openclam"),
                    ...accounts.map((account) => ({
                        agentId: account.agentId,
                        match: { channel: "openclam", accountId: account.accountId },
                    })),
                ];
            },
        });
    }
    catch (error) {
        await revokeNewConnection();
        throw error;
    }
    return {
        code: response.code,
        connectionId: response.connectionId,
        expiresAt: response.expiresAt,
        gatewayLabel,
        accounts,
        oldConnectionRevoked,
    };
}
