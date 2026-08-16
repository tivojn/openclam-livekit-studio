export const STAGES = ["llm", "stt", "tts"] as const;

export type Stage = (typeof STAGES)[number];
export type CredentialSource = "managed" | "byok";
export type XaiAuthMode = "api_key" | "oauth2";

export interface StageSelection {
  source: CredentialSource;
  provider: string;
  model: string;
  voice?: string;
  language?: string;
}

export interface LiveTalkProfile {
  llm: StageSelection;
  stt: StageSelection;
  tts: StageSelection;
  persona: Persona;
}

export interface ApiCredential {
  api_key: string;
  auth_mode?: XaiAuthMode;
}

export interface Persona {
  name: string;
  instructions: string;
}

export type StageCredentialMap = Partial<Record<Stage, ApiCredential>>;

export interface SessionStartRequest {
  participant_name?: string;
  profile: LiveTalkProfile;
  credentials?: StageCredentialMap;
}

export interface CredentialBundle {
  schema_version: 1;
  profile: LiveTalkProfile;
  credentials: StageCredentialMap;
}

export interface LeaseBinding {
  room_name: string;
  agent_name: string;
  profile_hash: string;
  expires_at: number;
}

export interface EncryptedPayload {
  algorithm: "A256GCM";
  iv: string;
  ciphertext: string;
}

export interface EncryptedLeaseRecord extends LeaseBinding {
  schema_version: 1;
  encrypted_payload: EncryptedPayload;
}

export interface LeaseClaimRequest {
  schema_version: 1;
  room_name: string;
  agent_name: string;
  profile_hash: string;
}

export interface AuthenticatedLeaseClaimRequest extends LeaseClaimRequest {
  auth_timestamp: number;
  auth_nonce: string;
}

export interface LeaseClaimResponse extends CredentialBundle {
  lease_id: string;
  profile_hash: string;
}

export interface ModelPolicy {
  default_language?: string;
  default_voice?: string;
  languages?: readonly string[];
  voices?: readonly string[];
}

export type SourceCatalog = Readonly<
  Record<string, Readonly<Record<string, ModelPolicy>>>
>;

export type StageCatalog = Readonly<
  Record<CredentialSource, SourceCatalog>
>;

export type ProfileCatalog = Readonly<Record<Stage, StageCatalog>>;
