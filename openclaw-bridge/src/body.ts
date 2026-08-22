import { HttpError } from "./errors";

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
    // The size decision does not depend on remote cancellation succeeding.
  }
}

export async function readBoundedRequestBody(
  request: Request,
  limitBytes: number,
): Promise<BoundedRequestBody> {
  if (!Number.isSafeInteger(limitBytes) || limitBytes < 1) {
    throw new Error("invalid_body_limit");
  }

  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null && /^\d+$/.test(contentLength)) {
    const advertised = Number(contentLength);
    if (!Number.isSafeInteger(advertised) || advertised > limitBytes) {
      throw new HttpError(413, "invalid_request");
    }
  }

  const buffer: Uint8Array<ArrayBuffer> = new Uint8Array(limitBytes);
  let length = 0;
  if (request.body !== null) {
    const reader = request.body.getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value.byteLength > limitBytes - length) {
          await cancelQuietly(reader);
          throw new HttpError(413, "invalid_request");
        }
        buffer.set(value, length);
        length += value.byteLength;
      }
    } finally {
      reader.releaseLock();
    }
  }

  const bytes = buffer.subarray(0, length);
  try {
    return { bytes, text: decoder.decode(bytes) };
  } catch {
    throw new HttpError(400, "invalid_request");
  }
}

export function parseJsonBody(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_request");
  }
}
