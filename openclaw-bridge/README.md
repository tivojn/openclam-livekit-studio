# OpenClam OpenClaw Bridge

This is the independent Cloudflare Worker transport between OpenClam iOS and
the OpenClaw `openclam` channel adapter. It has no dependency, binding, secret,
route, or deployment lifecycle shared with the LiveKit credential broker.

The bridge is a transport and pairing boundary. It does not contain an agent,
select a model, execute tools, or override OpenClaw routing. `accountId` is the
authoritative channel account; the adapter-provided `agentId` is display and
consistency metadata for OpenClam.

## Trust boundary

- Model, speech, LiveKit, and OpenClaw Gateway credentials never enter this
  Worker or the iOS connector profile.
- `POST /v1/pairings` requires the adapter bootstrap bearer.
- `POST /v1/adapters/{connectionId}/pairings` lets an already authenticated
  adapter rotate its own iPhone pairing without exposing or reusing the
  bootstrap bearer. It is rejected while that connection has an active turn.
- Pairing returns distinct adapter and client tokens. A raw token is returned
  once to the adapter. A SHA-256 verifier bound to each role and connection is
  persisted. The client token is additionally retained as AES-GCM ciphertext
  only until pairing expiry so the same installation can safely retry a lost
  redemption response without minting another identity.
- A pairing code contains 60 random bits, expires in at most ten minutes, and is
  consumed before a client credential is created or returned.
- Because the redeem contract intentionally contains no public pairing ID,
  invalid guesses cannot safely be attributed to a particular code. The Worker
  applies a five-failure, ten-minute throttle to the submitted installation ID.
  Production iOS authentication must bind that ID with App Attest so it cannot
  be freely changed by an attacker.
- Pending WebSocket frames are encrypted with AES-256-GCM. Authenticated data binds
  ciphertext to `connectionId`, direction, and sequence. Frames are deleted
  after cumulative acknowledgement or bounded expiry.
- No route logs request bodies, frame contents, labels, codes, or credentials.
  Runtime logging and persisted invocation logs are disabled in
  `wrangler.jsonc`.

This pilot bootstrap bearer is not public-user device identity. Before public
distribution, add App Attest assertions to redemption and client WebSocket
upgrades, and add Cloudflare rate-limit bindings keyed by the verified
installation.

## HTTP contract

All JSON objects use exact keys. Tokens are accepted only in
`Authorization: Bearer ...`; they are never accepted in a URL.

### Create a pairing

`POST /v1/pairings`

```json
{
  "v": 1,
  "adapterId": "2fc65e78-dbe0-4e9a-a6d7-2ff1fca21194",
  "gatewayLabel": "Home OpenClaw",
  "accounts": [
    { "accountId": "main", "agentId": "ara", "displayName": "Ara" }
  ]
}
```

The body is capped at 16,384 UTF-8 bytes and may advertise 1–32 unique
accounts. Success is `201`:

```json
{
  "v": 1,
  "pairingId": "5c2f426d-c6b8-40e5-9b0e-f26a42ab89c9",
  "connectionId": "1258f487-8c42-4430-bc41-10f0c3677122",
  "code": "OC-3Z7P-G2TW-C8RM",
  "expiresAt": 1787395200000,
  "adapterToken": "returned-once"
}
```

### Redeem a pairing

`POST /v1/pairings/redeem`

```json
{
  "v": 1,
  "code": "OC-3Z7P-G2TW-C8RM",
  "installationId": "49a14839-8a37-469d-b724-352d53ef3d87",
  "deviceLabel": "Zane's iPhone"
}
```

The body is capped at 2,048 UTF-8 bytes. Success is `200` and returns the
authoritative gateway label/account list plus `clientToken`. Before expiry, an
exact retry with the same code and installation ID returns that same token;
another installation is rejected. The retry token exists at rest only as
AES-GCM ciphertext and is cleared at pairing expiry or connector revocation.
Expired, consumed, missing, and throttled pairings use only the bounded safe
error schema in `shared/agent-connector-v1/pairing.schema.json`.

### Create a replacement iPhone pairing

`POST /v1/adapters/{connectionId}/pairings` requires the current adapter bearer
and an empty body. It copies only the already validated gateway label and agent
list into a new, independently keyed connector, returning the same create
response shape as `POST /v1/pairings`. The adapter must revoke the old connector
before committing its new local configuration. This is the endpoint used by
the OpenClam Studio pairing panel; the bridge bootstrap secret never enters the
Mac app.

`GET /v1/connectors/{connectionId}/status` requires the client bearer and has
no request body. It returns `204` for a valid connector, `401` for a mismatched
credential, and `404` after revocation or expiry. The iOS client calls this
only after a WebSocket upgrade fails, so a permanent stale pairing is shown as
Pair again instead of entering transient recovery.

### Revoke a connector

`DELETE /v1/connectors/{connectionId}` accepts either role-specific bearer,
requires an empty body, closes both sockets, removes pending content, and
returns `204`. Revocation is fail-closed; later upgrades and repeated deletion
return `404`.

## WebSocket contract

- iOS: `GET /v1/connectors/{connectionId}/events`
- adapter: `GET /v1/adapters/{connectionId}/events`

Both require their own bearer and `Upgrade: websocket`. No cursor is passed in
the URL: reconnect automatically replays the peer's still-unacknowledged frames
in sequence order. Each endpoint must durably persist its next outgoing
sequence. If that state is lost or corrupted, create a fresh pairing and revoke
the old connection only after the replacement is committed.

Every text frame follows `shared/agent-connector-v1/frame.schema.json` and is
capped at exactly 65,536 UTF-8 bytes. Per-direction sequence numbers must
strictly increase, and recently seen message UUIDs cannot repeat, except for one
byte-for-byte replay awaiting the strict persistence receipt below.

- `ack` is cumulative and removes peer frames through `payload.ackSeq`.
- `ack` frames are not forwarded and are never acknowledged.
- `heartbeat` advances replay state and is forwarded when the peer is online,
  but is intentionally ephemeral. Offline heartbeats are never placed in the
  pending queue and cannot displace real turns.
- Every other valid frame remains encrypted and pending until acknowledged or
  expired.
- The pilot caps the combined encrypted pending queue at 16 frames so its
  single SQLite Durable Object record remains conservatively below Cloudflare's
  2 MB key-plus-value limit even when every frame is the full 64 KiB.
- After durably recording a non-ack, non-heartbeat frame, the Worker returns a
  separate sequence-free `relay.persisted` control receipt to the sender. An
  exact replay gets the receipt again but is never forwarded or applied to turn
  lifecycle twice; altered identifier reuse closes the socket.
- Only one turn may be active per conversation. The bridge rejects a second
  submit, an unconfigured `accountId`, non-increasing delta revisions, duplicate
  acceptance, and a second final/error.
- An accepted turn has a 15-minute inactivity limit refreshed by each accepted
  or cumulative delta frame, plus a one-hour absolute maximum. Expiry revokes
  the connector and closes both endpoints with `turn_expired`; it never silently
  drops lifecycle state and later rejects an otherwise valid terminal.
- At most one authenticated socket per role is active. A newer connection
  replaces the older one.

The base Version 1 contract remains text-only. `turn.submit` may explicitly
negotiate `activity-v1`, `attachments-v1`, and `work-v1`; without the matching
capability the bridge rejects and never emits an extension kind. Activity is a
coalesced fixed enum. Work is a strict, bounded upsert timeline with safe
categories and replacement by step ID; the bridge never treats it as an
unbounded transcript or raw tool-output stream.

Generated files use separate authenticated HTTP routes:

- adapter upload: `PUT /v1/adapters/{connectionId}/attachments/{attachmentId}`;
- iOS full download: `GET /v1/connectors/{connectionId}/attachments/{attachmentId}`.

Uploads are bound to the active connection, conversation, and turn; allow at
most eight files, 32 MiB each and 64 MiB per turn; and store 512 KiB chunks in a
dedicated `ConnectorAttachment` SQLite Durable Object. Bytes never enter the
single connector session record or WebSocket frames. Download accepts only the
paired client bearer, no URL token/query/redirect/range, and returns exact
`Content-Type`/`Content-Length` with `no-store` and `nosniff`. The iOS client
downloads, verifies SHA-256 and length, atomically persists, then ACKs metadata.
ACK, turn error, revocation, and the default 24-hour alarm delete the blob.

## Local verification

```sh
npm install
npm run check
cp .dev.vars.example .dev.vars
npm run dev
```

The test suite runs against the Workers runtime and all three SQLite Durable Object
classes. It covers strict schemas and bounds, retry-safe redemption, same- and
different-installation races, retry-ciphertext expiry, installation throttling,
raw-token exclusion, role authentication, account routing, exact replay
receipts, duplicate-final suppression, cumulative acknowledgements, reconnect,
socket replacement, turn lifecycle, revocation, offline heartbeat pressure,
AES-GCM storage, wrong authenticated data, tampering, capability isolation,
idempotent uploads, private download authorization, streaming prefix checks,
attachment ACK/error/revocation cleanup, and per-turn size/count limits.

## Cloudflare configuration

The deployment name is `openclam-openclaw-bridge`. Its only state bindings are
the independent SQLite Durable Object classes `PairingCoordinator`,
`ConnectorSession`, and `ConnectorAttachment`.

Set four independent secrets; never add values to `wrangler.jsonc`:

```sh
npx wrangler secret put BRIDGE_BOOTSTRAP_TOKEN
npx wrangler secret put PAIRING_CODE_PEPPER
npx wrangler secret put TOKEN_VERIFIER_PEPPER
npx wrangler secret put PENDING_EVENT_KEK_B64
```

`PENDING_EVENT_KEK_B64` must decode to exactly 32 bytes. Generate each secret
independently. A deployment should use a dedicated hostname and Cloudflare
resources rather than a LiveKit route or binding.
