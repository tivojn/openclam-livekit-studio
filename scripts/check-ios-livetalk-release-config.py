#!/usr/bin/env python3
"""Fail closed before an iOS archive that would ship broken Live Talk.

The pilot bearer is intentionally never printed, hashed, copied, or passed as
an argument. This check reports only whether the ignored local xcconfig holds
a syntactically usable value; runtime still validates the signed Info.plist.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CONFIG = ROOT / "ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig"
TOKEN_KEY = "OPENCLAM_LIVETALK_APP_TOKEN"


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


def _valid_token(value: str) -> bool:
    if value.startswith("$(") or value == "replace-with-the-internal-pilot-token":
        return False
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return (
        32 <= len(encoded) <= 4_096
        and re.search(r"\s", value) is None
        and all(
            ord(character) >= 32 and ord(character) != 127
            for character in value
        )
    )


def main() -> int:
    token = _assignment(LOCAL_CONFIG, TOKEN_KEY)
    if not _valid_token(token):
        print(
            "Live Talk release configuration is incomplete: add the current "
            "pilot token to ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig."
        )
        return 1
    print("Live Talk release configuration is ready (token value not displayed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
