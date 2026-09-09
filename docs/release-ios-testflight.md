# iOS TestFlight runbook

Builds 56 and 57 were archived by hand in Xcode. This is the same flow written
down so it can be audited before an upload, current release build 77 (1.0.6,
Connected OpenClaw as the Live Talk conversation source).

## 1. Version

`ios/OpenClamLiveKit/project.yml` is the source of truth. Bump
`CURRENT_PROJECT_VERSION` (all four targets must match) and, for a feature
build, `MARKETING_VERSION`; then regenerate the project:

```bash
cd ios/OpenClamLiveKit && xcodegen generate
```

`ExportOptions-AppStore.plist` sets `manageAppVersionAndBuildNumber: false`,
so App Store Connect will reject a build number it has already seen.

## 2. Audit gates (all must pass)

```bash
# clean Git checkout, before installing dependencies or local config
python3 scripts/public-release-audit.py .

# configured build checkout
python3 scripts/check-ios-livetalk-release-config.py
python3 scripts/check-ios-agent-connector-release-config.py

# macOS side that produces the packages the phone imports
cd macos/OpenClamStudio && npm run check:syntax && npm test

# iOS unit tests
cd ios/OpenClamLiveKit && xcodebuild test -project OpenClamLiveKit.xcodeproj \
  -scheme OpenClamLiveKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Scripted 3D avatar audit (needs an `ios-3d` package installed under the app's
`Application Support/OpenClam/Avatars/v2/<id>`; screenshots land in the
directory given by the environment variable):

```bash
cd ios/OpenClamLiveKit
TEST_RUNNER_OPENCLAM_UITEST_SCREENSHOT_DIR=/tmp/openclam-3d-audit xcodebuild test \
  -project OpenClamLiveKit.xcodeproj -scheme OpenClamLiveKitUIAudit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenClamLiveKitUITests/OpenClam3DAvatarUITests
```

It opens the carousel, spins to the model avatar, activates it, and captures
standby, close-up and full-body frames. The simulator's speech service is
not dependable, so the test relaunches with the app's speech-hold hook for the
speaking-state capture; real mouth motion is covered by the unit tests
(`OpenClam3DAvatarTests`) and by the desktop renderer, which share the same
viseme channel tables.

Manual checks on a simulator or device before archiving:

- Import an `ios-3d` AVTR from Files; the card shows the model thumbnail.
- Select it; the figure renders, blinks and breathes; tap-to-talk or a read
  aloud reply moves the mouth in sync; compact and expanded presentations frame
  the face.
- A sprite avatar (Captain Ayer) still renders and animates unchanged.
- Tampered packages (wrong hash, extra file, Draco model) are refused with a
  clear message and leave no half-installed avatar.

## 3. Archive and upload

```bash
cd ios/OpenClamLiveKit
xcodebuild -project OpenClamLiveKit.xcodeproj -scheme OpenClamLiveKit \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/OpenClam-1.0.6-77.xcarchive archive
xcodebuild -exportArchive -archivePath build/OpenClam-1.0.6-77.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore.plist -exportPath build/export-77
```

`ExportOptions-AppStore.plist` has `destination: upload`, so the second
command signs with the automatic team profile (X7R8N6MMSU) and uploads to App
Store Connect using the Apple ID signed into Xcode. Add testers or an external
group in App Store Connect once processing finishes; the archive itself stays
out of the repository (`*.xcarchive/` is ignored).

## 4. After upload

- Note the build in the release commit (`release(ios): ship build 77`).
- Keep `contracts/release-feature-contract-v1.json` in step with any catalog
  tag change (none for 3D avatars; the Store still lists sprite packages).
