# OpenClam ↔ OpenClaw connector architecture

## Product behavior

Every OpenClam avatar has an explicit agent mode:

- **On this iPhone** keeps the existing local OpenClam routing.
- **OpenClaw** selects one paired OpenClaw connection and one advertised agent.

Chat and tap-to-talk use the selected agent mode. Tap-to-talk speech recognition
and read-aloud speech synthesis remain the avatar's existing iOS selections.
Continuous Live Talk remains an independent LiveKit media feature. Ordinary
macOS voice conversation stays on its low-latency streaming model. When that
model selects the constrained foreground-action tool, the tool sends the exact
latest finalized transcript through one authenticated RPC to the conversation's
selected and connected OpenClaw agent. With no selected OpenClaw agent, the
action fails closed and is never sent to a plain local language model. OpenClaw
Work events, generated files, and visible approval state therefore remain
identical to typed chat. LiveKit speaks only the bounded final text returned by
that route. iOS registers the same closed `openclam.submitAgentTurn.v1` RPC and
routes an agentic Live Talk request through the conversation's paired OpenClaw
connector. The authoritative final transcript remains visible, OpenClaw work
and approval state use the same cards as typed chat, a matching LiveKit echo is
suppressed, and barge-in or session end cancels the exact durable connector
turn. No mode silently falls back to another backend.

Changing mode or remote agent starts a new chat. Existing chats retain the route
that created them, so a local provider never receives an OpenClaw transcript and
one OpenClaw agent never inherits another agent's session.

## Telegram-like behavior without Telegram

Telegram, BotFather, Telegram accounts, and Telegram tokens are not part of this
feature. OpenClam borrows only the useful product pattern: a named bot/avatar
identity, an explicit agent binding, a one-time pairing code, scoped revocable
credentials, streaming replies, and reconnectable conversations.

OpenClaw's Gateway also accepts only a closed registry of client identities.
OpenClam must not impersonate the official `openclaw-ios` client merely to obtain
silent mobile pairing. The supported first-class design is an `openclam` channel
adapter with its own narrow pairing and transport.

References:

- [OpenClaw channel plugin guide](https://docs.openclaw.ai/plugins/sdk-channel-plugins)
- [OpenClaw multi-agent bindings](https://docs.openclaw.ai/concepts/multi-agent)

## Components

```text
OpenClam iOS                         OpenClaw host
┌──────────────────┐                ┌────────────────────┐
│ avatar mode      │                │ OpenClaw agents    │
│ PTT → text       │                │ channel bindings   │
│ existing TTS     │                │ openclam adapter   │
│ connector client │                └─────────┬──────────┘
└────────┬─────────┘                          │ outbound WSS
         │ outbound WSS                      │
         └──────────┐              ┌─────────┘
                    ▼              ▼
              Cloudflare Worker + Durable Objects
              `openclam-openclaw-bridge`
```

The bridge is independent from `openclam-livekit-pilot-broker`: separate code,
deployment, secrets, Durable Object namespaces, tests, and lifecycle. The bridge
cannot access LiveKit or AI-provider credentials.

Both the phone and adapter make outbound WSS connections, so the OpenClaw
Gateway does not need a public inbound port. The Durable Object can hibernate
while sockets remain connected, following Cloudflare's recommended server-side
WebSocket design.

- [Cloudflare Durable Object WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)

## Pairing and credentials

1. The first configured OpenClaw adapter asks the bridge for a ten-minute
   pairing using the deployment bootstrap secret. Later iPhone pairings are
   created from the existing adapter credential through the OpenClam Studio
   Settings panel; the bootstrap secret does not enter the desktop app.
2. The bridge returns `OC-XXXX-XXXX-XXXX` plus an adapter token exactly once.
3. The user enters the code in OpenClam.
4. The bridge atomically consumes it and returns a distinct client token exactly
   once, together with the allowed OpenClaw agents.
5. OpenClam stores the client token in ThisDeviceOnly Keychain storage. The
   adapter token stays on the OpenClaw host.
6. A user can explicitly remove an obsolete pairing on iPhone. The bridge is
   revoked before local credentials and any unfinished saved turn for that
   connection are removed; chat history and delivered files remain local.

The bridge stores only token verifiers. A code carries 60 bits of randomness,
expires after ten minutes, and cannot be replayed. Each installation is
throttled after five failed redemption attempts. Removing a connection revokes
both sides.

## Message lifecycle

The base contract carries text. Updated clients may also negotiate safe
enum-only activity and verified generated-file delivery:

1. `turn.submit`
2. `turn.accepted`
3. zero or more cumulative `assistant.delta` frames
4. exactly one `assistant.completed` or `turn.error`

Frames have independent per-direction sequences, UUID idempotency keys,
acknowledgements, bounded replay, and a 64 KiB ceiling. Reconnect resumes pending
delivery. One conversation admits one active turn; a second turn is rejected
rather than silently queued or interrupting the first.

The wire contract is in [`shared/agent-connector-v1`](../shared/agent-connector-v1/README.md).

## Security exclusions for v1

- no Telegram dependency or Telegram credential anywhere in the connector;
- no OpenClaw Gateway owner token at Cloudflare;
- no LLM/STT/TTS/LiveKit keys at Cloudflare;
- no iPhone file uploads, screenshots, clipboard data, or local iPhone tools;
- generated files may return only through the negotiated, authenticated,
  size-bounded attachment extension after local type, length, and SHA-256
  verification; sensitive media is excluded;
- dynamic Work updates are strict, bounded summaries; private reasoning, raw
  command lines/tool output, credentials, and absolute host paths never cross
  the connector;
- no remote tool-approval UI;
- no transcript content in bridge logs;
- no silent fallback from OpenClaw to a local provider.

## Future connectors

Hermez and EnConvo will implement the same app-level connector interface but use
independent adapters, deployments, secrets, and storage:

- `openclam-openclaw-bridge`
- `openclam-hermez-bridge`
- `openclam-enconvo-bridge`

Only the versioned wire envelope and generic security utilities are shared. A
future router can join them through Cloudflare Service Bindings without merging
their trust domains or public endpoints.
