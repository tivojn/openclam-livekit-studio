import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";

export const OPENCLAM_CHANNEL_ID = "openclam" as const;
export const IDENTIFIER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/u;
export const ACCOUNT_ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,63}$/u;
export const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

export type ConnectorCapability = "activity-v1" | "attachments-v1";

export type ActivityStatus =
  | "thinking"
  | "planning"
  | "searching"
  | "reading"
  | "editing"
  | "running_action"
  | "using_tools"
  | "creating_media"
  | "preparing_files"
  | "waiting_for_approval"
  | "finalizing";

export type OpenClamAttachment = {
  attachmentId: string;
  fileName: string;
  mediaType: string;
  byteCount: number;
  sha256: string;
  downloadPath: string;
  expiresAt: number;
};

export type OpenClamAttachmentUpload = {
  fileName: string;
  mediaType: string;
  buffer: Buffer;
};

export type OpenClamAccountConfig = {
  enabled?: boolean;
  agentId: string;
  displayName: string;
};

export type OpenClamChannelConfig = {
  enabled?: boolean;
  adapterId?: string;
  gatewayLabel?: string;
  bridgeUrl?: string;
  connectionId?: string;
  adapterTokenFile?: string;
  stateFile?: string;
  defaultAccount?: string;
  accounts?: Record<string, OpenClamAccountConfig>;
};

export type OpenClamCoreConfig = OpenClawConfig & {
  channels?: OpenClawConfig["channels"] & {
    openclam?: OpenClamChannelConfig;
  };
};

export type ResolvedOpenClamAccount = {
  accountId: string;
  agentId: string;
  displayName: string;
  enabled: boolean;
  configured: boolean;
  bridgeUrl: string;
  connectionId: string;
  adapterTokenFile: string;
  stateFile: string;
};

export type AccountDescriptor = {
  accountId: string;
  agentId: string;
  displayName: string;
};

export type CreatePairingRequest = {
  v: 1;
  adapterId: string;
  gatewayLabel: string;
  accounts: AccountDescriptor[];
};

export type CreatePairingResponse = {
  v: 1;
  pairingId: string;
  connectionId: string;
  code: string;
  expiresAt: number;
  adapterToken: string;
};

export type FrameKind =
  | "ack"
  | "heartbeat"
  | "turn.submit"
  | "turn.accepted"
  | "assistant.delta"
  | "assistant.activity.upsert"
  | "assistant.activity.clear"
  | "assistant.attachment"
  | "assistant.completed"
  | "turn.cancel"
  | "turn.error";

export type ConnectorFrame = {
  v: 1;
  kind: FrameKind;
  connectionId: string;
  conversationId?: string;
  messageId: string;
  seq: number;
  replyTo?: number;
  sentAt: number;
  payload: Record<string, unknown>;
};

export type RelayPersistedReceipt = {
  v: 1;
  kind: "relay.persisted";
  connectionId: string;
  payload: {
    senderSeq: number;
    messageId: string;
  };
};

export type BridgeInbound = ClientFrame | RelayPersistedReceipt;

export type AdapterState = {
  v: 1;
  connectionId: string;
  nextSeq: number;
  lastReceivedSeq: number;
  activeTurns: Array<{
    turnId: string;
    conversationId: string;
    accountId: string;
    recoveryExpiresAt?: number;
    recoveryError?: {
      code: string;
      message: string;
      retryable: boolean;
    };
  }>;
  completedTurnIds: string[];
};

export type TurnSubmitFrame = ConnectorFrame & {
  kind: "turn.submit";
  conversationId: string;
  payload: {
    turnId: string;
    accountId: string;
    text: string;
    capabilities?: ConnectorCapability[];
  };
};

export type TurnCancelFrame = ConnectorFrame & {
  kind: "turn.cancel";
  conversationId: string;
  payload: {
    turnId: string;
  };
};

export type ClientFrame = TurnSubmitFrame | TurnCancelFrame | (ConnectorFrame & {
  kind: "heartbeat";
});
