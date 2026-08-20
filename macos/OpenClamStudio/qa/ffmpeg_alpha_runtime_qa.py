#!/usr/bin/env python3
"""Prove a staged/package-local FFmpeg pair can create and inspect HEVC alpha."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def _run(command: list[str], label: str, timeout: int = 30) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"{label} could not run") from error
    if result.returncode:
        detail = (result.stderr or result.stdout or "command failed")[-2000:]
        raise RuntimeError(f"{label} failed: {detail}")
    return result


def _rgba_frames(width: int, height: int, count: int) -> bytes:
    output = bytearray()
    for frame in range(count):
        for y in range(height):
            for x in range(width):
                alpha = max(0, min(255, x * 4 + frame * 12))
                output.extend((235, 24 + y * 2, 72 + frame * 24, alpha))
    return bytes(output)


def verify_alpha_runtime(ffmpeg: Path, ffprobe: Path, label: str) -> None:
    for executable in (ffmpeg, ffprobe):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeError(f"{label} is missing {executable.name}")

    encoders = _run(
        [str(ffmpeg), "-hide_banner", "-encoders"], f"{label} encoder inventory"
    ).stdout
    decoders = _run(
        [str(ffmpeg), "-hide_banner", "-decoders"], f"{label} decoder inventory"
    ).stdout
    filters = _run(
        [str(ffmpeg), "-hide_banner", "-bsfs"], f"{label} bitstream-filter inventory"
    ).stdout
    if " hevc_videotoolbox " not in encoders:
        raise RuntimeError(f"{label} lacks the HEVC VideoToolbox encoder")
    for decoder in ("hevc", "prores", "rawvideo"):
        if f" {decoder} " not in decoders:
            raise RuntimeError(f"{label} lacks the {decoder} decoder")
    if "\ntrace_headers\n" not in f"\n{filters.strip()}\n":
        raise RuntimeError(f"{label} lacks the HEVC-alpha inspection filter")

    with tempfile.TemporaryDirectory(prefix="openclam-hevc-alpha-qa-") as temporary:
        root = Path(temporary)
        source = root / "procedural.rgba"
        movie = root / "procedural-alpha.mov"
        source.write_bytes(_rgba_frames(64, 64, 3))
        _run(
            [
                str(ffmpeg), "-y", "-v", "error", "-f", "rawvideo",
                "-pixel_format", "rgba", "-video_size", "64x64",
                "-framerate", "4", "-i", str(source),
                "-c:v", "hevc_videotoolbox", "-allow_sw", "1",
                "-alpha_quality", "0.95", "-q:v", "85", "-tag:v", "hvc1",
                "-pix_fmt", "bgra", "-an", str(movie),
            ],
            f"{label} provider-free HEVC-alpha encode",
        )
        size = movie.stat().st_size
        with movie.open("rb") as handle:
            header = handle.read(12)
        if not 1 <= size <= 16 * 1024 * 1024 \
                or header[4:8] != b"ftyp" or header[8:12] != b"qt  ":
            raise RuntimeError(f"{label} produced an invalid QuickTime movie")

        probe = _run(
            [
                str(ffprobe), "-v", "error", "-show_entries",
                "format=format_name,duration:"
                "stream=codec_type,codec_name,codec_tag_string,width,height",
                "-of", "json", str(movie),
            ],
            f"{label} ffprobe inspection",
        )
        try:
            metadata = json.loads(probe.stdout)
            streams = metadata["streams"]
            container = metadata["format"]
        except (KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"{label} ffprobe returned invalid JSON") from error
        if len(streams) != 1 or streams[0] != {
                "codec_name": "hevc", "codec_type": "video",
                "codec_tag_string": "hvc1", "width": 64, "height": 64}:
            raise RuntimeError(f"{label} encoded the wrong HEVC track shape")
        if "mov" not in str(container.get("format_name") or "").split(",") \
                or abs(float(container.get("duration") or 0) - 0.75) > 0.05:
            raise RuntimeError(f"{label} encoded the wrong MOV duration")

        trace = _run(
            [
                str(ffmpeg), "-hide_banner", "-loglevel", "trace", "-i", str(movie),
                "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "trace_headers",
                "-frames:v", "1", "-f", "null", "-",
            ],
            f"{label} alpha-layer inspection",
        )
        traced = trace.stdout + trace.stderr
        has_layer = re.search(
            r"nuh_layer_id:\s*1|nuh_layer_id\s+0*1\s*=\s*1", traced
        )
        enabled = re.search(r"alpha_channel_cancel_flag\s+0\s*=\s*0", traced)
        if "Alpha Channel Information" not in traced or not has_layer or not enabled:
            raise RuntimeError(f"{label} HEVC movie has no enabled alpha layer")

    print(f"{label} provider-free HEVC-alpha runtime QA passed")


if __name__ == "__main__":
    if len(os.sys.argv) != 2:
        raise SystemExit("usage: ffmpeg_alpha_runtime_qa.py /path/to/bin")
    directory = Path(os.sys.argv[1]).resolve()
    verify_alpha_runtime(directory / "ffmpeg", directory / "ffprobe", "FFmpeg")
