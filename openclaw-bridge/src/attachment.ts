import { DurableObject } from "cloudflare:workers";
import type { AttachmentBlobRecord } from "./types";

const META_KEY = "attachment";
const CHUNK_PREFIX = "chunk:";
const CHUNK_BYTES = 512 * 1_024;
const MAX_ATTACHMENT_BYTES = 32 * 1_024 * 1_024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const MEDIA_TYPE = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,62}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,62}$/;

const ZIP_MEDIA = new Set([
  "application/zip",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.presentation",
  "application/vnd.oasis.opendocument.spreadsheet",
]);
const OLE_MEDIA = new Set([
  "application/msword",
  "application/vnd.ms-powerpoint",
  "application/vnd.ms-excel",
]);
const TEXT_MEDIA = new Set([
  "text/plain",
  "text/csv",
  "text/markdown",
  "application/json",
]);

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
}

function chunkKey(index: number): string {
  return `${CHUNK_PREFIX}${index.toString().padStart(4, "0")}`;
}

function header(request: Request, name: string): string {
  const value = request.headers.get(name);
  if (value === null) throw new Error("invalid_attachment_metadata");
  return value;
}

function integerHeader(request: Request, name: string): number {
  const raw = header(request, name);
  if (!/^(0|[1-9][0-9]*)$/u.test(raw)) throw new Error("invalid_attachment_metadata");
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) throw new Error("invalid_attachment_metadata");
  return value;
}

function decodeFileName(value: string): string {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error("invalid_attachment_metadata");
  const normalized = value.replace(/-/gu, "+").replace(/_/gu, "/");
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const bytes = Uint8Array.from(atob(padded), (char) =>
    char.charCodeAt(0),
  );
  const decoded = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (
    [...decoded].length < 1 ||
    [...decoded].length > 160 ||
    /[\u0000-\u001f\u007f\\/]/u.test(decoded) ||
    decoded === "." ||
    decoded === ".."
  ) {
    throw new Error("invalid_attachment_metadata");
  }
  return decoded;
}

function parseMetadata(request: Request): AttachmentBlobRecord {
  const connectionId = header(request, "X-OpenClam-Connection-Id");
  const attachmentId = header(request, "X-OpenClam-Attachment-Id");
  const fileName = decodeFileName(header(request, "X-OpenClam-File-Name-B64"));
  const mediaType = header(request, "X-OpenClam-Media-Type");
  const byteCount = integerHeader(request, "X-OpenClam-Byte-Count");
  const sha256 = header(request, "X-OpenClam-SHA256");
  const createdAt = integerHeader(request, "X-OpenClam-Created-At");
  const expiresAt = integerHeader(request, "X-OpenClam-Expires-At");
  if (
    !UUID.test(connectionId) ||
    !UUID.test(attachmentId) ||
    !MEDIA_TYPE.test(mediaType) ||
    byteCount < 1 ||
    byteCount > MAX_ATTACHMENT_BYTES ||
    !SHA256.test(sha256) ||
    expiresAt <= createdAt
  ) {
    throw new Error("invalid_attachment_metadata");
  }
  return {
    v: 1,
    connectionId,
    attachmentId,
    fileName,
    mediaType,
    byteCount,
    sha256,
    chunkCount: Math.ceil(byteCount / CHUNK_BYTES),
    createdAt,
    expiresAt,
  };
}

function exactMetadata(left: AttachmentBlobRecord, right: AttachmentBlobRecord): boolean {
  return (
    left.connectionId === right.connectionId &&
    left.attachmentId === right.attachmentId &&
    left.fileName === right.fileName &&
    left.mediaType === right.mediaType &&
    left.byteCount === right.byteCount &&
    left.sha256 === right.sha256 &&
    left.expiresAt === right.expiresAt
  );
}

function startsWith(bytes: Uint8Array, signature: readonly number[], offset = 0): boolean {
  return signature.every((value, index) => bytes[offset + index] === value);
}

function ascii(bytes: Uint8Array, offset: number, count: number): string {
  return String.fromCharCode(...bytes.slice(offset, offset + count));
}

function validText(bytes: Uint8Array, mediaType: string): boolean {
  if (bytes.some((value) => value === 0)) return false;
  const value = new TextDecoder("utf-8").decode(bytes).trimStart();
  return mediaType !== "application/json" || value.startsWith("{") || value.startsWith("[");
}

function validMagic(mediaType: string, bytes: Uint8Array): boolean {
  if (TEXT_MEDIA.has(mediaType)) return validText(bytes, mediaType);
  if (ZIP_MEDIA.has(mediaType)) return startsWith(bytes, [0x50, 0x4b, 0x03, 0x04]);
  if (OLE_MEDIA.has(mediaType)) {
    return startsWith(bytes, [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]);
  }
  if (mediaType === "application/pdf") return ascii(bytes, 0, 5) === "%PDF-";
  if (mediaType === "application/rtf") return ascii(bytes, 0, 5) === "{\\rtf";
  if (mediaType === "image/png") {
    return startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  }
  if (mediaType === "image/jpeg") return startsWith(bytes, [0xff, 0xd8, 0xff]);
  if (mediaType === "image/gif") {
    const value = ascii(bytes, 0, 6);
    return value === "GIF87a" || value === "GIF89a";
  }
  if (mediaType === "image/webp") {
    return ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP";
  }
  if (mediaType === "audio/wav" || mediaType === "audio/x-wav") {
    return ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WAVE";
  }
  if (mediaType === "audio/ogg") return ascii(bytes, 0, 4) === "OggS";
  if (mediaType === "audio/flac") return ascii(bytes, 0, 4) === "fLaC";
  if (mediaType === "audio/mpeg") {
    return ascii(bytes, 0, 3) === "ID3" || (bytes[0] === 0xff && (bytes[1] ?? 0) >= 0xe0);
  }
  if (mediaType === "video/webm" || mediaType === "audio/webm") {
    return startsWith(bytes, [0x1a, 0x45, 0xdf, 0xa3]);
  }
  if (
    mediaType === "video/mp4" ||
    mediaType === "video/quicktime" ||
    mediaType === "audio/mp4"
  ) {
    return ascii(bytes, 4, 4) === "ftyp";
  }
  return false;
}

function contentDisposition(): string {
  return "attachment";
}

export class ConnectorAttachment extends DurableObject<Env> {
  private operationQueue: Promise<void> = Promise.resolve();

  override fetch(request: Request): Promise<Response> {
    return this.enqueue(() => this.route(request));
  }

  override alarm(): Promise<void> {
    return this.enqueue(() => this.deleteAll());
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operationQueue.then(operation);
    this.operationQueue = result.then(() => undefined, () => undefined);
    return result;
  }

  private async route(request: Request): Promise<Response> {
    const pathname = new URL(request.url).pathname;
    if (request.method === "PUT" && pathname === "/internal/upload") {
      return this.upload(request);
    }
    if (request.method === "GET" && pathname === "/internal/download") {
      return this.download();
    }
    if (request.method === "DELETE" && pathname === "/internal/delete") {
      await this.deleteAll();
      return new Response(null, { status: 204 });
    }
    return json({ error: "not_found" }, 404);
  }

  private async upload(request: Request): Promise<Response> {
    let expected: AttachmentBlobRecord;
    try {
      expected = parseMetadata(request);
    } catch {
      return json({ error: "invalid_request" }, 400);
    }
    const existing = await this.ctx.storage.get<AttachmentBlobRecord>(META_KEY);
    if (existing !== undefined) {
      if (!exactMetadata(existing, expected)) return json({ error: "conflict" }, 409);
      return json(existing);
    }
    if (request.body === null) return json({ error: "invalid_request" }, 400);

    const contentLength = request.headers.get("Content-Length");
    if (contentLength !== String(expected.byteCount)) {
      return json({ error: "invalid_request" }, 400);
    }
    // Set the bounded cleanup owner before reading the first byte so a
    // cancelled upload cannot strand partial chunk rows.
    await this.ctx.storage.setAlarm(expected.expiresAt);

    const reader = request.body.getReader();
    let magicPrefix = new Uint8Array(0);
    let carry = new Uint8Array(0);
    let received = 0;
    let chunkIndex = 0;
    try {
      while (true) {
        const item = await reader.read();
        if (item.done) break;
        const incoming = item.value;
        received += incoming.byteLength;
        if (received > expected.byteCount || received > MAX_ATTACHMENT_BYTES) {
          throw new Error("attachment_too_large");
        }
        if (magicPrefix.byteLength < 8_192) {
          const take = Math.min(8_192 - magicPrefix.byteLength, incoming.byteLength);
          const nextPrefix = new Uint8Array(magicPrefix.byteLength + take);
          nextPrefix.set(magicPrefix);
          nextPrefix.set(incoming.slice(0, take), magicPrefix.byteLength);
          magicPrefix = nextPrefix;
        }
        let offset = 0;
        if (carry.byteLength > 0) {
          const needed = CHUNK_BYTES - carry.byteLength;
          const take = Math.min(needed, incoming.byteLength);
          const nextCarry = new Uint8Array(carry.byteLength + take);
          nextCarry.set(carry);
          nextCarry.set(incoming.slice(0, take), carry.byteLength);
          carry = nextCarry;
          offset = take;
          if (carry.byteLength === CHUNK_BYTES) {
            await this.ctx.storage.put(chunkKey(chunkIndex), carry);
            chunkIndex += 1;
            carry = new Uint8Array(0);
          }
        }
        while (incoming.byteLength - offset >= CHUNK_BYTES) {
          const chunk = incoming.slice(offset, offset + CHUNK_BYTES);
          await this.ctx.storage.put(chunkKey(chunkIndex), chunk);
          chunkIndex += 1;
          offset += CHUNK_BYTES;
        }
        if (offset < incoming.byteLength) carry = incoming.slice(offset);
      }
      if (received !== expected.byteCount) throw new Error("attachment_size_mismatch");
      if (carry.byteLength > 0) {
        await this.ctx.storage.put(chunkKey(chunkIndex), carry);
        chunkIndex += 1;
      }
      if (chunkIndex !== expected.chunkCount) throw new Error("attachment_chunk_mismatch");
      if (!validMagic(expected.mediaType, magicPrefix)) {
        throw new Error("attachment_verification_failed");
      }
      await this.ctx.storage.put(META_KEY, expected);
      await this.ctx.storage.setAlarm(expected.expiresAt);
      return json(expected, 201);
    } catch {
      await this.deleteAll();
      return json({ error: "invalid_attachment" }, 400);
    } finally {
      reader.releaseLock();
    }
  }

  private async download(): Promise<Response> {
    const metadata = await this.ctx.storage.get<AttachmentBlobRecord>(META_KEY);
    if (metadata === undefined || metadata.expiresAt <= Date.now()) {
      if (metadata !== undefined) await this.deleteAll();
      return json({ error: "not_found" }, 404);
    }
    const storage = this.ctx.storage;
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        try {
          for (let index = 0; index < metadata.chunkCount; index += 1) {
            const value = await storage.get<Uint8Array | ArrayBuffer>(chunkKey(index));
            if (value === undefined) throw new Error("attachment_chunk_missing");
            controller.enqueue(value instanceof Uint8Array ? value : new Uint8Array(value));
          }
          controller.close();
        } catch (error) {
          controller.error(error);
        }
      },
    });
    return new Response(stream, {
      status: 200,
      headers: {
        "Cache-Control": "private, no-store",
        "Content-Disposition": contentDisposition(),
        "Content-Length": String(metadata.byteCount),
        "Content-Type": metadata.mediaType,
        ETag: `"${metadata.sha256}"`,
        "X-Content-Type-Options": "nosniff",
      },
    });
  }

  private async deleteAll(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }
}
