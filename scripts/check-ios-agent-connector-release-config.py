#!/usr/bin/env python3
"""Fail closed before an iOS archive with a disabled agent connector.

The bridge origin is public routing metadata, not a credential. This check
still reports only readiness so release logs stay stable and do not accidentally
become a source of deployment details.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "ios/OpenClamLiveKit/Config/AgentConnector.local.xcconfig"
ORIGIN_KEY = "OPENCLAM_AGENT_CONNECTOR_ORIGIN"
PROJECT = ROOT / "ios/OpenClamLiveKit/OpenClamLiveKit.xcodeproj"


def _assignment(path: Path, key: str) -> str:
    if not path.is_file():
        return ""
    value = ""
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or "=" not in line:
            continue
        name, candidate = line.split("=", 1)
        if name.strip() == key:
            value = candidate.strip()
    return value


def _valid_xcode_origin(value: str) -> bool:
    # A literal https:// is parsed by xcconfig as only "https:" because //
    # starts a comment. Require the Xcode-safe empty-expansion separator.
    if not value.startswith("https:/$()/") or value.count("/$()/") != 1:
        return False
    origin = value.replace("/$()/", "//", 1).rstrip("/")
    try:
        parsed = urlsplit(origin)
    except ValueError:
        return False
    return (
        parsed.scheme == "https"
        and bool(parsed.hostname)
        and parsed.username is None
        and parsed.password is None
        and parsed.path == ""
        and parsed.query == ""
        and parsed.fragment == ""
        and origin == f"https://{parsed.netloc}"
    )


def _normalized_origin(value: str) -> str:
    return value.replace("/$()/", "//", 1).rstrip("/")


def _resolved_release_origin() -> str:
    try:
        result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                str(PROJECT),
                "-scheme",
                "OpenClamLiveKit",
                "-configuration",
                "Release",
                "-showBuildSettings",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=45,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    prefix = f"{ORIGIN_KEY} = "
    matches = [
        line.strip()[len(prefix):].strip()
        for line in result.stdout.splitlines()
        if line.strip().startswith(prefix)
    ]
    return matches[-1] if matches else ""


def main() -> int:
    origin = _assignment(LOCAL_CONFIG, ORIGIN_KEY)
    if not _valid_xcode_origin(origin):
        print(
            "Agent Connector release configuration is incomplete: set the "
            "bridge root origin in Config/AgentConnector.local.xcconfig using "
            "the Xcode-safe https:/$()/host form."
        )
        return 1
    if _resolved_release_origin() != _normalized_origin(origin):
        print(
            "Agent Connector release configuration is not reaching the iOS "
            "Release build settings."
        )
        return 1
    print("Agent Connector release configuration is ready.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
