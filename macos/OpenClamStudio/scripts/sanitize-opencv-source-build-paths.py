#!/usr/bin/env python3
"""Make OpenCV's generated build-directory literal deterministic before compile."""

from __future__ import annotations

from pathlib import Path
import sys


UPSTREAM_LITERAL = '#define OPENCV_BUILD_DIR \\"${CMAKE_BINARY_DIR}\\"'
SANITIZED_LITERAL = (
    '#define OPENCV_BUILD_DIR '
    '\\"${OPENCLAM_CANONICAL_BUILD_ROOT}/build\\"'
)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: sanitize-opencv-source-build-paths.py OPENCV_SOURCE")
    source = Path(sys.argv[1]).resolve()
    cmake_file = source / "modules/core/CMakeLists.txt"
    if not cmake_file.is_file():
        raise SystemExit(f"OpenCV core CMake source is missing: {cmake_file}")
    text = cmake_file.read_text(encoding="utf-8")
    upstream_count = text.count(UPSTREAM_LITERAL)
    sanitized_count = text.count(SANITIZED_LITERAL)
    if upstream_count != 1 or sanitized_count != 0:
        raise SystemExit(
            "OpenCV build-directory source literal drifted; refusing to patch "
            f"(upstream={upstream_count}, sanitized={sanitized_count})"
        )
    cmake_file.write_text(
        text.replace(UPSTREAM_LITERAL, SANITIZED_LITERAL),
        encoding="utf-8",
    )
    verified = cmake_file.read_text(encoding="utf-8")
    if verified.count(SANITIZED_LITERAL) != 1 or UPSTREAM_LITERAL in verified:
        raise SystemExit("OpenCV build-directory source sanitization did not verify")
    print("sanitized OpenCV generated build-directory literal before configure")


if __name__ == "__main__":
    main()
