import type { EncryptedPayload, SocketRole } from "./types";

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const bytes: Uint8Array<ArrayBuffer> = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

async function pendingEventKey(encodedKey: string): Promise<CryptoKey> {
  let raw: Uint8Array<ArrayBuffer>;
  try {
    raw = base64ToBytes(encodedKey);
  } catch {
    throw new Error("invalid_pending_event_kek");
  }
  if (raw.byteLength !== 32) throw new Error("invalid_pending_event_kek");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

export function pendingFrameAdditionalData(
  connectionId: string,
  from: SocketRole,
  seq: number,
): string {
  return `${connectionId}\n${from}\n${seq}`;
}

export function pairingClientTokenAdditionalData(
  connectionId: string,
  installationVerifier: string,
): string {
  return `${connectionId}\nclient-token\n${installationVerifier}`;
}

export async function encryptPendingFrame(
  encodedFrame: string,
  encodedKey: string,
  connectionId: string,
  from: SocketRole,
  seq: number,
): Promise<EncryptedPayload> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: encoder.encode(
        pendingFrameAdditionalData(connectionId, from, seq),
      ),
      tagLength: 128,
    },
    await pendingEventKey(encodedKey),
    encoder.encode(encodedFrame),
  );
  return {
    algorithm: "A256GCM",
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
  };
}

export async function decryptPendingFrame(
  payload: EncryptedPayload,
  encodedKey: string,
  connectionId: string,
  from: SocketRole,
  seq: number,
): Promise<string> {
  if (payload.algorithm !== "A256GCM") {
    throw new Error("unsupported_pending_encryption");
  }
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: base64ToBytes(payload.iv),
      additionalData: encoder.encode(
        pendingFrameAdditionalData(connectionId, from, seq),
      ),
      tagLength: 128,
    },
    await pendingEventKey(encodedKey),
    base64ToBytes(payload.ciphertext),
  );
  return decoder.decode(plaintext);
}

export async function encryptPairingClientToken(
  token: string,
  encodedKey: string,
  connectionId: string,
  installationVerifier: string,
): Promise<EncryptedPayload> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: encoder.encode(
        pairingClientTokenAdditionalData(connectionId, installationVerifier),
      ),
      tagLength: 128,
    },
    await pendingEventKey(encodedKey),
    encoder.encode(token),
  );
  return {
    algorithm: "A256GCM",
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
  };
}

export async function decryptPairingClientToken(
  payload: EncryptedPayload,
  encodedKey: string,
  connectionId: string,
  installationVerifier: string,
): Promise<string> {
  if (payload.algorithm !== "A256GCM") {
    throw new Error("unsupported_pairing_encryption");
  }
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: base64ToBytes(payload.iv),
      additionalData: encoder.encode(
        pairingClientTokenAdditionalData(connectionId, installationVerifier),
      ),
      tagLength: 128,
    },
    await pendingEventKey(encodedKey),
    base64ToBytes(payload.ciphertext),
  );
  return decoder.decode(plaintext);
}

export async function sha256Hex(value: string): Promise<string> {
  const hash = new Uint8Array(
    await crypto.subtle.digest("SHA-256", encoder.encode(value)),
  );
  return [...hash].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function secureEqual(
  candidate: string,
  expected: string,
): Promise<boolean> {
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const leftBytes = new Uint8Array(left);
  const rightBytes = new Uint8Array(right);
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return difference === 0;
}

export async function pairingVerifier(
  code: string,
  pepper: string,
): Promise<string> {
  return sha256Hex(`${pepper}\nopenclam-pairing-v1\n${code}`);
}

export async function tokenVerifier(
  token: string,
  pepper: string,
  role: "client" | "adapter",
  connectionId: string,
): Promise<string> {
  return sha256Hex(
    `${pepper}\nopenclam-token-v1\n${role}\n${connectionId}\n${token}`,
  );
}

export async function installationVerifier(
  installationId: string,
  pepper: string,
): Promise<string> {
  return sha256Hex(
    `${pepper}\nopenclam-installation-v1\n${installationId}`,
  );
}

export function randomToken(): string {
  return bytesToBase64Url(crypto.getRandomValues(new Uint8Array(32)));
}

export function randomPairingCode(): string {
  const random = crypto.getRandomValues(new Uint8Array(12));
  const characters = [...random]
    .map((byte) => CROCKFORD[byte & 31] ?? "0")
    .join("");
  return `OC-${characters.slice(0, 4)}-${characters.slice(4, 8)}-${characters.slice(8)}`;
}

export function randomId(): string {
  return crypto.randomUUID();
}
