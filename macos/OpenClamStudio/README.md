# OpenClam Studio for macOS

OpenClam Studio is the standalone Mac edition of OpenClam LiveKit Pilot. It
combines regular chat, push-to-talk, continuous LiveKit voice, and a complete
desktop avatar authoring system in one Apple-silicon macOS app.

It is not a companion controller for the iPhone app. The Mac and iPhone keep
separate conversations, provider settings, credentials, avatars, and local
state, with no background synchronization. When the OpenClaw channel is
installed, the Mac Settings screen can create a one-time code that pairs an
iPhone directly with those OpenClaw agents. The Mac composer can also switch
from its local model to any configured OpenClaw agent for that conversation.
This does not synchronize either app's local data. Their only avatar-file boundary remains explicit AVTR export
from the Mac and explicit import on the iPhone.

## What it includes

- Regular chat with user-selected local or BYOK language models.
- OpenClaw chat mode with a live, expandable Work timeline and generated-file
  delivery. Only user-facing summaries and sanitized tool labels appear;
  private reasoning, raw commands/output, secrets, and host paths stay private.
- Hold-to-talk transcription and read-aloud voices with independent STT and
  TTS choices.
- LiveKit Live Talk with independently selectable LLM, STT, TTS, model,
  language, and voice. Managed LiveKit defaults and reviewed BYOK tuples use
  the same Cloudflare broker and LiveKit agent deployment as OpenClam on iOS.
- A Settings panel that creates and copies a one-time OpenClaw iPhone pairing
  code without Terminal or another OpenClaw bootstrap secret.
- A guided **Install & connect** action for a new OpenClaw setup. The signed
  app carries the reviewed runtime-only OpenClam channel package, installs or
  upgrades only that channel, advertises the existing OpenClaw agents, and
  restarts only the OpenClaw Gateway. A new bridge connection still requires
  its setup key; the key is sent only to the local installer process
  and is never saved in OpenClam, OpenClaw config, or shell history.
- A desktop avatar with calibrated face rig, lip sync, gaze, blinking, brows,
  full body, click reactions, walk, edge idle, and authored moves.
- Avatar Studio for portrait preparation, visemes, full-body turnaround,
  wardrobe direction, walk, edge idle, moves, local cutout, review, and
  activation.
- Two AVTR v2 exports:
  - **Mac project** (`macos-full`): complete editable source, head, body,
    calibration, walk, edge idle, moves, and authoring metadata.
  - **For iPhone** (`ios-light`): the strict 19-file runtime package accepted
    by OpenClam iOS, without raw sources, prompts, history, or credentials.

## Requirements

- Apple-silicon Mac
- macOS 14 or newer
- Node.js and `uv` for source development
- Python 3.12 for the packaged backend environment
- Your own credentials for any direct cloud provider you select
- The internal pilot token for LiveKit sessions

Provider secrets are write-only in Settings and stored under the
`com.lionheart.openclam.macos` macOS Keychain service. They are not written to
the project, renderer storage, AVTR files, or logs. The backend talks directly
to Apple's Security framework in-process; secret values never enter a command
line, child-process input/output, or temporary file.

After upgrading from a build that used the retired `/usr/bin/security` command,
enter provider keys and the LiveKit pilot token once again. That command created
items with a tool-owned legacy access list—and, in the affected build, often an
empty password. OpenClam deliberately uses a new internal `openclam-v2:` account
namespace and never reads, edits, or deletes those legacy items, avoiding an
authorization prompt or server hang. Logical setting names and the Keychain
service remain unchanged.

## Image generation and editing

Avatar Studio supports generation and reference-image editing with OpenAI
`gpt-image-2` and xAI `grok-imagine-image-2.0`. Image 2.0 is the default xAI
choice and accepts up to five reference images for an edit. New OpenAI and xAI
image lanes recommend those exact model IDs; explicitly saved legacy
image-model choices remain compatibility-only options rather than silently
changing an existing project.

OpenAI image inference uses a provider API key stored write-only in the Mac
Keychain. xAI API-key mode is ready now. The source also implements one global
**Sign in with xAI (OAuth2)** mode for Grok chat and optional live web search,
STT, TTS, image generation/editing, video generation/editing, and xAI BYOK
stages in Live Talk. OpenClam never mixes the two modes and never silently
falls back from OAuth to an API key or the reverse.

OAuth2 runs as **Grok Build compatibility**. OpenClam intentionally uses the
public client ID and ten scopes embedded in xAI's official Grok Build source,
audited at revision
[`eb267fe`](https://github.com/xai-org/grok-build/blob/eb267feff13129e568df38fb6fdf0ceb65f735d6/crates/codegen/xai-grok-shell/src/auth/config.rs).
That identity is pinned in signed source and cannot be replaced by an
environment variable. The release wrapper rejects changes to the client ID,
scope set, or audited revision.

OpenClam is still an independent client. Compatibility does not make it Grok
Build, create an OpenClam-owned xAI registration, imply an xAI partnership, or
import browser/Grok/CLI credentials. The browser receives only the verification
page and short user code; access and rotating refresh tokens stay in OpenClam's
own Keychain records. If xAI rotates, restricts, or withdraws Grok Build's
public client identity, this compatibility login may stop working; the separate
API-key option remains available and is never used as an automatic fallback.

The signed, packaged app persists its access and rotating refresh record in the
macOS Keychain, so one authorization survives ordinary app restarts. The
unsigned **OpenClam Studio Dev** host deliberately keeps OAuth credentials only
in backend memory: its authorization ends when that development app restarts
and it never reads, rewrites, or weakens the signed release's Keychain item.

## Source setup

```bash
scripts/setup-electron-backend.sh
npm ci
npm run check
npm start
```

`npm start` runs **OpenClam Studio Dev** directly from this checkout. It uses a
separate Electron instance lock and shell-state folder, so an installed or
mounted OpenClam Studio release may remain open without stealing the dev launch.
The Python service still loads the source files from this directory; no DMG
installation is involved. Because this host is unsigned, an xAI OAuth login is
explicitly session-only and must be repeated after a restart. Use a signed DMG
build when testing persistent OAuth consent.

The app listens only on loopback. Electron creates a private local
authentication token for each installation, stores it in its mode-0600 app
data file, and the backend fails closed if it is absent. The renderer never
receives stored provider keys or the LiveKit pilot token.

For a brand-new OpenClaw installation, open **Settings → AI & Voice →
OpenClaw · iPhone pairing**, paste the bridge setup key, and choose
**Install & connect**. Release packaging uses
`scripts/stage-openclaw-plugin.sh` to build and embed the exact runtime-only
channel archive and its non-secret bridge origin. Once connected, **Update
channel** upgrades the bundled OpenClam channel in one click without requiring
the setup key again. Neither action changes Telegram or another OpenClaw
channel.

`npm run fetch:model` (also run by the source start/dev preflight) downloads
the pinned MediaPipe files and the `mlx-community/whisper-small-mlx-4bit`
files only when generated staging copies are absent or invalid. The pinned
Whisper revision is `f1da4c67f2ee8b6e763b974e149aa65d5b7658b7`.
Installed builds bundle both model families: they never download a speech
model at startup or during push-to-talk, and fail clearly if the offline
bundle is missing or altered.

## LiveKit boundary

Starting a call asks the local authenticated backend for one room session. The
backend reads only the credentials required by the selected stages from
Keychain and sends them over HTTPS to the trusted OpenClam broker. For xAI,
that means either the selected global API key or one freshly refreshed OAuth
access token—never both. The broker creates a short-lived, one-use credential
lease and a room token. Credentials are not placed in room, participant, or
dispatch metadata.

LiveKit transports the call and runs the cloud agent. It does not synchronize
Mac data with the iPhone app. Ending a call stops the local microphone track and
disconnects the room.

## Avatar files

Both exports use the `.avtr` extension but have different strict, hash-ledgered
manifest variants. The Mac importer rejects the iPhone-light variant as an authoring
project; the iPhone importer rejects the Mac-full variant. Both verify strict
paths, entry types, sizes, hashes, and schemas before atomic installation.

See [`contracts/avatar-package-v2/README.md`](contracts/avatar-package-v2/README.md)
for the complete portable file contract.

## Avatar Store

Avatar Store is unavailable in v1.0.1: the shipped app has no remote catalog
URL, the Settings entry is hidden, and its IPC boundary fails closed before any
network request or cached remote entry can be used. Direct `.avtr` import,
library use, export, and deletion remain available in Avatar Studio. Dormant
generic catalog validation and download code is retained for a future release
only after its media and endpoint have been separately reviewed.

## Build a DMG

```bash
npm run check
npm audit
npm run dist
```

The release build uses Hardened Runtime, microphone-only media permission, and
the exact OpenClam iOS app icon. The source icon SHA-256 is
`d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f`.
The locally synthesized Live Talk connection sound SHA-256 is
`471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4`.
`npm run dist` is intentionally fail-closed. It requires the exact Developer ID
Application identity `THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)` and the
notarytool Keychain profile `OpenClamStudioNotary`; credentials are never
committed or printed. The command notarizes and staples the app before placing
it in the DMG, timestamp-signs and notarizes the outer DMG, then requires
successful `stapler`, `hdiutil`, Gatekeeper, and `syspolicy_check` verification.
It first runs the complete regression/privacy suite and full dependency audit,
then checks the architecture and deployment target of every staged
Mach-O. It writes the publishable SHA-256 only after stapling and all checks
pass. A red test, unsafe native artifact, missing identity/profile, rejected
notarization, or skipped verification stops the release without producing an
approved artifact.

The private `check:avatar` command is deliberately not a release prerequisite:
it analyzes a user's active portrait and generated avatar files, which must
never enter a clean source or release workspace. Release gating instead runs
the deterministic avatar/unit suite plus staged-runtime and packaged-app QA,
including a real offline push-to-talk transcription through the bundled Python,
FFmpeg, MLX Whisper model, and provider code.

## Security and privacy

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before distributing a build.

OpenClam Studio is licensed under the [MIT License](LICENSE), preserving the
attribution of the OpenClam and avatar-runtime sources from which it was built.
