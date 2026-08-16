import { authenticateAgent, authenticateClient } from "./auth";
import {
  CLAIM_REQUEST_LIMIT_BYTES,
  parseJsonBody,
  readBoundedRequestBody,
  SESSION_REQUEST_LIMIT_BYTES,
} from "./body";
import { profileHash } from "./crypto";
import { HttpError } from "./errors";
import { CredentialLease } from "./lease";
import { createParticipantToken } from "./livekit";
import { parseClaimRequest, parseSessionStartRequest } from "./validation";
import type { CredentialBundle } from "./types";

export { CredentialLease };

const SESSION_PATH = "/v1/live-talk/sessions";
const CLAIM_PATH = /^\/v1\/credential-leases\/([a-f0-9]{32})\/claim$/;
const ROOM_PREFIX = "openclam-lk-";
const PARTICIPANT_PREFIX = "user-";
const LEASE_MIN_SECONDS = 30;
const LEASE_MAX_SECONDS = 300;

function securityHeaders(headers = new Headers()): Headers {
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  return headers;
}

function json(value: unknown, status = 200, headers?: Headers): Response {
  return Response.json(value, {
    status,
    headers: securityHeaders(headers),
  });
}

function allowedOrigin(request: Request, env: Env): string | null {
  const origin = request.headers.get("Origin");
  return origin !== null && origin === env.CORS_ORIGIN ? origin : null;
}

function corsHeaders(request: Request, env: Env): Headers {
  const headers = new Headers();
  const origin = allowedOrigin(request, env);
  if (origin !== null) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Max-Age", "600");
    headers.set("Vary", "Origin");
  }
  return headers;
}

function randomHex(bytes: number): string {
  return [...crypto.getRandomValues(new Uint8Array(bytes))]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

function leaseTtl(env: Env): number {
  const ttl = Number(env.BYOK_LEASE_TTL_SECONDS);
  if (!Number.isInteger(ttl) || ttl < LEASE_MIN_SECONDS || ttl > LEASE_MAX_SECONDS) {
    throw new Error("invalid_byok_lease_ttl");
  }
  return ttl;
}

async function createSession(request: Request, env: Env): Promise<Response> {
  await authenticateClient(request, env);
  const rawBody = await readBoundedRequestBody(request, SESSION_REQUEST_LIMIT_BYTES);
  const input = parseSessionStartRequest(parseJsonBody(rawBody.text));
  const leaseId = randomHex(16);
  const roomName = `${ROOM_PREFIX}${randomHex(12)}`;
  const participantIdentity = `${PARTICIPANT_PREFIX}${randomHex(12)}`;
  const hash = await profileHash(input.profile, leaseId);
  const expiresAt = Date.now() + leaseTtl(env) * 1_000;

  const bundle: CredentialBundle = {
    schema_version: 1,
    profile: input.profile,
    credentials: input.credentials,
  };
  const lease = env.CREDENTIAL_LEASES.get(env.CREDENTIAL_LEASES.idFromName(leaseId));
  const stored = await lease.fetch("https://lease.internal/internal/create", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      schema_version: 1,
      lease_id: leaseId,
      room_name: roomName,
      agent_name: env.LIVEKIT_AGENT_NAME,
      profile_hash: hash,
      expires_at: expiresAt,
      bundle,
    }),
  });
  if (!stored.ok) {
    throw new Error("lease_creation_failed");
  }

  const dispatchMetadata = JSON.stringify({
    schema_version: 1,
    lease_id: leaseId,
    profile_hash: hash,
  });
  let participantToken: string;
  try {
    participantToken = await createParticipantToken({
      roomName,
      participantIdentity,
      participantName: input.participant_name ?? "OpenClam User",
      metadata: dispatchMetadata,
      env,
    });
  } catch {
    await lease.fetch("https://lease.internal/internal/delete", { method: "POST" });
    throw new Error("livekit_token_creation_failed");
  }

  return json(
    {
      server_url: env.LIVEKIT_URL,
      participant_token: participantToken,
    },
    201,
    corsHeaders(request, env),
  );
}

async function claimLease(
  request: Request,
  env: Env,
  leaseId: string,
): Promise<Response> {
  const rawBody = await readBoundedRequestBody(request, CLAIM_REQUEST_LIMIT_BYTES);
  const authenticated = await authenticateAgent(request, env, rawBody.bytes);
  const claimValue = parseJsonBody(rawBody.text);
  const claim = parseClaimRequest(claimValue);
  if (claim.agent_name !== env.LIVEKIT_AGENT_NAME) {
    throw new HttpError(403, "agent_not_allowed");
  }
  const lease = env.CREDENTIAL_LEASES.get(env.CREDENTIAL_LEASES.idFromName(leaseId));
  const response = await lease.fetch(
    `https://lease.internal/internal/claim?lease_id=${encodeURIComponent(leaseId)}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...claim,
        auth_timestamp: authenticated.timestamp,
        auth_nonce: authenticated.nonce,
      }),
    },
  );
  return new Response(response.body, {
    status: response.status,
    headers: securityHeaders(new Headers({ "Content-Type": "application/json" })),
  });
}

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true, service: "openclam-livekit-pilot-broker" });
  }
  if (request.method === "OPTIONS") {
    if (allowedOrigin(request, env) === null) {
      return json({ error: "origin_not_allowed" }, 403);
    }
    return new Response(null, { status: 204, headers: corsHeaders(request, env) });
  }
  if (request.method === "POST" && url.pathname === SESSION_PATH) {
    return createSession(request, env);
  }
  const claimMatch = CLAIM_PATH.exec(url.pathname);
  if (request.method === "POST" && claimMatch?.[1] !== undefined) {
    return claimLease(request, env, claimMatch[1]);
  }
  return json({ error: "not_found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof Response) {
        return new Response(error.body, {
          status: error.status,
          headers: securityHeaders(error.headers),
        });
      }
      if (error instanceof HttpError) {
        return json({ error: error.code }, error.status, corsHeaders(request, env));
      }
      // Deliberately do not log the exception: it may contain provider output
      // or request material. Observability still records status/latency.
      return json({ error: "internal_error" }, 500, corsHeaders(request, env));
    }
  },
} satisfies ExportedHandler<Env>;
