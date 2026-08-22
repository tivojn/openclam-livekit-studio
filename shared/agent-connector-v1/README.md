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
- Version 1 transports text only. It does not transport files, screenshots,
  provider credentials, local iPhone tools, or tool approvals.

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
It does not log message text. Pending frames are deleted after acknowledgement or
their bounded expiry. Version 1 has no transcript history API; OpenClam and
OpenClaw each retain history according to their own settings.
