import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { resolveStateDir } from "openclaw/plugin-sdk/state-paths";
import { UUID_PATTERN } from "./types.js";
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{40,128}$/u;
export function defaultCredentialPaths(connectionId) {
    const directory = join(resolveStateDir(), "credentials", "openclam", connectionId);
    return {
        adapterTokenFile: join(directory, "adapter-token"),
        stateFile: join(directory, "adapter-state.json"),
    };
}
async function writePrivateFile(path, contents) {
    const absolute = resolve(path);
    await mkdir(dirname(absolute), { recursive: true, mode: 0o700 });
    const temporary = `${absolute}.${randomUUID()}.tmp`;
    await writeFile(temporary, contents, { encoding: "utf8", mode: 0o600, flag: "wx" });
    await chmod(temporary, 0o600);
    await rename(temporary, absolute);
    await chmod(absolute, 0o600);
}
export async function writeAdapterCredential(path, token) {
    if (!TOKEN_PATTERN.test(token))
        throw new Error("invalid_adapter_token");
    await writePrivateFile(path, `${token}\n`);
}
export async function readAdapterCredential(path) {
    const info = await stat(path);
    if (!info.isFile())
        throw new Error("adapter_token_not_file");
    if (process.platform !== "win32" && (info.mode & 0o077) !== 0) {
        throw new Error("adapter_token_permissions_too_open");
    }
    const token = (await readFile(path, "utf8")).trim();
    if (!TOKEN_PATTERN.test(token))
        throw new Error("invalid_adapter_token");
    return token;
}
export function initialAdapterState(connectionId) {
    return {
        v: 1,
        connectionId,
        nextSeq: 1,
        lastReceivedSeq: 0,
        activeTurns: [],
        completedTurnIds: [],
    };
}
function parseAdapterState(value, connectionId) {
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new Error("invalid_adapter_state");
    }
    const candidate = value;
    if (candidate.v !== 1 ||
        candidate.connectionId !== connectionId ||
        !UUID_PATTERN.test(candidate.connectionId) ||
        !Number.isSafeInteger(candidate.nextSeq) ||
        (candidate.nextSeq ?? 0) < 1 ||
        !Number.isSafeInteger(candidate.lastReceivedSeq) ||
        (candidate.lastReceivedSeq ?? -1) < 0 ||
        !Array.isArray(candidate.activeTurns) ||
        !Array.isArray(candidate.completedTurnIds)) {
        throw new Error("invalid_adapter_state");
    }
    for (const turn of candidate.activeTurns) {
        if (!turn ||
            !UUID_PATTERN.test(turn.turnId) ||
            !UUID_PATTERN.test(turn.conversationId) ||
            typeof turn.accountId !== "string" ||
            (turn.recoveryExpiresAt !== undefined &&
                (!Number.isSafeInteger(turn.recoveryExpiresAt) || turn.recoveryExpiresAt < 1)) ||
            (turn.recoveryError !== undefined &&
                (typeof turn.recoveryError !== "object" ||
                    turn.recoveryError === null ||
                    typeof turn.recoveryError.code !== "string" ||
                    !/^[a-z][a-z0-9_]{0,63}$/u.test(turn.recoveryError.code) ||
                    typeof turn.recoveryError.message !== "string" ||
                    turn.recoveryError.message.length < 1 ||
                    turn.recoveryError.message.length > 240 ||
                    typeof turn.recoveryError.retryable !== "boolean"))) {
            throw new Error("invalid_adapter_state");
        }
    }
    if (candidate.completedTurnIds.some((id) => !UUID_PATTERN.test(id))) {
        throw new Error("invalid_adapter_state");
    }
    return candidate;
}
export async function readAdapterState(path, connectionId) {
    const info = await stat(path);
    if (!info.isFile())
        throw new Error("adapter_state_not_file");
    if (process.platform !== "win32" && (info.mode & 0o077) !== 0) {
        throw new Error("adapter_state_permissions_too_open");
    }
    return parseAdapterState(JSON.parse(await readFile(path, "utf8")), connectionId);
}
export async function writeAdapterState(path, state) {
    await writePrivateFile(path, `${JSON.stringify(state)}\n`);
}
