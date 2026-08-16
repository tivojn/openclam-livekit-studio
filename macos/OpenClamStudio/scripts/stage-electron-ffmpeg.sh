#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="7.1.5"
EXPECTED="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
LICENSE_EXPECTED="246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30"
CLEAR_PREFIX="/opt/openclam/ffmpeg-$VERSION"
CACHE="${OPENCLAM_BUILD_CACHE:-$HOME/Library/Caches/openclam-studio-build}"
ARCHIVE="$CACHE/ffmpeg-$VERSION.tar.xz"
URL="https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
OUT_DIR="$ROOT/.electron-ffmpeg"
OUT="$OUT_DIR/ffmpeg"

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_stage_entries() {
  /usr/bin/python3 - "$OUT_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {"ffmpeg", "LICENSE.LGPLv2.1.txt"}
if not root.is_dir():
    raise SystemExit("FFmpeg staging directory is missing")
entries = list(root.iterdir())
actual = {entry.name for entry in entries}
if actual != expected:
    raise SystemExit(
        "FFmpeg staging entries differ from the exact allowlist: "
        f"expected {sorted(expected)}, got {sorted(actual)}"
    )
for entry in entries:
    if entry.is_symlink() or not entry.is_file():
        raise SystemExit(f"FFmpeg staging entry is not a regular file: {entry.name}")
PY
}

verify_ffmpeg() {
  if ! verify_stage_entries; then
    return 1
  fi
  if [[ ! -x "$OUT" || ! -s "$OUT_DIR/LICENSE.LGPLv2.1.txt" ]]; then
    return 1
  fi
  if ! /usr/bin/python3 "$ROOT/scripts/audit-native-build-paths.py" "$OUT"; then
    return 1
  fi
  if [[ "$(checksum "$OUT_DIR/LICENSE.LGPLv2.1.txt")" != "$LICENSE_EXPECTED" ]]; then
    echo "refusing staged FFmpeg with an altered LGPL license" >&2
    return 1
  fi
  if ! /usr/bin/python3 - "$OUT" "$VERSION" <<'PY'
import pathlib
import re
import subprocess
import sys

binary = pathlib.Path(sys.argv[1]).resolve()
version = sys.argv[2]

def output(*arguments: str) -> str:
    result = subprocess.run(
        [str(binary), *arguments], capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise SystemExit(f"FFmpeg {' '.join(arguments)} inspection failed")
    return result.stdout + result.stderr

version_text = output("-version")
if f"ffmpeg version {version}" not in version_text:
    raise SystemExit("unexpected staged FFmpeg version")
configuration = next(
    (line for line in version_text.splitlines() if line.startswith("configuration:")), ""
)
if "--enable-gpl" in configuration or "--enable-nonfree" in configuration:
    raise SystemExit("refusing GPL or nonfree FFmpeg configuration")
license_text = output("-L")
if not re.search(r"GNU\s+Lesser\s+General\s+Public\s+License", license_text):
    raise SystemExit("refusing an FFmpeg binary that is not LGPL")

required = {
    "-decoders": {
        "aac", "alac", "flac", "mjpeg", "mp3", "opus", "pcm_s16le", "png", "vorbis"
    },
    "-encoders": {"h264_videotoolbox", "pcm_s16le"},
    "-demuxers": {"aiff", "flac", "image2", "matroska", "mov", "mp3", "ogg", "wav"},
    "-muxers": {"mp4", "s16le", "wav"},
    "-filters": {"aresample", "format", "scale"},
    "-protocols": {"file"},
}
for command, names in required.items():
    listing = output(command)
    available = set()
    for line in listing.splitlines():
        parts = line.split()
        if command == "-protocols":
            if len(parts) == 1 and parts[0] not in {"Input:", "Output:"}:
                available.add(parts[0])
        elif len(parts) >= 2:
            available.update(parts[1].split(","))
    missing = sorted(names - available)
    if missing:
        raise SystemExit(f"FFmpeg {command} is missing: {', '.join(missing)}")
PY
  then
    return 1
  fi
  if ! /usr/bin/lipo -archs "$OUT" | tr ' ' '\n' | grep -Fx arm64 >/dev/null; then
    echo "refusing staged FFmpeg without an arm64 slice" >&2
    return 1
  fi
  if otool -L "$OUT" | tail -n +2 | grep -Ev \
      '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep .; then
    echo "refusing staged FFmpeg with non-system library dependencies" >&2
    return 1
  fi
  /usr/bin/python3 "$ROOT/scripts/audit-macos-deployment-targets.py" \
    "$OUT_DIR" --max 14.0
}

if verify_ffmpeg; then
  echo "staged LGPL FFmpeg $VERSION already verified"
  exit 0
fi

[[ "$OUT_DIR" == "$ROOT/.electron-ffmpeg" ]] \
  || { echo "refusing to clear an unexpected FFmpeg staging path" >&2; exit 1; }
rm -rf -- "$OUT_DIR"
mkdir -p "$CACHE" "$OUT_DIR"
if [[ ! -f "$ARCHIVE" || "$(checksum "$ARCHIVE")" != "$EXPECTED" ]]; then
  TEMP="$(mktemp "${TMPDIR:-/tmp}/openclam-ffmpeg.XXXXXX")"
  trap 'rm -f "$TEMP"' EXIT
  curl --fail --location --silent --show-error "$URL" --output "$TEMP"
  ACTUAL="$(checksum "$TEMP")"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "FFmpeg source checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
  fi
  mv "$TEMP" "$ARCHIVE"
  trap - EXIT
fi

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/openclam-ffmpeg-build.XXXXXX")"
BUILD="$(cd "$BUILD" && pwd -P)"
trap 'rm -rf "$BUILD"' EXIT
tar -xf "$ARCHIVE" -C "$BUILD"
cd "$BUILD/ffmpeg-$VERSION"

DESTDIR="$BUILD/stage"

./configure \
  --prefix="$CLEAR_PREFIX" \
  --arch=arm64 \
  --cc=/usr/bin/clang \
  --disable-autodetect \
  --disable-debug \
  --disable-doc \
  --disable-network \
  --disable-everything \
  --disable-ffplay \
  --disable-ffprobe \
  --enable-ffmpeg \
  --enable-avcodec \
  --enable-avfilter \
  --enable-avformat \
  --enable-swresample \
  --enable-swscale \
  --enable-videotoolbox \
  --enable-zlib \
  --enable-protocol=file \
  --enable-demuxer=aiff,flac,image2,matroska,mov,mp3,ogg,wav \
  --enable-muxer=mp4,pcm_s16le,wav \
  --enable-decoder=aac,alac,flac,mjpeg,mp3,opus,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_s8,pcm_s16be,pcm_s16le,pcm_s24be,pcm_s24le,pcm_s32be,pcm_s32le,pcm_u8,png,vorbis \
  --enable-encoder=h264_videotoolbox,pcm_s16le \
  --enable-parser=aac,h264,mpegaudio,opus,png,vorbis \
  --enable-filter=aresample,format,scale \
  --extra-cflags=-mmacosx-version-min=12.0 \
  --extra-ldflags=-mmacosx-version-min=12.0

make -j"$(sysctl -n hw.logicalcpu)"
make install DESTDIR="$DESTDIR"
cp "$DESTDIR$CLEAR_PREFIX/bin/ffmpeg" "$OUT"
cp "$BUILD/ffmpeg-$VERSION/COPYING.LGPLv2.1" "$OUT_DIR/LICENSE.LGPLv2.1.txt"
strip -x "$OUT"
chmod 755 "$OUT"
xattr -cr "$OUT" 2>/dev/null || true

/usr/bin/python3 "$ROOT/scripts/audit-native-build-paths.py" \
  --reject-prefix "$BUILD" "$OUT"

if ! verify_ffmpeg; then
  echo "staged FFmpeg failed the release audit" >&2
  exit 1
fi
printf 'Staged minimal LGPL FFmpeg %s (%s)\n' "$VERSION" "$(stat -f '%z bytes' "$OUT")"
