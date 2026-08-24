#!/bin/bash
set -Eeuo pipefail

umask 077

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REPO_ROOT="$(cd "$PROJECT_ROOT/../.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/openclaw-plugin-openclam"
STAGE_ROOT="$PROJECT_ROOT/.electron-openclaw-plugin"
TEMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/openclam-channel-stage.XXXXXX")"
BUILD_ROOT="$TEMP_ROOT/source"

cleanup() {
  /bin/rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

[[ -f "$PLUGIN_ROOT/package.json" ]] || {
  echo 'OpenClaw channel source is unavailable.' >&2
  exit 1
}

for source_path in \
  README.md index.ts openclaw.plugin.json package.json package-lock.json \
  setup-entry.ts tsconfig.json tsconfig.build.json; do
  [[ -f "$PLUGIN_ROOT/$source_path" ]] || {
    echo "OpenClaw channel build input is unavailable: $source_path" >&2
    exit 1
  }
done
[[ -d "$PLUGIN_ROOT/src" ]] || {
  echo 'OpenClaw channel source directory is unavailable.' >&2
  exit 1
}

/bin/mkdir -p "$BUILD_ROOT"
for source_path in \
  README.md index.ts openclaw.plugin.json package.json package-lock.json \
  setup-entry.ts tsconfig.json tsconfig.build.json; do
  /bin/cp -p -- "$PLUGIN_ROOT/$source_path" "$BUILD_ROOT/$source_path"
done
/bin/cp -R -p -- "$PLUGIN_ROOT/src" "$BUILD_ROOT/src"

(
  cd "$BUILD_ROOT"
  npm ci --ignore-scripts --no-audit --no-fund >/dev/null
  npm run build >/dev/null
  npm pack --ignore-scripts --pack-destination "$TEMP_ROOT" >/dev/null
)

ARCHIVE=''
ARCHIVE_COUNT=0
while IFS= read -r candidate; do
  ARCHIVE="$candidate"
  ARCHIVE_COUNT=$((ARCHIVE_COUNT + 1))
done < <(/usr/bin/find "$TEMP_ROOT" -maxdepth 1 -type f -name '*.tgz' -print)
[[ "$ARCHIVE_COUNT" -eq 1 && -n "$ARCHIVE" ]] || {
  echo 'OpenClaw channel packaging did not produce exactly one archive.' >&2
  exit 1
}

ORIGIN="${OPENCLAM_AGENT_CONNECTOR_ORIGIN:-}"
if [[ -z "$ORIGIN" ]]; then
  LOCAL_CONFIG="$REPO_ROOT/ios/OpenClamLiveKit/Config/AgentConnector.local.xcconfig"
  [[ -f "$LOCAL_CONFIG" ]] || {
    echo 'OpenClaw bridge release configuration is unavailable.' >&2
    exit 1
  }
  ORIGIN="$(/usr/bin/awk -F= '
    /^[[:space:]]*OPENCLAM_AGENT_CONNECTOR_ORIGIN[[:space:]]*=/ {
      value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); print value; exit
    }
  ' "$LOCAL_CONFIG")"
fi
/bin/mkdir -p "$STAGE_ROOT"
/bin/cp -f -- "$ARCHIVE" "$STAGE_ROOT/openclam-channel.tgz"
/bin/chmod 600 "$STAGE_ROOT/openclam-channel.tgz"

/usr/bin/python3 - "$ORIGIN" "$STAGE_ROOT/install-config.json" <<'PY'
import json
import os
import pathlib
import sys
from urllib.parse import urlsplit

origin = sys.argv[1].strip().replace("/$()/", "//").rstrip("/")
parsed = urlsplit(origin)
if (
    parsed.scheme != "https"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.path
    or parsed.query
    or parsed.fragment
    or origin != f"https://{parsed.netloc}"
):
    raise SystemExit("OpenClaw bridge origin must be one HTTPS root origin")
target = pathlib.Path(sys.argv[2])
temporary = target.with_suffix(".tmp")
temporary.write_text(
    json.dumps({"v": 1, "bridge_origin": origin}, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY

echo 'Staged the bounded OpenClaw channel installer.'
