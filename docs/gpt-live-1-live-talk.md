# GPT-Live-1 full-duplex Live Talk

Live Talk on the Mac now has two engines, chosen in Settings before a call:

- **LiveKit pipeline** (the existing engine): separate Listening, Thinking and
  Speaking services, including LiveKit managed defaults, personal-account
  (BYOK) tuples and Connected OpenClaw.
- **OpenAI GPT-Live-1** (new): OpenAI's full-duplex voice model listens and
  speaks for the whole call in one model, decides its own turns, answers
  while the user is still talking, and delegates reasoning and tool calls to
  a backend Responses model. It uses the OpenAI key stored in the Mac
  Keychain. OpenAI bills the voice session per minute (per second, no
  rounding) plus backend model tokens.

## Select it

Settings → AI & Voice → Continuous Live Talk → **Live Talk engine**. Choosing
*OpenAI GPT-Live-1 · full duplex* sets the Thinking stage to
`byok / openai / gpt-live-1` with a voice picker (Marin is the default; the
other twelve OpenAI GPT-Live voices are listed with their regional influence).
The Listening and Voice stages dim and are not used, but their saved choices
are kept for the pipeline engine. Save Live Talk, then start the call with the
usual button. Switching the engine back to the pipeline restores the last
pipeline Thinking choice on that page.

The Mac still requires a selected, connected OpenClaw agent before any Live
Talk call starts, because the foreground-agent route is the only way a spoken
action, live search, file, media or messaging request is carried out.

## Routing and ownership

The approved tuple contract gains thirteen LLM rows
`["llm","byok","openai","gpt-live-1",<voice>,null]`. GPT-Live-1 is the only
LLM row that carries a voice; every other LLM row still rejects one. The rows
are mirrored in the broker catalog, the agent's catalog copy and the Mac
contract copy, and the release script pins the new contract hash.

The broker profile stays three-stage. For a GPT-Live call the Mac bridge sends
the user's Thinking selection plus the LiveKit managed *placeholders* for
Listening and Voice, and resolves only the OpenAI key. Saved personal-account
speech keys and the shared xAI mode are never read for a full-duplex call.

The LiveKit agent builds `GPTLiveModel` from the pinned OpenAI plugin instead
of STT, LLM and TTS plugins. It runs with **responses delegation**: the voice
model gets a short conversation prompt (style, backchannel and interruption
policy, and a delegation policy that names the foreground OpenClam agent as
the only backend capability), while the backend model `gpt-5.6-luna` gets the
tool instructions and the `use_foreground_agent` function tool. Both prompts
carry the same delimited untrusted persona block and final safety rules as
the cascade, and neither can change after the session starts.

Differences from the pipeline engine:

- **Turns and barge-in are the model's.** The session attaches an explicit
  Silero VAD only so LiveKit can cut playback when the user interrupts.
  LiveKit turn detection, endpointing and preemptive generation do not apply.
- **No fixed scripts.** GPT-Live cannot speak an exact sentence, so the
  deterministic email-draft flow is unavailable in this engine: the
  `prepare_email_draft` tool is not exposed to the backend model and the
  spoken email interception is skipped. The foreground-agent result returns
  to the backend model as the tool output; the voice model relays it under
  instructions that forbid embellishing it, instead of LiveKit speaking the
  exact text.
- **Lip-sync follows the audio.** GPT-Live transcripts arrive after the audio,
  so the agent publishes no word-timing packets; the Mac's audio-driven
  viseme fallback and the transcript-driven expressions handle the avatar.
  Captions are forwarded as soon as each transcript lands.
- **The greeting is a request, not an utterance.** The model may decline the
  opening greeting; the call is still connected and it answers when the user
  speaks.
- **Chinese**: GPT-Live voices are English or Portuguese influenced; the
  model follows the language of the latest spoken turn as before.

## Dependencies and rollout

- The agent moves from LiveKit Agents 1.6.9 to **1.8.1** (all plugins pinned
  together) and adds `livekit-plugins-silero`. The one test that pinned the
  1.6.x tool executor internals now asserts the 1.8 shape: a `StopResponse`
  from a tool records an empty, non-error output with `reply_required=False`.
- The OpenAI plugin requires an API key on an account with GPT-Live access.
- Deploy order: broker (new catalog rows), then the LiveKit agent (new SDK,
  Silero model files via `download-files`), then Mac clients. Existing
  pipeline clients remain compatible throughout.
- iOS is unchanged: its three-stage catalog does not list the new rows, and
  its tuple-matrix test still passes.

## Validation

- Agent: `pytest` — 309 tests, including per-voice construction of
  `GPTLiveModel`, the session shape (explicit VAD, no STT/TTS, model-side
  turn detection), tool exposure, and fail-closed email behaviour.
- Broker: `npm run check` — 84 tests, including the fixture parity check and
  the new GPT-Live acceptance and rejection cases.
- Mac: `npm test` — Python unit suites plus the renderer, settings and Live
  Talk QA scripts; the settings QA pins the engine picker and the inert
  speech stages.
