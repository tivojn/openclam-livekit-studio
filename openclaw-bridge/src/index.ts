import { readBoundedRequestBody, parseJsonBody } from "./body";
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
import type { PairingRecord, SocketRole } from "./types";
import {
  bearerToken,
  CREATE_BODY_LIMIT_BYTES,
  parseCreatePairing,
  parseRedeemPairing,
  REDEEM_BODY_LIMIT_BYTES,
  uuidPath,
} from "./validation";

export { ConnectorSession, PairingCoordinator };

const CREATE_PAIRING_PATH = "/v1/pairings";
const REDEEM_PAIRING_PATH = "/v1/pairings/redeem";
const CLIENT_EVENTS_PATH = /^\/v1\/connectors\/([^/]+)\/events$/;
const ADAPTER_EVENTS_PATH = /^\/v1\/adapters\/([^/]+)\/events$/;
const DELETE_CONNECTOR_PATH = /^\/v1\/connectors\/([^/]+)$/;
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

function requireJson(request: Request): void {
  const contentType = request.headers.get("Content-Type") ?? "";
  if (!/^application\/json(?:\s*;|$)/i.test(contentType)) {
    throw new HttpError(400, "invalid_request");
  }
}

async function authenticateBootstrap(request: Request, env: Env): Promise<void> {
  const candidate = bearerToken(request);
  if (
    candidate === null ||
    !(await secureEqual(candidate, env.BRIDGE_BOOTSTRAP_TOKEN))
  ) {
    unauthorized();
  }
}

function coordinator(env: Env): DurableObjectStub<PairingCoordinator> {
  return env.PAIRINGS.get(env.PAIRINGS.idFromName(PAIRING_COORDINATOR_NAME));
}

function session(env: Env, connectionId: string): DurableObjectStub<ConnectorSession> {
  return env.CONNECTOR_SESSIONS.get(
    env.CONNECTOR_SESSIONS.idFromName(connectionId),
  );
}

async function createPairing(request: Request, env: Env): Promise<Response> {
  validateConfiguration(env);
  await authenticateBootstrap(request, env);
  requireJson(request);
  const raw = await readBoundedRequestBody(request, CREATE_BODY_LIMIT_BYTES);
  const input = parseCreatePairing(parseJsonBody(raw.text));
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
  if (request.body !== null) return errorResponse("invalid_request", 400);
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
