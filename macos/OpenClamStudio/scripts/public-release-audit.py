#!/usr/bin/env python3
"""Fail when private or generated material enters the public source tree."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
DENIED_PARTS = {
    ".electron-python-runtime", ".electron-models", ".electron-ffmpeg", ".learnings", ".venv",
    "avatars", "dist", "dist-electron", "models", "node_modules", "proof",
    "__pycache__",
}
DENIED_NAMES = {
    "active.json", "config.json", ".DS_Store", "backend.log", ".env",
    "id_rsa", "id_ed25519",
}
DENIED_SUFFIXES = {
    ".avtr", ".bak", ".der", ".dmg", ".env", ".gif", ".gz", ".heic",
    ".icns", ".jpeg", ".jpg", ".key", ".log", ".mobileprovision", ".mov",
    ".mp3", ".mp4", ".p12", ".p8", ".pem", ".pfx", ".pkg", ".png",
    ".provisionprofile", ".pyc", ".task", ".tmp", ".wav", ".webm",
    ".webp", ".xz", ".zip",
}
ALLOWED_BINARY = {
    Path("assets/icon.icns"), Path("assets/icon.png"),
    Path("assets/live-talk-connection.wav"),
    Path("assets/openclam-app-icon.png"),
    Path("electron/tray-icon.png"),
    Path("electron/tray-icon@2x.png"),
    Path("electron/tray-icon@3x.png"),
    Path("web/assets/sf-symbols/avatar-layer.png"),
    Path("web/assets/sf-symbols/avatar-picker.png"),
    Path("web/assets/sf-symbols/avatar-window.png"),
    Path("web/assets/sf-symbols/checkmark.png"),
    Path("web/assets/sf-symbols/chevron-down.png"),
    Path("web/assets/sf-symbols/close-up.png"),
    Path("web/assets/sf-symbols/edge-idle.png"),
    Path("web/assets/sf-symbols/face-mirror.png"),
    Path("web/assets/sf-symbols/horizon-walk.png"),
    Path("web/assets/sf-symbols/moves.png"),
    Path("web/assets/sf-symbols/opacity.png"),
    Path("web/assets/sf-symbols/phone-down.png"),
    Path("web/assets/sf-symbols/phone.png"),
    Path("web/assets/sf-symbols/settings.png"),
    Path("web/assets/sf-symbols/speaker-slash.png"),
    Path("web/assets/sf-symbols/standby.png"),
    Path("web/assets/sf-symbols/stop.png"),
    Path("web/assets/sf-symbols/thread-layer.png"),
    Path("web/assets/sf-symbols/waveform.png"),
}
ALLOWED_BINARY_HASHES = {
    Path("assets/icon.icns"): "5bec8b8a81778d5713864c32044eb163613d22c91a5eb56f1aa8bb16fecebd3c",
    Path("assets/icon.png"): "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("assets/live-talk-connection.wav"): "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("assets/openclam-app-icon.png"): "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("electron/tray-icon.png"): "b3c4c8feda8e99023280b61e5cf8fbf508c6cf60e51452dc9d5da26332d397c9",
    Path("electron/tray-icon@2x.png"): "e1c524968ad7b7252f462143b95f0764668370dcfb04da240b2b2f7aac80f712",
    Path("electron/tray-icon@3x.png"): "f7c01e384bb20625640b18fb2ba83ee3f0b8e75e5f31bb65c5933c86e9303e3b",
    # The Electron renderer cannot call AppKit directly. These monochrome
    # masks are the complete reviewed SF Symbols export; every byte stays
    # hash-pinned so a new or changed glyph fails this release gate closed.
    Path("web/assets/sf-symbols/avatar-layer.png"): "26407469ef8bda214ef8bceb8617b57be3f6f7228a64ab4659bdbad3aedaf235",
    Path("web/assets/sf-symbols/avatar-picker.png"): "f258a462ccfd024cd6d496f9b0628a4163fa4165ec11448881b35f1ec1590e7d",
    Path("web/assets/sf-symbols/avatar-window.png"): "12e2896359e7f803b9beddbcdd40116f433537cadc8f8f9907825a479052c16c",
    Path("web/assets/sf-symbols/checkmark.png"): "9dbec0f288a02891d6aa97f38edc3b3b880e778dae3924231d63ed719a920306",
    Path("web/assets/sf-symbols/chevron-down.png"): "61892662ee922cc944c8db821ec9ddf5a6b8137e7736ed890430548e6ec06e97",
    Path("web/assets/sf-symbols/close-up.png"): "54d3def5a0580bf15cf7c4c456f00b1c1c417c6d5fa956031f506a9f12ba05e1",
    Path("web/assets/sf-symbols/edge-idle.png"): "bb4eb398435474dff4d7d6959d125e22760d7a9c042f4dc7b8c95632cf02f8f6",
    Path("web/assets/sf-symbols/face-mirror.png"): "0b738a0edac243c7e86d77d7d48e23dbedd9a267117901c1942c75777969975a",
    Path("web/assets/sf-symbols/horizon-walk.png"): "7e290fce00d32e1dec6d0c5f1a63424699a7f10a395144af833b7d85ce8cfb47",
    Path("web/assets/sf-symbols/moves.png"): "4bd6833f388579dc29db6082ac57282b1e690b47cea173535c618a5408a587f9",
    Path("web/assets/sf-symbols/opacity.png"): "4509d81dc8ce0c775fcb666ae6a93f76191e8bf32a42726241d8dda20cedb69a",
    Path("web/assets/sf-symbols/phone-down.png"): "08954878c58408dd090955bc52df000d12d5e77688b54813131bb290a434c6fc",
    Path("web/assets/sf-symbols/phone.png"): "d80f603ea240c68c54db68dc6ea307ae059d9fabeed708951ce2b9ce45b80757",
    Path("web/assets/sf-symbols/settings.png"): "0dea54ca3b69bdeedd4d2328ae939f534f38f363c0ac44d48573569d81236119",
    Path("web/assets/sf-symbols/speaker-slash.png"): "9eaa2f5d756ecbbf8c6810b66e8f1fa6fb05921ce28c568880e7e2eb2df75020",
    Path("web/assets/sf-symbols/standby.png"): "48c6cfe49a24d084613ccd66365deee30fc27067f7aa5f1ce2f1c732a444f83a",
    Path("web/assets/sf-symbols/stop.png"): "f55715c19d24ac2f52d6cc5dc048c07343ad14efc794ea9b5629bc5da0af8b06",
    Path("web/assets/sf-symbols/thread-layer.png"): "c7df77fdcddbd7b52cba04ca9dcb325cad5d63cf2ee68f49b95e05ee9e44b217",
    Path("web/assets/sf-symbols/waveform.png"): "5d7e354a3fd8ffb4ce8ae9657f43c6ab2c48627fe401dd3f1620db2c4379e7b9",
}
PATTERNS = {
    "personal home path": re.compile(
        r"/" + r"Users/(?!example(?:/|$)|yourname(?:/|$))[^/\s\"']+"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\bgh[opsu]_[A-Za-z0-9]{20,}\b"),
    # Provider keys are literal high-entropy values, not ordinary source
    # identifiers such as ``xai_oauth_protocol_error``.  xAI console keys use
    # the ``xai-`` prefix; matching ``xai_`` made every OAuth symbol look like
    # a credential and weakened the usefulness of this release gate.
    "provider credential": re.compile(
        r"(?:\bsk-[A-Za-z0-9_-]{20,}\b"
        r"|\bgsk_[A-Za-z0-9_-]{20,}\b"
        r"|\bxai-[A-Za-z0-9]{24,}\b)"
    ),
    "agent workspace id": re.compile(r"agent\|[A-Za-z0-9_-]{8,}"),
}


def candidate_files() -> list[Path]:
    # OpenClam Studio intentionally lives in a larger source suite.  Asking
    # Git from ROOT still discovers that parent worktree and, with the final
    # pathspec, returns paths relative to this project.  Checking ROOT/.git
    # would miss that arrangement and recursively audit node_modules/.venv
    # after CI installs dependencies.
    probe = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
    )
    if probe.returncode == 0 and probe.stdout.strip() == b"true":
        result = subprocess.run(
            [
                "git", "-C", str(ROOT), "ls-files", "--cached", "--others",
                "--exclude-standard", "-z", "--", ".",
            ],
            capture_output=True,
            check=True,
        )
        return [Path(value.decode()) for value in result.stdout.split(b"\0") if value]
    return [
        path.relative_to(ROOT)
        for path in ROOT.rglob("*")
        if path.is_file() and not set(path.relative_to(ROOT).parts) & DENIED_PARTS
    ]


def audit() -> list[str]:
    errors: list[str] = []
    for relative in sorted(set(candidate_files())):
        path = ROOT / relative
        if not path.is_file():
            continue
        parts = set(relative.parts)
        if parts & DENIED_PARTS:
            errors.append(f"generated/private directory: {relative}")
            continue
        if relative.name in DENIED_NAMES or relative.name.startswith(".env."):
            errors.append(f"runtime/private file: {relative}")
            continue
        suffix = relative.suffix.lower()
        if suffix in DENIED_SUFFIXES and relative not in ALLOWED_BINARY:
            errors.append(f"generated/private media: {relative}")
            continue
        if path.stat().st_size > 10 * 1024 * 1024:
            errors.append(f"oversized source artifact: {relative}")
            continue
        if relative in ALLOWED_BINARY:
            expected = ALLOWED_BINARY_HASHES.get(relative)
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if expected is None or actual != expected:
                errors.append(f"approved binary hash mismatch: {relative}")
            continue
        raw = path.read_bytes()
        if b"\0" in raw:
            errors.append(f"unreviewed binary source artifact: {relative}")
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"non-UTF-8 source artifact: {relative}")
            continue
        for label, pattern in PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{label}: {relative}")
    return errors


def main() -> int:
    errors = audit()
    if errors:
        print("Public release audit failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Public release audit passed ({len(candidate_files())} files inspected).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
