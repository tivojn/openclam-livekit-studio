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
}
ALLOWED_BINARY_HASHES = {
    Path("assets/icon.icns"): "5bec8b8a81778d5713864c32044eb163613d22c91a5eb56f1aa8bb16fecebd3c",
    Path("assets/icon.png"): "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("assets/live-talk-connection.wav"): "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("assets/openclam-app-icon.png"): "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("electron/tray-icon.png"): "b3c4c8feda8e99023280b61e5cf8fbf508c6cf60e51452dc9d5da26332d397c9",
    Path("electron/tray-icon@2x.png"): "e1c524968ad7b7252f462143b95f0764668370dcfb04da240b2b2f7aac80f712",
    Path("electron/tray-icon@3x.png"): "f7c01e384bb20625640b18fb2ba83ee3f0b8e75e5f31bb65c5933c86e9303e3b",
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
