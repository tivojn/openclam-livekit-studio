import {
  RoomAgentDispatch,
  RoomConfiguration,
  TrackSource,
} from "@livekit/protocol";
import { AccessToken } from "livekit-server-sdk";

interface TokenOptions {
  roomName: string;
  participantIdentity: string;
  participantName: string;
  metadata: string;
  env: Env;
}

export async function createParticipantToken(options: TokenOptions): Promise<string> {
  const ttlSeconds = Number(options.env.LIVEKIT_TOKEN_TTL_SECONDS);
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 3_600) {
    throw new Error("invalid_livekit_token_ttl");
  }

  const token = new AccessToken(
    options.env.LIVEKIT_API_KEY,
    options.env.LIVEKIT_API_SECRET,
    {
      identity: options.participantIdentity,
      name: options.participantName,
      ttl: ttlSeconds,
    },
  );
  token.metadata = JSON.stringify({ schema_version: 1, role: "human" });
  token.addGrant({
    roomJoin: true,
    room: options.roomName,
    canPublish: true,
    canPublishSources: [TrackSource.MICROPHONE],
    canSubscribe: true,
    // Required for the foreground app to return bounded responses to the
    // deterministic review-only email RPC and the cross-client selected-agent
    // turn RPC. The room and participant identity remain single-session, random,
    // and short-lived; this grant is transport, not tool authority.
    canPublishData: true,
  });
  token.roomConfig = new RoomConfiguration({
    agents: [
      new RoomAgentDispatch({
        agentName: options.env.LIVEKIT_AGENT_NAME,
        metadata: options.metadata,
      }),
    ],
  });
  return token.toJwt();
}
