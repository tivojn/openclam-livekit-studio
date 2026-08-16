#!/bin/bash
# Produce the only publishable macOS artifact. This deliberately keeps
# electron-builder notarization disabled: every Apple check below is explicit,
# mandatory, and covered by qa/release_security_qa.js.
set -Eeuo pipefail

umask 077

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DIST_DIR="$PROJECT_ROOT/dist-electron"
PRODUCT_NAME='OpenClam Studio'
APP_ID='com.lionheart.openclam.macos'
IDENTITY_QUALIFIER='THE GREAT LIONHEART PTE. LTD. (X7R8N6MMSU)'
SIGN_IDENTITY="Developer ID Application: $IDENTITY_QUALIFIER"
TEAM_ID='X7R8N6MMSU'
NOTARY_PROFILE='OpenClamStudioNotary'
BUILDER="$PROJECT_ROOT/node_modules/.bin/electron-builder"
AUDIT_PYTHON="$PROJECT_ROOT/.venv/bin/python"
UVX_BIN="$(command -v uvx || true)"
WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/openclam-release.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mounted-dmg"
MOUNTED=0

PACKAGE_VERSION="$(/usr/bin/plutil -extract version raw -o - "$PROJECT_ROOT/package.json" 2>/dev/null)" \
  || { echo 'release failed: package.json has no readable version' >&2; exit 1; }
[[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo 'release failed: package version must be strict X.Y.Z' >&2; exit 1; }

PROFILE_VERIFIED=0
XAI_OAUTH_CLIENT_VERIFIED=0
SOURCE_CHECKS_VERIFIED=0
NATIVE_ARTIFACTS_VERIFIED=0
STAGED_NATIVE_PATHS_VERIFIED=0
PACKAGED_NATIVE_PATHS_VERIFIED=0
SOURCE_ASSETS_VERIFIED=0
PACKAGED_ASSETS_VERIFIED=0
SOURCE_LICENSES_VERIFIED=0
PACKAGED_LICENSES_VERIFIED=0
PYTHON_DEPENDENCIES_AUDITED=0
STAGED_RUNTIME_VERIFIED=0
PACKAGED_RUNTIME_VERIFIED=0
APP_BUILT=0
APP_SIGNED=0
APP_NOTARIZED=0
APP_STAPLED=0
DMG_BUILT=0
DMG_SIGNED=0
DMG_NOTARIZED=0
DMG_STAPLED=0
DMG_VERIFIED=0
MOUNTED_APP_VERIFIED=0
FINAL_HASH_WRITTEN=0

fail() {
  echo "release failed: $*" >&2
  exit 1
}

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_executable() {
  [[ -x "$1" ]] || fail "required executable is unavailable: $1"
}

require_sha256() {
  local target="$1"
  local expected="$2"
  local label="$3"
  [[ -f "$target" ]] || fail "$label is missing: $target"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$target")"
  actual="${actual%% *}"
  [[ "$actual" == "$expected" ]] \
    || fail "$label SHA-256 mismatch (expected $expected, got $actual)"
}

require_exact_directory_files() {
  local directory="$1"
  local label="$2"
  shift 2
  if ! "$AUDIT_PYTHON" - "$directory" "$@" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = set(sys.argv[2:])
if not root.is_dir():
    raise SystemExit(f"missing directory: {root}")
entries = list(root.iterdir())
actual = {entry.name for entry in entries}
if actual != expected:
    raise SystemExit(f"expected {sorted(expected)}, got {sorted(actual)}")
for entry in entries:
    if entry.is_symlink() or not entry.is_file():
        raise SystemExit(f"not a regular file: {entry.name}")
PY
  then
    fail "$label does not match its exact file allowlist"
  fi
}

for executable in \
  /usr/bin/basename /usr/bin/codesign /usr/bin/ditto /usr/bin/hdiutil /usr/bin/mktemp \
  /usr/bin/lipo /usr/bin/otool /usr/bin/plutil /usr/bin/security /usr/bin/shasum \
  /usr/bin/syspolicy_check /usr/bin/xcrun /usr/sbin/spctl \
  "$AUDIT_PYTHON" "$BUILDER"; do
  require_executable "$executable"
done
[[ -n "$UVX_BIN" && -x "$UVX_BIN" ]] || fail 'uvx is required for pip-audit'

[[ "$DIST_DIR" == "$PROJECT_ROOT/dist-electron" ]] \
  || fail 'refusing to clean an unexpected output directory'

cd "$PROJECT_ROOT"

# OAuth client IDs are public, but they still identify the application. This
# compatibility release deliberately carries the exact identity and scopes
# audited from xAI's official Grok Build source. Fail closed on drift or any
# environment/config override, and never claim OpenClam itself is Grok Build.
if ! "$AUDIT_PYTHON" - "$PROJECT_ROOT/server/xai_oauth.py" <<'PY'
import ast
import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
tree = ast.parse(source, filename=str(source_path))
expected = {
    "GROK_BUILD_COMPAT_CLIENT_ID": "b1a00492-073a-47ea-816f-4c329264a828",
    "GROK_BUILD_COMPAT_SOURCE_REVISION": (
        "eb267feff13129e568df38fb6fdf0ceb65f735d6"
    ),
    "SCOPES": (
        "openid",
        "profile",
        "email",
        "offline_access",
        "grok-cli:access",
        "api:access",
        "conversations:read",
        "conversations:write",
        "workspaces:read",
        "workspaces:write",
    ),
}
actual = {}
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    for target in node.targets:
        if isinstance(target, ast.Name) and target.id in expected:
            actual[target.id] = ast.literal_eval(node.value)
for name, wanted in expected.items():
    if actual.get(name) != wanted:
        raise SystemExit(f"audited Grok Build compatibility {name} drifted")
for forbidden in (
    "OPENCLAM_XAI_OAUTH_CLIENT_ID",
    "GROK_OAUTH2_CLIENT_ID",
    "os.getenv(",
    "os.environ",
):
    if forbidden in source:
        raise SystemExit("environment-supplied OAuth identity is prohibited")
if '"referrer": "grok-build"' in source:
    raise SystemExit("OpenClam must not identify its requests as Grok Build")
PY
then
  fail 'xAI Grok Build compatibility identity audit failed'
fi
XAI_OAUTH_CLIENT_VERIFIED=1

# Prove that the exact release identity and named notarytool Keychain profile
# exist before spending time staging or building. Nothing reads or prints the
# credential value.
IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)" \
  || fail 'could not inspect code-signing identities'
case "$IDENTITIES" in
  *\"$SIGN_IDENTITY\"*) ;;
  *) fail "missing exact signing identity: $SIGN_IDENTITY" ;;
esac
unset IDENTITIES

if ! /usr/bin/xcrun notarytool history \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >"$WORK_DIR/notary-profile.json"; then
  fail "Keychain profile $NOTARY_PROFILE is missing or cannot authenticate"
fi
if ! "$AUDIT_PYTHON" - "$WORK_DIR/notary-profile.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, dict):
    raise SystemExit("notarytool history response must be a JSON object")
PY
then
  fail 'notarytool profile check returned invalid JSON'
fi
PROFILE_VERIFIED=1

verify_signature_identity() {
  local target="$1"
  local label="$2"
  local report="$WORK_DIR/codesign-${label}.txt"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
  /usr/bin/codesign -d --verbose=4 "$target" 2>"$report"
  local details
  details="$(<"$report")"
  case "$details" in
    *"Authority=$SIGN_IDENTITY"*) ;;
    *) fail "$label is not signed by the required Developer ID identity" ;;
  esac
  case "$details" in
    *"TeamIdentifier=$TEAM_ID"*) ;;
    *) fail "$label has the wrong signing team" ;;
  esac
  case "$details" in
    *"Timestamp=none"*) fail "$label has no secure signing timestamp" ;;
    *"Timestamp="*) ;;
    *) fail "$label has no secure signing timestamp" ;;
  esac
}

verify_syspolicy() {
  local mode="$1"
  local target="$2"
  local label="$3"
  local report="$WORK_DIR/syspolicy-${label}.txt"
  local result=0

  /usr/bin/syspolicy_check "$mode" "$target" --verbose >"$report" 2>&1 \
    || result=$?
  if [[ "$result" -eq 0 ]]; then
    return 0
  fi

  # macOS 26 exits 70 when the only structured findings are warnings about
  # native Python extension modules below Contents/Resources.  Those warnings
  # must not masquerade as either a clean preflight or a release acceptance:
  # allow only an all-Warning report here, then still require actual Apple
  # notarization, stapling, and Gatekeeper assessment below.
  if ! "$AUDIT_PYTHON" - "$report" "$mode" <<'PY'
import pathlib
import re
import sys

report = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
severities = re.findall(r"^\s*Severity:\s*([^\s]+)\s*$", report, flags=re.MULTILINE)
if not severities:
    raise SystemExit(f"syspolicy_check {sys.argv[2]} failed without structured findings")
unexpected = sorted({value for value in severities if value != "Warning"})
if unexpected:
    raise SystemExit(
        f"syspolicy_check {sys.argv[2]} reported non-warning severities: {unexpected}"
    )
print(
    f"syspolicy_check {sys.argv[2]} returned warning-only findings "
    f"({len(severities)}); Apple acceptance remains mandatory"
)
PY
  then
    fail "syspolicy_check $mode rejected $label"
  fi
}

verify_bundle_metadata() {
  local app_path="$1"
  local expected_version="$2"
  local label="$3"
  local info="$app_path/Contents/Info.plist"
  [[ -f "$info" ]] || fail "$label has no Info.plist"
  local identifier version
  identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null)" \
    || fail "$label has no CFBundleIdentifier"
  version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info" 2>/dev/null)" \
    || fail "$label has no CFBundleShortVersionString"
  [[ "$identifier" == "$APP_ID" ]] \
    || fail "$label has the wrong bundle identifier: $identifier"
  [[ "$version" == "$expected_version" ]] \
    || fail "$label has the wrong bundle version: $version"
}

submit_and_require_accepted() {
  local artifact="$1"
  local label="$2"
  local result="$WORK_DIR/notary-${label}.json"
  if ! /usr/bin/xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json >"$result"; then
    fail "Apple notarization submission failed for $label"
  fi
  local status
  status="$("$AUDIT_PYTHON" - "$result" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
status = payload.get("status") if isinstance(payload, dict) else None
if not isinstance(status, str) or not status:
    raise SystemExit("notarytool response has no string status")
print(status)
PY
  )" || fail "Apple notarization returned no status for $label"
  [[ "$status" == 'Accepted' ]] \
    || fail "Apple notarization did not accept $label (status: $status)"
}

verify_distributable_app() {
  local app_path="$1"
  local label="$2"
  verify_bundle_metadata "$app_path" "$PACKAGE_VERSION" "$label"
  verify_signature_identity "$app_path" "$label"
  /usr/bin/xcrun stapler validate -v "$app_path"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app_path"
  # syspolicy_check distribution is routed through the warning-only validator.
  verify_syspolicy distribution "$app_path" "$label-distribution"
}

# A release command must be self-contained: it cannot rely on the operator
# remembering to run the regression, privacy, or dependency gates separately.
npm run check
# check:avatar intentionally remains a local diagnostic for a user's private
# active portrait. Release QA uses deterministic avatar/unit tests plus the
# staged and packaged runtime probes below, so no private avatar is required.
npm run check:privacy
npm audit
npm audit --omit=dev
SOURCE_CHECKS_VERIFIED=1

# Stage everything first, then validate every staged Mach-O before invoking
# the pinned local builder.
npm run stage:livekit
node qa/third_party_licenses_qa.js
SOURCE_LICENSES_VERIFIED=1

ICON_PNG_SHA='d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f'
ICON_ICNS_SHA='5bec8b8a81778d5713864c32044eb163613d22c91a5eb56f1aa8bb16fecebd3c'
RINGTONE_SHA='471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4'
LIVEKIT_CLIENT_SHA='a77a2f4c363e93099d7c135721c9ec81d6c5bacc691796dad799222e33cbfb31'
LIVEKIT_TUPLES_SHA='ea285d07a250275c543a02647227f0dbf1890d099f245c0b90fac0d4515b8daf'

require_sha256 assets/openclam-app-icon.png "$ICON_PNG_SHA" 'canonical iOS icon'
require_sha256 assets/icon.png "$ICON_PNG_SHA" 'Electron icon PNG'
require_sha256 assets/icon.icns "$ICON_ICNS_SHA" 'Electron icon ICNS'
require_sha256 assets/live-talk-connection.wav "$RINGTONE_SHA" 'premium ringtone source'
require_sha256 web/vendor/live-talk-connection.wav "$RINGTONE_SHA" 'staged premium ringtone'
require_sha256 node_modules/livekit-client/dist/livekit-client.umd.js \
  "$LIVEKIT_CLIENT_SHA" 'pinned LiveKit client source'
require_sha256 web/vendor/livekit-client.umd.js \
  "$LIVEKIT_CLIENT_SHA" 'staged LiveKit client'
require_sha256 contracts/live-talk-approved-tuples-v1.json \
  "$LIVEKIT_TUPLES_SHA" 'approved LiveKit tuple contract'
SOURCE_ASSETS_VERIFIED=1

npm run fetch:model

FACE_MODEL_SHA='64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff'
FACE_LICENSE_SHA='8707eef0533987efc5b155d64761eeb6e20793f50b9bd1a68dad1cf4719d0ed8'
WHISPER_CONFIG_SHA='d414b27f911c1c416a90525a0f856e0dc1c9e38632a833ca8dd05c58b3d8a01a'
WHISPER_WEIGHTS_SHA='ca6659298fe7550468ff0fc49dea7442615d9a53d1ce087aaded1b7627451998'
WHISPER_LICENSE_SHA='b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d'
WHISPER_MANIFEST_SHA='fe8fcd4669ddde49085cbfda28f207ec715000ff37c8fa51197ab63fdef91e83'
WHISPER_STAGE='.electron-models/whisper-small-mlx-4bit'
require_sha256 .electron-models/face_landmarker.task "$FACE_MODEL_SHA" \
  'staged MediaPipe face model'
require_sha256 .electron-models/LICENSE.Apache-2.0.txt "$FACE_LICENSE_SHA" \
  'staged MediaPipe license'
require_sha256 "$WHISPER_STAGE/config.json" "$WHISPER_CONFIG_SHA" \
  'staged Whisper config'
require_sha256 "$WHISPER_STAGE/weights.npz" "$WHISPER_WEIGHTS_SHA" \
  'staged Whisper weights'
require_sha256 "$WHISPER_STAGE/LICENSE.openai-whisper-MIT.txt" "$WHISPER_LICENSE_SHA" \
  'staged Whisper license'
require_sha256 "$WHISPER_STAGE/openclam-model-manifest.json" "$WHISPER_MANIFEST_SHA" \
  'staged Whisper manifest'

npm run build:native
npm run stage:backend

require_exact_directory_files "$PROJECT_ROOT/.electron-ffmpeg" \
  'staged FFmpeg directory' ffmpeg LICENSE.LGPLv2.1.txt

"$AUDIT_PYTHON" scripts/audit-macos-deployment-targets.py \
  .electron-python-runtime .electron-site-packages .electron-ffmpeg .electron-native \
  --max 14.0

FFMPEG_PATH="$PROJECT_ROOT/.electron-ffmpeg/ffmpeg"
CUTOUT_PATH="$PROJECT_ROOT/.electron-native/person-cutout"
NATIVE_PATH_AUDIT="$PROJECT_ROOT/scripts/audit-native-build-paths.py"
FFMPEG_LICENSE_SHA='246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30'
require_sha256 "$PROJECT_ROOT/.electron-ffmpeg/LICENSE.LGPLv2.1.txt" \
  "$FFMPEG_LICENSE_SHA" 'staged FFmpeg LGPL license'
for binary in "$FFMPEG_PATH" "$CUTOUT_PATH"; do
  [[ -x "$binary" ]] || fail "staged executable is missing: $binary"
  [[ "$(/usr/bin/lipo -archs "$binary")" == 'arm64' ]] \
    || fail "staged executable is not arm64-only: $binary"
done

"$AUDIT_PYTHON" "$NATIVE_PATH_AUDIT" \
  "$FFMPEG_PATH" "$PROJECT_ROOT/.electron-site-packages/cv2" \
  "$PROJECT_ROOT/.electron-native"
STAGED_NATIVE_PATHS_VERIFIED=1

FFMPEG_DEPENDENCIES="$(/usr/bin/otool -L "$FFMPEG_PATH")"
while IFS= read -r dependency_line; do
  [[ "$dependency_line" == "$FFMPEG_PATH:" ]] && continue
  dependency="${dependency_line#"${dependency_line%%[![:space:]]*}"}"
  dependency="${dependency%% *}"
  [[ -z "$dependency" ]] && continue
  case "$dependency" in
    /usr/lib/*|/System/Library/*) ;;
    *) fail "staged FFmpeg has a non-system dependency: $dependency" ;;
  esac
done <<< "$FFMPEG_DEPENDENCIES"
unset FFMPEG_DEPENDENCIES

FFMPEG_CONFIGURATION="$("$FFMPEG_PATH" -buildconf 2>&1)"
for required_option in \
  '--arch=arm64' '--disable-autodetect' '--disable-network' \
  '--disable-everything' '--enable-videotoolbox'; do
  case "$FFMPEG_CONFIGURATION" in
    *"$required_option"*) ;;
    *) fail "staged FFmpeg is missing required build option: $required_option" ;;
  esac
done
case "$FFMPEG_CONFIGURATION" in
  *'--enable-gpl'*|*'--enable-nonfree'*)
    fail 'staged FFmpeg enables a prohibited GPL/nonfree build mode' ;;
esac
unset FFMPEG_CONFIGURATION

FFMPEG_LICENSE="$("$FFMPEG_PATH" -L 2>&1)"
case "$FFMPEG_LICENSE" in
  *'GNU Lesser General Public'*) ;;
  *) fail 'staged FFmpeg does not report the expected LGPL license' ;;
esac
case "$FFMPEG_LICENSE" in
  *'GNU General Public License'*) fail 'staged FFmpeg reports GPL mode' ;;
esac
unset FFMPEG_LICENSE

require_ffmpeg_component() {
  local listing="$1"
  local component="$2"
  local kind="$3"
  case "$listing" in
    *" $component "*) ;;
    *) fail "staged FFmpeg is missing required $kind: $component" ;;
  esac
}

FFMPEG_ENCODERS="$("$FFMPEG_PATH" -hide_banner -encoders 2>/dev/null)"
for component in h264_videotoolbox pcm_s16le; do
  require_ffmpeg_component "$FFMPEG_ENCODERS" "$component" 'encoder'
done
unset FFMPEG_ENCODERS

FFMPEG_DEMUXERS="$("$FFMPEG_PATH" -hide_banner -demuxers 2>/dev/null)"
for component in aiff flac image2 matroska,webm mov,mp4,m4a,3gp,3g2,mj2 mp3 ogg wav; do
  require_ffmpeg_component "$FFMPEG_DEMUXERS" "$component" 'demuxer'
done
unset FFMPEG_DEMUXERS

FFMPEG_DECODERS="$("$FFMPEG_PATH" -hide_banner -decoders 2>/dev/null)"
for component in \
  aac alac flac mjpeg mp3 opus pcm_f32be pcm_f32le pcm_f64be pcm_f64le \
  pcm_s8 pcm_s16be pcm_s16le pcm_s24be pcm_s24le pcm_s32be pcm_s32le \
  pcm_u8 png vorbis; do
  require_ffmpeg_component "$FFMPEG_DECODERS" "$component" 'decoder'
done
unset FFMPEG_DECODERS

FFMPEG_MUXERS="$("$FFMPEG_PATH" -hide_banner -muxers 2>/dev/null)"
for component in mp4 s16le wav; do
  require_ffmpeg_component "$FFMPEG_MUXERS" "$component" 'muxer'
done
unset FFMPEG_MUXERS
NATIVE_ARTIFACTS_VERIFIED=1

"$AUDIT_PYTHON" qa/staged_runtime_qa.py "$PROJECT_ROOT"
STAGED_RUNTIME_VERIFIED=1
"$UVX_BIN" --from pip-audit==2.10.1 pip-audit \
  --path "$PROJECT_ROOT/.electron-site-packages" \
  --strict --progress-spinner off
PYTHON_DEPENDENCIES_AUDITED=1

/bin/rm -rf -- "$DIST_DIR"
"$BUILDER" --mac dir --arm64 --publish never

shopt -s nullglob
APP_CANDIDATES=("$DIST_DIR"/mac*/"$PRODUCT_NAME.app")
[[ "${#APP_CANDIDATES[@]}" -eq 1 ]] \
  || fail "expected exactly one signed $PRODUCT_NAME.app"
APP_PATH="${APP_CANDIDATES[0]}"
APP_BUILT=1
verify_bundle_metadata "$APP_PATH" "$PACKAGE_VERSION" 'built-app'

APP_RESOURCES="$APP_PATH/Contents/Resources"
require_exact_directory_files "$APP_RESOURCES/backend/bin" \
  'packaged FFmpeg directory' ffmpeg LICENSE.LGPLv2.1.txt
require_sha256 "$APP_RESOURCES/backend/bin/LICENSE.LGPLv2.1.txt" \
  "$FFMPEG_LICENSE_SHA" 'packaged FFmpeg LGPL license'
BUNDLE_ICON_NAME="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - \
  "$APP_PATH/Contents/Info.plist")"
case "$BUNDLE_ICON_NAME" in
  *.icns) ;;
  *) BUNDLE_ICON_NAME="$BUNDLE_ICON_NAME.icns" ;;
esac
require_sha256 "$APP_RESOURCES/$BUNDLE_ICON_NAME" "$ICON_ICNS_SHA" \
  'packaged application icon'
require_sha256 "$APP_RESOURCES/backend/web/vendor/live-talk-connection.wav" \
  "$RINGTONE_SHA" 'packaged premium ringtone'
require_sha256 "$APP_RESOURCES/backend/web/vendor/livekit-client.umd.js" \
  "$LIVEKIT_CLIENT_SHA" 'packaged LiveKit client'
require_sha256 "$APP_RESOURCES/backend/contracts/live-talk-approved-tuples-v1.json" \
  "$LIVEKIT_TUPLES_SHA" 'packaged LiveKit tuple contract'
require_sha256 "$APP_RESOURCES/backend/models/face_landmarker.task" \
  "$FACE_MODEL_SHA" 'packaged MediaPipe face model'
require_sha256 "$APP_RESOURCES/backend/models/LICENSE.Apache-2.0.txt" \
  "$FACE_LICENSE_SHA" 'packaged MediaPipe license'
PACKAGED_WHISPER="$APP_RESOURCES/backend/models/whisper-small-mlx-4bit"
require_sha256 "$PACKAGED_WHISPER/config.json" "$WHISPER_CONFIG_SHA" \
  'packaged Whisper config'
require_sha256 "$PACKAGED_WHISPER/weights.npz" "$WHISPER_WEIGHTS_SHA" \
  'packaged Whisper weights'
require_sha256 "$PACKAGED_WHISPER/LICENSE.openai-whisper-MIT.txt" \
  "$WHISPER_LICENSE_SHA" 'packaged Whisper license'
require_sha256 "$PACKAGED_WHISPER/openclam-model-manifest.json" \
  "$WHISPER_MANIFEST_SHA" 'packaged Whisper manifest'
PACKAGED_ASSETS_VERIFIED=1

"$AUDIT_PYTHON" "$NATIVE_PATH_AUDIT" \
  "$APP_RESOURCES/backend/bin/ffmpeg" \
  "$APP_RESOURCES/python/lib/python3.12/site-packages/cv2" \
  "$APP_RESOURCES/native"
PACKAGED_NATIVE_PATHS_VERIFIED=1

node qa/third_party_licenses_qa.js "$APP_PATH"
PACKAGED_LICENSES_VERIFIED=1

"$AUDIT_PYTHON" qa/packaged_runtime_qa.py "$APP_PATH"
PACKAGED_RUNTIME_VERIFIED=1

verify_signature_identity "$APP_PATH" 'app-before-notarization'
# syspolicy_check notary-submission is routed through the warning-only validator.
verify_syspolicy notary-submission "$APP_PATH" 'app-notary-submission'
APP_SIGNED=1

APP_ZIP="$WORK_DIR/OpenClam-Studio-app.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
submit_and_require_accepted "$APP_ZIP" 'app'
APP_NOTARIZED=1

/usr/bin/xcrun stapler staple -v "$APP_PATH"
/usr/bin/xcrun stapler validate -v "$APP_PATH"
APP_STAPLED=1
verify_distributable_app "$APP_PATH" 'app-after-staple'

# Build the final disk image from the already-notarized, stapled app. The DMG
# itself is then independently timestamp-signed and notarized.
"$BUILDER" --mac dmg --arm64 --publish never --prepackaged "$APP_PATH"
EXPECTED_DMG_NAME="OpenClam-Studio-${PACKAGE_VERSION}-arm64.dmg"
EXPECTED_DMG_PATH="$DIST_DIR/$EXPECTED_DMG_NAME"
DMG_CANDIDATES=("$DIST_DIR"/*.dmg)
[[ "${#DMG_CANDIDATES[@]}" -eq 1 && "${DMG_CANDIDATES[0]}" == "$EXPECTED_DMG_PATH" ]] \
  || fail "expected exactly the release DMG $EXPECTED_DMG_NAME"
[[ -f "$EXPECTED_DMG_PATH" ]] || fail "expected release DMG is missing: $EXPECTED_DMG_NAME"
DMG_PATH="$EXPECTED_DMG_PATH"
DMG_BUILT=1

/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
verify_signature_identity "$DMG_PATH" 'dmg-before-notarization'
DMG_SIGNED=1
/usr/bin/hdiutil verify "$DMG_PATH"

submit_and_require_accepted "$DMG_PATH" 'dmg'
DMG_NOTARIZED=1
/usr/bin/xcrun stapler staple -v "$DMG_PATH"
/usr/bin/xcrun stapler validate -v "$DMG_PATH"
DMG_STAPLED=1

# Gatekeeper checks both the signed outer image and the exact app users will
# receive when it is mounted. hdiutil verification also catches UDIF damage.
verify_signature_identity "$DMG_PATH" 'dmg-after-staple'
/usr/bin/hdiutil verify "$DMG_PATH"
/usr/sbin/spctl --assess --type open \
  --context context:primary-signature --verbose=4 "$DMG_PATH"
DMG_VERIFIED=1

/bin/mkdir -p "$MOUNT_DIR"
/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly \
  -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=1
MOUNTED_APP="$MOUNT_DIR/$PRODUCT_NAME.app"
MOUNTED_APP_CANDIDATES=("$MOUNT_DIR"/*.app)
[[ "${#MOUNTED_APP_CANDIDATES[@]}" -eq 1 \
  && "${MOUNTED_APP_CANDIDATES[0]}" == "$MOUNTED_APP" \
  && -d "$MOUNTED_APP" ]] \
  || fail "mounted DMG does not contain exactly $PRODUCT_NAME.app"
verify_distributable_app "$MOUNTED_APP" 'mounted-app'
MOUNTED_APP_VERIFIED=1
/usr/bin/hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

# This checksum is deliberately last: stapling mutates the DMG, so any earlier
# checksum would not identify the artifact published to GitHub.
FINAL_HASH="$(/usr/bin/shasum -a 256 "$DMG_PATH")"
FINAL_HASH="${FINAL_HASH%% *}"
[[ "$FINAL_HASH" =~ ^[0-9a-f]{64}$ ]] || fail 'could not compute final DMG SHA-256'
/usr/bin/printf '%s  %s\n' "$FINAL_HASH" "$(/usr/bin/basename "$DMG_PATH")" \
  >"$DMG_PATH.sha256"
FINAL_HASH_WRITTEN=1

for gate in \
  PROFILE_VERIFIED XAI_OAUTH_CLIENT_VERIFIED SOURCE_CHECKS_VERIFIED \
  NATIVE_ARTIFACTS_VERIFIED STAGED_NATIVE_PATHS_VERIFIED PACKAGED_NATIVE_PATHS_VERIFIED \
  SOURCE_ASSETS_VERIFIED PACKAGED_ASSETS_VERIFIED \
  SOURCE_LICENSES_VERIFIED PACKAGED_LICENSES_VERIFIED \
  PYTHON_DEPENDENCIES_AUDITED STAGED_RUNTIME_VERIFIED PACKAGED_RUNTIME_VERIFIED \
  APP_BUILT APP_SIGNED APP_NOTARIZED APP_STAPLED \
  DMG_BUILT DMG_SIGNED DMG_NOTARIZED DMG_STAPLED DMG_VERIFIED \
  MOUNTED_APP_VERIFIED FINAL_HASH_WRITTEN; do
  [[ "${!gate}" -eq 1 ]] || fail "mandatory release gate was skipped: $gate"
done

echo "release complete: $DMG_PATH"
echo "SHA-256: $FINAL_HASH"
