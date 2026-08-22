import { invalidRequest } from "./errors";
import type {
  AccountDescriptor,
  ConnectorFrame,
  CreatePairingRequest,
  FrameKind,
  RedeemPairingRequest,
} from "./types";

export const CREATE_BODY_LIMIT_BYTES = 16_384;
export const REDEEM_BODY_LIMIT_BYTES = 2_048;
export const FRAME_LIMIT_BYTES = 65_536;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const PAIRING_CODE = /^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;
const SAFE_ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/;
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/u;
const FRAME_KINDS = new Set<FrameKind>([
  "ack",
  "heartbeat",
  "turn.submit",
  "turn.accepted",
  "assistant.delta",
  "assistant.completed",
  "turn.cancel",
  "turn.error",
]);

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const accepted = new Set([...required, ...optional]);
  if (Object.keys(value).some((key) => !accepted.has(key))) invalidRequest();
  if (required.some((key) => !(key in value))) invalidRequest();
}

function codePointLength(value: string): number {
  return [...value].length;
}

function boundedString(
  value: unknown,
  minimum: number,
  maximum: number,
  controlsAllowed = false,
): string {
  if (typeof value !== "string") invalidRequest();
  const length = codePointLength(value);
  if (
    length < minimum ||
    length > maximum ||
    (!controlsAllowed && CONTROL_CHARACTER.test(value))
  ) {
    invalidRequest();
  }
  return value;
}

function uuid(value: unknown): string {
  const parsed = boundedString(value, 36, 36);
  if (!UUID.test(parsed)) invalidRequest();
  return parsed;
}

function positiveInteger(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) invalidRequest();
  return value as number;
}

function nonnegativeInteger(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) invalidRequest();
  return value as number;
}

function parseAccount(value: unknown): AccountDescriptor {
  if (!isRecord(value)) invalidRequest();
  exactKeys(value, ["accountId", "agentId", "displayName"]);
  const accountId = boundedString(value.accountId, 1, 64);
  const agentId = boundedString(value.agentId, 1, 64);
  const displayName = boundedString(value.displayName, 1, 80);
  if (!IDENTIFIER.test(accountId) || !IDENTIFIER.test(agentId)) invalidRequest();
  if (displayName.trim().length === 0) invalidRequest();
  return { accountId, agentId, displayName };
}

export function parseCreatePairing(value: unknown): CreatePairingRequest {
  if (!isRecord(value)) invalidRequest();
  exactKeys(value, ["v", "adapterId", "gatewayLabel", "accounts"]);
  if (value.v !== 1 || !Array.isArray(value.accounts)) invalidRequest();
  if (value.accounts.length < 1 || value.accounts.length > 32) invalidRequest();
  const accounts = value.accounts.map(parseAccount);
  if (new Set(accounts.map((account) => account.accountId)).size !== accounts.length) {
    invalidRequest();
  }
  const gatewayLabel = boundedString(value.gatewayLabel, 1, 80);
  if (gatewayLabel.trim().length === 0) invalidRequest();
  return {
    v: 1,
    adapterId: uuid(value.adapterId),
    gatewayLabel,
    accounts,
  };
}

export function parseRedeemPairing(value: unknown): RedeemPairingRequest {
  if (!isRecord(value)) invalidRequest();
  exactKeys(value, ["v", "code", "installationId", "deviceLabel"]);
  const code = boundedString(value.code, 17, 17);
  const deviceLabel = boundedString(value.deviceLabel, 1, 80);
  if (
    value.v !== 1 ||
    !PAIRING_CODE.test(code) ||
    deviceLabel.trim().length === 0
  ) {
    invalidRequest();
  }
  return {
    v: 1,
    code,
    installationId: uuid(value.installationId),
    deviceLabel,
  };
}

function parsePayload(
  kind: FrameKind,
  value: unknown,
): Record<string, unknown> {
  if (!isRecord(value) || Object.keys(value).length > 16) invalidRequest();
  if (kind === "heartbeat") {
    exactKeys(value, [], ["lastReceivedSeq"]);
    return value.lastReceivedSeq === undefined
      ? {}
      : { lastReceivedSeq: nonnegativeInteger(value.lastReceivedSeq) };
  }
  if (kind === "ack") {
    exactKeys(value, ["ackSeq"]);
    return { ackSeq: positiveInteger(value.ackSeq) };
  }
  if (kind === "turn.submit") {
    exactKeys(value, ["turnId", "accountId", "text"]);
    const accountId = boundedString(value.accountId, 1, 64);
    if (!IDENTIFIER.test(accountId)) invalidRequest();
    return {
      turnId: uuid(value.turnId),
      accountId,
      text: boundedString(value.text, 1, 32_000, true),
    };
  }
  if (kind === "assistant.delta") {
    exactKeys(value, ["turnId", "revision", "text"]);
    const revision = positiveInteger(value.revision);
    if (revision > 100_000) invalidRequest();
    return {
      turnId: uuid(value.turnId),
      revision,
      text: boundedString(value.text, 0, 32_000, true),
    };
  }
  if (kind === "assistant.completed") {
    exactKeys(value, ["turnId", "text"]);
    return {
      turnId: uuid(value.turnId),
      text: boundedString(value.text, 1, 32_000, true),
    };
  }
  if (kind === "turn.error") {
    exactKeys(value, ["turnId", "code", "message", "retryable"]);
    const code = boundedString(value.code, 1, 64);
    if (!SAFE_ERROR_CODE.test(code) || typeof value.retryable !== "boolean") {
      invalidRequest();
    }
    return {
      turnId: uuid(value.turnId),
      code,
      message: boundedString(value.message, 1, 240),
      retryable: value.retryable,
    };
  }
  exactKeys(value, ["turnId"]);
  return { turnId: uuid(value.turnId) };
}

export function parseConnectorFrame(value: unknown): ConnectorFrame {
  if (!isRecord(value)) invalidRequest();
  exactKeys(
    value,
    ["v", "kind", "connectionId", "messageId", "seq", "sentAt", "payload"],
    ["conversationId", "replyTo"],
  );
  if (value.v !== 1 || typeof value.kind !== "string") invalidRequest();
  if (!FRAME_KINDS.has(value.kind as FrameKind)) invalidRequest();
  const kind = value.kind as FrameKind;
  const requiresConversation = !["ack", "heartbeat"].includes(kind);
  const conversationId =
    value.conversationId === undefined ? undefined : uuid(value.conversationId);
  if (requiresConversation && conversationId === undefined) invalidRequest();
  const replyTo =
    value.replyTo === undefined ? undefined : positiveInteger(value.replyTo);
  return {
    v: 1,
    kind,
    connectionId: uuid(value.connectionId),
    ...(conversationId === undefined ? {} : { conversationId }),
    messageId: uuid(value.messageId),
    seq: positiveInteger(value.seq),
    ...(replyTo === undefined ? {} : { replyTo }),
    sentAt: nonnegativeInteger(value.sentAt),
    payload: parsePayload(kind, value.payload),
  };
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (header === null || !header.startsWith("Bearer ")) return null;
  const token = header.slice(7);
  if (!/^[A-Za-z0-9_-]{40,128}$/.test(token)) return null;
  return token;
}

export function uuidPath(value: string): boolean {
  return UUID.test(value);
}
