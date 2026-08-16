#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="7.1.5"
EXPECTED="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
URL="https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
CACHE="${OPENCLAM_BUILD_CACHE:-$HOME/Library/Caches/openclam-studio-build}"
SOURCE="$CACHE/ffmpeg-$VERSION.tar.xz"
OUTPUT_DIRECTORY="${1:-$ROOT/dist-source}"
OUTPUT="$OUTPUT_DIRECTORY/OpenClam-Studio-FFmpeg-$VERSION-Source.tar.xz"
CHECKSUM="$OUTPUT.sha256"

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "$CACHE" "$OUTPUT_DIRECTORY"
if [[ ! -f "$SOURCE" || "$(checksum "$SOURCE")" != "$EXPECTED" ]]; then
  TEMP="$(mktemp "${TMPDIR:-/tmp}/openclam-ffmpeg-source.XXXXXX")"
  trap 'rm -f "$TEMP"' EXIT
  curl --fail --location --silent --show-error "$URL" --output "$TEMP"
  ACTUAL="$(checksum "$TEMP")"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "FFmpeg source checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
  fi
  mv "$TEMP" "$SOURCE"
  trap - EXIT
fi

ditto "$SOURCE" "$OUTPUT"
ACTUAL="$(checksum "$OUTPUT")"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Prepared FFmpeg source asset checksum mismatch" >&2
  exit 1
fi
printf '%s  %s\n' "$ACTUAL" "$(basename "$OUTPUT")" > "$CHECKSUM"
printf 'Prepared %s\nPrepared %s\n' "$OUTPUT" "$CHECKSUM"
