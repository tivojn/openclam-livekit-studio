import { HttpError, unauthorized } from "./errors";

const BEARER_PREFIX = "Bearer ";

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
}

async function digestBytes(value: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", value));
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export async function secureEqual(
  candidate: string,
  expected: string,
): Promise<boolean> {
  const [left, right] = await Promise.all([digest(candidate), digest(expected)]);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function bearerValue(request: Request): string | null {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith(BEARER_PREFIX)) {
    return null;
  }
  const value = header.slice(BEARER_PREFIX.length);
  return value.length > 0 ? value : null;
}

export async function authenticateClient(
  request: Request,
  env: Env,
): Promise<void> {
  // Fail closed until the production App Attest verifier is wired in. The pilot
  // bearer is acceptable only for the internal TestFlight proof of concept.
  if (env.AUTH_MODE !== "pilot") {
    throw new HttpError(503, "client_authentication_not_configured");
  }

  const candidate = bearerValue(request);
  if (
    candidate === null ||
    env.PILOT_APP_TOKEN.length < 32 ||
    !(await secureEqual(candidate, env.PILOT_APP_TOKEN))
  ) {
    unauthorized();
  }
}

export async function authenticateAgent(
  request: Request,
  env: Env,
  body: Uint8Array<ArrayBuffer>,
): Promise<{ timestamp: number; nonce: string }> {
  if (env.OPENCLAM_BROKER_AGENT_TOKEN.length < 32) {
    unauthorized();
  }

  const timestampValue = request.headers.get("X-OpenClam-Timestamp") ?? "";
  const nonce = request.headers.get("X-OpenClam-Nonce") ?? "";
  const signature = request.headers.get("X-OpenClam-Signature") ?? "";
  const timestamp = Number(timestampValue);
  const now = Math.floor(Date.now() / 1_000);
  if (
    !/^\d{10}$/.test(timestampValue) ||
    !Number.isSafeInteger(timestamp) ||
    Math.abs(now - timestamp) > 30 ||
    !/^[A-Za-z0-9_-]{24}$/.test(nonce) ||
    !/^[A-Za-z0-9_-]{43}$/.test(signature)
  ) {
    unauthorized();
  }

  const url = new URL(request.url);
  const bodyHash = [...(await digestBytes(body))]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  const canonical = `${timestampValue}\n${nonce}\n${request.method.toUpperCase()}\n${url.pathname}\n${bodyHash}`;
  const hmacKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.OPENCLAM_BROKER_AGENT_TOKEN),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = bytesToBase64Url(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", hmacKey, new TextEncoder().encode(canonical)),
    ),
  );
  if (!(await secureEqual(signature, expected))) {
    unauthorized();
  }
  return { timestamp, nonce };
}
