# Connected OpenClaw in Live Talk

Live Talk can use the OpenClaw agent selected in the current conversation for
every finalized spoken turn. Speech recognition and speech synthesis remain
independently selectable. OpenClaw owns the reply, model, session, memory and
tools; another voice model does not rewrite either the request or the answer.

## Select it

- **Mac:** Settings → AI & Voice → Continuous Live Talk → Thinking →
  Conversation source → Connected OpenClaw. Save Live Talk, select an OpenClaw
  agent in the chat composer, then start the call.
- **iPhone:** Edit the active avatar's AI & Voice settings → Continuous Live
  Talk → Language model → Connected OpenClaw. Select a paired OpenClaw agent
  for the chat before starting the call.

Keep the app in the foreground and its existing OpenClaw connection available.
The selected agent is pinned when the call starts. End the call before changing
agents. Choose LiveKit managed or another supported model to switch back.
Existing installations keep their previous choice until this option is selected.

## Routing and ownership

The exact approved LLM selection is `connected / openclaw / selected-agent`.
The broker accepts this selection without an LLM credential and rejects both
credentials for this route and connected speech-recognition/synthesis choices.
OpenClaw model credentials remain with OpenClaw. On iPhone, the existing paired
connector transports the turn; its credential is not sent to the voice broker.

The voice agent implements a custom LLM node on the pinned LiveKit Agents SDK.
It invokes `openclam.submitAgentTurn.v1` for every finalized user turn, including
greetings, follow-ups and motion requests. The foreground client validates the
agent caller, matching finalized transcript, deadline and request ID, then uses
the same OpenClaw conversation transport as typed chat. A local presentation
context describes the avatar's installed motions without replacing OpenClaw's
identity or tool policy. The original transcript remains the visible user turn.

The completed OpenClaw reply owns the visible assistant message and avatar
reaction. LiveKit speaks that reply once; the client suppresses its duplicate
caption and local read-aloud. Normal speech-task cancellation handles interruption,
and replay guards prevent SDK retries from dispatching the same turn again.
Preemptive LLM generation is disabled for this route. Connection readiness uses
the existing chime; no fabricated user greeting is sent to OpenClaw.

The existing transport bounds remain: 300-second RPC deadline, 8 KB spoken
request, 6 KB spoken reply and 128 delegated turns per call. Speech starts after
the completed OpenClaw reply, so its model/tool latency is audible. Connection or
agent failures are reported instead of silently falling back to another LLM.

## Validation

The Python agent suite passed 275 tests, the broker passed TypeScript validation
and 68 tests, and the iOS Live Talk simulator suite passed 73 tests. Mac validation
passed 1,386 Python tests plus renderer, call ownership, routing and release QA.
New tests cover exact transcript routing, small talk, Chinese input, replay,
failure, cancellation, selected-agent pinning and one speech owner.

A synthetic-speech probe joined the deployed LiveKit room, forwarded its real
STT-generated RPC through the Mac's connected `main` agent, and received spoken
audio and matching captions. The agent answered a greeting/wave request and
remembered the supplied favorite color in a follow-up. Each turn dispatched once.
Observed OpenClaw completion times were 12.39 and 18.15 seconds. This probe did
not capture a microphone or exercise the physical iPhone microphone/UI.

Server rollout on 2026-09-09: LiveKit agent `7LYaYaPpCnDy` and broker version
`348d469b-f6f9-4858-8607-0e49bdd6b49c`. Existing managed/BYOK clients remain
compatible. A new client build is required to select Connected OpenClaw.

A second deployed probe used “Can you do a” followed by a pause and “kung fu
punch?” The two final STT fragments arrived 3.01 seconds apart. The production
Mac transcript validator accepted their complete request, OpenClaw returned a
kung-fu demonstration reply, and LiveKit delivered matching speech. Regression
tests reject a suffix-only request and preserve explicit claimed-turn and
interruption boundaries without relying on packet timing.

## iPhone launch follow-up (build 78)

The build 77 TestFlight launch crash was symbolicated using the matching archive
UUID. It is a main-thread stack-guard fault in Swift's type metadata decoder,
called from `ConversationView.threadContent(in:)`, before Live Talk begins.
Apple's reports show the same failure in build 75 on iOS 27 beta. The timeline
now places each heterogeneous row behind a concrete `ConversationThreadElement`
boundary; extracting helpers that still return `some View` does not bound that
recursive metadata graph. Message and email-review IDs stay outside the boundary
so lazy layout, scroll placement, and review navigation remain intact.

The release audit includes repeated cold launches of the real app, sidebar and
settings access, and conversation placement at the largest accessibility size.
The available simulator runs iOS 26.5; the affected physical iOS 27 beta phone
is not connected to Xcode, so verification on that device remains necessary.
