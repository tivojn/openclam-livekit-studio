#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.electron-python-runtime/bin/python"
SITE_PACKAGES="${1:-$ROOT/.electron-site-packages}"
VERSION="4.12.0"
EXPECTED="44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d"
CACHE="${OPENCLAM_BUILD_CACHE:-$HOME/Library/Caches/openclam-studio-build}"
ARCHIVE="$CACHE/opencv-$VERSION.tar.gz"
URL="https://github.com/opencv/opencv/archive/refs/tags/$VERSION.tar.gz"
CANONICAL_BUILD_ROOT="/usr/src/openclam/opencv-$VERSION"
CANONICAL_INSTALL_PREFIX="/opt/openclam/opencv-$VERSION"

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

if [[ "$(uname -m)" != "arm64" ]] || [[ ! -x "$PYTHON" ]] || [[ ! -d "$SITE_PACKAGES/numpy" ]]; then
  echo "OpenCV staging requires the Apple Silicon Python runtime and staged NumPy" >&2
  exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required to build the GPL-free OpenCV runtime" >&2
  exit 1
fi

mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" || "$(checksum "$ARCHIVE")" != "$EXPECTED" ]]; then
  TEMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/openclam-opencv.XXXXXX")"
  trap 'rm -f "$TEMP_ARCHIVE"' EXIT
  curl --fail --location --silent --show-error "$URL" --output "$TEMP_ARCHIVE"
  ACTUAL="$(checksum "$TEMP_ARCHIVE")"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo "OpenCV source checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
    exit 1
  fi
  mv "$TEMP_ARCHIVE" "$ARCHIVE"
  trap - EXIT
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openclam-opencv-build.XXXXXX")"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
tar -xf "$ARCHIVE" -C "$BUILD_ROOT"
SOURCE="$BUILD_ROOT/opencv-$VERSION"
BUILD="$BUILD_ROOT/build"
DESTDIR="$BUILD_ROOT/stage"
INSTALL="$DESTDIR$CANONICAL_INSTALL_PREFIX"
NUMPY_INCLUDE="$(PYTHONPATH="$SITE_PACKAGES" "$PYTHON" -B -c 'import numpy; print(numpy.get_include())')"
TOOLCHAIN="$BUILD_ROOT/toolchain"
BUILD_ROOT_ALIAS="${BUILD_ROOT#/private}"
PATH_MAP_FLAGS="-ffile-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT -fdebug-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT -fmacro-prefix-map=$BUILD_ROOT=$CANONICAL_BUILD_ROOT"
if [[ "$BUILD_ROOT_ALIAS" != "$BUILD_ROOT" ]]; then
  PATH_MAP_FLAGS="$PATH_MAP_FLAGS -ffile-prefix-map=$BUILD_ROOT_ALIAS=$CANONICAL_BUILD_ROOT -fdebug-prefix-map=$BUILD_ROOT_ALIAS=$CANONICAL_BUILD_ROOT -fmacro-prefix-map=$BUILD_ROOT_ALIAS=$CANONICAL_BUILD_ROOT"
fi
"$PYTHON" "$ROOT/scripts/sanitize-opencv-source-build-paths.py" "$SOURCE"
mkdir -p "$TOOLCHAIN"
ln -s "$PYTHON" "$TOOLCHAIN/python"
ln -s "$ROOT/.electron-python-runtime/include/python3.12" "$TOOLCHAIN/python-include"
ln -s "$ROOT/.electron-python-runtime/lib/libpython3.12.dylib" \
  "$TOOLCHAIN/libpython3.12.dylib"
ln -s "$NUMPY_INCLUDE" "$TOOLCHAIN/numpy-include"

if ! PYTHONPATH="$SITE_PACKAGES" cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$CANONICAL_INSTALL_PREFIX" \
    -DCMAKE_C_FLAGS="$PATH_MAP_FLAGS" \
    -DCMAKE_CXX_FLAGS="$PATH_MAP_FLAGS" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_SKIP_RPATH=ON \
    -DBUILD_LIST=core,imgproc,imgcodecs,video,videoio,photo,calib3d,features2d,python3 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_PERF_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_opencv_apps=OFF \
    -DBUILD_opencv_java=OFF \
    -DBUILD_opencv_js=OFF \
    -DBUILD_opencv_python2=OFF \
    -DBUILD_opencv_python3=ON \
    -DOPENCV_ENABLE_NONFREE=OFF \
    -DOPENCV_CMAKE_HOOKS_DIR="$ROOT/scripts/opencv-cmake-hooks" \
    -DOPENCV_GENERATE_PKGCONFIG=OFF \
    -DOPENCLAM_NATIVE_BUILD_ROOT="$BUILD_ROOT" \
    -DOPENCLAM_NATIVE_BUILD_ROOT_ALIAS="$BUILD_ROOT_ALIAS" \
    -DOPENCLAM_CANONICAL_BUILD_ROOT="$CANONICAL_BUILD_ROOT" \
    -DBUILD_JPEG=ON \
    -DBUILD_OPENJPEG=ON \
    -DBUILD_PNG=ON \
    -DBUILD_ZLIB=ON \
    -DWITH_AVFOUNDATION=ON \
    -DWITH_EIGEN=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_GSTREAMER=OFF \
    -DWITH_IPP=OFF \
    -DWITH_ITT=OFF \
    -DWITH_JASPER=OFF \
    -DWITH_OPENCL=OFF \
    -DWITH_OPENEXR=OFF \
    -DWITH_OPENGL=OFF \
    -DWITH_OPENNI=OFF \
    -DWITH_OPENNI2=OFF \
    -DWITH_PROTOBUF=OFF \
    -DWITH_QT=OFF \
    -DWITH_TIFF=OFF \
    -DWITH_VTK=OFF \
    -DWITH_WEBP=OFF \
    -DPYTHON3_EXECUTABLE="$TOOLCHAIN/python" \
    -DPYTHON3_INCLUDE_DIR="$TOOLCHAIN/python-include" \
    -DPYTHON3_LIBRARY="$TOOLCHAIN/libpython3.12.dylib" \
    -DPYTHON3_NUMPY_INCLUDE_DIRS="$TOOLCHAIN/numpy-include" \
    -DPYTHON3_PACKAGES_PATH="$CANONICAL_INSTALL_PREFIX/python" \
    >"$BUILD_ROOT/configure.log" 2>&1; then
    grep -B3 -A5 -E 'CMake Error|ERROR:|Failed to download|error:' "$BUILD_ROOT/configure.log" >&2 || \
      tail -80 "$BUILD_ROOT/configure.log" >&2
    exit 1
fi

if [[ ! -f "$BUILD/opencv_data_config.hpp" || ! -f "$BUILD/version_string.tmp" ]]; then
  echo "OpenCV configure did not produce its audited build metadata" >&2
  exit 1
fi
"$PYTHON" "$ROOT/scripts/audit-native-build-paths.py" \
  --reject-prefix "$BUILD_ROOT" \
  "$BUILD/opencv_data_config.hpp" "$BUILD/version_string.tmp"
if ! grep -F \
    "#define OPENCV_BUILD_DIR \"$CANONICAL_BUILD_ROOT/build\"" \
    "$BUILD/opencv_data_config.hpp" >/dev/null; then
  echo "OpenCV generated build-directory literal is not canonical" >&2
  exit 1
fi

cmake --build "$BUILD" --parallel "$(sysctl -n hw.logicalcpu)"
DESTDIR="$DESTDIR" cmake --install "$BUILD"

if [[ ! -f "$INSTALL/python/cv2/__init__.py" ]]; then
  echo "OpenCV Python package was not produced" >&2
  exit 1
fi

"$PYTHON" - "$INSTALL/python/cv2" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
(root / "config.py").write_text(
    "BINARIES_PATHS = [] + BINARIES_PATHS\n", encoding="utf-8"
)
(root / "config-3.12.py").write_text(
    "import os\n"
    "PYTHON_EXTENSIONS_PATHS = [os.path.join(LOADER_DIR, 'python-3.12')] "
    "+ PYTHON_EXTENSIONS_PATHS\n",
    encoding="utf-8",
)
PY
cp "$SOURCE/LICENSE" "$INSTALL/python/cv2/LICENSE.txt"

"$PYTHON" "$ROOT/scripts/audit-native-build-paths.py" \
  --reject-prefix "$BUILD_ROOT" "$INSTALL/python/cv2"

"$PYTHON" - "$SITE_PACKAGES" <<'PY'
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1]).resolve()
if root.name != ".electron-site-packages" or not root.is_dir():
    raise SystemExit(f"refusing to rewrite unexpected site-packages path: {root}")
for path in root.iterdir():
    normalized = path.name.lower().replace("-", "_")
    if path.name == "cv2" or normalized.startswith("opencv_"):
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
PY
ditto "$INSTALL/python/cv2" "$SITE_PACKAGES/cv2"
xattr -cr "$SITE_PACKAGES/cv2" 2>/dev/null || true

"$PYTHON" "$ROOT/scripts/audit-native-build-paths.py" \
  --reject-prefix "$BUILD_ROOT" "$SITE_PACKAGES/cv2"

if find "$SITE_PACKAGES/cv2" -type f \( \
    -name 'libavcodec*' -o -name 'libavformat*' -o -name 'libx264*' \
    -o -name 'libx265*' -o -name 'librubberband*' -o -name 'libvidstab*' \
  \) -print | grep .; then
  echo "refusing to stage OpenCV with bundled GPL-capable codec libraries" >&2
  exit 1
fi

OPENCLAM_NO_RVM=1 PYTHONPATH="$SITE_PACKAGES" "$PYTHON" -B - <<'PY'
import cv2
import numpy as np

image = np.zeros((12, 12, 3), dtype=np.uint8)
gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
assert gray.shape == (12, 12)
assert not hasattr(cv2, "xfeatures2d")
build = cv2.getBuildInformation()
assert not any(
    "FFMPEG:" in line and not line.rstrip().endswith("NO")
    for line in build.splitlines()
), build
assert "AVFoundation:                YES" in build
print(f"staged GPL-free OpenCV {cv2.__version__} without FFmpeg")
PY

CV2_BINARY="$(find "$SITE_PACKAGES/cv2" -type f -name 'cv2*.so' -print -quit)"
if [[ -z "$CV2_BINARY" ]]; then
  echo "staged OpenCV extension is missing" >&2
  exit 1
fi
if otool -L "$CV2_BINARY" | tail -n +2 | grep -Ev \
    '^[[:space:]]+(/usr/lib/|/System/Library/)' | grep .; then
  echo "refusing to stage OpenCV with non-system dynamic dependencies" >&2
  exit 1
fi
if otool -l "$CV2_BINARY" | grep -A2 'cmd LC_RPATH' | grep -E '/opt/homebrew|/usr/local|/Users|/var/folders' >/dev/null; then
  echo "refusing to stage OpenCV with a build-machine runtime path" >&2
  exit 1
fi
"$PYTHON" "$ROOT/scripts/audit-macos-deployment-targets.py" "$SITE_PACKAGES/cv2" --max 14.0
