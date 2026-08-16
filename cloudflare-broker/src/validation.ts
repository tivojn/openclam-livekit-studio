import { PROFILE_CATALOG } from "./catalog";
import { unprocessable } from "./errors";
import {
  STAGES,
  type CredentialSource,
  type LiveTalkProfile,
  type ModelPolicy,
  type SessionStartRequest,
  type Stage,
  type StageCredentialMap,
  type StageSelection,
  type XaiAuthMode,
} from "./types";

const MAX_API_KEY_LENGTH = 4_096;
const MAX_NAME_LENGTH = 80;
const MAX_INSTRUCTIONS_BYTES = 4_096;
const PROVIDER_ID = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;
const OPTIONAL_VALUE = /^[\p{L}\p{N}][\p{L}\p{N} ._:/-]{0,127}$/u;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export { isRecord };

function exactKeys(
  value: Record<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = [],
): void {
  const accepted = new Set([...required, ...optional]);
  for (const key of Object.keys(value)) {
    if (!accepted.has(key)) {
      unprocessable("unknown_field");
    }
  }
  for (const key of required) {
    if (!(key in value)) {
      unprocessable("missing_field");
    }
  }
}

function requiredString(
  value: unknown,
  code: string,
  maxLength: number,
): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    unprocessable(code);
  }
  return value;
}

function policyFor(
  stage: Stage,
  source: CredentialSource,
  provider: string,
  model: string,
): ModelPolicy {
  const sourceCatalog = PROFILE_CATALOG[stage][source] as Record<
    string,
    Record<string, ModelPolicy>
  >;
  const policy = sourceCatalog[provider]?.[model];
  if (policy === undefined) {
    unprocessable("selection_not_allowed");
  }
  return policy;
}

function optionalCatalogValue(
  value: unknown,
  allowed: readonly string[] | undefined,
  fallback: string | undefined,
  code: string,
): string | undefined {
  // An absent policy means the field itself is not part of this tuple. Do not
  // turn it into an open-ended string parameter for a provider constructor.
  if (allowed === undefined) {
    if (value !== undefined || fallback !== undefined) {
      unprocessable(code);
    }
    return undefined;
  }
  const selected = value === undefined ? fallback : requiredString(value, code, 128);
  if (selected === undefined) {
    return undefined;
  }
  if (!OPTIONAL_VALUE.test(selected) || !allowed.includes(selected)) {
    unprocessable(code);
  }
  return selected;
}

function parseSelection(value: unknown, stage: Stage): StageSelection {
  if (!isRecord(value)) {
    unprocessable("invalid_stage_selection");
  }
  exactKeys(value, ["source", "provider", "model"], ["voice", "language"]);

  if (value.source !== "managed" && value.source !== "byok") {
    unprocessable("invalid_credential_source");
  }
  const source = value.source;
  const provider = requiredString(value.provider, "invalid_provider", 32);
  const model = requiredString(value.model, "invalid_model", 128);
  if (!PROVIDER_ID.test(provider) || !MODEL_ID.test(model)) {
    unprocessable("invalid_selection_identifier");
  }

  const policy = policyFor(stage, source, provider, model);
  const voice = optionalCatalogValue(
    value.voice,
    policy.voices,
    policy.default_voice,
    "voice_not_allowed",
  );
  const language = optionalCatalogValue(
    value.language,
    policy.languages,
    policy.default_language,
    "language_not_allowed",
  );

  return {
    source,
    provider,
    model,
    ...(voice === undefined ? {} : { voice }),
    ...(language === undefined ? {} : { language }),
  };
}

function parseProfile(value: unknown): LiveTalkProfile {
  if (!isRecord(value)) {
    unprocessable("invalid_profile");
  }
  exactKeys(value, ["llm", "stt", "tts", "persona"]);
  if (!isRecord(value.persona)) {
    unprocessable("invalid_persona");
  }
  exactKeys(value.persona, ["name", "instructions"]);

  const personaName = requiredString(
    value.persona.name,
    "invalid_persona_name",
    MAX_NAME_LENGTH,
  ).trim();
  const instructions = requiredString(
    value.persona.instructions,
    "invalid_persona_instructions",
    MAX_INSTRUCTIONS_BYTES,
  ).trim();
  if (
    personaName.length === 0 ||
    instructions.length === 0 ||
    new TextEncoder().encode(instructions).byteLength > MAX_INSTRUCTIONS_BYTES
  ) {
    unprocessable("invalid_persona");
  }

  return {
    llm: parseSelection(value.llm, "llm"),
    stt: parseSelection(value.stt, "stt"),
    tts: parseSelection(value.tts, "tts"),
    persona: {
      name: personaName,
      instructions,
    },
  };
}

function parseCredentials(
  value: unknown,
  profile: LiveTalkProfile,
): StageCredentialMap {
  const credentialsValue = value ?? {};
  if (!isRecord(credentialsValue)) {
    unprocessable("invalid_credentials");
  }
  exactKeys(credentialsValue, [], STAGES);
  const credentials: StageCredentialMap = {};
  let globalXaiAuth:
    | { authMode: XaiAuthMode; bearerToken: string }
    | undefined;

  for (const stage of STAGES) {
    const candidate = credentialsValue[stage];
    if (profile[stage].source === "managed") {
      if (candidate !== undefined) {
        unprocessable("credential_for_managed_stage");
      }
      continue;
    }
    if (!isRecord(candidate)) {
      unprocessable("missing_byok_credential");
    }
    const isXai = profile[stage].provider === "xai";
    exactKeys(candidate, ["api_key"], isXai ? ["auth_mode"] : []);
    const apiKey = requiredString(candidate.api_key, "invalid_api_key", MAX_API_KEY_LENGTH);
    if (apiKey.length < 8 || /\s/u.test(apiKey)) {
      unprocessable("invalid_api_key");
    }
    let authMode: XaiAuthMode | undefined;
    if (isXai) {
      if (candidate.auth_mode === undefined) {
        // Existing iOS builds predate this field and always send an xAI API
        // key. Canonicalize that legacy shape before encrypting the lease.
        authMode = "api_key";
      } else if (
        candidate.auth_mode === "api_key" || candidate.auth_mode === "oauth2"
      ) {
        authMode = candidate.auth_mode;
      } else {
        unprocessable("invalid_auth_mode");
      }
      if (
        globalXaiAuth !== undefined &&
        (globalXaiAuth.authMode !== authMode ||
          globalXaiAuth.bearerToken !== apiKey)
      ) {
        unprocessable("inconsistent_xai_auth");
      }
      globalXaiAuth = { authMode, bearerToken: apiKey };
    }
    credentials[stage] = {
      api_key: apiKey,
      ...(authMode === undefined ? {} : { auth_mode: authMode }),
    };
  }
  return credentials;
}

export function parseSessionStartRequest(
  value: unknown,
): SessionStartRequest & { credentials: StageCredentialMap } {
  if (!isRecord(value)) {
    unprocessable("invalid_request");
  }
  exactKeys(value, ["profile"], ["participant_name", "credentials"]);
  const profile = parseProfile(value.profile);
  const credentials = parseCredentials(value.credentials, profile);

  const participantName =
    value.participant_name === undefined
      ? undefined
      : requiredString(value.participant_name, "invalid_participant_name", MAX_NAME_LENGTH);
  return {
    profile,
    credentials,
    ...(participantName === undefined ? {} : { participant_name: participantName }),
  };
}

export function parseClaimRequest(value: unknown): {
  schema_version: 1;
  room_name: string;
  agent_name: string;
  profile_hash: string;
} {
  if (!isRecord(value)) {
    unprocessable("invalid_claim");
  }
  exactKeys(value, ["schema_version", "room_name", "agent_name", "profile_hash"]);
  if (value.schema_version !== 1) {
    unprocessable("unsupported_schema_version");
  }
  const profileHash = requiredString(value.profile_hash, "invalid_profile_hash", 64);
  if (!/^[a-f0-9]{64}$/.test(profileHash)) {
    unprocessable("invalid_profile_hash");
  }
  return {
    schema_version: 1,
    room_name: requiredString(value.room_name, "invalid_room_name", 128),
    agent_name: requiredString(value.agent_name, "invalid_agent_name", 128),
    profile_hash: profileHash,
  };
}
