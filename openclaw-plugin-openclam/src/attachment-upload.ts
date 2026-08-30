import { createHash, randomUUID } from "node:crypto";
import type {
  OpenClamAttachment,
  OpenClamAttachmentUpload,
} from "./types.js";
import { UUID_PATTERN } from "./types.js";

const SHA256 = /^[0-9a-f]{64}$/u;
const MEDIA_TYPE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$/u;

export class OpenClamAttachmentUploadError extends Error {
  constructor(readonly diagnostic: string) {
    super("attachment_upload_failed");
    this.name = "OpenClamAttachmentUploadError";
  }
}

function networkDiagnostic(error: unknown, aborted: boolean): string {
  const name = error instanceof Error ? error.name : "unknown";
  const cause = error instanceof Error && isRecord(error.cause) ? error.cause : undefined;
  const rawCode = typeof cause?.code === "string" ? cause.code : "";
  const code = /^[A-Z0-9_]{1,64}$/u.test(rawCode) ? `_${rawCode}` : "";
  const rawMessage = typeof cause?.message === "string" ? cause.message : "";
  const message = rawMessage
    .replace(/[^A-Za-z0-9]+/gu, "_")
    .replace(/^_+|_+$/gu, "")
    .slice(0, 96);
  return `network_${name}${code}${message ? `_${message}` : ""}${aborted ? "_aborted" : ""}`;
}

function buildUploadUrl(
  bridgeUrl: string,
  connectionId: string,
  attachmentId: string,
): string {
  const url = new URL(bridgeUrl);
  if (url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("invalid_bridge_url");
  }
  const local = ["localhost", "127.0.0.1", "::1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) {
    throw new Error("invalid_bridge_url");
  }
  url.pathname = `/v1/adapters/${connectionId}/attachments/${attachmentId}`;
  return url.toString();
}

function fileNameHeader(fileName: string): string {
  return Buffer.from(fileName, "utf8").toString("base64url");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length && keys.every((key) => key in value);
}

function parseUploadResponse(
  value: unknown,
  expected: Omit<OpenClamAttachment, "expiresAt" | "downloadPath">,
  connectionId: string,
): OpenClamAttachment {
  if (
    !isRecord(value) ||
    !exactKeys(value, [
      "v",
      "attachmentId",
      "fileName",
      "mediaType",
      "byteCount",
      "sha256",
      "downloadPath",
      "expiresAt",
    ]) ||
    value.v !== 1 ||
    value.attachmentId !== expected.attachmentId ||
    value.fileName !== expected.fileName ||
    value.mediaType !== expected.mediaType ||
    value.byteCount !== expected.byteCount ||
    value.sha256 !== expected.sha256 ||
    value.downloadPath !==
      `/v1/connectors/${connectionId}/attachments/${expected.attachmentId}` ||
    !Number.isSafeInteger(value.expiresAt) ||
    (value.expiresAt as number) <= Date.now()
  ) {
    throw new Error("invalid_attachment_response");
  }
  return {
    attachmentId: expected.attachmentId,
    fileName: expected.fileName,
    mediaType: expected.mediaType,
    byteCount: expected.byteCount,
    sha256: expected.sha256,
    downloadPath: value.downloadPath as string,
    expiresAt: value.expiresAt as number,
  };
}

export async function uploadOpenClamAttachment(params: {
  bridgeUrl: string;
  connectionId: string;
  token: string;
  conversationId: string;
  turnId: string;
  attachment: OpenClamAttachmentUpload;
  signal?: AbortSignal;
  fetchImpl?: typeof fetch;
}): Promise<OpenClamAttachment> {
  const attachmentId = randomUUID();
  const byteCount = params.attachment.buffer.byteLength;
  const sha256 = createHash("sha256").update(params.attachment.buffer).digest("hex");
  if (
    !UUID_PATTERN.test(params.connectionId) ||
    !UUID_PATTERN.test(params.conversationId) ||
    !UUID_PATTERN.test(params.turnId) ||
    !UUID_PATTERN.test(attachmentId) ||
    byteCount < 1 ||
    byteCount > 32 * 1_024 * 1_024 ||
    [...params.attachment.fileName].length < 1 ||
    [...params.attachment.fileName].length > 160 ||
    /[\u0000-\u001f\u007f\\/]/u.test(params.attachment.fileName) ||
    params.attachment.fileName === "." ||
    params.attachment.fileName === ".." ||
    !MEDIA_TYPE.test(params.attachment.mediaType) ||
    !SHA256.test(sha256)
  ) {
    throw new Error("invalid_attachment");
  }
  const expected = {
    attachmentId,
    fileName: params.attachment.fileName,
    mediaType: params.attachment.mediaType,
    byteCount,
    sha256,
  };
  const url = buildUploadUrl(params.bridgeUrl, params.connectionId, attachmentId);
  let response: Response | undefined;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      response = await (params.fetchImpl ?? fetch)(url, {
        method: "PUT",
        redirect: "error",
        signal: params.signal,
        headers: {
          Authorization: `Bearer ${params.token}`,
          "Content-Type": params.attachment.mediaType,
          "X-OpenClam-Conversation-Id": params.conversationId,
          "X-OpenClam-File-Name-B64": fileNameHeader(params.attachment.fileName),
          "X-OpenClam-SHA256": sha256,
          "X-OpenClam-Turn-Id": params.turnId,
        },
        body: Buffer.from(params.attachment.buffer),
      });
    } catch (error) {
      if (params.signal?.aborted || attempt === 2) {
        throw new OpenClamAttachmentUploadError(
          networkDiagnostic(error, params.signal?.aborted === true),
        );
      }
      continue;
    }
    if (response.status === 201) break;
    if (response.status < 500 || attempt === 2) {
      throw new OpenClamAttachmentUploadError(`http_${response.status}`);
    }
  }
  if (response?.status !== 201) {
    throw new OpenClamAttachmentUploadError(`http_${response?.status ?? "none"}`);
  }
  const raw = await response.text();
  if (Buffer.byteLength(raw, "utf8") > 8_192) throw new Error("invalid_attachment_response");
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error("invalid_attachment_response");
  }
  return parseUploadResponse(value, expected, params.connectionId);
}
