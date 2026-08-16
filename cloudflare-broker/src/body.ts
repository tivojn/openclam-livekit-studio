import { HttpError } from "./errors";

export const SESSION_REQUEST_LIMIT_BYTES = 32_768;
export const CLAIM_REQUEST_LIMIT_BYTES = 4_096;

const decoder = new TextDecoder("utf-8", { fatal: true });

export interface BoundedRequestBody {
  bytes: Uint8Array<ArrayBuffer>;
  text: string;
}

async function cancelQuietly(
  reader: ReadableStreamDefaultReader<Uint8Array<ArrayBufferLike>>,
): Promise<void> {
  try {
    await reader.cancel("request_too_large");
  } catch {
    // The limit decision must not depend on whether the remote stream accepts
    // cancellation.
  }
}

/**
 * Reads at most `limitBytes` from an untrusted request stream.
 *
 * Content-Length is only an early rejection hint: the streaming counter is the
 * authority, so missing, incorrect, and chunked lengths cannot bypass the cap.
 * A single fixed-size buffer is allocated and an overflowing chunk is never
 * copied into it.
 */
export async function readBoundedRequestBody(
  request: Request,
  limitBytes: number,
): Promise<BoundedRequestBody> {
  if (!Number.isSafeInteger(limitBytes) || limitBytes < 1) {
    throw new Error("invalid_request_body_limit");
  }

  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null && /^\d+$/.test(contentLength)) {
    const advertisedBytes = Number(contentLength);
    if (!Number.isSafeInteger(advertisedBytes) || advertisedBytes > limitBytes) {
      throw new HttpError(413, "request_too_large");
    }
  }

  const buffer: Uint8Array<ArrayBuffer> = new Uint8Array(limitBytes);
  let bytesRead = 0;

  if (request.body !== null) {
    const reader = request.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        if (value.byteLength > limitBytes - bytesRead) {
          await cancelQuietly(reader);
          throw new HttpError(413, "request_too_large");
        }
        buffer.set(value, bytesRead);
        bytesRead += value.byteLength;
      }
    } finally {
      reader.releaseLock();
    }
  }

  const bytes = buffer.subarray(0, bytesRead);
  try {
    return { bytes, text: decoder.decode(bytes) };
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}

export function parseJsonBody(body: string): unknown {
  try {
    return JSON.parse(body);
  } catch {
    throw new HttpError(400, "invalid_json");
  }
}
