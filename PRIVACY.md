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
- Avatar Store requests its public catalog, thumbnails, and packages from the
  configured GitHub release origin after an explicit user action.

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

## Avatars

AVTR export and import are explicit. Runtime packages exclude credentials,
conversations, application settings, and build diagnostics. The public source
tree includes only a deterministic synthetic guide. Human-likeness avatars and
thumbnails may be distributed through the separate Avatar Store only after
rights and consent are documented.

The macOS-specific detail is in
[`macos/OpenClamStudio/PRIVACY.md`](macos/OpenClamStudio/PRIVACY.md).
