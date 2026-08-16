#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "OpenClam Studio requires an Apple-silicon Mac." >&2
  exit 1
fi
if [[ ! -x .venv/bin/python ]]; then
  scripts/setup-electron-backend.sh
fi
if [[ ! -d node_modules/electron ]]; then
  npm ci
fi

exec npm start
