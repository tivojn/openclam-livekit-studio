# OpenClam LiveKit Credential Broker

This Worker is the narrow control-plane bridge between the OpenClam iOS app and
its LiveKit agent. It never receives microphone audio, transcripts, or model
responses. LiveKit carries all realtime media.

## Security model

1. iOS keeps provider keys in a non-synchronizing Keychain item with
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
2. When the user starts Live Talk, iOS sends only the keys required by the three
   selected stages to `POST /v1/live-talk/sessions` over HTTPS.
3. This Worker validates every provider/model/voice/language against the closed
   catalog in `src/catalog.ts`.
4. Credentials are encrypted using AES-256-GCM and a Worker secret KEK, then
   stored in a dedicated Durable Object with a 30–300 second alarm.
5. The LiveKit dispatch metadata contains exactly
   `{schema_version, lease_id, profile_hash}`. It never contains a credential.
   The hash is salted by the random lease ID, so identical profiles cannot be
   correlated across sessions.
6. The named LiveKit agent claims that lease once with a timestamped HMAC proof.
   The Durable Object deletes all state before decrypting/returning the bundle,
   so concurrent or later replays fail.
7. The agent keeps the keys only in job memory and discards them when the room
   ends. It must not log the claim response or provider exception bodies.

The keys necessarily cross into the trusted broker and agent process: a cloud
agent cannot call a provider using a secret that never leaves the phone. This
design minimizes that exposure; it does not claim a zero-risk BYOK system.

## HTTP contract

`POST /v1/live-talk/sessions` authenticates the app, creates a unique room and
lease, and returns the standard LiveKit endpoint response:

```json
{
  "server_url": "wss://project.livekit.cloud",
  "participant_token": "eyJ..."
}
```

The session body includes the profile and optional stage credentials. BYOK
credentials are keyed by stage, never by arbitrary client references:

```json
{
  "participant_name": "Zane",
  "profile": {
    "llm": {"source":"byok","provider":"xai","model":"grok-4.3"},
    "stt": {"source":"managed","provider":"livekit","model":"deepgram/nova-3","language":"multi"},
    "tts": {"source":"byok","provider":"gemini","model":"gemini-3.1-flash-tts-preview","voice":"Sadachbia"},
    "persona": {"name":"Clam","instructions":"Be warm, concise, and natural."}
  },
  "credentials": {
    "llm": {"api_key":"..."},
    "tts": {"api_key":"..."}
  }
}
```

The Worker reads this request as a stream and enforces a 32,768-byte cap even
when `Content-Length` is missing, incorrect, or the upload is chunked. The agent
claim route uses the same bounded reader with a 4,096-byte cap. An overflowing
chunk is rejected before it is copied into the fixed-size request buffer.

The returned participant JWT permits joining and subscribing. Media publishing
is restricted to `TrackSource.MICROPHONE`; camera and screen-share publishing
are disabled. Participant data publishing stays enabled only so the iPhone can
return a bounded response to the agent's authenticated email-draft RPC. The app
still applies caller, room, attempt, transcript, replay, deadline, and foreground
checks before it stages an editable draft; the data grant is not tool authority.

`POST /v1/credential-leases/:id/claim` is agent-only. The agent sends:

- `X-OpenClam-Timestamp`: Unix seconds, accepted within ±30 seconds;
- `X-OpenClam-Nonce`: exactly 24 base64url characters (18 random bytes,
  without padding);
- `X-OpenClam-Signature`: base64url without padding of HMAC-SHA256.

The signature input is exact UTF-8 bytes, with line-feed separators:

```text
${timestamp}\n${nonce}\nPOST\n${path}\n${sha256hex(rawRequestBody)}
```

The raw request body is hashed exactly as received. The agent currently emits
compact JSON with recursively sorted object keys. The HMAC is keyed by
`OPENCLAM_BROKER_AGENT_TOKEN`. The request and successful response intentionally
match the agent contract; see the integration tests for the full shape.

`profile_hash` uses this exact, language-independent scheme:

```text
lowercase_hex(SHA-256(UTF-8(canonical_json(profile) + "\n" + lease_id)))
```

`canonical_json` recursively sorts object keys lexicographically, preserves
array order, and emits compact JSON with no insignificant whitespace. The
`lease_id` is the exact lowercase 32-character hexadecimal ID from dispatch
metadata.

## Authentication seam

`AUTH_MODE=pilot` accepts `Authorization: Bearer <PILOT_APP_TOKEN>` only for the
internal TestFlight pilot. During a device migration, the optional
`PILOT_APP_TOKEN_NEXT` secret can enroll the replacement device without
invalidating the bearer already present in active pilot builds. A static token
embedded in an app can be extracted, so either bearer is an abuse-control gate,
not production device identity.

Before public distribution, implement automatic Apple App Attest verification:

- add an `AppAttestAuthenticator` behind `authenticateClient`;
- verify Apple attestation once, storing the installation key ID/server state;
- require and verify an assertion over the method, path, body digest, and a
  single-use server challenge on every session request;
- reject replayed counters/challenges and use DeviceCheck only as the documented
  fallback for unsupported devices;
- change `AUTH_MODE` to `app_attest`; the current implementation deliberately
  fails closed for any non-`pilot` value.

App Attest is automatic and requires no manual Cloudflare enrollment screen.

## Pilot rate-limit gap

There is deliberately no process-local rate counter. Worker isolates are
ephemeral and distributed, so such a counter would be inconsistent and easy to
bypass. The current static pilot bearer is only a coarse abuse gate. Before
public release, add a Cloudflare Rate Limiting binding or an equivalent
account/zone rule keyed by the verified App Attest installation identity, with
separate limits for session creation and agent claims. That requires explicit
Cloudflare configuration and is not represented by the current bindings.

## Local verification

```sh
npm install
npm run check
cp .dev.vars.example .dev.vars
npm run dev
```

Never put secrets in `wrangler.jsonc`. For deployment, set all five secrets:

```sh
npx wrangler secret put LIVEKIT_API_KEY
npx wrangler secret put LIVEKIT_API_SECRET
npx wrangler secret put BYOK_KEK_B64
npx wrangler secret put OPENCLAM_BROKER_AGENT_TOKEN
npx wrangler secret put PILOT_APP_TOKEN
# Optional during a device migration; remove after clients move to App Attest.
npx wrangler secret put PILOT_APP_TOKEN_NEXT
```

Set `LIVEKIT_URL`, the exact named `LIVEKIT_AGENT_NAME`, and a real locked origin
before deployment. This directory intentionally contains no account IDs, API
keys, project secrets, or deployment state.
