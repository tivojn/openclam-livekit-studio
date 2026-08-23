# OpenClam Agent Connector v1

This contract connects an OpenClam client to one independently deployed agent
adapter. The first adapter is OpenClaw. Future Hermez and EnConvo adapters use
their own deployments and credentials while sharing this wire envelope.

## Trust boundary

- OpenClam-specific adapter and client tokens are the only channel credentials;
  the connector has no external messaging-channel dependency.
- LLM, STT, TTS, LiveKit, and OpenClaw Gateway credentials never enter the
  bridge.
- A one-time pairing code authorizes one OpenClam installation. Pairing returns
  distinct, revocable client and adapter tokens. SHA-256 token verifiers are
  persisted for authentication; one client token is additionally retained only
  as bounded AES-GCM ciphertext until the pairing expires so an interrupted
  redemption can return the same credential.
- Tokens are sent in `Authorization: Bearer ...` headers, never URLs, logs, or
  error bodies.
- The base Version 1 contract is text-only. A client may explicitly negotiate
  the bounded `activity-v1` and `attachments-v1` extensions per turn. Provider
  credentials, local iPhone tools, tool approvals, reasoning, tool arguments,
  and tool output never cross this connector.

## Pairing

The OpenClaw adapter creates a pairing:

`POST /v1/pairings`

The request is authenticated with the Worker bootstrap secret and contains a
gateway label plus the bounded list of OpenClaw accounts/agents available to the
phone. The response includes:

- a single-use `OC-XXXX-XXXX-XXXX` code;
- a non-secret pairing and connection identifier;
- an adapter token returned exactly once;
- an authoritative expiry no more than ten minutes in the future.

OpenClam redeems the code with `POST /v1/pairings/redeem`. The 60-bit code
expires after ten minutes. A retry with the same code and installation ID before
that expiry returns the same client identity and token, covering a lost HTTP
response or failed Keychain save. A different installation is rejected, and no
retry can mint a second client credential. The bridge retains the retry token
only as bounded AES-GCM ciphertext and removes it at pairing expiry or connector
revocation. Each installation is throttled after five failed redemption
attempts. OpenClam stores only the returned client token in a
`WhenUnlockedThisDeviceOnly` Keychain item. Pairing codes are never persisted.

Once an adapter is configured, it may create a replacement iPhone code with an
empty authenticated `POST /v1/adapters/{connectionId}/pairings`. This uses only
that connector's adapter token, not the deployment bootstrap secret, and is
rejected while a turn is active. The replacement is a new connector identity;
the adapter revokes the previous connector before switching its local config.
Code expiry is therefore a simple retry in the host UI, never an app reset.

After a failed client WebSocket upgrade, iOS may authenticate
`GET /v1/connectors/{connectionId}/status`. A `204` means the pairing is still
valid and the transport failure remains retryable; `401` or `404` means the
saved pairing must be replaced. The probe carries the same client bearer only
in its authorization header and returns no connector metadata.

## WebSockets

- iOS: `GET /v1/connectors/{connectionId}/events`
- adapter: `GET /v1/adapters/{connectionId}/events`

Both upgrades require the role-specific bearer token. A connector session has at
most one active socket for each role. A newer authenticated socket replaces the
older socket for that role.

Every text frame follows `frame.schema.json`. The encoded frame limit is 64 KiB.
Each direction has its own monotonically increasing `seq`; message IDs are UUIDs.
The bridge rejects old sequence numbers and duplicate message IDs except for the
one exact-byte replay described below. Forwarded frames remain bounded and
pending until the recipient acknowledges their sender sequence. Reconnect
automatically replays the peer's unacknowledged frames.

After a non-heartbeat, non-`ack` frame is durably recorded, the bridge sends a
strict control envelope back to its sender:

```json
{
  "v": 1,
  "kind": "relay.persisted",
  "connectionId": "00000000-0000-4000-8000-000000000000",
  "payload": {
    "senderSeq": 1,
    "messageId": "00000000-0000-4000-8000-000000000000"
  }
}
```

This receipt consumes neither role's sequence space and is never persisted,
forwarded, or acknowledged. Each role retains the exact encoded frame until it
receives the matching receipt. If the receipt or response is lost, replaying
the exact same bytes, sequence, and message ID is idempotent: the bridge sends
the receipt again without applying turn lifecycle or forwarding the frame a
second time. Reusing either identifier with altered bytes is rejected.

OpenClam stores one gateway-scoped exact `turn.submit` or `turn.cancel` outbox
in WhenUnlocked, This Device Only Keychain storage for at most 15 minutes. A
transport reconnect or app restart replays the original encoded bytes with the
same conversation, turn, sequence, and message IDs and reconciles the result
into the original chat; it never silently resubmits under a new turn. Receipt,
acceptance, terminal, cancellation, or visible expiry reconciliation clears the
corresponding bounded outbox.

## Turn lifecycle

1. iOS sends `turn.submit` with an allowed `accountId`, stable local
   `conversationId`, user text, and an idempotent `turnId`.
2. The adapter sends `turn.accepted` once OpenClaw admits the turn, retains its
   exact encoded bytes, and waits for the matching `relay.persisted` receipt
   before starting OpenClaw execution.
3. The adapter may send cumulative `assistant.delta` frames. `text` is the whole
   reply observed at that revision, not a token patch.
4. The adapter sends exactly one authoritative `assistant.completed` with the
   final text, or one `turn.error` with a safe code and user-facing message.
5. iOS may send `turn.cancel`. Cancellation is idempotent.

Only one active turn is allowed per conversation. A second submit must be
rejected as `conversation_busy`; it must not silently interrupt or queue behind
the first turn.

The bridge refreshes a turn's 15-minute inactivity deadline on acceptance and
each cumulative delta and enforces a one-hour absolute maximum. Expiry deletes
the connector session and visibly closes both endpoints with `turn_expired`
rather than silently discarding lifecycle state.

## Optional capabilities

An updated client may add the exact, unique `capabilities` array to
`turn.submit.payload`. A missing array is the legacy contract. The adapter and
bridge must emit no extension frame kinds unless that turn advertised the
matching capability, so an upgraded bridge remains compatible with existing
paired builds.

`activity-v1` adds one coalesced activity card. The adapter sends only the fixed
safe status enum in `assistant.activity.upsert`, or `assistant.activity.clear`;
arbitrary progress text, chain of thought, tool names, arguments, output,
commands, and paths are forbidden. Activity revisions increase per turn and the
terminal frame implicitly clears the card.

`attachments-v1` adds authenticated generated-file delivery:

1. The adapter resolves media only through OpenClaw's agent-scoped outbound
   media API and uploads it with its bearer to
   `PUT /v1/adapters/{connectionId}/attachments/{attachmentId}`.
2. The bridge stores bytes in a separate chunked SQLite Durable Object, never in
   the connector session record or a WebSocket frame. A turn allows at most
   eight files, 32 MiB each and 64 MiB combined.
3. The adapter sends durable `assistant.attachment` metadata before
   `assistant.completed`. Metadata includes only a safe basename, media type,
   exact byte count, SHA-256, expiry, and the relative private download path;
   it never includes the source path, URL, or a token.
4. iOS performs a full authenticated
   `GET /v1/connectors/{connectionId}/attachments/{attachmentId}`, rejects
   redirects, verifies the exact type, length, and SHA-256, atomically stores the
   file, persists chat state, and only then ACKs the attachment frame. A failed
   download is not ACKed, so metadata replays after reconnect.
5. The client ACK deletes relay bytes. Turn failure, connector revocation, and
   the default 24-hour bounded expiry also delete them; the attachment object's
   own alarm is the cleanup fallback.

Sensitive live-only OpenClaw media is deliberately unsupported in this first
extension and fails closed with a fixed notice. It is never uploaded or written
to ordinary iOS chat history. A media-only successful turn uses a neutral
caption such as `Created 1 file.`

## Per-avatar routing

Pairing is gateway-scoped. The pairing response advertises allowed OpenClaw
accounts, each containing an `accountId`, `agentId`, and display name. An avatar
stores only `{connectorId, connectionId, accountId, agentId, displayName}` in its
non-secret profile. The client token is gateway-scoped in Keychain and is not
duplicated per avatar.

Changing an avatar between On iPhone and OpenClaw, or selecting another remote
agent, starts a new local chat. Existing chats retain their original route.
OpenClam never silently falls back to its local LLM when a remote turn fails.

## Privacy and retention

The bridge logs only opaque IDs, event kinds, byte sizes, durations, and status.
It does not log message text, filenames, or source paths. Pending frames are
deleted after acknowledgement or their bounded expiry. Attachment bytes are
private bearer-authorized objects with `no-store`/`nosniff` responses and are
deleted after verified client ACK, failure, revocation, or expiry. Version 1 has
no transcript history API; OpenClam and OpenClaw each retain history according
to their own settings.
