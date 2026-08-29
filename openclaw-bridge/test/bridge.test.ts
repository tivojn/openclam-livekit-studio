import { env } from "cloudflare:workers";
import { reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import {
  decryptPendingFrame,
  encryptPendingFrame,
  pairingVerifier,
  tokenVerifier,
} from "../src/crypto";
import worker from "../src/index";
import type {
  AttachmentBlobRecord,
  AttachmentRecord,
  ConnectorFrame,
  PairingRecord,
  PendingFrame,
  SessionRecord,
  SocketRole,
} from "../src/types";

const BOOTSTRAP_TOKEN =
  "test-bootstrap-token-that-is-at-least-forty-characters-long";
const TEST_KEK = "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=";
const GATEWAY_LABEL = "Zane's OpenClaw";
const openedSockets = new Set<WebSocket>();

interface CreatedPairing {
  v: 1;
  pairingId: string;
  connectionId: string;
  code: string;
  expiresAt: number;
  adapterToken: string;
}

interface RedeemedPairing {
  v: 1;
  connectionId: string;
  gatewayLabel: string;
  accounts: Array<{ accountId: string; agentId: string; displayName: string }>;
  clientToken: string;
}

const accounts = [
  { accountId: "main", agentId: "ara", displayName: "Ara" },
  { accountId: "research", agentId: "researcher", displayName: "Research" },
];

afterEach(async () => {
  for (const socket of openedSockets) {
    if (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN) {
      try {
        socket.close(1000, "test cleanup");
      } catch {
        // The peer may already have completed the close handshake.
      }
    }
  }
  openedSockets.clear();
  await new Promise((resolve) => setTimeout(resolve, 1));
  await reset();
});

function request(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`https://bridge.test${path}`, init), env);
}

function createBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 1,
    adapterId: crypto.randomUUID(),
    gatewayLabel: GATEWAY_LABEL,
    accounts,
    ...overrides,
  };
}

async function createPairing(
  body: unknown = createBody(),
  token = BOOTSTRAP_TOKEN,
): Promise<{ response: Response; value?: CreatedPairing }> {
  const response = await request("/v1/pairings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) return { response };
  return { response, value: await response.json<CreatedPairing>() };
}

async function redeemPairing(
  code: string,
  installationId = crypto.randomUUID(),
): Promise<{ response: Response; value?: RedeemedPairing }> {
  const response = await request("/v1/pairings/redeem", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      v: 1,
      code,
      installationId,
      deviceLabel: "iPhone",
    }),
  });
  if (!response.ok) return { response };
  return { response, value: await response.json<RedeemedPairing>() };
}

async function paired(): Promise<{
  created: CreatedPairing;
  redeemed: RedeemedPairing;
}> {
  const creation = await createPairing();
  expect(creation.response.status).toBe(201);
  if (creation.value === undefined) throw new Error("missing create response");
  const redemption = await redeemPairing(creation.value.code);
  expect(redemption.response.status).toBe(200);
  if (redemption.value === undefined) throw new Error("missing redeem response");
  return { created: creation.value, redeemed: redemption.value };
}

async function openSocket(
  role: SocketRole,
  connectionId: string,
  token: string,
): Promise<WebSocket> {
  const prefix = role === "client" ? "connectors" : "adapters";
  const response = await request(`/v1/${prefix}/${connectionId}/events`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      Upgrade: "websocket",
    },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (socket === null) throw new Error("missing WebSocket");
  socket.accept();
  openedSockets.add(socket);
  return socket;
}

function message(socket: WebSocket): Promise<MessageEvent> {
  return new Promise((resolve) => {
    socket.addEventListener("message", resolve, { once: true });
  });
}

function closed(socket: WebSocket): Promise<CloseEvent> {
  return new Promise((resolve) => {
    socket.addEventListener("close", resolve, { once: true });
  });
}

function frame(
  connectionId: string,
  kind: ConnectorFrame["kind"],
  seq: number,
  payload: Record<string, unknown>,
  conversationId?: string,
): ConnectorFrame {
  return {
    v: 1,
    kind,
    connectionId,
    ...(conversationId === undefined ? {} : { conversationId }),
    messageId: crypto.randomUUID(),
    seq,
    sentAt: Date.now(),
    payload,
  };
}

function send(socket: WebSocket, value: ConnectorFrame): void {
  socket.send(JSON.stringify(value));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes).buffer),
  );
  return [...digest].map((value) => value.toString(16).padStart(2, "0")).join("");
}

function fileNameBase64Url(fileName: string): string {
  const encoded = btoa(String.fromCharCode(...new TextEncoder().encode(fileName)));
  return encoded.replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, "");
}

function attachmentUploadHeaders(params: {
  token: string;
  conversationId: string;
  turnId: string;
  fileName: string;
  mediaType: string;
  bytes: Uint8Array;
  sha256: string;
}): Headers {
  return new Headers({
    Authorization: `Bearer ${params.token}`,
    "Content-Length": String(params.bytes.byteLength),
    "Content-Type": params.mediaType,
    "X-OpenClam-Conversation-Id": params.conversationId,
    "X-OpenClam-File-Name-B64": fileNameBase64Url(params.fileName),
    "X-OpenClam-SHA256": params.sha256,
    "X-OpenClam-Turn-Id": params.turnId,
  });
}

function internalAttachmentHeaders(record: AttachmentBlobRecord): Headers {
  return new Headers({
    "Content-Length": String(record.byteCount),
    "X-OpenClam-Attachment-Id": record.attachmentId,
    "X-OpenClam-Byte-Count": String(record.byteCount),
    "X-OpenClam-Connection-Id": record.connectionId,
    "X-OpenClam-Created-At": String(record.createdAt),
    "X-OpenClam-Expires-At": String(record.expiresAt),
    "X-OpenClam-File-Name-B64": fileNameBase64Url(record.fileName),
    "X-OpenClam-Media-Type": record.mediaType,
    "X-OpenClam-SHA256": record.sha256,
  });
}

async function eventually(predicate: () => boolean | Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!(await predicate())) {
    if (Date.now() >= deadline) throw new Error("test_timeout");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

async function activeAttachmentTurn(): Promise<{
  created: CreatedPairing;
  redeemed: RedeemedPairing;
  client: WebSocket;
  adapter: WebSocket;
  conversationId: string;
  turnId: string;
}> {
  const { created, redeemed } = await paired();
  const client = await openSocket("client", created.connectionId, redeemed.clientToken);
  const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
  const conversationId = crypto.randomUUID();
  const turnId = crypto.randomUUID();
  const forwardedSubmit = message(adapter);
  send(client, frame(
    created.connectionId,
    "turn.submit",
    1,
    {
      turnId,
      accountId: "main",
      text: "Create an attachment",
      capabilities: ["activity-v1", "attachments-v1"],
    },
    conversationId,
  ));
  expect(JSON.parse((await forwardedSubmit).data as string).kind).toBe("turn.submit");
  const forwardedAcceptance = message(client);
  send(adapter, frame(
    created.connectionId,
    "turn.accepted",
    1,
    { turnId },
    conversationId,
  ));
  expect(JSON.parse((await forwardedAcceptance).data as string).kind).toBe("turn.accepted");
  return { created, redeemed, client, adapter, conversationId, turnId };
}

describe("HTTP pairing contract", () => {
  it("returns only a content-free health description", async () => {
    const response = await request("/healthz");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      service: "openclam-openclaw-bridge",
      protocol: 1,
    });
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  it("requires the bootstrap bearer without reflecting it", async () => {
    const missing = await request("/v1/pairings", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(createBody()),
    });
    expect(missing.status).toBe(401);
    expect(await missing.json()).toEqual({
      error: { code: "unauthorized", message: "Authentication failed." },
    });

    const wrongSecret = "wrong-secret-that-must-not-appear-anywhere-in-output-value";
    const wrong = await createPairing(createBody(), wrongSecret);
    expect(wrong.response.status).toBe(401);
    expect(await wrong.response.text()).not.toContain(wrongSecret);
  });

  it("creates an exact bounded one-time pairing response", async () => {
    const startedAt = Date.now();
    const { response, value } = await createPairing();
    expect(response.status).toBe(201);
    expect(value).toBeDefined();
    expect(Object.keys(value ?? {}).sort()).toEqual([
      "adapterToken",
      "code",
      "connectionId",
      "expiresAt",
      "pairingId",
      "v",
    ]);
    expect(value?.v).toBe(1);
    expect(value?.pairingId).toMatch(/^[0-9a-f-]{36}$/);
    expect(value?.connectionId).toMatch(/^[0-9a-f-]{36}$/);
    expect(value?.code).toMatch(
      /^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/,
    );
    expect(value?.adapterToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(value?.expiresAt).toBeGreaterThan(startedAt);
    expect(value?.expiresAt).toBeLessThanOrEqual(Date.now() + 600_000);
  });

  it("lets the authenticated adapter create a fresh iPhone pairing without the bootstrap secret", async () => {
    const first = await createPairing();
    expect(first.response.status).toBe(201);
    if (first.value === undefined) throw new Error("missing create response");

    const unauthorized = await request(
      `/v1/adapters/${first.value.connectionId}/pairings`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${"W".repeat(43)}` },
      },
    );
    expect(unauthorized.status).toBe(401);

    const response = await request(
      `/v1/adapters/${first.value.connectionId}/pairings`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${first.value.adapterToken}` },
      },
    );
    expect(response.status).toBe(201);
    const replacement = await response.json<CreatedPairing>();
    expect(replacement.connectionId).not.toBe(first.value.connectionId);
    expect(replacement.adapterToken).not.toBe(first.value.adapterToken);
    expect(Object.keys(replacement).sort()).toEqual([
      "adapterToken",
      "code",
      "connectionId",
      "expiresAt",
      "pairingId",
      "v",
    ]);

    const redeemed = await redeemPairing(replacement.code);
    expect(redeemed.response.status).toBe(200);
    expect(redeemed.value).toMatchObject({
      connectionId: replacement.connectionId,
      gatewayLabel: GATEWAY_LABEL,
      accounts,
    });
    const adapter = await openSocket(
      "adapter",
      replacement.connectionId,
      replacement.adapterToken,
    );
    adapter.close(1000, "done");
  });

  it("lets a client distinguish a valid connection from a revoked pairing", async () => {
    const { created, redeemed } = await paired();
    const path = `/v1/connectors/${created.connectionId}/status`;

    const valid = await request(path, {
      headers: { Authorization: `Bearer ${redeemed.clientToken}` },
    });
    expect(valid.status).toBe(204);

    const unauthorized = await request(path, {
      headers: { Authorization: `Bearer ${"W".repeat(43)}` },
    });
    expect(unauthorized.status).toBe(401);

    const revoked = await request(`/v1/connectors/${created.connectionId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${redeemed.clientToken}` },
    });
    expect(revoked.status).toBe(204);

    const missing = await request(path, {
      headers: { Authorization: `Bearer ${redeemed.clientToken}` },
    });
    expect(missing.status).toBe(404);
  });

  it("rejects unknown fields, duplicate accounts, invalid ids, and excess accounts", async () => {
    const cases = [
      createBody({ unknown: true }),
      createBody({
        accounts: [accounts[0], { ...accounts[0], agentId: "other" }],
      }),
      createBody({ adapterId: "not-a-uuid" }),
      createBody({ accounts: Array.from({ length: 33 }, (_, index) => ({
        accountId: `a${index}`,
        agentId: `agent${index}`,
        displayName: `Agent ${index}`,
      })) }),
    ];
    for (const value of cases) {
      const result = await createPairing(value);
      expect(result.response.status).toBe(400);
      expect(await result.response.json()).toEqual({
        error: {
          code: "invalid_request",
          message: "The request could not be accepted.",
        },
      });
    }
  });

  it("enforces the create byte limit even for a streamed body", async () => {
    const oversized = new Uint8Array(16_385).fill(65);
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(oversized.subarray(0, 8_000));
        controller.enqueue(oversized.subarray(8_000));
        controller.close();
      },
    });
    const response = await worker.fetch(
      new Request("https://bridge.test/v1/pairings", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${BOOTSTRAP_TOKEN}`,
          "Content-Type": "application/json",
        },
        body,
      }),
      env,
    );
    expect(response.status).toBe(413);
  });

  it("retries redemption for the same installation without minting a second credential", async () => {
    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const installationId = crypto.randomUUID();
    const first = await redeemPairing(creation.value.code, installationId);
    expect(first.response.status).toBe(200);
    expect(first.value).toEqual({
      v: 1,
      connectionId: creation.value.connectionId,
      gatewayLabel: GATEWAY_LABEL,
      accounts,
      clientToken: expect.stringMatching(/^[A-Za-z0-9_-]{43}$/),
    });

    const retry = await redeemPairing(creation.value.code, installationId);
    expect(retry.response.status).toBe(200);
    expect(retry.value).toEqual(first.value);

    const otherInstallation = await redeemPairing(creation.value.code);
    expect(otherInstallation.response.status).toBe(409);
    expect(await otherInstallation.response.json()).toEqual({
      error: {
        code: "pairing_consumed",
        message: "The pairing code has already been used.",
      },
    });
  });

  it("returns the same credential under concurrent same-installation redemption", async () => {
    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const installationId = crypto.randomUUID();

    const results = await Promise.all([
      redeemPairing(creation.value.code, installationId),
      redeemPairing(creation.value.code, installationId),
    ]);

    expect(results.map((result) => result.response.status)).toEqual([200, 200]);
    expect(results[0]?.value?.clientToken).toBe(results[1]?.value?.clientToken);
    expect(results[0]?.value?.connectionId).toBe(results[1]?.value?.connectionId);
  });

  it("allows only one installation when different installations race redemption", async () => {
    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const results = await Promise.all([
      redeemPairing(creation.value.code, crypto.randomUUID()),
      redeemPairing(creation.value.code, crypto.randomUUID()),
    ]);
    expect(results.map((result) => result.response.status).sort()).toEqual([200, 409]);
    expect(results.filter((result) => result.value !== undefined)).toHaveLength(1);
    const rejected = results.find((result) => result.response.status === 409);
    expect(await rejected?.response.json()).toEqual({
      error: {
        code: "pairing_consumed",
        message: "The pairing code has already been used.",
      },
    });
  });

  it("locks one installation after five failed redemption attempts", async () => {
    const installationId = crypto.randomUUID();
    const invalidCodes = [
      "OC-0000-0000-0001",
      "OC-0000-0000-0002",
      "OC-0000-0000-0003",
      "OC-0000-0000-0004",
      "OC-0000-0000-0005",
    ];
    for (let index = 0; index < invalidCodes.length; index += 1) {
      const result = await redeemPairing(invalidCodes[index] ?? "", installationId);
      expect(result.response.status).toBe(index === 4 ? 423 : 404);
    }

    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const locked = await redeemPairing(creation.value.code, installationId);
    expect(locked.response.status).toBe(423);
    expect(await locked.response.json()).toEqual({
      error: {
        code: "pairing_locked",
        message: "Pairing is temporarily locked.",
      },
    });
  });

  it("recognizes an expired pairing without returning metadata", async () => {
    const code = "OC-1234-5678-9ABC";
    const verifier = await pairingVerifier(code, env.PAIRING_CODE_PEPPER);
    const record: PairingRecord = {
      v: 1,
      pairingId: crypto.randomUUID(),
      connectionId: crypto.randomUUID(),
      adapterId: crypto.randomUUID(),
      gatewayLabel: "Expired gateway",
      accounts: [accounts[0]!],
      verifier,
      createdAt: Date.now() - 700_000,
      expiresAt: Date.now() - 1,
    };
    const stub = env.PAIRINGS.get(
      env.PAIRINGS.idFromName("openclam-agent-connector-v1"),
    );
    await stub.fetch("https://pairing.internal/internal/create", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ record }),
    });
    const result = await redeemPairing(code);
    expect(result.response.status).toBe(410);
    const text = await result.response.text();
    expect(text).toContain("pairing_expired");
    expect(text).not.toContain("Expired gateway");
  });

  it("persists verifiers and bounded ciphertext, never a raw code or token", async () => {
    const { created, redeemed } = await paired();
    const pairingStub = env.PAIRINGS.get(
      env.PAIRINGS.idFromName("openclam-agent-connector-v1"),
    );
    const pairingStorage = await runInDurableObject(
      pairingStub,
      async (_instance, state) => [...(await state.storage.list()).entries()],
    );
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const sessionStorage = await runInDurableObject(
      sessionStub,
      async (_instance, state) => [...(await state.storage.list()).entries()],
    );
    const persisted = JSON.stringify([pairingStorage, sessionStorage]);
    expect(persisted).not.toContain(created.code);
    expect(persisted).not.toContain(created.adapterToken);
    expect(persisted).not.toContain(redeemed.clientToken);
    expect(persisted).toContain("adapterTokenVerifier");
    expect(persisted).toContain("clientTokenVerifier");
    expect(persisted).toContain("encryptedClientToken");
  });

  it("clears the encrypted retry credential at pairing expiry", async () => {
    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const installationId = crypto.randomUUID();
    const redeemed = await redeemPairing(creation.value.code, installationId);
    expect(redeemed.response.status).toBe(200);

    const pairingStub = env.PAIRINGS.get(
      env.PAIRINGS.idFromName("openclam-agent-connector-v1"),
    );
    await runInDurableObject(pairingStub, async (_instance, state) => {
      const pairings = await state.storage.list<PairingRecord>({ prefix: "pairing:" });
      const entry = [...pairings.entries()][0];
      if (entry === undefined) throw new Error("missing pairing record");
      await state.storage.put(entry[0], { ...entry[1], expiresAt: Date.now() - 1 });
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    expect(await runDurableObjectAlarm(pairingStub)).toBe(true);

    const retained = await runInDurableObject(pairingStub, async (_instance, state) => {
      const pairings = await state.storage.list<PairingRecord>({ prefix: "pairing:" });
      return [...pairings.values()][0];
    });
    expect(retained?.consumedAt).toBeDefined();
    expect(retained?.installationVerifier).toBeDefined();
    expect(retained?.encryptedClientToken).toBeUndefined();

    const retry = await redeemPairing(creation.value.code, installationId);
    expect(retry.response.status).toBe(410);
    expect(await retry.response.json()).toEqual({
      error: {
        code: "pairing_expired",
        message: "The pairing code has expired.",
      },
    });
  });

  it("removes an abandoned session and pairing metadata after bounded expiry", async () => {
    const creation = await createPairing();
    if (creation.value === undefined) throw new Error("missing create response");
    const now = Date.now();
    const cleanupAt = now - 1;
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(creation.value.connectionId),
    );
    await runInDurableObject(sessionStub, async (_instance, state) => {
      const record = await state.storage.get<SessionRecord>("session");
      if (record === undefined) throw new Error("missing session record");
      await state.storage.put("session", { ...record, unpairedCleanupAt: cleanupAt });
    });

    const pairingStub = env.PAIRINGS.get(
      env.PAIRINGS.idFromName("openclam-agent-connector-v1"),
    );
    await runInDurableObject(pairingStub, async (_instance, state) => {
      const pairings = await state.storage.list<PairingRecord>({ prefix: "pairing:" });
      const entry = [...pairings.entries()][0];
      if (entry === undefined) throw new Error("missing pairing record");
      const [key, record] = entry;
      await state.storage.put(key, {
        ...record,
        expiresAt: cleanupAt - 600_000,
      });
      await state.storage.setAlarm(now + 60_000);
    });

    expect(await runDurableObjectAlarm(pairingStub)).toBe(true);
    const pairingStorage = await runInDurableObject(
      pairingStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    const sessionStorage = await runInDurableObject(
      sessionStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    expect(pairingStorage).toEqual([]);
    expect(sessionStorage).toEqual([]);

    const reconnect = await request(
      `/v1/adapters/${creation.value.connectionId}/events`,
      {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${creation.value.adapterToken}`,
        },
      },
    );
    expect(reconnect.status).toBe(404);
  });
});

describe("authenticated connector WebSockets", () => {
  it("rejects missing, wrong-role, and wrong tokens", async () => {
    const { created, redeemed } = await paired();
    const missing = await request(
      `/v1/connectors/${created.connectionId}/events`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(missing.status).toBe(401);

    const wrongRole = await request(
      `/v1/connectors/${created.connectionId}/events`,
      {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${created.adapterToken}`,
        },
      },
    );
    expect(wrongRole.status).toBe(401);

    const wrong = await request(`/v1/adapters/${created.connectionId}/events`, {
      headers: {
        Upgrade: "websocket",
        Authorization: `Bearer ${redeemed.clientToken}`,
      },
    });
    expect(wrong.status).toBe(401);
  });

  it("forwards, cumulatively acknowledges, and does not replay acknowledged frames", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    let adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = frame(
      created.connectionId,
      "turn.submit",
      1,
      { turnId, accountId: "main", text: "private transcript sentinel" },
      conversationId,
    );
    const received = message(adapter);
    send(client, submitted);
    expect(JSON.parse((await received).data as string)).toEqual(submitted);

    send(
      adapter,
      frame(created.connectionId, "ack", 1, { ackSeq: 1 }),
    );

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    let pending: PendingFrame[] = [];
    await eventually(async () => {
      pending = await runInDurableObject(
        sessionStub,
        async (_instance, state) =>
          (await state.storage.get<SessionRecord>("session"))?.pending ?? [],
      );
      return pending.length === 0;
    });
    expect(pending).toHaveLength(0);
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("replays an unacknowledged encrypted frame after adapter reconnect", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = frame(
      created.connectionId,
      "turn.submit",
      1,
      { turnId, accountId: "main", text: "replay me after reconnect" },
      conversationId,
    );
    send(client, submitted);

    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    expect(JSON.parse((await message(adapter)).data as string)).toEqual(submitted);
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("stores pending transcript frames only as AES-GCM ciphertext", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const plaintext = "ultra private pending transcript sentinel";
    const submitted = frame(
      created.connectionId,
      "turn.submit",
      1,
      { turnId: crypto.randomUUID(), accountId: "main", text: plaintext },
      crypto.randomUUID(),
    );
    const delivered = message(adapter);
    send(client, submitted);

    // Production persists the encrypted pending frame before forwarding it.
    // Waiting for delivery is therefore a deterministic durable-write barrier;
    // reading storage immediately after WebSocket.send() races the async handler.
    expect(JSON.parse((await delivered).data as string)).toEqual(submitted);

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const stored = await runInDurableObject(
      sessionStub,
      async (_instance, state) => state.storage.get<SessionRecord>("session"),
    );
    expect(stored?.pending).toHaveLength(1);
    expect(JSON.stringify(stored?.pending)).not.toContain(plaintext);
    expect(stored?.pending[0]?.encrypted.algorithm).toBe("A256GCM");
    expect(stored?.pending[0]?.encrypted.iv).toBeTruthy();
    expect(stored?.pending[0]?.encrypted.ciphertext).toBeTruthy();
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("keeps a worst-case 16-frame encrypted record below the SQLite value limit", async () => {
    const { created } = await paired();
    const expiresAt = Date.now() + 900_000;
    const plaintext = "x".repeat(65_536);
    const pending = await Promise.all(
      Array.from({ length: 16 }, async (_, index) => ({
        from: "client" as const,
        seq: index + 1,
        messageId: crypto.randomUUID(),
        encrypted: await encryptPendingFrame(
          plaintext,
          env.PENDING_EVENT_KEK_B64,
          created.connectionId,
          "client",
          index + 1,
        ),
        expiresAt,
      })),
    );
    const seen = (offset: number) => Array.from({ length: 512 }, (_, index) => ({
      seq: offset + index + 1,
      messageId: crypto.randomUUID(),
      digest: "a".repeat(64),
      kind: "assistant.delta" as const,
      expiresAt,
    }));
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const encodedBytes = await runInDurableObject(sessionStub, async (_instance, state) => {
      const stored = await state.storage.get<SessionRecord>("session");
      if (stored === undefined) throw new Error("missing session");
      const nearLimit: SessionRecord = {
        ...stored,
        pending,
        seenClient: seen(0),
        seenAdapter: seen(512),
        highestClientSeq: 512,
        highestAdapterSeq: 1_024,
      };
      const bytes = new TextEncoder().encode(JSON.stringify(nearLimit)).byteLength;
      await state.storage.put("session", nearLimit);
      return bytes;
    });
    expect(encodedBytes).toBeLessThan(1_800_000);
  });

  it("closes before admitting a seventeenth pending frame", async () => {
    expect(env.MAX_PENDING_FRAMES).toBe("16");
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    await runInDurableObject(sessionStub, async (_instance, state) => {
      const stored = await state.storage.get<SessionRecord>("session");
      if (stored === undefined) throw new Error("missing session");
      const encrypted = await encryptPendingFrame(
        "bounded",
        env.PENDING_EVENT_KEK_B64,
        created.connectionId,
        "client",
        1,
      );
      stored.pending = Array.from({ length: 16 }, (_, index) => ({
        from: "client" as const,
        seq: index + 1,
        messageId: crypto.randomUUID(),
        encrypted,
        expiresAt: Date.now() + 900_000,
      }));
      await state.storage.put("session", stored);
    });

    const limited = closed(client);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId: crypto.randomUUID(), accountId: "main", text: "one too many" },
        crypto.randomUUID(),
      ),
    );
    const event = await limited;
    expect(event.code).toBe(1013);
    expect(event.reason).toBe("pending_limit");
  });

  it("keeps offline heartbeats ephemeral so they cannot exhaust pending turns", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    for (let seq = 1; seq <= 140; seq += 1) {
      send(
        client,
        frame(created.connectionId, "heartbeat", seq, {
          lastReceivedSeq: 0,
        }),
      );
    }

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    let stored: SessionRecord | undefined;
    await eventually(async () => {
      stored = await runInDurableObject(
        sessionStub,
        async (_instance, state) => state.storage.get<SessionRecord>("session"),
      );
      return stored?.highestClientSeq === 140;
    });
    expect(stored?.highestClientSeq).toBe(140);
    expect(stored?.pending).toHaveLength(0);

    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const received = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        141,
        { turnId, accountId: "main", text: "real turn still admitted" },
        conversationId,
      ),
    );
    const delivered = JSON.parse((await received).data as string) as ConnectorFrame;
    expect(delivered.kind).toBe("turn.submit");
    expect(delivered.seq).toBe(141);
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("receipts durable frames and exact replays without forwarding or applying them twice", async () => {
    const { created, redeemed } = await paired();
    let client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const submitted = frame(
      created.connectionId,
      "turn.submit",
      1,
      { turnId: crypto.randomUUID(), accountId: "main", text: "persist exactly once" },
      crypto.randomUUID(),
    );
    const encoded = JSON.stringify(submitted);
    const firstReceipt = message(client);
    const firstForward = message(adapter);
    client.send(encoded);
    expect(JSON.parse((await firstReceipt).data as string)).toEqual({
      v: 1,
      kind: "relay.persisted",
      connectionId: created.connectionId,
      payload: { senderSeq: submitted.seq, messageId: submitted.messageId },
    });
    expect(JSON.parse((await firstForward).data as string)).toEqual(submitted);

    client.close(1000, "reconnect before receipt state is committed locally");
    client = await openSocket("client", created.connectionId, redeemed.clientToken);
    let unexpectedOnConnect = 0;
    const countUnexpected = () => {
      unexpectedOnConnect += 1;
    };
    client.addEventListener("message", countUnexpected);
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(unexpectedOnConnect).toBe(0);
    client.removeEventListener("message", countUnexpected);

    let duplicateForwards = 0;
    const countDuplicate = () => {
      duplicateForwards += 1;
    };
    adapter.addEventListener("message", countDuplicate);
    const replayReceipt = message(client);
    client.send(encoded);
    expect(JSON.parse((await replayReceipt).data as string)).toEqual({
      v: 1,
      kind: "relay.persisted",
      connectionId: created.connectionId,
      payload: { senderSeq: submitted.seq, messageId: submitted.messageId },
    });
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(duplicateForwards).toBe(0);
    adapter.removeEventListener("message", countDuplicate);

    const cancelled = frame(
      created.connectionId,
      "turn.cancel",
      2,
      { turnId: submitted.payload.turnId },
      submitted.conversationId,
    );
    const encodedCancel = JSON.stringify(cancelled);
    const cancelReceipt = message(client);
    const cancelForward = message(adapter);
    client.send(encodedCancel);
    expect(JSON.parse((await cancelReceipt).data as string).payload).toEqual({
      senderSeq: cancelled.seq,
      messageId: cancelled.messageId,
    });
    expect(JSON.parse((await cancelForward).data as string)).toEqual(cancelled);

    duplicateForwards = 0;
    adapter.addEventListener("message", countDuplicate);
    const cancelReplayReceipt = message(client);
    client.send(encodedCancel);
    expect(JSON.parse((await cancelReplayReceipt).data as string).payload).toEqual({
      senderSeq: cancelled.seq,
      messageId: cancelled.messageId,
    });
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(duplicateForwards).toBe(0);
    adapter.removeEventListener("message", countDuplicate);

    const alteredReplay = closed(client);
    client.send(JSON.stringify({
      ...submitted,
      payload: { ...submitted.payload, text: "altered replay" },
    }));
    const closeEvent = await alteredReplay;
    expect(closeEvent.code).toBe(1008);
    expect(closeEvent.reason).toBe("replay_rejected");
    adapter.close(1000, "done");
  });

  it("rejects old sequence numbers and duplicate message ids", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const turn = frame(
      created.connectionId,
      "turn.submit",
      1,
      { turnId: crypto.randomUUID(), accountId: "main", text: "first" },
      crypto.randomUUID(),
    );
    send(client, turn);
    const closeEvent = closed(client);
    send(client, { ...turn, messageId: crypto.randomUUID() });
    const closedValue = await closeEvent;
    expect(closedValue.code).toBe(1008);
    expect(closedValue.reason).toBe("replay_rejected");

    const replacement = await openSocket(
      "client",
      created.connectionId,
      redeemed.clientToken,
    );
    const duplicateId = closed(replacement);
    send(replacement, {
      ...turn,
      seq: 2,
    });
    expect((await duplicateId).reason).toBe("replay_rejected");
    replacement.close(1000, "done");
  });

  it("enforces account allowlisting and one active turn per conversation", async () => {
    const first = await paired();
    let client = await openSocket(
      "client",
      first.created.connectionId,
      first.redeemed.clientToken,
    );
    const disallowed = closed(client);
    send(
      client,
      frame(
        first.created.connectionId,
        "turn.submit",
        1,
        { turnId: crypto.randomUUID(), accountId: "not-configured", text: "no" },
        crypto.randomUUID(),
      ),
    );
    expect((await disallowed).reason).toBe("account_not_allowed");

    client = await openSocket(
      "client",
      first.created.connectionId,
      first.redeemed.clientToken,
    );
    const conversationId = crypto.randomUUID();
    send(
      client,
      frame(
        first.created.connectionId,
        "turn.submit",
        1,
        { turnId: crypto.randomUUID(), accountId: "main", text: "one" },
        conversationId,
      ),
    );
    const busy = closed(client);
    send(
      client,
      frame(
        first.created.connectionId,
        "turn.submit",
        2,
        { turnId: crypto.randomUUID(), accountId: "main", text: "two" },
        conversationId,
      ),
    );
    expect((await busy).reason).toBe("conversation_busy");
  });

  it("rejects a duplicate active turn ID in another conversation", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "first" },
        crypto.randomUUID(),
      ),
    );
    await submitted;

    const duplicate = closed(client);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        2,
        { turnId, accountId: "main", text: "same turn, different chat" },
        crypto.randomUUID(),
      ),
    );
    expect((await duplicate).reason).toBe("duplicate_turn");
    adapter.close(1000, "done");
  });

  it("rejects cancellation from a conversation other than the active turn", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "do not cross-cancel" },
        crypto.randomUUID(),
      ),
    );
    await submitted;

    const mismatch = closed(client);
    send(
      client,
      frame(
        created.connectionId,
        "turn.cancel",
        2,
        { turnId },
        crypto.randomUUID(),
      ),
    );
    expect((await mismatch).reason).toBe("turn_mismatch");
    adapter.close(1000, "done");
  });

  it("enforces cumulative revisions and exactly one final frame", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "hello" },
        conversationId,
      ),
    );
    await submitted;
    send(adapter, frame(created.connectionId, "ack", 1, { ackSeq: 1 }));

    let delivered = message(client);
    send(
      adapter,
      frame(created.connectionId, "turn.accepted", 2, { turnId }, conversationId),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe("turn.accepted");

    delivered = message(client);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.delta",
        3,
        { turnId, revision: 1, text: "Hel" },
        conversationId,
      ),
    );
    const delta = JSON.parse((await delivered).data as string) as ConnectorFrame;
    expect(delta.payload).toEqual({ turnId, revision: 1, text: "Hel" });

    delivered = message(client);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.completed",
        4,
        { turnId, text: "Hello" },
        conversationId,
      ),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe(
      "assistant.completed",
    );

    const duplicateFinal = closed(adapter);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.completed",
        5,
        { turnId, text: "Hello again" },
        conversationId,
      ),
    );
    expect((await duplicateFinal).reason).toBe("turn_mismatch");
    client.close(1000, "done");
  });

  it("relays only capability-gated, bounded, path-safe work steps", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(client, frame(
      created.connectionId,
      "turn.submit",
      1,
      {
        turnId,
        accountId: "main",
        text: "show the work",
        capabilities: ["activity-v1", "attachments-v1", "work-v1"],
      },
      conversationId,
    ));
    await submitted;

    let delivered = message(client);
    send(adapter, frame(
      created.connectionId,
      "turn.accepted",
      1,
      { turnId },
      conversationId,
    ));
    await delivered;

    delivered = message(client);
    send(adapter, frame(
      created.connectionId,
      "assistant.work.upsert",
      2,
      {
        turnId,
        revision: 1,
        stepId: "tool-call-1",
        category: "tool",
        state: "running",
        title: "Searching documentation",
        tool: "web_search",
        detail: "Looking for the supported API",
      },
      conversationId,
    ));
    const work = JSON.parse((await delivered).data as string) as ConnectorFrame;
    expect(work.kind).toBe("assistant.work.upsert");
    expect(work.payload.stepId).toBe("tool-call-1");

    const rejected = closed(adapter);
    send(adapter, frame(
      created.connectionId,
      "assistant.work.upsert",
      3,
      {
        turnId,
        revision: 2,
        stepId: "tool-call-1",
        category: "command",
        state: "completed",
        title: "Command finished",
        output: "authorization: Bearer secret-material",
      },
      conversationId,
    ));
    expect((await rejected).reason).toBe("invalid_frame");
    client.close(1000, "done");
  });

  it("keeps a long-running turn active when acceptance and deltas refresh activity", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "long running" },
        conversationId,
      ),
    );
    await submitted;

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const oldStartedAt = Date.now() - 20 * 60 * 1_000;
    await runInDurableObject(sessionStub, async (_instance, state) => {
      const stored = await state.storage.get<SessionRecord>("session");
      if (stored === undefined) throw new Error("missing session");
      const active = stored.activeTurns[0];
      if (active === undefined) throw new Error("missing active turn");
      stored.activeTurns[0] = {
        ...active,
        startedAt: oldStartedAt,
        lastActivityAt: Date.now() - 1_000,
      };
      await state.storage.put("session", stored);
    });

    const acceptedAt = Date.now();
    let delivered = message(client);
    send(
      adapter,
      frame(created.connectionId, "turn.accepted", 1, { turnId }, conversationId),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe("turn.accepted");
    let stored = await runInDurableObject(
      sessionStub,
      async (_instance, state) => state.storage.get<SessionRecord>("session"),
    );
    expect(stored?.activeTurns[0]?.startedAt).toBe(oldStartedAt);
    expect(stored?.activeTurns[0]?.lastActivityAt).toBeGreaterThanOrEqual(acceptedAt);

    await runInDurableObject(sessionStub, async (_instance, state) => {
      const current = await state.storage.get<SessionRecord>("session");
      if (current === undefined) throw new Error("missing session");
      const active = current.activeTurns[0];
      if (active === undefined) throw new Error("missing active turn");
      current.activeTurns[0] = {
        ...active,
        lastActivityAt: Date.now() - 14 * 60 * 1_000,
      };
      await state.storage.put("session", current);
    });
    const deltaAt = Date.now();
    delivered = message(client);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.delta",
        2,
        { turnId, revision: 1, text: "still running" },
        conversationId,
      ),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe("assistant.delta");
    stored = await runInDurableObject(
      sessionStub,
      async (_instance, state) => state.storage.get<SessionRecord>("session"),
    );
    expect(stored?.activeTurns[0]?.lastActivityAt).toBeGreaterThanOrEqual(deltaAt);

    delivered = message(client);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.completed",
        3,
        { turnId, text: "finished" },
        conversationId,
      ),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe("assistant.completed");
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("revokes the connector visibly when an active turn reaches its absolute limit", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();
    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "expire safely" },
        conversationId,
      ),
    );
    await submitted;

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    await runInDurableObject(sessionStub, async (_instance, state) => {
      const stored = await state.storage.get<SessionRecord>("session");
      if (stored === undefined) throw new Error("missing session");
      const active = stored.activeTurns[0];
      if (active === undefined) throw new Error("missing active turn");
      stored.activeTurns[0] = {
        ...active,
        startedAt: Date.now() - 3_600_001,
        lastActivityAt: Date.now(),
      };
      await state.storage.put("session", stored);
      await state.storage.setAlarm(Date.now() - 1);
    });
    const clientClosed = closed(client);
    const adapterClosed = closed(adapter);
    await runDurableObjectAlarm(sessionStub);
    expect((await clientClosed).reason).toBe("turn_expired");
    expect((await adapterClosed).reason).toBe("turn_expired");
    const storageKeys = await runInDurableObject(
      sessionStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    expect(storageKeys).toEqual([]);
    const reconnect = await request(
      `/v1/connectors/${created.connectionId}/events`,
      {
        headers: {
          Authorization: `Bearer ${redeemed.clientToken}`,
          Upgrade: "websocket",
        },
      },
    );
    expect(reconnect.status).toBe(404);
  });

  it("receipts a transcript-free recovery error after a persisted final without showing a duplicate", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const adapter = await openSocket("adapter", created.connectionId, created.adapterToken);
    const conversationId = crypto.randomUUID();
    const turnId = crypto.randomUUID();

    const submitted = message(adapter);
    send(
      client,
      frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId, accountId: "main", text: "finish before the adapter restarts" },
        conversationId,
      ),
    );
    await submitted;

    let delivered = message(client);
    send(
      adapter,
      frame(created.connectionId, "turn.accepted", 1, { turnId }, conversationId),
    );
    expect(JSON.parse((await delivered).data as string).kind).toBe("turn.accepted");

    delivered = message(client);
    send(
      adapter,
      frame(
        created.connectionId,
        "assistant.completed",
        2,
        { turnId, text: "authoritative final" },
        conversationId,
      ),
    );
    expect(JSON.parse((await delivered).data as string).payload.text).toBe(
      "authoritative final",
    );

    let duplicateVisibleFrames = 0;
    const countDuplicate = () => {
      duplicateVisibleFrames += 1;
    };
    client.addEventListener("message", countDuplicate);
    const recovery = frame(
      created.connectionId,
      "turn.error",
      3,
      {
        turnId,
        code: "adapter_restarted",
        message: "OpenClaw restarted during this reply. Please try again.",
        retryable: true,
      },
      conversationId,
    );
    const receipt = message(adapter);
    send(adapter, recovery);
    expect(JSON.parse((await receipt).data as string)).toEqual({
      v: 1,
      kind: "relay.persisted",
      connectionId: created.connectionId,
      payload: { senderSeq: recovery.seq, messageId: recovery.messageId },
    });
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(duplicateVisibleFrames).toBe(0);
    client.removeEventListener("message", countDuplicate);

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const stored = await runInDurableObject(
      sessionStub,
      async (_instance, state) => state.storage.get<SessionRecord>("session"),
    );
    expect(stored?.activeTurns).toHaveLength(0);
    expect(stored?.settledTurns).toHaveLength(1);
    expect(stored?.highestAdapterSeq).toBe(3);
    client.close(1000, "done");
    adapter.close(1000, "done");
  });

  it("rejects non-schema payloads and frames above 64 KiB", async () => {
    const { created, redeemed } = await paired();
    let client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const invalid = closed(client);
    client.send(JSON.stringify({
      ...frame(
        created.connectionId,
        "turn.submit",
        1,
        { turnId: crypto.randomUUID(), accountId: "main", text: "ok" },
        crypto.randomUUID(),
      ),
      extra: true,
    }));
    expect((await invalid).reason).toBe("invalid_frame");

    client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const oversized = closed(client);
    client.send("x".repeat(65_537));
    const closeEvent = await oversized;
    expect(closeEvent.code).toBe(1009);
    expect(closeEvent.reason).toBe("frame_too_large");
  });

  it("replaces an older same-role socket", async () => {
    const { created, redeemed } = await paired();
    const first = await openSocket("client", created.connectionId, redeemed.clientToken);
    const firstClosed = closed(first);
    const second = await openSocket("client", created.connectionId, redeemed.clientToken);
    const event = await firstClosed;
    expect(event.code).toBe(4001);
    expect(event.reason).toBe("replaced");
    second.close(1000, "done");
  });

  it("revokes with either role token and closes active sockets", async () => {
    const { created, redeemed } = await paired();
    const client = await openSocket("client", created.connectionId, redeemed.clientToken);
    const clientClosed = closed(client);
    const deleted = await request(`/v1/connectors/${created.connectionId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${created.adapterToken}` },
    });
    expect(deleted.status).toBe(204);
    expect((await clientClosed).reason).toBe("revoked");

    const repeated = await request(`/v1/connectors/${created.connectionId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${created.adapterToken}` },
    });
    expect(repeated.status).toBe(404);
    const reconnect = await request(
      `/v1/connectors/${created.connectionId}/events`,
      {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${redeemed.clientToken}`,
        },
      },
    );
    expect(reconnect.status).toBe(404);

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(created.connectionId),
    );
    const sessionStorage = await runInDurableObject(
      sessionStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    expect(sessionStorage).toEqual([]);
    const pairingStub = env.PAIRINGS.get(
      env.PAIRINGS.idFromName("openclam-agent-connector-v1"),
    );
    const pairingStorage = await runInDurableObject(
      pairingStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    expect(pairingStorage).toEqual([]);
  });

  it("accepts a zero-byte DELETE body stream from an external client", async () => {
    const { created } = await paired();
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.close();
      },
    });
    const deleted = await worker.fetch(
      new Request(`https://bridge.test/v1/connectors/${created.connectionId}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${created.adapterToken}` },
        body,
      }),
      env,
    );
    expect(deleted.status).toBe(204);
  });

  it("cannot resurrect a session when revocation races an in-flight frame", async () => {
    const connectionId = crypto.randomUUID();
    const clientToken = "client-token-that-is-long-enough-for-the-auth-validator";
    const adapterToken = "adapter-token-that-is-long-enough-for-the-auth-validator";
    const clientTokenVerifier = await tokenVerifier(
      clientToken,
      env.TOKEN_VERIFIER_PEPPER,
      "client",
      connectionId,
    );
    const adapterTokenVerifier = await tokenVerifier(
      adapterToken,
      env.TOKEN_VERIFIER_PEPPER,
      "adapter",
      connectionId,
    );
    const initialRecord = {
      v: 1,
      connectionId,
      adapterId: crypto.randomUUID(),
      gatewayLabel: GATEWAY_LABEL,
      accounts,
      adapterTokenVerifier,
      clientTokenVerifier,
      installationVerifier: "test-installation-verifier",
      createdAt: Date.now(),
      unpairedCleanupAt: Date.now() + 1_200_000,
      pairedAt: Date.now(),
      highestClientSeq: 0,
      highestAdapterSeq: 0,
      acknowledgedClientSeq: 0,
      acknowledgedAdapterSeq: 0,
      pending: [],
      seenClient: [],
      seenAdapter: [],
      activeTurns: [],
      activeClientSocketId: "client-socket",
    } satisfies SessionRecord;
    const submitted = frame(
      connectionId,
      "turn.submit",
      1,
      {
        turnId: crypto.randomUUID(),
        accountId: "main",
        text: "frame held before durable persistence",
      },
      crypto.randomUUID(),
    );
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(connectionId),
    );
    const outcome = await runInDurableObject(
      sessionStub,
      async (instance, state) => {
        await state.storage.put("session", initialRecord);
        let signalPersistenceStarted: (() => void) | undefined;
        let releasePersistence: (() => void) | undefined;
        const persistenceStarted = new Promise<void>((resolve) => {
          signalPersistenceStarted = resolve;
        });
        const persistenceRelease = new Promise<void>((resolve) => {
          releasePersistence = resolve;
        });
        let heldPendingWrite = false;
        const target = instance as unknown as {
          persistSession(record: SessionRecord): Promise<void>;
        };
        const originalPersist = target.persistSession.bind(instance);
        target.persistSession = async (record: SessionRecord) => {
          if (!heldPendingWrite && record.pending.length > 0) {
            heldPendingWrite = true;
            signalPersistenceStarted?.();
            await persistenceRelease;
          }
          await originalPersist(record);
        };
        const fakeSocket = {
          deserializeAttachment() {
            return { v: 1, role: "client", socketId: "client-socket" };
          },
          close() {},
        } as unknown as WebSocket;

        const inFlightFrame = instance.webSocketMessage(
          fakeSocket,
          JSON.stringify(submitted),
        );
        await persistenceStarted;
        let revokeSettled = false;
        const revoke = instance.fetch(
          new Request("https://session.internal/internal/delete", {
            method: "DELETE",
            headers: { Authorization: `Bearer ${adapterToken}` },
          }),
        ).then((response) => {
          revokeSettled = true;
          return response;
        });
        await Promise.resolve();
        const settledWhileFrameWasHeld = revokeSettled;

        releasePersistence?.();
        await inFlightFrame;
        const revokeStatus = (await revoke).status;
        const storageKeys = [...(await state.storage.list()).keys()];
        const reconnectStatus = (await instance.fetch(
          new Request("https://session.internal/internal/connect?role=client", {
            headers: {
              Upgrade: "websocket",
              Authorization: `Bearer ${clientToken}`,
            },
          }),
        )).status;
        return {
          settledWhileFrameWasHeld,
          revokeStatus,
          storageKeys,
          reconnectStatus,
        };
      },
    );
    expect(outcome.settledWhileFrameWasHeld).toBe(false);
    expect(outcome.revokeStatus).toBe(204);
    expect(outcome.storageKeys).toEqual([]);
    expect(outcome.reconnectStatus).toBe(404);
  });
});

describe("authenticated attachment relay", () => {
  it("accepts a 160-code-point filename at the four-byte UTF-8 boundary", async () => {
    const active = await activeAttachmentTurn();
    const attachmentId = crypto.randomUUID();
    const fileName = "📋".repeat(160);
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const sha256 = await sha256Hex(bytes);
    expect([...fileName]).toHaveLength(160);
    expect(fileNameBase64Url(fileName).length).toBeGreaterThan(640);

    const uploaded = await request(
      `/v1/adapters/${active.created.connectionId}/attachments/${attachmentId}`,
      {
        method: "PUT",
        headers: attachmentUploadHeaders({
          token: active.created.adapterToken,
          conversationId: active.conversationId,
          turnId: active.turnId,
          fileName,
          mediaType: "image/png",
          bytes,
          sha256,
        }),
        body: bytes,
      },
    );

    expect(uploaded.status).toBe(201);
    expect((await uploaded.json<{ fileName: string }>()).fileName).toBe(fileName);
  });

  it("retries the same upload idempotently, authorizes only the paired client, and deletes after ACK", async () => {
    const active = await activeAttachmentTurn();
    const attachmentId = crypto.randomUUID();
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const sha256 = await sha256Hex(bytes);
    const path = `/v1/adapters/${active.created.connectionId}/attachments/${attachmentId}`;
    const upload = () => request(path, {
      method: "PUT",
      headers: attachmentUploadHeaders({
        token: active.created.adapterToken,
        conversationId: active.conversationId,
        turnId: active.turnId,
        fileName: "ara.png",
        mediaType: "image/png",
        bytes,
        sha256,
      }),
      body: bytes,
    });

    const first = await upload();
    expect(first.status).toBe(201);
    const metadata = await first.json<{
      v: 1;
      attachmentId: string;
      fileName: string;
      mediaType: string;
      byteCount: number;
      sha256: string;
      downloadPath: string;
      expiresAt: number;
    }>();
    const retry = await upload();
    expect(retry.status).toBe(201);
    expect(await retry.json()).toEqual(metadata);

    const attachmentForward = message(active.client);
    send(active.adapter, frame(
      active.created.connectionId,
      "assistant.attachment",
      2,
      { turnId: active.turnId, ...metadata, v: undefined },
      active.conversationId,
    ));
    const delivered = JSON.parse((await attachmentForward).data as string) as ConnectorFrame;
    expect(delivered.kind).toBe("assistant.attachment");
    expect(delivered.payload).toEqual({
      turnId: active.turnId,
      attachmentId,
      fileName: "ara.png",
      mediaType: "image/png",
      byteCount: bytes.byteLength,
      sha256,
      downloadPath: `/v1/connectors/${active.created.connectionId}/attachments/${attachmentId}`,
      expiresAt: metadata.expiresAt,
    });

    const other = await paired();
    const downloadPath = metadata.downloadPath;
    expect((await request(downloadPath, {
      headers: { Authorization: `Bearer ${active.created.adapterToken}` },
    })).status).toBe(401);
    expect((await request(downloadPath, {
      headers: { Authorization: `Bearer ${other.redeemed.clientToken}` },
    })).status).toBe(401);
    expect((await request(`${downloadPath}?token=forbidden`, {
      headers: { Authorization: `Bearer ${active.redeemed.clientToken}` },
    })).status).toBe(400);
    expect((await request(downloadPath, {
      headers: {
        Authorization: `Bearer ${active.redeemed.clientToken}`,
        Range: "bytes=0-1",
      },
    })).status).toBe(400);

    const downloaded = await request(downloadPath, {
      headers: { Authorization: `Bearer ${active.redeemed.clientToken}` },
    });
    expect(downloaded.status).toBe(200);
    expect(downloaded.headers.get("Content-Type")).toBe("image/png");
    expect(downloaded.headers.get("Content-Length")).toBe(String(bytes.byteLength));
    expect(downloaded.headers.get("Cache-Control")).toContain("no-store");
    expect(downloaded.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(new Uint8Array(await downloaded.arrayBuffer())).toEqual(bytes);

    send(active.client, frame(
      active.created.connectionId,
      "ack",
      2,
      { ackSeq: 2 },
    ));
    await eventually(async () => (await request(downloadPath, {
      headers: { Authorization: `Bearer ${active.redeemed.clientToken}` },
    })).status === 404);

    const completionForward = message(active.client);
    send(active.adapter, frame(
      active.created.connectionId,
      "assistant.completed",
      3,
      { turnId: active.turnId, text: "Created 1 file." },
      active.conversationId,
    ));
    expect(JSON.parse((await completionForward).data as string).kind).toBe(
      "assistant.completed",
    );

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(active.created.connectionId),
    );
    const stored = await runInDurableObject(
      sessionStub,
      async (_instance, state) => state.storage.get<SessionRecord>("session"),
    );
    expect(stored?.attachments ?? []).toEqual([]);
    const blobStub = env.ATTACHMENTS.get(
      env.ATTACHMENTS.idFromName(`${active.created.connectionId}:${attachmentId}`),
    );
    const blobKeys = await runInDurableObject(
      blobStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    );
    expect(blobKeys).toEqual([]);
  });

  it("validates long JSON and split UTF-8 prefixes without buffering a full attachment", async () => {
    const cases = [
      {
        fileName: "large.json",
        mediaType: "application/json",
        bytes: new TextEncoder().encode(JSON.stringify({ value: "a".repeat(12_000) })),
      },
      {
        fileName: "split.txt",
        mediaType: "text/plain",
        bytes: new TextEncoder().encode(`${"a".repeat(8_191)}🙂tail`),
      },
    ];
    for (const value of cases) {
      const connectionId = crypto.randomUUID();
      const attachmentId = crypto.randomUUID();
      const now = Date.now();
      const record: AttachmentBlobRecord = {
        v: 1,
        connectionId,
        attachmentId,
        fileName: value.fileName,
        mediaType: value.mediaType,
        byteCount: value.bytes.byteLength,
        sha256: await sha256Hex(value.bytes),
        chunkCount: Math.ceil(value.bytes.byteLength / (512 * 1_024)),
        createdAt: now,
        expiresAt: now + 60_000,
      };
      const blobStub = env.ATTACHMENTS.get(
        env.ATTACHMENTS.idFromName(`${connectionId}:${attachmentId}`),
      );
      const response = await blobStub.fetch("https://attachment.internal/internal/upload", {
        method: "PUT",
        headers: internalAttachmentHeaders(record),
        body: value.bytes,
      });
      expect(response.status).toBe(201);
      const downloaded = await blobStub.fetch("https://attachment.internal/internal/download");
      expect(new Uint8Array(await downloaded.arrayBuffer())).toEqual(value.bytes);
      expect(await runDurableObjectAlarm(blobStub)).toBe(true);
      expect(await runInDurableObject(
        blobStub,
        async (_instance, state) => [...(await state.storage.list()).keys()],
      )).toEqual([]);
    }
  });

  it("cleans partial uploads and removes ready blobs when a connector is revoked", async () => {
    const partialConnectionId = crypto.randomUUID();
    const partialAttachmentId = crypto.randomUUID();
    const now = Date.now();
    const declaredBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const partialRecord: AttachmentBlobRecord = {
      v: 1,
      connectionId: partialConnectionId,
      attachmentId: partialAttachmentId,
      fileName: "partial.png",
      mediaType: "image/png",
      byteCount: declaredBytes.byteLength,
      sha256: await sha256Hex(declaredBytes),
      chunkCount: 1,
      createdAt: now,
      expiresAt: now + 60_000,
    };
    const partialStub = env.ATTACHMENTS.get(
      env.ATTACHMENTS.idFromName(`${partialConnectionId}:${partialAttachmentId}`),
    );
    const shortBody = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(declaredBytes.slice(0, 4));
        controller.close();
      },
    });
    const partialResponse = await partialStub.fetch(
      "https://attachment.internal/internal/upload",
      {
        method: "PUT",
        headers: internalAttachmentHeaders(partialRecord),
        body: shortBody,
      },
    );
    expect(partialResponse.status).toBe(400);
    expect(await runInDurableObject(
      partialStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    )).toEqual([]);

    const active = await activeAttachmentTurn();
    const attachmentId = crypto.randomUUID();
    const bytes = declaredBytes;
    const sha256 = await sha256Hex(bytes);
    const uploaded = await request(
      `/v1/adapters/${active.created.connectionId}/attachments/${attachmentId}`,
      {
        method: "PUT",
        headers: attachmentUploadHeaders({
          token: active.created.adapterToken,
          conversationId: active.conversationId,
          turnId: active.turnId,
          fileName: "revoke.png",
          mediaType: "image/png",
          bytes,
          sha256,
        }),
        body: bytes,
      },
    );
    expect(uploaded.status).toBe(201);
    const revoked = await request(`/v1/connectors/${active.created.connectionId}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${active.created.adapterToken}` },
    });
    expect(revoked.status).toBe(204);
    const blobStub = env.ATTACHMENTS.get(
      env.ATTACHMENTS.idFromName(`${active.created.connectionId}:${attachmentId}`),
    );
    expect(await runInDurableObject(
      blobStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    )).toEqual([]);
  });

  it("removes announced attachment bytes and pending metadata on a failed turn", async () => {
    const active = await activeAttachmentTurn();
    const attachmentId = crypto.randomUUID();
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const sha256 = await sha256Hex(bytes);
    const uploaded = await request(
      `/v1/adapters/${active.created.connectionId}/attachments/${attachmentId}`,
      {
        method: "PUT",
        headers: attachmentUploadHeaders({
          token: active.created.adapterToken,
          conversationId: active.conversationId,
          turnId: active.turnId,
          fileName: "failed.png",
          mediaType: "image/png",
          bytes,
          sha256,
        }),
        body: bytes,
      },
    );
    const metadata = await uploaded.json<Record<string, unknown>>();
    const attachmentForward = message(active.client);
    send(active.adapter, frame(
      active.created.connectionId,
      "assistant.attachment",
      2,
      { turnId: active.turnId, ...metadata, v: undefined },
      active.conversationId,
    ));
    expect(JSON.parse((await attachmentForward).data as string).kind).toBe(
      "assistant.attachment",
    );
    const errorForward = message(active.client);
    send(active.adapter, frame(
      active.created.connectionId,
      "turn.error",
      3,
      {
        turnId: active.turnId,
        code: "agent_failed",
        message: "OpenClaw could not complete this reply.",
        retryable: true,
      },
      active.conversationId,
    ));
    expect(JSON.parse((await errorForward).data as string).kind).toBe("turn.error");

    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(active.created.connectionId),
    );
    await eventually(async () => {
      const stored = await runInDurableObject(
        sessionStub,
        async (_instance, state) => state.storage.get<SessionRecord>("session"),
      );
      return (stored?.attachments?.length ?? 0) === 0 &&
        !stored?.pending.some((pending) => pending.kind === "assistant.attachment");
    });
    const blobStub = env.ATTACHMENTS.get(
      env.ATTACHMENTS.idFromName(`${active.created.connectionId}:${attachmentId}`),
    );
    expect(await runInDurableObject(
      blobStub,
      async (_instance, state) => [...(await state.storage.list()).keys()],
    )).toEqual([]);
  });

  it("enforces eight files and 64 MiB per turn in the session reservation", async () => {
    const active = await activeAttachmentTurn();
    const sessionStub = env.CONNECTOR_SESSIONS.get(
      env.CONNECTOR_SESSIONS.idFromName(active.created.connectionId),
    );
    const now = Date.now();
    const base = {
      conversationId: active.conversationId,
      turnId: active.turnId,
      fileName: "file.bin",
      mediaType: "application/zip",
      sha256: "a".repeat(64),
      createdAt: now,
      expiresAt: now + 60_000,
    };
    const reserve = (value: Record<string, unknown>) => sessionStub.fetch(
      "https://session.internal/internal/attachments/reserve",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${active.created.adapterToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(value),
      },
    );
    for (let index = 0; index < 8; index += 1) {
      const attachmentId = crypto.randomUUID();
      expect((await reserve({
        ...base,
        attachmentId,
        byteCount: 1,
        downloadPath:
          `/v1/connectors/${active.created.connectionId}/attachments/${attachmentId}`,
      })).status).toBe(201);
    }
    const ninthId = crypto.randomUUID();
    expect((await reserve({
      ...base,
      attachmentId: ninthId,
      byteCount: 1,
      downloadPath: `/v1/connectors/${active.created.connectionId}/attachments/${ninthId}`,
    })).status).toBe(413);

    await runInDurableObject(sessionStub, async (_instance, state) => {
      const stored = await state.storage.get<SessionRecord>("session");
      if (stored === undefined) throw new Error("missing session");
      const sized = [0, 1].map((index) => {
        const attachmentId = crypto.randomUUID();
        return {
          ...base,
          attachmentId,
          byteCount: 32 * 1_024 * 1_024,
          downloadPath:
            `/v1/connectors/${active.created.connectionId}/attachments/${attachmentId}`,
          state: "uploading",
        } satisfies AttachmentRecord;
      });
      await state.storage.put("session", { ...stored, attachments: sized });
    });
    const overTotalId = crypto.randomUUID();
    expect((await reserve({
      ...base,
      attachmentId: overTotalId,
      byteCount: 1,
      downloadPath:
        `/v1/connectors/${active.created.connectionId}/attachments/${overTotalId}`,
    })).status).toBe(413);
  });
});

describe("pending-frame encryption", () => {
  it("round-trips only with the exact connection, direction, and sequence AAD", async () => {
    const connectionId = crypto.randomUUID();
    const plaintext = JSON.stringify({ private: "do not persist me as text" });
    const payload = await encryptPendingFrame(
      plaintext,
      TEST_KEK,
      connectionId,
      "client",
      9,
    );
    expect(JSON.stringify(payload)).not.toContain("do not persist");
    await expect(
      decryptPendingFrame(payload, TEST_KEK, connectionId, "client", 9),
    ).resolves.toBe(plaintext);
    await expect(
      decryptPendingFrame(payload, TEST_KEK, connectionId, "adapter", 9),
    ).rejects.toBeDefined();
    await expect(
      decryptPendingFrame(payload, TEST_KEK, connectionId, "client", 10),
    ).rejects.toBeDefined();
    await expect(
      decryptPendingFrame(payload, TEST_KEK, crypto.randomUUID(), "client", 9),
    ).rejects.toBeDefined();
  });

  it("rejects ciphertext and IV tampering", async () => {
    const connectionId = crypto.randomUUID();
    const payload = await encryptPendingFrame(
      "sensitive",
      TEST_KEK,
      connectionId,
      "adapter",
      3,
    );
    const tamperedCiphertext = {
      ...payload,
      ciphertext: `${payload.ciphertext.slice(0, -2)}AA`,
    };
    await expect(
      decryptPendingFrame(
        tamperedCiphertext,
        TEST_KEK,
        connectionId,
        "adapter",
        3,
      ),
    ).rejects.toBeDefined();

    const pending: PendingFrame = {
      from: "adapter",
      seq: 3,
      messageId: crypto.randomUUID(),
      encrypted: payload,
      expiresAt: Date.now() + 1_000,
    };
    expect(JSON.stringify(pending)).not.toContain("sensitive");
  });
});
