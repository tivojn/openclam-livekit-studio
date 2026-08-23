import { randomUUID } from "node:crypto";
import {
  IDENTIFIER_PATTERN,
  type BridgeInbound,
  type ClientFrame,
  type ConnectorFrame,
  type CreatePairingResponse,
  type FrameKind,
  UUID_PATTERN,
} from "./types.js";

export const FRAME_LIMIT_BYTES = 65_536;
export const MAX_TEXT_LENGTH = 32_000;
const SAFE_ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/u;
const PAIRING_CODE = /^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/u;
const TOKEN = /^[A-Za-z0-9_-]{40,128}$/u;
const FRAME_KINDS = new Set<FrameKind>([
  "ack",
  "heartbeat",
  "turn.submit",
  "turn.accepted",
  "assistant.delta",
  "assistant.activity.upsert",
  "assistant.activity.clear",
  "assistant.work.upsert",
  "assistant.attachment",
  "assistant.completed",
  "turn.cancel",
  "turn.error",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): boolean {
  const accepted = new Set([...required, ...optional]);
  return (
    required.every((key) => key in value) &&
    Object.keys(value).every((key) => accepted.has(key))
  );
}

function validSafeInteger(value: unknown, minimum: number): value is number {
  return Number.isSafeInteger(value) && (value as number) >= minimum;
}

function validString(value: unknown, min: number, max: number): value is string {
  return typeof value === "string" && [...value].length >= min && [...value].length <= max;
}

export function parseBridgeInbound(raw: string, expectedConnectionId: string): BridgeInbound {
  if (Buffer.byteLength(raw, "utf8") > FRAME_LIMIT_BYTES) {
    throw new Error("frame_too_large");
  }
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("invalid_frame");
  }
  if (isRecord(value) && value.kind === "relay.persisted") {
    if (
      !exactKeys(value, ["v", "kind", "connectionId", "payload"]) ||
      value.v !== 1 ||
      value.connectionId !== expectedConnectionId ||
      !UUID_PATTERN.test(String(value.connectionId)) ||
      !isRecord(value.payload) ||
      !exactKeys(value.payload, ["senderSeq", "messageId"]) ||
      !validSafeInteger(value.payload.senderSeq, 1) ||
      !UUID_PATTERN.test(String(value.payload.messageId))
    ) {
      throw new Error("invalid_frame");
    }
    return value as BridgeInbound;
  }
  if (
    !isRecord(value) ||
    !exactKeys(
      value,
      ["v", "kind", "connectionId", "messageId", "seq", "sentAt", "payload"],
      ["conversationId", "replyTo"],
    ) ||
    value.v !== 1 ||
    typeof value.kind !== "string" ||
    !FRAME_KINDS.has(value.kind as FrameKind) ||
    value.connectionId !== expectedConnectionId ||
    !UUID_PATTERN.test(String(value.connectionId)) ||
    !UUID_PATTERN.test(String(value.messageId)) ||
    !validSafeInteger(value.seq, 1) ||
    !validSafeInteger(value.sentAt, 0) ||
    !isRecord(value.payload)
  ) {
    throw new Error("invalid_frame");
  }
  const kind = value.kind as FrameKind;
  if (!["heartbeat", "turn.submit", "turn.cancel"].includes(kind)) {
    throw new Error("invalid_client_kind");
  }
  if (kind === "heartbeat") {
    if (!exactKeys(value.payload, [], ["lastReceivedSeq"])) throw new Error("invalid_frame");
    if (
      value.payload.lastReceivedSeq !== undefined &&
      !validSafeInteger(value.payload.lastReceivedSeq, 0)
    ) {
      throw new Error("invalid_frame");
    }
    return value as ClientFrame;
  }
  if (!UUID_PATTERN.test(String(value.conversationId))) throw new Error("invalid_frame");
  if (!exactKeys(
    value.payload,
    kind === "turn.submit" ? ["turnId", "accountId", "text"] : ["turnId"],
    kind === "turn.submit" ? ["capabilities"] : [],
  )) {
    throw new Error("invalid_frame");
  }
  if (!UUID_PATTERN.test(String(value.payload.turnId))) throw new Error("invalid_frame");
  if (kind === "turn.submit") {
    if (
      !IDENTIFIER_PATTERN.test(String(value.payload.accountId)) ||
      !validString(value.payload.text, 1, MAX_TEXT_LENGTH) ||
      (value.payload.capabilities !== undefined &&
        (!Array.isArray(value.payload.capabilities) ||
          value.payload.capabilities.length > 3 ||
          new Set(value.payload.capabilities).size !== value.payload.capabilities.length ||
          value.payload.capabilities.some(
            (capability) => capability !== "activity-v1" && capability !== "attachments-v1" && capability !== "work-v1",
          )))
    ) {
      throw new Error("invalid_frame");
    }
  }
  return value as ClientFrame;
}

export function parseClientFrame(raw: string, expectedConnectionId: string): ClientFrame {
  const value = parseBridgeInbound(raw, expectedConnectionId);
  if (value.kind === "relay.persisted") throw new Error("invalid_client_kind");
  return value;
}

export function parseCreatePairingResponse(value: unknown): CreatePairingResponse {
  if (
    !isRecord(value) ||
    !exactKeys(value, ["v", "pairingId", "connectionId", "code", "expiresAt", "adapterToken"]) ||
    value.v !== 1 ||
    !UUID_PATTERN.test(String(value.pairingId)) ||
    !UUID_PATTERN.test(String(value.connectionId)) ||
    !PAIRING_CODE.test(String(value.code)) ||
    !validSafeInteger(value.expiresAt, 0) ||
    !TOKEN.test(String(value.adapterToken))
  ) {
    throw new Error("invalid_pairing_response");
  }
  return value as CreatePairingResponse;
}

export function createFrame(params: {
  kind: FrameKind;
  connectionId: string;
  seq: number;
  conversationId?: string;
  replyTo?: number;
  payload: Record<string, unknown>;
}): ConnectorFrame {
  return {
    v: 1,
    kind: params.kind,
    connectionId: params.connectionId,
    ...(params.conversationId ? { conversationId: params.conversationId } : {}),
    messageId: randomUUID(),
    seq: params.seq,
    ...(params.replyTo ? { replyTo: params.replyTo } : {}),
    sentAt: Date.now(),
    payload: params.payload,
  };
}

export function safeTurnErrorPayload(params: {
  turnId: string;
  code: string;
  message: string;
  retryable: boolean;
}): Record<string, unknown> {
  const code = SAFE_ERROR_CODE.test(params.code) ? params.code : "agent_failed";
  const message = truncateUnicode(params.message.trim(), 240) || "The OpenClaw turn failed.";
  return { turnId: params.turnId, code, message, retryable: params.retryable };
}

export function truncateUnicode(value: string, maximumCodePoints: number): string {
  if (maximumCodePoints < 1) return "";
  let count = 0;
  let end = 0;
  for (const codePoint of value) {
    if (count >= maximumCodePoints) break;
    end += codePoint.length;
    count += 1;
  }
  return end === value.length ? value : value.slice(0, end);
}

export function encodeFrame(frame: ConnectorFrame): string {
  const encoded = JSON.stringify(frame);
  if (Buffer.byteLength(encoded, "utf8") > FRAME_LIMIT_BYTES) {
    throw new Error("frame_too_large");
  }
  return encoded;
}

export function encodeFrameWithTextBudget(
  frame: ConnectorFrame,
  payloadKey: "text" | "message",
): { frame: ConnectorFrame; encoded: string } {
  const text = frame.payload[payloadKey];
  if (typeof text !== "string") return { frame, encoded: encodeFrame(frame) };
  const direct = JSON.stringify(frame);
  if (Buffer.byteLength(direct, "utf8") <= FRAME_LIMIT_BYTES) {
    return { frame, encoded: direct };
  }
  const codePoints = Array.from(text);
  let lower = 0;
  let upper = codePoints.length;
  let fittedFrame: ConnectorFrame | undefined;
  let fittedEncoded: string | undefined;
  while (lower <= upper) {
    const middle = Math.floor((lower + upper) / 2);
    const candidate: ConnectorFrame = {
      ...frame,
      payload: { ...frame.payload, [payloadKey]: codePoints.slice(0, middle).join("") },
    };
    const encoded = JSON.stringify(candidate);
    if (Buffer.byteLength(encoded, "utf8") <= FRAME_LIMIT_BYTES) {
      fittedFrame = candidate;
      fittedEncoded = encoded;
      lower = middle + 1;
    } else {
      upper = middle - 1;
    }
  }
  if (!fittedFrame || !fittedEncoded || fittedFrame.payload[payloadKey] === "") {
    throw new Error("frame_too_large");
  }
  return { frame: fittedFrame, encoded: fittedEncoded };
}
