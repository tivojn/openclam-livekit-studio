#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/models"
STAGE_DIR="$ROOT/.electron-models"
MODEL="$MODEL_DIR/face_landmarker.task"
STAGED="$STAGE_DIR/face_landmarker.task"
URL="https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
EXPECTED="64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
WHISPER_MANIFEST="$ROOT/scripts/whisper-small-mlx-4bit.manifest.json"
WHISPER_REPO="mlx-community/whisper-small-mlx-4bit"
WHISPER_REVISION="f1da4c67f2ee8b6e763b974e149aa65d5b7658b7"
WHISPER_STAGE="$STAGE_DIR/whisper-small-mlx-4bit"
WHISPER_LICENSE_REVISION="e58f28804528831904c3b6f2c0e473f346223433"
WHISPER_LICENSE_NAME="LICENSE.openai-whisper-MIT.txt"

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_whisper_bundle() {
  OPENCLAM_WHISPER_DIR="$1" OPENCLAM_WHISPER_MANIFEST="$WHISPER_MANIFEST" \
    /usr/bin/python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["OPENCLAM_WHISPER_DIR"])
expected_path = Path(os.environ["OPENCLAM_WHISPER_MANIFEST"])
try:
    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    installed = json.loads(
        (root / "openclam-model-manifest.json").read_text(encoding="utf-8")
    )
except (OSError, ValueError):
    raise SystemExit(1)

if expected != installed:
    raise SystemExit(1)
files = expected.get("files")
if expected.get("schema_version") != 1 or set(files or {}) != {
    "config.json", "weights.npz", "LICENSE.openai-whisper-MIT.txt"
}:
    raise SystemExit("invalid checked Whisper manifest")
allowed = set(files) | {"openclam-model-manifest.json"}
entries = list(root.iterdir())
if ({path.name for path in entries} != allowed
        or any(path.is_symlink() or not path.is_file() for path in entries)):
    raise SystemExit(1)
for name, record in files.items():
    path = root / name
    try:
        size = path.stat().st_size
    except OSError:
        raise SystemExit(1)
    if size != record.get("size"):
        raise SystemExit(1)
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != record.get("sha256"):
        raise SystemExit(1)
PY
}

verify_model_stage_layout() {
  OPENCLAM_MODEL_STAGE="$STAGE_DIR" /usr/bin/python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["OPENCLAM_MODEL_STAGE"])
expected = {
    "face_landmarker.task", "LICENSE.Apache-2.0.txt", "whisper-small-mlx-4bit"
}
entries = list(root.iterdir())
if {path.name for path in entries} != expected:
    raise SystemExit("unexpected file or partial directory in .electron-models")
for path in entries:
    if path.is_symlink():
        raise SystemExit("symlinks are not allowed in .electron-models")
    if path.name == "whisper-small-mlx-4bit":
        if not path.is_dir():
            raise SystemExit("offline Whisper stage is not a directory")
    elif not path.is_file():
        raise SystemExit(f"unexpected staged model entry: {path.name}")
PY
}

WHISPER_WORK=""
cleanup_whisper_work() {
  if [[ -z "$WHISPER_WORK" ]]; then
    return
  fi
  local temp_base
  temp_base="${TMPDIR:-/tmp}"
  temp_base="${temp_base%/}"
  case "$WHISPER_WORK" in
    "$temp_base"/openclam-whisper-stage.*)
      rm -rf -- "$WHISPER_WORK"
      ;;
    *)
      echo "refusing to remove unexpected Whisper temp path" >&2
      ;;
  esac
}

stage_whisper_bundle() {
  if verify_whisper_bundle "$WHISPER_STAGE" 2>/dev/null; then
    printf 'Offline Whisper model verified: %s@%s\n' \
      "$WHISPER_REPO" "$WHISPER_REVISION"
    return
  fi

  local work
  local temp_base
  temp_base="${TMPDIR:-/tmp}"
  temp_base="${temp_base%/}"
  work="$(mktemp -d "$temp_base/openclam-whisper-stage.XXXXXX")"
  WHISPER_WORK="$work"
  trap cleanup_whisper_work EXIT
  local name
  for name in config.json weights.npz; do
    curl --fail --location --silent --show-error --retry 3 \
      --proto '=https' --tlsv1.2 \
      "https://huggingface.co/$WHISPER_REPO/resolve/$WHISPER_REVISION/$name?download=true" \
      --output "$work/$name"
  done
  curl --fail --location --silent --show-error --retry 3 \
    --proto '=https' --tlsv1.2 \
    "https://raw.githubusercontent.com/openai/whisper/$WHISPER_LICENSE_REVISION/LICENSE" \
    --output "$work/$WHISPER_LICENSE_NAME"
  cp "$WHISPER_MANIFEST" "$work/openclam-model-manifest.json"
  if ! verify_whisper_bundle "$work"; then
    echo "offline Whisper model failed its checked file manifest" >&2
    exit 1
  fi
  rm -rf "$WHISPER_STAGE"
  mv "$work" "$WHISPER_STAGE"
  WHISPER_WORK=""
  trap - EXIT
  printf 'Offline Whisper model staged: %s@%s\n' \
    "$WHISPER_REPO" "$WHISPER_REVISION"
}

mkdir -p "$MODEL_DIR" "$STAGE_DIR"
if [[ ! -f "$MODEL" || "$(checksum "$MODEL")" != "$EXPECTED" ]]; then
  TEMP="$(mktemp "${TMPDIR:-/tmp}/openclam-face-model.XXXXXX")"
  trap 'rm -f "$TEMP"' EXIT
  curl --fail --location --silent --show-error "$URL" --output "$TEMP"
  ACTUAL="$(checksum "$TEMP")"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "face model checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
  fi
  mv "$TEMP" "$MODEL"
  trap - EXIT
fi
cp "$MODEL" "$STAGED"
LICENSE_SOURCE="$(find "$ROOT/.venv/lib/python3.12/site-packages" -path '*/mediapipe-*.dist-info/licenses/LICENSE' -type f -print -quit 2>/dev/null || true)"
if [[ -n "$LICENSE_SOURCE" ]]; then
  cp "$LICENSE_SOURCE" "$STAGE_DIR/LICENSE.Apache-2.0.txt"
else
  echo "MediaPipe license file is missing; run backend setup before packaging" >&2
  exit 1
fi
stage_whisper_bundle
verify_model_stage_layout
printf 'Face model verified: %s\n' "$EXPECTED"
