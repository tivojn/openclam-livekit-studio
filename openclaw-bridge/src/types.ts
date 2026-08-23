export type SocketRole = "client" | "adapter";

export type ConnectorCapability = "activity-v1" | "attachments-v1" | "work-v1";

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

export type WorkCategory =
  | "reasoning_summary"
  | "plan"
  | "tool"
  | "command"
  | "file"
  | "approval"
  | "status";

export type WorkState = "running" | "completed" | "failed" | "waiting";

export interface AccountDescriptor {
  accountId: string;
  agentId: string;
  displayName: string;
}

export interface CreatePairingRequest {
  v: 1;
  adapterId: string;
  gatewayLabel: string;
  accounts: AccountDescriptor[];
}

export interface RedeemPairingRequest {
  v: 1;
  code: string;
  installationId: string;
  deviceLabel: string;
}

export type FrameKind =
  | "ack"
  | "heartbeat"
  | "turn.submit"
  | "turn.accepted"
  | "assistant.delta"
  | "assistant.activity.upsert"
  | "assistant.activity.clear"
  | "assistant.work.upsert"
  | "assistant.attachment"
  | "assistant.completed"
  | "turn.cancel"
  | "turn.error";

export interface ConnectorFrame {
  v: 1;
  kind: FrameKind;
  connectionId: string;
  conversationId?: string;
  messageId: string;
  seq: number;
  replyTo?: number;
  sentAt: number;
  payload: Record<string, unknown>;
}

export interface RelayPersistedReceipt {
  v: 1;
  kind: "relay.persisted";
  connectionId: string;
  payload: {
    senderSeq: number;
    messageId: string;
  };
}

export interface SessionRecord {
  v: 1;
  connectionId: string;
  adapterId: string;
  gatewayLabel: string;
  accounts: AccountDescriptor[];
  adapterTokenVerifier: string;
  clientTokenVerifier?: string;
  installationVerifier?: string;
  createdAt: number;
  unpairedCleanupAt: number;
  pairedAt?: number;
  highestClientSeq: number;
  highestAdapterSeq: number;
  acknowledgedClientSeq: number;
  acknowledgedAdapterSeq: number;
  pending: PendingFrame[];
  seenClient: SeenMessage[];
  seenAdapter: SeenMessage[];
  activeTurns: ActiveTurn[];
  attachments?: AttachmentRecord[];
  settledTurns?: SettledTurn[];
  activeClientSocketId?: string;
  activeAdapterSocketId?: string;
}

export interface PendingFrame {
  from: SocketRole;
  seq: number;
  messageId: string;
  encrypted: EncryptedPayload;
  expiresAt: number;
  kind?: FrameKind;
  turnId?: string;
  attachmentId?: string;
  workStepId?: string;
}

export interface EncryptedPayload {
  algorithm: "A256GCM";
  iv: string;
  ciphertext: string;
}

export interface SeenMessage {
  seq: number;
  messageId: string;
  digest: string;
  kind: FrameKind;
  expiresAt: number;
}

export interface SettledTurn {
  conversationId: string;
  turnId: string;
  settledAt: number;
}

export interface ActiveTurn {
  conversationId: string;
  turnId: string;
  startedAt: number;
  lastActivityAt?: number;
  accepted?: boolean;
  lastRevision?: number;
  finalState?: "completed" | "error";
  capabilities?: ConnectorCapability[];
  lastActivityRevision?: number;
  lastWorkRevision?: number;
}

export interface AttachmentRecord {
  attachmentId: string;
  conversationId: string;
  turnId: string;
  fileName: string;
  mediaType: string;
  byteCount: number;
  sha256: string;
  downloadPath: string;
  createdAt: number;
  expiresAt: number;
  state: "uploading" | "ready" | "announced" | "acknowledged";
}

export interface AttachmentBlobRecord {
  v: 1;
  connectionId: string;
  attachmentId: string;
  fileName: string;
  mediaType: string;
  byteCount: number;
  sha256: string;
  chunkCount: number;
  createdAt: number;
  expiresAt: number;
}

export interface PairingRecord {
  v: 1;
  pairingId: string;
  connectionId: string;
  adapterId: string;
  gatewayLabel: string;
  accounts: AccountDescriptor[];
  verifier: string;
  createdAt: number;
  expiresAt: number;
  consumedAt?: number;
  installationVerifier?: string;
  encryptedClientToken?: EncryptedPayload;
}

export interface RedeemFailureRecord {
  count: number;
  expiresAt: number;
}
