import {
  parseJsonBody,
  readBoundedRequestBody,
  requireEmptyRequestBody,
} from "./body";
import { ConnectorAttachment } from "./attachment";
import {
  pairingVerifier,
  randomId,
  randomPairingCode,
  randomToken,
  secureEqual,
  tokenVerifier,
} from "./crypto";
import {
  HttpError,
  publicError,
  type PublicErrorCode,
  unauthorized,
} from "./errors";
import { PairingCoordinator } from "./pairing";
import { ConnectorSession } from "./session";
import type {
  AttachmentRecord,
  CreatePairingRequest,
  PairingRecord,
  SocketRole,
} from "./types";
import {
  bearerToken,
  CREATE_BODY_LIMIT_BYTES,
  parseCreatePairing,
  parseAttachmentUpload,
  parseRedeemPairing,
  REDEEM_BODY_LIMIT_BYTES,
  uuidPath,
} from "./validation";

export { ConnectorAttachment, ConnectorSession, PairingCoordinator };

const CREATE_PAIRING_PATH = "/v1/pairings";
const REDEEM_PAIRING_PATH = "/v1/pairings/redeem";
const CLIENT_EVENTS_PATH = /^\/v1\/connectors\/([^/]+)\/events$/;
const ADAPTER_EVENTS_PATH = /^\/v1\/adapters\/([^/]+)\/events$/;
const ADAPTER_PAIRING_PATH = /^\/v1\/adapters\/([^/]+)\/pairings$/;
const CLIENT_STATUS_PATH = /^\/v1\/connectors\/([^/]+)\/status$/;
const DELETE_CONNECTOR_PATH = /^\/v1\/connectors\/([^/]+)$/;
const ADAPTER_ATTACHMENT_PATH =
  /^\/v1\/adapters\/([^/]+)\/attachments\/([^/]+)$/;
const CLIENT_ATTACHMENT_PATH =
  /^\/v1\/connectors\/([^/]+)\/attachments\/([^/]+)$/;
const PAIRING_COORDINATOR_NAME = "openclam-agent-connector-v1";

function securityHeaders(headers = new Headers()): Headers {
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  return headers;
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: securityHeaders() });
}

function errorResponse(code: PublicErrorCode, status: number): Response {
  return json(publicError(code), status);
}

function validateConfiguration(env: Env): void {
  if (
    env.BRIDGE_BOOTSTRAP_TOKEN.length < 40 ||
    (env.BRIDGE_BOOTSTRAP_TOKEN_NEXT !== undefined &&
      env.BRIDGE_BOOTSTRAP_TOKEN_NEXT.length < 40) ||
    env.PAIRING_CODE_PEPPER.length < 32 ||
    env.TOKEN_VERIFIER_PEPPER.length < 32 ||
    env.PENDING_EVENT_KEK_B64.length < 40
  ) {
    throw new HttpError(503, "unavailable");
  }
}

function pairingTtlMilliseconds(env: Env): number {
  const seconds = Number(env.PAIRING_TTL_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 60 || seconds > 600) {
    throw new HttpError(503, "unavailable");
  }
  return seconds * 1_000;
}

function attachmentTtlMilliseconds(env: Env): number {
  const seconds = Number(env.ATTACHMENT_TTL_SECONDS);
  if (!Number.isInteger(seconds) || seconds < 300 || seconds > 7 * 24 * 60 * 60) {
    throw new HttpError(503, "unavailable");
  }
  return seconds * 1_000;
}

function requireJson(request: Request): void {
  const contentType = request.headers.get("Content-Type") ?? "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    throw new HttpError(400, "invalid_request");
  }
}

async function authenticateBootstrap(request: Request, env: Env): Promise<void> {
  const candidate = bearerToken(request);
  if (candidate === null) {
    unauthorized();
  }
  const currentMatches = await secureEqual(candidate, env.BRIDGE_BOOTSTRAP_TOKEN);
  const nextMatches = env.BRIDGE_BOOTSTRAP_TOKEN_NEXT === undefined
    ? false
    : await secureEqual(candidate, env.BRIDGE_BOOTSTRAP_TOKEN_NEXT);
  if (!currentMatches && !nextMatches) unauthorized();
}

function coordinator(env: Env): DurableObjectStub<PairingCoordinator> {
  return env.PAIRINGS.get(env.PAIRINGS.idFromName(PAIRING_COORDINATOR_NAME));
}

function session(env: Env, connectionId: string): DurableObjectStub<ConnectorSession> {
  return env.CONNECTOR_SESSIONS.get(
    env.CONNECTOR_SESSIONS.idFromName(connectionId),
  );
}

function attachment(
  env: Env,
  connectionId: string,
  attachmentId: string,
): DurableObjectStub<ConnectorAttachment> {
  return env.ATTACHMENTS.get(
    env.ATTACHMENTS.idFromName(`${connectionId}:${attachmentId}`),
  );
}

function authorizationHeaders(request: Request): Headers {
  const headers = new Headers();
  const authorization = request.headers.get("Authorization");
  if (authorization !== null) headers.set("Authorization", authorization);
  return headers;
}

function attachmentBlobHeaders(record: AttachmentRecord): Headers {
  return new Headers({
    "Content-Length": String(record.byteCount),
    "X-OpenClam-Attachment-Id": record.attachmentId,
    "X-OpenClam-Byte-Count": String(record.byteCount),
    "X-OpenClam-Connection-Id": record.downloadPath.split("/")[3] ?? "",
    "X-OpenClam-Created-At": String(record.createdAt),
    "X-OpenClam-Expires-At": String(record.expiresAt),
    "X-OpenClam-File-Name-B64": btoa(
      String.fromCharCode(...new TextEncoder().encode(record.fileName)),
    ).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=+$/u, ""),
    "X-OpenClam-Media-Type": record.mediaType,
    "X-OpenClam-SHA256": record.sha256,
  });
}

async function deleteAttachmentBlob(
  env: Env,
  connectionId: string,
  attachmentId: string,
): Promise<void> {
  try {
    await attachment(env, connectionId, attachmentId).fetch(
      "https://attachment.internal/internal/delete",
      { method: "DELETE" },
    );
  } catch {
    // The attachment Durable Object alarm remains the bounded cleanup fallback.
  }
}

async function issuePairing(
  env: Env,
  input: CreatePairingRequest,
): Promise<Response> {
  const now = Date.now();
  const expiresAt = now + pairingTtlMilliseconds(env);
  const unpairedCleanupAt = expiresAt + pairingTtlMilliseconds(env);

  for (let attempt = 0; attempt < 4; attempt += 1) {
    const code = randomPairingCode();
    const pairingId = randomId();
    const connectionId = randomId();
    const adapterToken = randomToken();
    const verifier = await pairingVerifier(code, env.PAIRING_CODE_PEPPER);
    const adapterTokenVerifier = await tokenVerifier(
      adapterToken,
      env.TOKEN_VERIFIER_PEPPER,
      "adapter",
      connectionId,
    );
    const record: PairingRecord = {
      v: 1,
      pairingId,
      connectionId,
      adapterId: input.adapterId,
      gatewayLabel: input.gatewayLabel,
      accounts: input.accounts,
      verifier,
      createdAt: now,
      expiresAt,
    };
    const stored = await coordinator(env).fetch(
      "https://pairing.internal/internal/create",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ record }),
      },
    );
    if (stored.status === 409) continue;
    if (!stored.ok) throw new HttpError(503, "unavailable");

    const created = await session(env, connectionId).fetch(
      "https://session.internal/internal/create",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          connectionId,
          adapterId: input.adapterId,
          gatewayLabel: input.gatewayLabel,
          accounts: input.accounts,
          adapterTokenVerifier,
          createdAt: now,
          unpairedCleanupAt,
        }),
      },
    );
    if (!created.ok) {
      await coordinator(env).fetch("https://pairing.internal/internal/delete", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ verifier }),
      });
      throw new HttpError(503, "unavailable");
    }

    return json(
      { v: 1, pairingId, connectionId, code, expiresAt, adapterToken },
      201,
    );
  }
  throw new HttpError(503, "unavailable");
}

async function createPairing(request: Request, env: Env): Promise<Response> {
  validateConfiguration(env);
  await authenticateBootstrap(request, env);
  requireJson(request);
  const raw = await readBoundedRequestBody(request, CREATE_BODY_LIMIT_BYTES);
  return issuePairing(env, parseCreatePairing(parseJsonBody(raw.text)));
}

async function createAdapterPairing(
  request: Request,
  env: Env,
  connectionId: string,
): Promise<Response> {
  validateConfiguration(env);
  if (!uuidPath(connectionId)) return errorResponse("not_found", 404);
  await requireEmptyRequestBody(request);
  const headers = authorizationHeaders(request);
  const authorized = await session(env, connectionId).fetch(
    "https://session.internal/internal/pairings/authorize",
    { method: "POST", headers },
  );
  if (!authorized.ok) {
    if (authorized.status === 401) return errorResponse("unauthorized", 401);
    if (authorized.status === 404) return errorResponse("not_found", 404);
    if (authorized.status === 409) return errorResponse("conversation_busy", 409);
    return errorResponse("unavailable", 503);
  }
  const input = parseCreatePairing(await authorized.json());
  return issuePairing(env, input);
}

async function connectorStatus(
  request: Request,
  env: Env,
  connectionId: string,
): Promise<Response> {
  validateConfiguration(env);
  if (!uuidPath(connectionId)) return errorResponse("not_found", 404);
  await requireEmptyRequestBody(request);
  const response = await session(env, connectionId).fetch(
    "https://session.internal/internal/status",
    { method: "GET", headers: authorizationHeaders(request) },
  );
  if (response.status === 204) return new Response(null, { status: 204 });
  if (response.status === 401) return errorResponse("unauthorized", 401);
  if (response.status === 404) return errorResponse("not_found", 404);
  return errorResponse("unavailable", 503);
}

async function redeemPairing(request: Request, env: Env): Promise<Response> {
  validateConfiguration(env);
  requireJson(request);
  const raw = await readBoundedRequestBody(request, REDEEM_BODY_LIMIT_BYTES);
  const input = parseRedeemPairing(parseJsonBody(raw.text));
  const response = await coordinator(env).fetch(
    "https://pairing.internal/internal/redeem",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input),
    },
  );
  if (response.ok) {
    return new Response(response.body, {
      status: response.status,
      headers: securityHeaders(new Headers({ "Content-Type": "application/json" })),
    });
  }
  const value = await response.json<{ error?: PublicErrorCode }>();
  const code = value.error;
  if (
    code === "not_found" ||
    code === "pairing_expired" ||
    code === "pairing_locked" ||
    code === "pairing_consumed" ||
    code === "unavailable"
  ) {
    return errorResponse(code, response.status);
  }
  return errorResponse("unavailable", 503);
}

async function connectSocket(
  request: Request,
  env: Env,
  connectionId: string,
  role: SocketRole,
): Promise<Response> {
  validateConfiguration(env);
  if (!uuidPath(connectionId)) return errorResponse("not_found", 404);
  const headers = new Headers();
  const authorization = request.headers.get("Authorization");
  const upgrade = request.headers.get("Upgrade");
  if (authorization !== null) headers.set("Authorization", authorization);
  if (upgrade !== null) headers.set("Upgrade", upgrade);
  const response = await session(env, connectionId).fetch(
    `https://session.internal/internal/connect?role=${role}`,
    { method: "GET", headers },
  );
  if (response.status === 101) return response;
  const value = await response.json<{ error?: string }>();
  if (value.error === "unauthorized") return errorResponse("unauthorized", 401);
  if (value.error === "not_found") return errorResponse("not_found", 404);
  if (value.error === "invalid_request") return errorResponse("invalid_request", 400);
  return errorResponse("unavailable", 503);
}

async function deleteConnector(
  request: Request,
  env: Env,
  connectionId: string,
): Promise<Response> {
  validateConfiguration(env);
  if (!uuidPath(connectionId)) return errorResponse("not_found", 404);
  await requireEmptyRequestBody(request);
  const headers = new Headers();
  const authorization = request.headers.get("Authorization");
  if (authorization !== null) headers.set("Authorization", authorization);
  const response = await session(env, connectionId).fetch(
    "https://session.internal/internal/delete",
    { method: "DELETE", headers },
  );
  if (response.status === 204) {
    // Session deletion is the fail-closed security boundary. Pairing metadata
    // is removed immediately when possible and remains bounded by its alarm if
    // the coordinator is transiently unavailable.
    try {
      await coordinator(env).fetch(
        "https://pairing.internal/internal/delete-connection",
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ connectionId }),
        },
      );
    } catch {
      // Never turn a completed revocation into a misleading retryable failure.
    }
    return new Response(null, { status: 204 });
  }
  const value = await response.json<{ error?: string }>();
  if (value.error === "unauthorized") return errorResponse("unauthorized", 401);
  if (value.error === "not_found") return errorResponse("not_found", 404);
  return errorResponse("unavailable", 503);
}

async function uploadAttachment(
  request: Request,
  env: Env,
  connectionId: string,
  attachmentId: string,
): Promise<Response> {
  validateConfiguration(env);
  if (!uuidPath(connectionId) || !uuidPath(attachmentId)) {
    return errorResponse("not_found", 404);
  }
  const input = parseAttachmentUpload(request, attachmentId);
  const now = Date.now();
  const candidate: AttachmentRecord = {
    ...input,
    downloadPath: `/v1/connectors/${connectionId}/attachments/${attachmentId}`,
    createdAt: now,
    expiresAt: now + attachmentTtlMilliseconds(env),
    state: "uploading",
  };
  const authHeaders = authorizationHeaders(request);
  authHeaders.set("Content-Type", "application/json");
  const reserve = await session(env, connectionId).fetch(
    "https://session.internal/internal/attachments/reserve",
    {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify(candidate),
    },
  );
  if (!reserve.ok) {
    if (reserve.status === 401) return errorResponse("unauthorized", 401);
    if (reserve.status === 404) return errorResponse("not_found", 404);
    if (reserve.status === 413) return errorResponse("invalid_request", 413);
    if (reserve.status === 409) return errorResponse("invalid_request", 409);
    return errorResponse("unavailable", 503);
  }
  const reserved = await reserve.json<{ attachment?: AttachmentRecord }>();
  const record = reserved.attachment;
  if (
    record === undefined ||
    record.attachmentId !== input.attachmentId ||
    record.conversationId !== input.conversationId ||
    record.turnId !== input.turnId ||
    record.fileName !== input.fileName ||
    record.mediaType !== input.mediaType ||
    record.byteCount !== input.byteCount ||
    record.sha256 !== input.sha256 ||
    record.downloadPath !== candidate.downloadPath
  ) {
    return errorResponse("unavailable", 503);
  }

  const blobResponse = await attachment(env, connectionId, attachmentId).fetch(
    "https://attachment.internal/internal/upload",
    {
      method: "PUT",
      headers: attachmentBlobHeaders(record),
      body: request.body,
    },
  );
  if (!blobResponse.ok) {
    await session(env, connectionId).fetch(
      "https://session.internal/internal/attachments/abort",
      {
        method: "POST",
        headers: authHeaders,
        body: JSON.stringify({ attachmentId }),
      },
    );
    await deleteAttachmentBlob(env, connectionId, attachmentId);
    return blobResponse.status === 400 || blobResponse.status === 409
      ? errorResponse("invalid_request", blobResponse.status)
      : errorResponse("unavailable", 503);
  }

  const commit = await session(env, connectionId).fetch(
    "https://session.internal/internal/attachments/commit",
    {
      method: "POST",
      headers: authHeaders,
      body: JSON.stringify({ attachmentId }),
    },
  );
  if (!commit.ok) {
    await deleteAttachmentBlob(env, connectionId, attachmentId);
    await session(env, connectionId).fetch(
      "https://session.internal/internal/attachments/abort",
      {
        method: "POST",
        headers: authHeaders,
        body: JSON.stringify({ attachmentId }),
      },
    );
    return commit.status === 401
      ? errorResponse("unauthorized", 401)
      : commit.status === 404
        ? errorResponse("not_found", 404)
        : errorResponse("unavailable", 503);
  }
  return json(
    {
      v: 1,
      attachmentId: record.attachmentId,
      fileName: record.fileName,
      mediaType: record.mediaType,
      byteCount: record.byteCount,
      sha256: record.sha256,
      downloadPath: record.downloadPath,
      expiresAt: record.expiresAt,
    },
    201,
  );
}

async function downloadAttachment(
  request: Request,
  env: Env,
  connectionId: string,
  attachmentId: string,
): Promise<Response> {
  validateConfiguration(env);
  const url = new URL(request.url);
  if (
    !uuidPath(connectionId) ||
    !uuidPath(attachmentId) ||
    url.search !== "" ||
    request.headers.has("Range")
  ) {
    return errorResponse("invalid_request", 400);
  }
  const authorization = authorizationHeaders(request);
  const allowed = await session(env, connectionId).fetch(
    `https://session.internal/internal/attachments/${attachmentId}`,
    { method: "GET", headers: authorization },
  );
  if (!allowed.ok) {
    if (allowed.status === 401) return errorResponse("unauthorized", 401);
    if (allowed.status === 404) return errorResponse("not_found", 404);
    return errorResponse("unavailable", 503);
  }
  const response = await attachment(env, connectionId, attachmentId).fetch(
    "https://attachment.internal/internal/download",
  );
  if (!response.ok) {
    return response.status === 404
      ? errorResponse("not_found", 404)
      : errorResponse("unavailable", 503);
  }
  return new Response(response.body, {
    status: 200,
    headers: securityHeaders(new Headers(response.headers)),
  });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, service: "openclam-openclaw-bridge", protocol: 1 });
  }
  if (request.method === "POST" && url.pathname === CREATE_PAIRING_PATH) {
    return createPairing(request, env);
  }
  if (request.method === "POST" && url.pathname === REDEEM_PAIRING_PATH) {
    return redeemPairing(request, env);
  }

  const clientMatch = CLIENT_EVENTS_PATH.exec(url.pathname);
  if (request.method === "GET" && clientMatch?.[1] !== undefined) {
    return connectSocket(request, env, clientMatch[1], "client");
  }
  const adapterMatch = ADAPTER_EVENTS_PATH.exec(url.pathname);
  if (request.method === "GET" && adapterMatch?.[1] !== undefined) {
    return connectSocket(request, env, adapterMatch[1], "adapter");
  }
  const adapterPairingMatch = ADAPTER_PAIRING_PATH.exec(url.pathname);
  if (request.method === "POST" && adapterPairingMatch?.[1] !== undefined) {
    return createAdapterPairing(request, env, adapterPairingMatch[1]);
  }
  const clientStatusMatch = CLIENT_STATUS_PATH.exec(url.pathname);
  if (request.method === "GET" && clientStatusMatch?.[1] !== undefined) {
    return connectorStatus(request, env, clientStatusMatch[1]);
  }
  const adapterAttachmentMatch = ADAPTER_ATTACHMENT_PATH.exec(url.pathname);
  if (
    request.method === "PUT" &&
    adapterAttachmentMatch?.[1] !== undefined &&
    adapterAttachmentMatch[2] !== undefined
  ) {
    return uploadAttachment(
      request,
      env,
      adapterAttachmentMatch[1],
      adapterAttachmentMatch[2],
    );
  }
  const clientAttachmentMatch = CLIENT_ATTACHMENT_PATH.exec(url.pathname);
  if (
    request.method === "GET" &&
    clientAttachmentMatch?.[1] !== undefined &&
    clientAttachmentMatch[2] !== undefined
  ) {
    return downloadAttachment(
      request,
      env,
      clientAttachmentMatch[1],
      clientAttachmentMatch[2],
    );
  }
  const deleteMatch = DELETE_CONNECTOR_PATH.exec(url.pathname);
  if (request.method === "DELETE" && deleteMatch?.[1] !== undefined) {
    return deleteConnector(request, env, deleteMatch[1]);
  }
  return errorResponse("not_found", 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HttpError) {
        return errorResponse(error.code, error.status);
      }
      // Never log request, frame, token, or transcript material.
      return errorResponse("unavailable", 503);
    }
  },
} satisfies ExportedHandler<Env>;
