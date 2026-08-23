import { invalidRequest } from "./errors";
import type {
  AccountDescriptor,
  ActivityStatus,
  ConnectorCapability,
  ConnectorFrame,
  CreatePairingRequest,
  FrameKind,
  RedeemPairingRequest,
  WorkCategory,
  WorkState,
} from "./types";

export const CREATE_BODY_LIMIT_BYTES = 16_384;
export const REDEEM_BODY_LIMIT_BYTES = 2_048;
export const FRAME_LIMIT_BYTES = 65_536;
export const MAX_ATTACHMENT_BYTES = 33_554_432;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const PAIRING_CODE = /^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;
const SAFE_ERROR_CODE = /^[a-z][a-z0-9_]{0,63}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const MEDIA_TYPE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$/;
const DOWNLOAD_PATH = /^\/v1\/connectors\/([0-9a-f-]{36})\/attachments\/([0-9a-f-]{36})$/;
const CONTROL_CHARACTER = /[\u0000-\u001f\u007f]/u;
const FILE_NAME_SEPARATOR = /[\\/]/u;
const WORK_STEP_ID = /^[a-z0-9][a-z0-9._:-]{0,63}$/u;
const PRIVATE_PATH = /(?:file:\/\/|(?:^|\s)[A-Za-z]:[\\/]|\\\\[^\s\\]+\\|(?:^|\s)\/(?!\/))/iu;
const SECRET_MATERIAL = /(?:authorization\s*:|\bbearer\s+[A-Za-z0-9._~+\/-]+=*|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)\s*[:=])/iu;
const CONNECTOR_CAPABILITIES = new Set<ConnectorCapability>([
  "activity-v1",
  "attachments-v1",
  "work-v1",
]);
const ACTIVITY_STATUSES = new Set<ActivityStatus>([
  "thinking",
  "planning",
  "searching",
  "reading",
  "editing",
  "running_action",
  "using_tools",
  "creating_media",
  "preparing_files",
  "waiting_for_approval",
  "finalizing",
]);
const WORK_CATEGORIES = new Set<WorkCategory>([
  "reasoning_summary", "plan", "tool", "command", "file", "approval", "status",
]);
const WORK_STATES = new Set<WorkState>([
  "running", "completed", "failed", "waiting",
]);
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

function parseCapabilities(value: unknown): ConnectorCapability[] {
  if (!Array.isArray(value) || value.length > 3) invalidRequest();
  const capabilities = value.map((item) => {
    if (typeof item !== "string" || !CONNECTOR_CAPABILITIES.has(item as ConnectorCapability)) {
      invalidRequest();
    }
    return item as ConnectorCapability;
  });
  if (new Set(capabilities).size !== capabilities.length) invalidRequest();
  return capabilities;
}

function nonnegativeInteger(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) invalidRequest();
  return value as number;
}

function safeWorkText(value: unknown, maximum: number): string {
  const parsed = boundedString(value, 1, maximum, true);
  if (PRIVATE_PATH.test(parsed) || SECRET_MATERIAL.test(parsed)) invalidRequest();
  return parsed;
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
    exactKeys(value, ["turnId", "accountId", "text"], ["capabilities"]);
    const accountId = boundedString(value.accountId, 1, 64);
    if (!IDENTIFIER.test(accountId)) invalidRequest();
    return {
      turnId: uuid(value.turnId),
      accountId,
      text: boundedString(value.text, 1, 32_000, true),
      ...(value.capabilities === undefined
        ? {}
        : { capabilities: parseCapabilities(value.capabilities) }),
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
  if (kind === "assistant.activity.upsert") {
    exactKeys(value, ["turnId", "revision", "status"]);
    const revision = positiveInteger(value.revision);
    if (
      revision > 100_000 ||
      typeof value.status !== "string" ||
      !ACTIVITY_STATUSES.has(value.status as ActivityStatus)
    ) {
      invalidRequest();
    }
    return {
      turnId: uuid(value.turnId),
      revision,
      status: value.status,
    };
  }
  if (kind === "assistant.activity.clear") {
    exactKeys(value, ["turnId", "revision"]);
    const revision = positiveInteger(value.revision);
    if (revision > 100_000) invalidRequest();
    return { turnId: uuid(value.turnId), revision };
  }
  if (kind === "assistant.work.upsert") {
    exactKeys(
      value,
      ["turnId", "revision", "stepId", "category", "state", "title"],
      ["detail", "tool", "command", "path", "output"],
    );
    const revision = positiveInteger(value.revision);
    const stepId = boundedString(value.stepId, 1, 64);
    if (
      revision > 100_000 ||
      !WORK_STEP_ID.test(stepId) ||
      typeof value.category !== "string" ||
      !WORK_CATEGORIES.has(value.category as WorkCategory) ||
      typeof value.state !== "string" ||
      !WORK_STATES.has(value.state as WorkState)
    ) {
      invalidRequest();
    }
    const path = value.path === undefined ? undefined : safeWorkText(value.path, 512);
    if (
      path !== undefined &&
      (path.startsWith("/") || /^[A-Za-z]:[\\/]/u.test(path) || path.startsWith("\\\\") ||
        path.startsWith("file:") || path.split("/").includes(".."))
    ) {
      invalidRequest();
    }
    return {
      turnId: uuid(value.turnId),
      revision,
      stepId,
      category: value.category,
      state: value.state,
      title: safeWorkText(value.title, 120),
      ...(value.detail === undefined ? {} : { detail: safeWorkText(value.detail, 1_000) }),
      ...(value.tool === undefined ? {} : { tool: safeWorkText(value.tool, 80) }),
      ...(value.command === undefined ? {} : { command: safeWorkText(value.command, 1_000) }),
      ...(path === undefined ? {} : { path }),
      ...(value.output === undefined ? {} : { output: safeWorkText(value.output, 2_000) }),
    };
  }
  if (kind === "assistant.attachment") {
    exactKeys(value, [
      "turnId",
      "attachmentId",
      "fileName",
      "mediaType",
      "byteCount",
      "sha256",
      "downloadPath",
      "expiresAt",
    ]);
    const attachmentId = uuid(value.attachmentId);
    const fileName = boundedString(value.fileName, 1, 160);
    const mediaType = boundedString(value.mediaType, 3, 127);
    const byteCount = positiveInteger(value.byteCount);
    const sha256 = boundedString(value.sha256, 64, 64);
    const downloadPath = boundedString(value.downloadPath, 100, 100);
    const expiresAt = nonnegativeInteger(value.expiresAt);
    const match = DOWNLOAD_PATH.exec(downloadPath);
    if (
      byteCount > 33_554_432 ||
      FILE_NAME_SEPARATOR.test(fileName) ||
      fileName === "." ||
      fileName === ".." ||
      !MEDIA_TYPE.test(mediaType) ||
      !SHA256.test(sha256) ||
      match?.[2] !== attachmentId
    ) {
      invalidRequest();
    }
    return {
      turnId: uuid(value.turnId),
      attachmentId,
      fileName,
      mediaType,
      byteCount,
      sha256,
      downloadPath,
      expiresAt,
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

export type AttachmentUploadInput = {
  attachmentId: string;
  conversationId: string;
  turnId: string;
  fileName: string;
  mediaType: string;
  byteCount: number;
  sha256: string;
};

function decodeBase64UrlUtf8(value: string): string {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) invalidRequest();
  try {
    const normalized = value.replace(/-/gu, "+").replace(/_/gu, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    invalidRequest();
  }
}

export function parseAttachmentUpload(
  request: Request,
  attachmentIdPath: string,
): AttachmentUploadInput {
  const conversationId = uuid(request.headers.get("X-OpenClam-Conversation-Id"));
  const turnId = uuid(request.headers.get("X-OpenClam-Turn-Id"));
  const fileName = boundedString(
    decodeBase64UrlUtf8(
      boundedString(request.headers.get("X-OpenClam-File-Name-B64"), 1, 1_024),
    ),
    1,
    160,
  );
  const mediaType = boundedString(request.headers.get("Content-Type"), 3, 127);
  const sha256 = boundedString(request.headers.get("X-OpenClam-SHA256"), 64, 64);
  const contentLength = request.headers.get("Content-Length");
  if (
    !uuidPath(attachmentIdPath) ||
    FILE_NAME_SEPARATOR.test(fileName) ||
    fileName === "." ||
    fileName === ".." ||
    !MEDIA_TYPE.test(mediaType) ||
    !SHA256.test(sha256) ||
    contentLength === null ||
    !/^[1-9][0-9]*$/u.test(contentLength) ||
    request.headers.has("Content-Encoding") ||
    request.body === null
  ) {
    invalidRequest();
  }
  const byteCount = Number(contentLength);
  if (!Number.isSafeInteger(byteCount) || byteCount > MAX_ATTACHMENT_BYTES) {
    invalidRequest();
  }
  return {
    attachmentId: attachmentIdPath,
    conversationId,
    turnId,
    fileName,
    mediaType,
    byteCount,
    sha256,
  };
}
