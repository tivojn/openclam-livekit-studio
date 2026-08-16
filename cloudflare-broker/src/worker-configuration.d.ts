interface Env {
  CREDENTIAL_LEASES: DurableObjectNamespace<import("./lease").CredentialLease>;

  AUTH_MODE: string;
  BYOK_LEASE_TTL_SECONDS: string;
  CORS_ORIGIN: string;
  LIVEKIT_AGENT_NAME: string;
  LIVEKIT_TOKEN_TTL_SECONDS: string;
  LIVEKIT_URL: string;

  OPENCLAM_BROKER_AGENT_TOKEN: string;
  BYOK_KEK_B64: string;
  LIVEKIT_API_KEY: string;
  LIVEKIT_API_SECRET: string;
  PILOT_APP_TOKEN: string;
}
