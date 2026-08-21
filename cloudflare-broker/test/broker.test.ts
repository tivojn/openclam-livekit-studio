import { env } from "cloudflare:workers";
import { reset, runDurableObjectAlarm } from "cloudflare:test";
import { decodeJwt } from "jose";
import { afterEach, describe, expect, it } from "vitest";
import approvedTupleFixture from "../../contracts/live-talk-approved-tuples-v1.json";
import { PROFILE_CATALOG } from "../src/catalog";
import { canonicalJson, sha256Hex } from "../src/crypto";
import worker from "../src/index";
import type { ModelPolicy } from "../src/types";

const APP_TOKEN = "test-pilot-app-token-that-is-long-enough";
const AGENT_TOKEN = "test-agent-broker-secret-that-is-long-enough";

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function agentSignature(
  token: string,
  timestamp: string,
  nonce: string,
  path: string,
  body: string,
): Promise<string> {
  const bodyDigest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)),
  );
  const bodyHash = [...bodyDigest]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  const canonical = `${timestamp}\n${nonce}\nPOST\n${path}\n${bodyHash}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return base64Url(
    new Uint8Array(
      await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical)),
    ),
  );
}

function managedProfile() {
  return {
    llm: { source: "managed", provider: "livekit", model: "google/gemma-4-31b-it" },
    stt: {
      source: "managed",
      provider: "livekit",
      model: "deepgram/nova-3",
      language: "multi",
    },
    tts: {
      source: "managed",
      provider: "livekit",
      model: "fishaudio/s2.1-pro",
      voice: "933563129e564b19a115bedd57b7406a",
    },
    persona: { name: "Clam", instructions: "Be warm and concise." },
  };
}

function byokBody(secret = "provider-secret-must-never-leak") {
  return {
    participant_name: "Zane",
    profile: {
      ...managedProfile(),
      llm: { source: "byok", provider: "xai", model: "grok-4.3" },
      tts: {
        source: "byok",
        provider: "gemini",
        model: "gemini-3.1-flash-tts-preview",
        voice: "Sadachbia",
      },
    },
    credentials: {
      llm: { api_key: secret },
      tts: { api_key: "google-provider-secret" },
    },
  };
}

function allXaiBody(
  authMode: "api_key" | "oauth2" = "oauth2",
  bearerToken = "one-global-xai-bearer",
) {
  return {
    participant_name: "Zane",
    profile: {
      ...managedProfile(),
      llm: { source: "byok", provider: "xai", model: "grok-4.5" },
      stt: {
        source: "byok",
        provider: "xai",
        model: "grok-transcribe",
        language: "en",
      },
      tts: {
        source: "byok",
        provider: "xai",
        model: "xai-tts",
        voice: "ara",
        language: "auto",
      },
    },
    credentials: {
      llm: { api_key: bearerToken, auth_mode: authMode },
      stt: { api_key: bearerToken, auth_mode: authMode },
      tts: { api_key: bearerToken, auth_mode: authMode },
    },
  };
}

type SelectableStage = "llm" | "stt" | "tts";
type CatalogTuple = [
  SelectableStage,
  "managed" | "byok",
  string,
  string,
  string | null,
  string | null,
];

function tupleSortKey(tuple: CatalogTuple): string {
  return tuple.map((value) => value ?? "").join("\u001f");
}

function sortedTuples(tuples: readonly CatalogTuple[]): CatalogTuple[] {
  return [...tuples].sort((left, right) => {
    const leftKey = tupleSortKey(left);
    const rightKey = tupleSortKey(right);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
}

function boundedValues(
  allowed: readonly string[] | undefined,
  fallback: string | undefined,
  field: string,
): Array<string | null> {
  if (allowed === undefined) {
    if (fallback !== undefined) {
      throw new Error(`${field} has a default but no closed allowed-value list`);
    }
    return [null];
  }
  if (fallback === undefined || !allowed.includes(fallback)) {
    throw new Error(`${field} default is missing from its allowed-value list`);
  }
  return [...allowed];
}

function flattenedWorkerCatalog(): CatalogTuple[] {
  const tuples: CatalogTuple[] = [];
  for (const stage of ["llm", "stt", "tts"] as const) {
    for (const source of ["managed", "byok"] as const) {
      const providers = PROFILE_CATALOG[stage][source] as Record<
        string,
        Record<string, ModelPolicy>
      >;
      for (const [provider, models] of Object.entries(providers)) {
        for (const [model, policy] of Object.entries(models)) {
          const voices = boundedValues(
            policy.voices,
            policy.default_voice,
            `${stage}.${source}.${provider}.${model}.voice`,
          );
          const languages = boundedValues(
            policy.languages,
            policy.default_language,
            `${stage}.${source}.${provider}.${model}.language`,
          );
          for (const voice of voices) {
            for (const language of languages) {
              tuples.push([stage, source, provider, model, voice, language]);
            }
          }
        }
      }
    }
  }
  return sortedTuples(tuples);
}

function bodyForSelection(
  stage: SelectableStage,
  selection: Record<string, string>,
) {
  const profile: Record<string, unknown> = { ...managedProfile() };
  profile[stage] = selection;
  return {
    participant_name: "Catalog test",
    profile,
    credentials: {
      [stage]: { api_key: `${stage}-provider-test-key` },
    },
  };
}

const addedSelections: Array<
  [SelectableStage, Record<string, string>]
> = [
  ...[
    ["openai", "gpt-5.6-luna"],
    ["openai", "gpt-5.6-terra"],
    ["openai", "gpt-5.6-sol"],
    ["xai", "grok-4.5"],
    ["gemini", "gemini-3.6-flash"],
    ["gemini", "gemini-3.5-flash-lite"],
    ["anthropic", "claude-haiku-4-5"],
  ].map(
    ([provider, model]) =>
      ["llm", { source: "byok", provider, model }] as [
        SelectableStage,
        Record<string, string>,
      ],
  ),
  ...["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"].flatMap((model) =>
    ["en", "zh"].map(
      (language) =>
        [
          "stt",
          { source: "byok", provider: "openai", model, language },
        ] as [SelectableStage, Record<string, string>],
    ),
  ),
  ...["eve", "leo", "rex", "sal"].map(
    (voice) =>
      [
        "tts",
        {
          source: "byok",
          provider: "xai",
          model: "xai-tts",
          voice,
          language: "auto",
        },
      ] as [SelectableStage, Record<string, string>],
  ),
  [
    "tts",
    {
      source: "byok",
      provider: "gemini",
      model: "gemini-3.1-flash-tts-preview",
      voice: "Kore",
    },
  ],
  ...["tts-1", "tts-1-hd"].map(
    (model) =>
      [
        "tts",
        { source: "byok", provider: "openai", model, voice: "alloy" },
      ] as [SelectableStage, Record<string, string>],
  ),
  ...["EXAVITQu4vr4xnSDxMaL", "JBFqnCBsd6RMkjVDRZzb"].map(
    (voice) =>
      [
        "tts",
        {
          source: "byok",
          provider: "elevenlabs",
          model: "eleven_flash_v2_5",
          voice,
        },
      ] as [SelectableStage, Record<string, string>],
  ),
  [
    "tts",
    {
      source: "byok",
      provider: "elevenlabs",
      model: "eleven_multilingual_v2",
      voice: "JBFqnCBsd6RMkjVDRZzb",
    },
  ],
];

const managedFishVoices = [
  "bf322df2096a46f18c579d0baa36f41d",
  "536d3a5e000945adb7038665781a4aca",
  "9a9cf47702da476aa4629e2506d4a857",
  "79d0bd3e4e5444b18f7b6d89b5927bf1",
  "e3cd384158934cc9a01029cd7d278634",
  "933563129e564b19a115bedd57b7406a",
  "b347db033a6549378b48d00acb0d06cd",
] as const;

function chunkedTextBody(value: string): ReadableStream<Uint8Array<ArrayBuffer>> {
  const bytes = new TextEncoder().encode(value);
  const firstEnd = Math.max(1, Math.floor(bytes.byteLength / 2));
  const chunks = [bytes.slice(0, firstEnd), bytes.slice(firstEnd)];
  let index = 0;
  return new ReadableStream({
    pull(controller) {
      const chunk = chunks[index];
      if (chunk === undefined) {
        controller.close();
        return;
      }
      controller.enqueue(chunk);
      index += 1;
    },
  });
}

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return worker.fetch(new Request(`https://broker.test${path}`, init), env);
}

async function start(
  body: unknown,
  token = APP_TOKEN,
  streamed = false,
): Promise<Response> {
  const encodedBody = JSON.stringify(body);
  return fetchWorker("/v1/live-talk/sessions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Origin: "https://app.openclam.test",
    },
    body: streamed ? chunkedTextBody(encodedBody) : encodedBody,
  });
}

async function startAndDispatch(body: unknown = byokBody(), streamed = false) {
  const response = await start(body, APP_TOKEN, streamed);
  expect(response.status).toBe(201);
  const value = await response.json<{ participant_token: string; server_url: string }>();
  const jwt = decodeJwt(value.participant_token) as Record<string, unknown>;
  const video = jwt.video as {
    room: string;
    canPublishData: boolean;
    canPublishSources: string[];
  };
  const roomConfig = jwt.roomConfig as {
    agents: Array<{ agentName: string; metadata: string }>;
  };
  const metadata = JSON.parse(roomConfig.agents[0]?.metadata ?? "{}") as {
    schema_version: number;
    lease_id: string;
    profile_hash: string;
  };
  return { value, jwt, video, metadata };
}

async function claim(
  leaseId: string,
  roomName: string,
  profileHash: string,
  token = AGENT_TOKEN,
  overrides?: {
    timestamp?: number;
    nonce?: string;
    signature?: string;
    rawBody?: string;
    streamed?: boolean;
  },
): Promise<Response> {
  const path = `/v1/credential-leases/${leaseId}/claim`;
  const body =
    overrides?.rawBody ??
    JSON.stringify({
      schema_version: 1,
      room_name: roomName,
      agent_name: "openclam-livekit-pilot",
      profile_hash: profileHash,
    });
  const timestamp = String(overrides?.timestamp ?? Math.floor(Date.now() / 1_000));
  const nonce = overrides?.nonce ?? base64Url(crypto.getRandomValues(new Uint8Array(18)));
  const signature =
    overrides?.signature ?? (await agentSignature(token, timestamp, nonce, path, body));
  return fetchWorker(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-OpenClam-Timestamp": timestamp,
      "X-OpenClam-Nonce": nonce,
      "X-OpenClam-Signature": signature,
    },
    body: overrides?.streamed === true ? chunkedTextBody(body) : body,
  });
}

afterEach(async () => reset());

describe("broker", () => {
  it("returns health without configuration details", async () => {
    const response = await fetchWorker("/healthz");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      service: "openclam-livekit-pilot-broker",
    });
  });

  it("requires app authentication", async () => {
    const response = await start(byokBody(), "wrong-token");
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });

  it("requires agent authentication", async () => {
    const dispatch = await startAndDispatch();
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
      "wrong-agent-token",
    );
    expect(response.status).toBe(401);
  });

  it("rejects stale timestamps and invalid claim signatures", async () => {
    const dispatch = await startAndDispatch();
    const stale = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
      AGENT_TOKEN,
      { timestamp: Math.floor(Date.now() / 1_000) - 31 },
    );
    expect(stale.status).toBe(401);

    const invalid = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
      AGENT_TOKEN,
      { signature: "A".repeat(43) },
    );
    expect(invalid.status).toBe(401);
  });

  it("uses a unique room and fixed named dispatch with opaque metadata", async () => {
    const secret = "provider-secret-must-never-leak";
    const first = await startAndDispatch(byokBody(secret));
    const second = await startAndDispatch(byokBody(secret));

    expect(first.value.server_url).toBe("wss://test.livekit.cloud");
    expect(first.video.room).toMatch(/^openclam-lk-[a-f0-9]{24}$/);
    expect(first.video.room).not.toBe(second.video.room);
    expect(Object.keys(first.metadata).sort()).toEqual([
      "lease_id",
      "profile_hash",
      "schema_version",
    ]);
    expect(first.metadata.lease_id).toMatch(/^[a-f0-9]{32}$/);
    expect(first.metadata.profile_hash).toMatch(/^[a-f0-9]{64}$/);
    expect(first.metadata.profile_hash).not.toBe(second.metadata.profile_hash);
    expect(first.metadata.profile_hash).toBe(
      await sha256Hex(
        `${canonicalJson(byokBody(secret).profile)}\n${first.metadata.lease_id}`,
      ),
    );
    expect(first.jwt.metadata).toBe('{"schema_version":1,"role":"human"}');
    expect(first.video.canPublishSources).toEqual(["microphone"]);
    expect(first.video.canPublishData).toBe(true);
    expect(JSON.stringify(first.jwt)).not.toContain(secret);
    expect(JSON.stringify(first.jwt)).not.toContain("api_key");
  });

  it("claims exactly once and returns credentials only to the bound agent", async () => {
    const dispatch = await startAndDispatch();
    const first = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(first.status).toBe(200);
    const bundle = await first.json<Record<string, unknown>>();
    expect(Object.keys(bundle).sort()).toEqual([
      "credentials",
      "lease_id",
      "profile",
      "profile_hash",
      "schema_version",
    ]);
    expect(JSON.stringify(bundle)).toContain("provider-secret-must-never-leak");

    const replay = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(replay.status).toBe(404);
    expect(await replay.json()).toEqual({ error: "lease_not_found" });
  });

  it("canonicalizes legacy iOS xAI credentials to API-key mode inside the lease", async () => {
    const dispatch = await startAndDispatch(byokBody("legacy-ios-xai-key"));
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(response.status).toBe(200);
    const bundle = await response.json<{
      credentials: {
        llm: { api_key: string; auth_mode: string };
        tts: { api_key: string; auth_mode?: string };
      };
    }>();
    expect(bundle.credentials.llm).toEqual({
      api_key: "legacy-ios-xai-key",
      auth_mode: "api_key",
    });
    expect(bundle.credentials.tts).toEqual({
      api_key: "google-provider-secret",
    });
  });

  it.each(["api_key", "oauth2"] as const)(
    "preserves explicit xAI %s mode only in the encrypted one-use lease",
    async (authMode) => {
      const body = byokBody("selected-xai-bearer");
      body.credentials.llm = {
        api_key: "selected-xai-bearer",
        auth_mode: authMode,
      } as typeof body.credentials.llm & { auth_mode: typeof authMode };

      const dispatch = await startAndDispatch(body);
      expect(JSON.stringify(dispatch.value)).not.toContain(authMode);
      expect(JSON.stringify(dispatch.jwt)).not.toContain(authMode);

      const response = await claim(
        dispatch.metadata.lease_id,
        dispatch.video.room,
        dispatch.metadata.profile_hash,
      );
      expect(response.status).toBe(200);
      const bundle = await response.json<{
        credentials: { llm: { api_key: string; auth_mode: string } };
      }>();
      expect(bundle.credentials.llm).toEqual({
        api_key: "selected-xai-bearer",
        auth_mode: authMode,
      });
    },
  );

  it.each(["api_key", "oauth2"] as const)(
    "requires and preserves one global xAI %s mode and bearer across all stages",
    async (authMode) => {
      const body = allXaiBody(authMode);
      const dispatch = await startAndDispatch(body);
      const response = await claim(
        dispatch.metadata.lease_id,
        dispatch.video.room,
        dispatch.metadata.profile_hash,
      );
      expect(response.status).toBe(200);
      const bundle = await response.json<{
        credentials: Record<
          SelectableStage,
          { api_key: string; auth_mode: string }
        >;
      }>();
      expect(bundle.credentials).toEqual(body.credentials);
    },
  );

  it("accepts legacy and explicit API-key xAI stages only when the bearer matches", async () => {
    const body = allXaiBody("api_key");
    const legacyLlm = body.credentials.llm as {
      api_key: string;
      auth_mode?: string;
    };
    delete legacyLlm.auth_mode;

    const dispatch = await startAndDispatch(body);
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    const bundle = await response.json<{
      credentials: Record<
        SelectableStage,
        { api_key: string; auth_mode: string }
      >;
    }>();
    expect(response.status).toBe(200);
    expect(bundle.credentials.llm.auth_mode).toBe("api_key");
    expect(bundle.credentials.stt.auth_mode).toBe("api_key");
    expect(bundle.credentials.tts.auth_mode).toBe("api_key");
  });

  it.each([
    ["different bearer", "api_key", "different-xai-bearer"],
    ["different mode", "oauth2", "one-global-xai-bearer"],
  ] as const)(
    "rejects xAI stages with a %s",
    async (_label, secondMode, secondBearer) => {
      const body = allXaiBody("api_key");
      body.credentials.stt = {
        api_key: secondBearer,
        auth_mode: secondMode,
      };
      const response = await start(body);
      expect(response.status).toBe(422);
      expect(await response.json()).toEqual({
        error: "inconsistent_xai_auth",
      });
    },
  );

  it("allows one global xAI credential alongside independent non-xAI stages", async () => {
    const body = byokBody("selected-xai-oauth-bearer");
    body.credentials.llm = {
      api_key: "selected-xai-oauth-bearer",
      auth_mode: "oauth2",
    } as typeof body.credentials.llm & { auth_mode: "oauth2" };
    expect((await start(body)).status).toBe(201);
  });

  it("accepts normal streamed session and claim request bodies", async () => {
    const dispatch = await startAndDispatch(byokBody(), true);
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
      AGENT_TOKEN,
      { streamed: true },
    );
    expect(response.status).toBe(200);
  });

  it("enforces exact byte caps on chunked session and claim bodies", async () => {
    const sessionAtLimit = await fetchWorker("/v1/live-talk/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${APP_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: chunkedTextBody(" ".repeat(32_768)),
    });
    expect(sessionAtLimit.status).toBe(400);
    expect(await sessionAtLimit.json()).toEqual({ error: "invalid_json" });

    const sessionOverflow = await fetchWorker("/v1/live-talk/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${APP_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: chunkedTextBody(" ".repeat(32_769)),
    });
    expect(sessionOverflow.status).toBe(413);
    expect(await sessionOverflow.json()).toEqual({ error: "request_too_large" });

    const claimAtLimit = await claim(
      "0".repeat(32),
      "unused",
      "0".repeat(64),
      AGENT_TOKEN,
      { rawBody: " ".repeat(4_096), streamed: true },
    );
    expect(claimAtLimit.status).toBe(400);
    expect(await claimAtLimit.json()).toEqual({ error: "invalid_json" });

    const claimOverflow = await claim(
      "0".repeat(32),
      "unused",
      "0".repeat(64),
      AGENT_TOKEN,
      { rawBody: " ".repeat(4_097), streamed: true },
    );
    expect(claimOverflow.status).toBe(413);
    expect(await claimOverflow.json()).toEqual({ error: "request_too_large" });
  });

  it("consumes a lease on binding mismatch", async () => {
    const dispatch = await startAndDispatch();
    const mismatch = await claim(
      dispatch.metadata.lease_id,
      "wrong-room",
      dispatch.metadata.profile_hash,
    );
    expect(mismatch.status).toBe(403);
    const laterCorrectClaim = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(laterCorrectClaim.status).toBe(404);
  });

  it("expires a lease through its Durable Object alarm", async () => {
    const dispatch = await startAndDispatch();
    const stub = env.CREDENTIAL_LEASES.get(
      env.CREDENTIAL_LEASES.idFromName(dispatch.metadata.lease_id),
    );
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(response.status).toBe(404);
  });

  it("rejects unknown providers, models, voices, and credential shapes", async () => {
    const unknownProvider = byokBody();
    unknownProvider.profile.llm = {
      source: "byok",
      provider: "attacker",
      model: "run-anything",
    };
    expect((await start(unknownProvider)).status).toBe(422);

    const unknownVoice = byokBody();
    unknownVoice.profile.tts.voice = "arbitrary-user-controlled-voice";
    expect((await start(unknownVoice)).status).toBe(422);

    const voiceOnLLM = byokBody() as ReturnType<typeof byokBody> & {
      profile: { llm: { voice?: string } };
    };
    voiceOnLLM.profile.llm.voice = "constructor-smuggling";
    expect((await start(voiceOnLLM)).status).toBe(422);

    const languageOnNonLanguageTTS = byokBody() as ReturnType<typeof byokBody> & {
      profile: { tts: { language?: string } };
    };
    languageOnNonLanguageTTS.profile.tts.language = "attacker-language";
    expect((await start(languageOnNonLanguageTTS)).status).toBe(422);

    const extraCredentialField = byokBody() as ReturnType<typeof byokBody> & {
      credentials: { llm: { api_key: string; base_url?: string }; tts: { api_key: string } };
    };
    extraCredentialField.credentials.llm.base_url = "https://attacker.example";
    expect((await start(extraCredentialField)).status).toBe(422);

    const whitespaceKey = byokBody("provider secret with spaces");
    expect((await start(whitespaceKey)).status).toBe(422);
  });

  it("rejects unknown xAI modes and any auth mode on non-xAI credentials", async () => {
    const unknownXaiMode = byokBody() as ReturnType<typeof byokBody> & {
      credentials: {
        llm: { api_key: string; auth_mode?: string };
        tts: { api_key: string; auth_mode?: string };
      };
    };
    unknownXaiMode.credentials.llm.auth_mode = "hybrid";
    const unknownResponse = await start(unknownXaiMode);
    expect(unknownResponse.status).toBe(422);
    expect(await unknownResponse.json()).toEqual({ error: "invalid_auth_mode" });

    const nonXaiMode = byokBody() as ReturnType<typeof byokBody> & {
      credentials: {
        llm: { api_key: string; auth_mode?: string };
        tts: { api_key: string; auth_mode?: string };
      };
    };
    nonXaiMode.credentials.tts.auth_mode = "api_key";
    const nonXaiResponse = await start(nonXaiMode);
    expect(nonXaiResponse.status).toBe(422);
    expect(await nonXaiResponse.json()).toEqual({ error: "unknown_field" });
  });

  it("keeps the selectable catalog at the reviewed bounded superset", () => {
    expect(Object.keys(PROFILE_CATALOG.llm.byok.openai)).toEqual([
      "gpt-5.4-mini",
      "gpt-5.6-luna",
      "gpt-5.6-terra",
      "gpt-5.6-sol",
    ]);
    expect(Object.keys(PROFILE_CATALOG.llm.byok.xai)).toEqual([
      "grok-4.3",
      "grok-4.5",
    ]);
    expect(Object.keys(PROFILE_CATALOG.llm.byok.gemini)).toEqual([
      "gemini-3.6-flash",
      "gemini-3.5-flash",
      "gemini-3.5-flash-lite",
    ]);
    expect(Object.keys(PROFILE_CATALOG.llm.byok.anthropic)).toEqual([
      "claude-haiku-4-5",
      "claude-sonnet-4-6",
    ]);
    expect(Object.keys(PROFILE_CATALOG.stt.byok.openai)).toEqual([
      "gpt-4o-transcribe",
      "gpt-4o-mini-transcribe",
      "whisper-1",
    ]);
    expect(PROFILE_CATALOG.stt.managed.livekit["deepgram/nova-3"]).toEqual({
      default_language: "multi",
      languages: ["multi", "en", "zh"],
    });
    expect(PROFILE_CATALOG.stt.byok.xai["grok-transcribe"]).toEqual({
      default_language: "en",
      languages: ["en"],
    });
    expect(PROFILE_CATALOG.tts.byok.xai["xai-tts"]).toEqual({
      default_voice: "ara",
      voices: ["ara", "eve", "leo", "rex", "sal"],
      default_language: "auto",
      languages: ["auto"],
    });
    expect(
      PROFILE_CATALOG.tts.byok.gemini["gemini-3.1-flash-tts-preview"].voices,
    ).toEqual(["Sadachbia", "Kore"]);
    expect(Object.keys(PROFILE_CATALOG.tts.byok.openai)).toEqual([
      "gpt-4o-mini-tts",
      "tts-1",
      "tts-1-hd",
    ]);
    expect(Object.keys(PROFILE_CATALOG.tts.byok.elevenlabs)).toEqual([
      "eleven_flash_v2_5",
      "eleven_multilingual_v2",
    ]);
    expect(
      PROFILE_CATALOG.tts.byok.elevenlabs.eleven_flash_v2_5.voices,
    ).toEqual(["EXAVITQu4vr4xnSDxMaL", "JBFqnCBsd6RMkjVDRZzb"]);
    expect(
      PROFILE_CATALOG.tts.byok.elevenlabs.eleven_multilingual_v2.voices,
    ).toEqual(["JBFqnCBsd6RMkjVDRZzb"]);
    expect(
      PROFILE_CATALOG.tts.managed.livekit["fishaudio/s2.1-pro"],
    ).toEqual({
      default_voice: "933563129e564b19a115bedd57b7406a",
      voices: managedFishVoices,
    });
  });

  it("matches the canonical broker-agent tuple fixture exactly", () => {
    // The fixture normalizes every tuple to six fields and nulls absent
    // voice/language values before applying the shared lexical sort rule.
    expect(approvedTupleFixture.schema_version).toBe(1);
    const fixtureTuples = approvedTupleFixture.tuples as CatalogTuple[];
    expect(fixtureTuples).toEqual(sortedTuples(fixtureTuples));
    expect(flattenedWorkerCatalog()).toEqual(fixtureTuples);
  });

  it.each(addedSelections)(
    "accepts reviewed %s selection %#",
    async (stage, selection) => {
      expect((await start(bodyForSelection(stage, selection))).status).toBe(201);
    },
  );

  it.each(managedFishVoices)(
    "accepts reviewed managed Fish voice %s",
    async (voice) => {
      const profile = {
        ...managedProfile(),
        tts: {
          source: "managed",
          provider: "livekit",
          model: "fishaudio/s2.1-pro",
          voice,
        },
      };
      expect(
        (await start({ participant_name: "Fish voice test", profile })).status,
      ).toBe(201);
    },
  );

  it("defaults an omitted managed Fish voice to Sarah", async () => {
    const profile = {
      ...managedProfile(),
      tts: {
        source: "managed",
        provider: "livekit",
        model: "fishaudio/s2.1-pro",
      },
    };
    const dispatch = await startAndDispatch({
      participant_name: "Fish default test",
      profile,
    });
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(response.status).toBe(200);
    const bundle = await response.json<{
      profile: { tts: { voice: string } };
    }>();
    expect(bundle.profile.tts.voice).toBe("933563129e564b19a115bedd57b7406a");
  });

  it("defaults an omitted xAI TTS language to provider auto detection", async () => {
    const body = byokBody();
    body.profile.tts = {
      source: "byok",
      provider: "xai",
      model: "xai-tts",
      voice: "ara",
    };
    // xAI uses one global credential across every selected xAI stage.
    body.credentials.tts = {
      api_key: body.credentials.llm.api_key,
    };

    const dispatch = await startAndDispatch(body);
    const response = await claim(
      dispatch.metadata.lease_id,
      dispatch.video.room,
      dispatch.metadata.profile_hash,
    );
    expect(response.status).toBe(200);
    const bundle = await response.json<{
      profile: { tts: { language: string } };
    }>();
    expect(bundle.profile.tts.language).toBe("auto");
  });

  it("rejects an unreviewed managed Fish voice", async () => {
    const profile = {
      ...managedProfile(),
      tts: {
        source: "managed",
        provider: "livekit",
        model: "fishaudio/s2.1-pro",
        voice: "unreviewed-managed-voice",
      },
    };
    expect(
      (await start({ participant_name: "Fish voice test", profile })).status,
    ).toBe(422);
  });

  it.each([
    ["llm", { source: "byok", provider: "openai", model: "gpt-5.6" }],
    [
      "llm",
      { source: "byok", provider: "anthropic", model: "claude-sonnet-5" },
    ],
    [
      "stt",
      {
        source: "byok",
        provider: "openai",
        model: "gpt-4o-transcribe",
        language: "fr",
      },
    ],
    [
      "tts",
      {
        source: "byok",
        provider: "openai",
        model: "tts-1",
        voice: "nova",
      },
    ],
    [
      "tts",
      {
        source: "byok",
        provider: "elevenlabs",
        model: "eleven_multilingual_v2",
        voice: "EXAVITQu4vr4xnSDxMaL",
      },
    ],
    [
      "tts",
      {
        source: "byok",
        provider: "gemini",
        model: "gemini-2.5-flash-preview-tts",
        voice: "Kore",
      },
    ],
    [
      "tts",
      {
        source: "byok",
        provider: "xai",
        model: "xai-tts",
        voice: "ara",
        language: "en",
      },
    ],
  ] as Array<[SelectableStage, Record<string, string>]>) (
    "rejects unreviewed or cross-model %s selection %#",
    async (stage, selection) => {
      expect((await start(bodyForSelection(stage, selection))).status).toBe(422);
    },
  );

  it("does not leak secrets in session responses, JWTs, or safe errors", async () => {
    const secret = "super-secret-provider-value";
    const good = await start(byokBody(secret));
    const goodText = await good.text();
    expect(goodText).not.toContain(secret);
    expect(goodText).not.toContain("api_key");

    const invalid = byokBody(secret) as ReturnType<typeof byokBody> & {
      unexpected?: string;
    };
    invalid.unexpected = secret;
    const bad = await start(invalid);
    const badText = await bad.text();
    expect(bad.status).toBe(422);
    expect(badText).not.toContain(secret);
  });

  it("locks browser CORS to the configured origin", async () => {
    const allowed = await fetchWorker("/v1/live-talk/sessions", {
      method: "OPTIONS",
      headers: { Origin: "https://app.openclam.test" },
    });
    expect(allowed.status).toBe(204);
    expect(allowed.headers.get("Access-Control-Allow-Origin")).toBe(
      "https://app.openclam.test",
    );

    const denied = await fetchWorker("/v1/live-talk/sessions", {
      method: "OPTIONS",
      headers: { Origin: "https://evil.example" },
    });
    expect(denied.status).toBe(403);
    expect(denied.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });
});
