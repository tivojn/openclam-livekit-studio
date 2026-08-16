#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UV="${UV:-$(command -v uv || true)}"

MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if [[ "$(uname -m)" != "arm64" ]] || (( MACOS_MAJOR < 14 )); then
  echo "OpenClam Studio requires macOS 14 or newer on Apple silicon." >&2
  exit 1
fi
if [[ -z "$UV" && -x "$HOME/.local/bin/uv" ]]; then
  UV="$HOME/.local/bin/uv"
fi
if [[ -z "$UV" ]]; then
  echo "uv is required. Install it from https://docs.astral.sh/uv/." >&2
  exit 1
fi

PYTHON="${PYTHON:-python3.12}"
cd "$ROOT"
"$UV" venv .venv --python "$PYTHON"
"$UV" pip sync --python .venv/bin/python --require-hashes requirements-backend.lock
"$ROOT/scripts/fetch-face-model.sh"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "warning: ffmpeg is missing; Electron release builds bundle the required LGPL runtime" >&2
fi

.venv/bin/python - <<'PY'
import cv2, fastapi, httpx, mediapipe, numpy, soundfile, uvicorn
import kokoro, mlx_whisper
print("OpenClam Studio backend ready")
PY
