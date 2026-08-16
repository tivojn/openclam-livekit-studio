import type { EncryptedPayload, LiveTalkProfile } from "./types";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
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

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (typeof value === "object" && value !== null) {
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      sorted[key] = canonicalize((value as Record<string, unknown>)[key]);
    }
    return sorted;
  }
  return value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

export async function sha256Hex(value: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
  return [...hash].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function profileHash(
  profile: LiveTalkProfile,
  leaseId: string,
): Promise<string> {
  return sha256Hex(`${canonicalJson(profile)}\n${leaseId}`);
}

async function encryptionKey(encodedKey: string): Promise<CryptoKey> {
  let raw: Uint8Array<ArrayBuffer>;
  try {
    raw = base64ToBytes(encodedKey);
  } catch {
    throw new Error("invalid_byok_kek");
  }
  if (raw.byteLength !== 32) {
    throw new Error("invalid_byok_kek");
  }
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function encryptJson(
  value: unknown,
  encodedKey: string,
  additionalData: string,
): Promise<EncryptedPayload> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: encoder.encode(additionalData),
      tagLength: 128,
    },
    await encryptionKey(encodedKey),
    encoder.encode(JSON.stringify(value)),
  );
  return {
    algorithm: "A256GCM",
    iv: bytesToBase64(iv),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
  };
}

export async function decryptJson<T>(
  payload: EncryptedPayload,
  encodedKey: string,
  additionalData: string,
): Promise<T> {
  if (payload.algorithm !== "A256GCM") {
    throw new Error("unsupported_encryption_algorithm");
  }
  const plaintext = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: base64ToBytes(payload.iv),
      additionalData: encoder.encode(additionalData),
      tagLength: 128,
    },
    await encryptionKey(encodedKey),
    base64ToBytes(payload.ciphertext),
  );
  return JSON.parse(decoder.decode(plaintext)) as T;
}
