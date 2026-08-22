interface Env {
  PAIRINGS: DurableObjectNamespace<
    import("./pairing").PairingCoordinator
  >;
  CONNECTOR_SESSIONS: DurableObjectNamespace<
    import("./session").ConnectorSession
  >;
  ATTACHMENTS: DurableObjectNamespace<
    import("./attachment").ConnectorAttachment
  >;

  PAIRING_TTL_SECONDS: string;
  PENDING_FRAME_TTL_SECONDS: string;
  ACTIVE_TURN_IDLE_TTL_SECONDS: string;
  ACTIVE_TURN_MAX_DURATION_SECONDS: string;
  MAX_PENDING_FRAMES: string;
  ATTACHMENT_TTL_SECONDS: string;

  BRIDGE_BOOTSTRAP_TOKEN: string;
  PAIRING_CODE_PEPPER: string;
  TOKEN_VERIFIER_PEPPER: string;
  PENDING_EVENT_KEK_B64: string;
}
