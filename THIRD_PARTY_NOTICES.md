# Third-party notices

Third-party components remain governed by their own licenses and service terms.
Exact dependency versions are recorded in the checked-in lock files and Xcode
package resolution.

## iOS

The iOS app uses the LiveKit Swift client (Apache-2.0), LiveKit WebRTC and
UniFFI binary packages, SwiftProtobuf (Apache-2.0), and ZIPFoundation (MIT).
Their upstream package repositories and license files are identified by
`ios/OpenClamLiveKit/OpenClamLiveKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## macOS

Electron, Chromium, Node.js, Python, LiveKit JS, FFmpeg, OpenCV, MediaPipe,
MLX/Whisper, and packaged Python dependency notices are documented in
[`macos/OpenClamStudio/THIRD_PARTY_NOTICES.md`](macos/OpenClamStudio/THIRD_PARTY_NOTICES.md).
That file also records the corresponding-source obligations for the LGPL
FFmpeg binary release.

## Broker and agent

The Cloudflare Worker's JavaScript dependency versions and integrity hashes are
in `cloudflare-broker/package-lock.json`. The LiveKit agent's Python dependency
constraints are in `agent/pyproject.toml`. A distributor must preserve the
licenses and notices supplied by those packages and review them again whenever
the locks change.

## OpenClaw connector

The `openclam` channel adapter integrates with OpenClaw, which is distributed
under the MIT License. The adapter and independent Cloudflare Worker record
their exact JavaScript dependency versions and integrity hashes in
`openclaw-plugin-openclam/package-lock.json` and
`openclaw-bridge/package-lock.json`. Their upstream licenses and notices remain
in force. The connector does not include or redistribute Telegram code, SDKs,
or credentials.

## Models and network services

Bundled or downloaded model weights may have terms separate from their runtime
software. Cloud services also have provider terms independent of this source
license. The MIT license for OpenClam does not grant rights to third-party
models, service marks, a person's likeness, user-provided content, or the
separately restricted Captain Ayer and Ara media described in
[`AVATAR_ASSET_LICENSE.md`](AVATAR_ASSET_LICENSE.md).
