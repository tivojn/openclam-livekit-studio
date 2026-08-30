import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { describe, expect, it, vi } from "vitest";
import { uploadOpenClamAttachment } from "../src/attachment-upload.js";

describe("OpenClam attachment upload", () => {
  it("retries response loss with the same attachment identity and exact digest", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    const body = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
    const urls: string[] = [];
    const headers: Headers[] = [];
    let attempts = 0;
    const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      attempts += 1;
      const url = String(input);
      urls.push(url);
      headers.push(new Headers(init?.headers));
      if (attempts === 1) throw new Error("response_lost");
      const attachmentId = url.split("/").at(-1) ?? "";
      const sha256 = headers.at(-1)?.get("X-OpenClam-SHA256") ?? "";
      return Response.json({
        v: 1,
        attachmentId,
        fileName: "ara.png",
        mediaType: "image/png",
        byteCount: body.byteLength,
        sha256,
        downloadPath: `/v1/connectors/${connectionId}/attachments/${attachmentId}`,
        expiresAt: Date.now() + 60_000,
      }, { status: 201 });
    });

    const result = await uploadOpenClamAttachment({
      bridgeUrl: "https://bridge.example/",
      connectionId,
      token: "T".repeat(48),
      conversationId,
      turnId,
      attachment: { fileName: "ara.png", mediaType: "image/png", buffer: body },
      fetchImpl: fetchImpl as typeof fetch,
    });

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(new Set(urls).size).toBe(1);
    expect(result.attachmentId).toBe(urls[0]?.split("/").at(-1));
    expect(Object.keys(result).sort()).toEqual([
      "attachmentId",
      "byteCount",
      "downloadPath",
      "expiresAt",
      "fileName",
      "mediaType",
      "sha256",
    ]);
    expect(result).not.toHaveProperty("v");
    expect(headers[0]?.get("Authorization")).toBe(`Bearer ${"T".repeat(48)}`);
    expect(headers[0]?.get("Content-Length")).toBeNull();
    expect(headers[0]?.get("X-OpenClam-SHA256")).toBe(
      createHash("sha256").update(body).digest("hex"),
    );
    expect(headers[0]?.get("X-OpenClam-File-Name-B64")).not.toContain("ara.png");
  });

  it("rejects response metadata substitution and path-like filenames", async () => {
    const common = {
      bridgeUrl: "https://bridge.example/",
      connectionId: randomUUID(),
      token: "T".repeat(48),
      conversationId: randomUUID(),
      turnId: randomUUID(),
    };
    await expect(uploadOpenClamAttachment({
      ...common,
      attachment: {
        fileName: "/srv/private/secret.png",
        mediaType: "image/png",
        buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      },
      fetchImpl: vi.fn() as unknown as typeof fetch,
    })).rejects.toThrow("invalid_attachment");

    await expect(uploadOpenClamAttachment({
      ...common,
      attachment: {
        fileName: "safe.png",
        mediaType: "image/png",
        buffer: Buffer.from([0x89, 0x50, 0x4e, 0x47]),
      },
      fetchImpl: vi.fn(async (input: string | URL | Request) => {
        const attachmentId = String(input).split("/").at(-1);
        return Response.json({
          v: 1,
          attachmentId,
          fileName: "substituted.png",
          mediaType: "image/png",
          byteCount: 4,
          sha256: "0".repeat(64),
          downloadPath: `/v1/connectors/${common.connectionId}/attachments/${attachmentId}`,
          expiresAt: Date.now() + 60_000,
        }, { status: 201 });
      }) as unknown as typeof fetch,
    })).rejects.toThrow("invalid_attachment_response");
  });

  it("lets Node fetch send an exact Content-Length and Buffer body on the wire", async () => {
    const connectionId = randomUUID();
    const conversationId = randomUUID();
    const turnId = randomUUID();
    const body = Buffer.from([0x00, 0x89, 0x50, 0x4e, 0x47, 0xff]);
    let observedLength: string | undefined;
    let observedBody = Buffer.alloc(0);
    const server = createServer((request, response) => {
      const chunks: Buffer[] = [];
      request.on("data", (chunk: Buffer) => chunks.push(Buffer.from(chunk)));
      request.on("end", () => {
        observedLength = request.headers["content-length"];
        observedBody = Buffer.concat(chunks);
        const attachmentId = request.url?.split("/").at(-1) ?? "";
        response.writeHead(201, { "Content-Type": "application/json" });
        response.end(JSON.stringify({
          v: 1,
          attachmentId,
          fileName: "wire.png",
          mediaType: "image/png",
          byteCount: body.byteLength,
          sha256: createHash("sha256").update(body).digest("hex"),
          downloadPath: `/v1/connectors/${connectionId}/attachments/${attachmentId}`,
          expiresAt: Date.now() + 60_000,
        }));
      });
    });

    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    try {
      const address = server.address() as AddressInfo;
      await uploadOpenClamAttachment({
        bridgeUrl: `http://127.0.0.1:${address.port}/`,
        connectionId,
        token: "T".repeat(48),
        conversationId,
        turnId,
        attachment: { fileName: "wire.png", mediaType: "image/png", buffer: body },
      });
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => error ? reject(error) : resolve());
      });
    }

    expect(observedLength).toBe(String(body.byteLength));
    expect(observedBody).toEqual(body);
  });
});
