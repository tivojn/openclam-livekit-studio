# Privacy

OpenClam Studio has no analytics, advertising SDK, device pairing, or data
synchronization with OpenClam on iPhone.

## Stored on this Mac

The app may store conversation history, avatar source portraits, authoring
prompts, generated head/body/motion material, runtime sprites, active avatar,
window preferences, and non-secret provider selections in its Application
Support directory. Provider keys, xAI OAuth access/refresh state, the selected
xAI authentication mode, and the LiveKit pilot token are stored in the macOS
Keychain under `com.lionheart.openclam.macos`.

That persistence applies to the signed, packaged app. The unsigned source
development host keeps xAI OAuth credentials and the LiveKit pilot token only
in backend memory, forgets them when the app restarts, and does not access the
signed release's Keychain items. It may persist only the non-secret selected
xAI authentication mode in its mode-0600 Application Support data.

The local backend listens only on `127.0.0.1`, requires a random per-install
token kept in a mode-0600 app-data file, and does not reveal Keychain values to
the renderer.

## Network data

- A selected cloud LLM receives the current request, relevant conversation,
  and active avatar persona.
- A selected cloud STT service receives microphone audio.
- A selected cloud TTS service receives reply text.
- When enabled, Grok web search sends the question and relevant conversation
  context to xAI so its server-side search tool can retrieve current web pages
  and return cited results.
- Live Talk sends audio through LiveKit and the selected speech/model services.
  BYOK keys required by that call travel over HTTPS to the trusted broker as a
  short-lived one-use lease; they are never room metadata.
- Avatar generation sends only the references and direction required for the
  operation to the image or video provider selected in Avatar Studio. Local
  cutout, calibration, rig assembly, and AVTR packaging stay on the Mac.
  OpenAI GPT Image 2 uses its matching API key. xAI Grok Imagine Image 2.0
  uses the globally selected xAI API-key or OAuth2 mode. Image 2.0 editing may
  send up to five user-selected references in one request.
- Choosing xAI OAuth uses **Grok Build compatibility**: the public client
  identity and ten scopes embedded in xAI's Grok Build source at the revision
  pinned by OpenClam, followed by an
  `auth.x.ai` device-login page. OpenClam stores
  the resulting access and rotating refresh tokens only in Keychain, refreshes
  them directly with `auth.x.ai`, and sends access tokens only to pinned xAI
  inference origins (or through the trusted one-use Live Talk credential
  lease). OpenClam does not send a Grok Build referrer, read browser cookies,
  or import credentials from Grok, Grok Build, another app, or a CLI file.
  This compatibility mode does not create an OpenClam xAI registration or
  imply a partnership. If xAI changes or withdraws that public identity, OAuth
  may stop working; the independently selectable API-key mode remains
  available and is never used as an automatic fallback.
- Source setup and the source-development preflight download the
  checksum-pinned public MediaPipe Face Landmarker and MLX Whisper Small 4-bit
  model files when their generated staging copies are absent or invalid.
  Release builds include both models. Those build-time requests contain no
  portrait, microphone audio, conversation, credential, or device state.
- An installed build never downloads a speech model at startup or while using
  push-to-talk. It resolves the public Whisper model name to the verified model
  inside the app bundle; a missing or modified bundle produces a clear local
  error instead of falling back to Hugging Face.
- Packaged builds check this project's GitHub Releases endpoint for a newer
  version. The request contains the app's product user-agent and ordinary
  network metadata, not conversations, avatars, credentials, or device state.
- Avatar Store is unavailable in v1.0.1. The shipped app has no catalog URL,
  does not request store catalogs, thumbnails, or packages, and does not expose
  any stale store cache. Local `.avtr` import and library management do not
  contact a store.

Provider terms and retention policies apply to requests made to those
providers. Local Ollama, macOS System Voice, and bundled MLX Whisper options
keep their respective model traffic on the Mac.

## Microphone

Microphone capture starts only while push-to-talk is held or a Live Talk call
is active. Releasing push-to-talk, hanging up, closing the call, or quitting
stops the local track. The app does not request System Audio Recording,
Accessibility, or Apple Events automation.

## Camera and chat files

Camera capture starts only after the user chooses **Take a Photo** in the chat
composer and stops when the photo is used, the camera sheet is cancelled, or
the app closes. A chosen or captured file is copied into OpenClam's private
application data and is supplied only to the OpenClaw agent selected for that
chat. OpenClam never adds files from the Mac without an explicit composer
choice. Received and sent chat files remain available to that Mac's chat
history until their OpenClam application data is removed.

## AVTR exports

Export is always explicit. Mac-full packages include avatar authoring material
but exclude runtime caches, diagnostics, histories, application settings, and
credentials. iPhone-light packages contain only the fixed verified runtime
assets. Neither file causes background synchronization.

Directly imported AVTR packages use the same strict validation and remain local
after installation. The Mac accepts only the `macos-full` authoring variant;
the iPhone accepts only `ios-light`. Neither app silently substitutes the other
platform's package.

## Deletion

Deleting an avatar removes that local avatar after validation. Uninstalling the
application does not automatically erase its Application Support directory or
Keychain entries. Remove those separately if you want all local data erased.
