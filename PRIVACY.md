# Privacy

OpenClam has no advertising SDK and does not require the iPhone and Mac apps to
pair or synchronize with each other.

## Data stored on a device

The apps may store conversations, preferences, imported avatars, and generated
avatar material in their local containers. Provider credentials are stored in
the platform Keychain. They are not source files, AVTR exports, logs, room
metadata, or Avatar Store catalog fields.

Deleting an app may not delete every Keychain or Application Support item.
Users who want complete removal must delete those records separately.

## Data sent to selected services

- A selected cloud language model receives the request and relevant context.
- A selected cloud speech-to-text service receives audio captured during the
  explicit speech session.
- A selected cloud text-to-speech service receives reply text.
- A selected image or video provider receives only the references and
  instructions submitted for that operation.
- Live Talk sends microphone audio through LiveKit and the selected model and
  speech services.
- The reviewed Avatar Store sends catalog and package requests only when the
  user opens or downloads from the Store. Users may instead import a local AVTR
  package explicitly from Files.
- When an avatar is explicitly switched to OpenClaw mode, OpenClam sends that
  chat's user text and receives streamed reply text through the independently
  deployed OpenClam bridge. OpenClam sends no audio, iPhone files, screenshots,
  clipboard data, provider credentials, or iPhone tool approvals through this
  connector. A negotiated extension may receive bounded generated files from
  OpenClaw after iOS verifies their type, length, and SHA-256.

Provider terms and retention policies apply. Local system voices and bundled
offline speech recognition keep their respective inference traffic on-device.

## BYOK Live Talk boundary

For a BYOK Live Talk stage, the client reads only the selected credential from
Keychain and sends it over HTTPS to the trusted broker. The broker encrypts it
in a short-lived, one-use lease. The named LiveKit agent atomically consumes
that lease and holds the credential only for the call. The broker does not
receive microphone audio, transcripts, or model responses, and credentials are
never placed in LiveKit room, participant, or dispatch metadata.

This is bounded cloud exposure, not a claim that a cloud agent can use a key
without the key leaving the device.

## OpenClaw connector boundary

OpenClaw pairing returns a scoped client credential that is stored in
ThisDeviceOnly Keychain storage. The bridge stores only credential verifiers.
Pending text frames are encrypted at rest, deleted after acknowledgement or a
bounded expiry, and are not written to Worker logs. OpenClam and OpenClaw keep
their own chat histories under their respective settings; the bridge is not a
history service.

Each chat records the route that created it. Changing an avatar between On this
iPhone and OpenClaw, or choosing a different remote agent, starts a new chat so
one backend does not inherit another backend's transcript. Disconnecting
revokes the bridge connection before local credentials are removed. The user
may explicitly remove an obsolete pairing on iPhone; this also discards only
that connection's unfinished saved turn while retaining chat history and
already delivered files.

The OpenClaw connector has no Telegram dependency and receives no LiveKit,
language-model, speech-recognition, or speech-synthesis credentials. Continuous
Live Talk remains on its separate LiveKit path.

## Avatars

AVTR export and import are explicit. Runtime packages exclude credentials,
conversations, application settings, and build diagnostics. The public source
tree bundles only the reviewed Captain Ayer and Ara runtime assets. Their exact
paths and hashes are pinned by the public release audit, and their media license
is separate from the MIT software license. No source portraits or
avatar-authoring projects are shipped.

The macOS-specific detail is in
[`macos/OpenClamStudio/PRIVACY.md`](macos/OpenClamStudio/PRIVACY.md).
