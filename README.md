# OpenClam

OpenClam is an open-source iPhone and Apple-silicon Mac assistant with typed
chat, push-to-talk, LiveKit voice sessions, and portable AVTR avatars. This
repository contains both clients, their shared contracts, and the optional
LiveKit broker and agent used for continuous cloud voice.

## Repository map

| Path | Purpose |
| --- | --- |
| `ios/OpenClamLiveKit` | iOS app, extensions, tests, and XcodeGen project |
| `macos/OpenClamStudio` | Electron shell, local Python backend, Avatar Studio, tests, and release tooling |
| `shared` | Versioned avatar-package and avatar-store contracts plus deterministic fixtures |
| `contracts` | Live Talk provider/profile contract shared by clients, broker, and agent |
| `cloudflare-broker` | Optional Cloudflare Worker for session tokens and one-use BYOK leases |
| `agent` | Optional LiveKit voice agent that consumes those leases |

The iPhone and Mac apps are independent. They do not pair or synchronize
histories, credentials, settings, or avatars. AVTR export/import is an explicit
file transfer; Avatar Store networking is disabled in v1.0.1.

## Privacy-safe source tree

This public tree contains no provider keys, signing credentials, deployment
state, user conversations, recordings, source portraits, authoring projects,
or acceptance screenshots. The iOS app bundles exactly two reviewed avatars:
Captain Ayer and Ara. Their immutable runtime assets are covered by the narrow
distribution permission in [`AVATAR_ASSET_LICENSE.md`](AVATAR_ASSET_LICENSE.md)
and the exact path/hash allowlist in `scripts/public-release-audit.py`; the
bundled provenance record identifies their rights basis. They are not
MIT-licensed.

No other human-likeness avatar package or thumbnail may enter this repository
or its Git history without an equivalent ownership, consent, redistribution,
provenance, and immutable-hash review. Avatar Store networking is disabled in
v1.0.1; local AVTR import and deletion remain available.

Run the repository audit before every public commit or release:

```sh
python3 scripts/public-release-audit.py .
```

For a release, write the exact file/mode/SHA-256 manifest outside the source
tree, then require the same manifest when auditing the source tree and its
extracted Git archive:

```sh
python3 scripts/public-release-audit.py \
  --write-manifest /tmp/openclam-source-manifest.json .
python3 scripts/public-release-audit.py \
  --manifest /tmp/openclam-source-manifest.json .
```

For the first public commit, also require fresh one-commit history:

```sh
python3 scripts/public-release-audit.py --require-fresh-history .
```

## Build the iOS app

Requirements: Xcode 16 or newer and an iOS 17 or newer simulator. The checked-in
project can be built directly; XcodeGen is needed only after editing
`project.yml`.

```sh
xcodebuild \
  -project ios/OpenClamLiveKit/OpenClamLiveKit.xcodeproj \
  -scheme OpenClamLiveKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

`Config/LiveTalk.xcconfig` contains public defaults and imports the ignored
`Config/LiveTalk.local.xcconfig` when present. Never commit the local file,
pilot bearer, signing profiles, archives, or TestFlight export material.

## Build the macOS app

See [`macos/OpenClamStudio/README.md`](macos/OpenClamStudio/README.md) for the
development and packaging prerequisites.

```sh
cd macos/OpenClamStudio
scripts/setup-electron-backend.sh
npm ci
npm run check
npm start
```

The distributable DMG is a GitHub Release asset, not source. The fail-closed
release command requires the documented Developer ID and notarization profile;
it must be run only by an authorized release operator.

## Optional LiveKit services

The clients can use LiveKit-managed inference or selected BYOK stages. A cloud
agent necessarily needs a provider credential to call a BYOK provider. The
broker minimizes this exposure by validating a closed catalog and issuing a
short-lived, encrypted, one-use lease; credentials never enter room or dispatch
metadata. See [`cloudflare-broker/README.md`](cloudflare-broker/README.md).

The checked-in pilot authentication mode is not a public-production identity
system. Replace it with App Attest or equivalent installation authentication
and account-level rate limiting before opening the broker to untrusted clients.

## Security, privacy, and licensing

- [`PRIVACY.md`](PRIVACY.md) explains local and network data boundaries.
- [`SECURITY.md`](SECURITY.md) describes reporting and release requirements.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) routes component notices.
- [`PUBLIC_RELEASE_CHECKLIST.md`](PUBLIC_RELEASE_CHECKLIST.md) is the release gate.

The software source is available under the [MIT License](LICENSE). The bundled
Captain Ayer and Ara media are separately restricted, and third-party packages,
models, and services retain their own licenses and terms.
