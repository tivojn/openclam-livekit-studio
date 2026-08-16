#!/usr/bin/env python3
"""Fail closed when private, generated, or unreviewed material enters source.

The audit prints rule labels and paths only. It never prints matched content.
Run it from a clean public snapshot before every public commit or release.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


ALLOWED_TOP_LEVEL = {
    ".gitignore",
    "CONTRIBUTING.md",
    "LICENSE",
    "PRIVACY.md",
    "PUBLIC_RELEASE_CHECKLIST.md",
    "README.md",
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
    "agent",
    "cloudflare-broker",
    "contracts",
    "ios",
    "macos",
    "scripts",
    "shared",
}

REQUIRED_FILES = {
    Path(".gitignore"),
    Path("CONTRIBUTING.md"),
    Path("LICENSE"),
    Path("PRIVACY.md"),
    Path("PUBLIC_RELEASE_CHECKLIST.md"),
    Path("README.md"),
    Path("SECURITY.md"),
    Path("THIRD_PARTY_NOTICES.md"),
    Path("agent/pyproject.toml"),
    Path("cloudflare-broker/package-lock.json"),
    Path("cloudflare-broker/package.json"),
    Path("contracts/live-talk-approved-tuples-v1.json"),
    Path("ios/OpenClamLiveKit/OpenClamLiveKit.xcodeproj/project.pbxproj"),
    Path("ios/OpenClamLiveKit/project.yml"),
    Path("macos/OpenClamStudio/package-lock.json"),
    Path("macos/OpenClamStudio/package.json"),
    Path("shared/avatar-package-v2/fixtures/ios-light-golden.avtr"),
}

DENIED_DIR_NAMES = {
    ".electron-ffmpeg",
    ".electron-models",
    ".electron-python-runtime",
    ".mypy_cache",
    ".npm",
    ".pytest_cache",
    ".ruff_cache",
    ".swiftpm",
    ".venv",
    ".wrangler",
    "DerivedData",
    "SourcePackages",
    "__pycache__",
    "acceptance-output",
    "avatars",
    "dist",
    "dist-electron",
    "inbox",
    "models",
    "node_modules",
    "outputs",
    "proof",
    "xcuserdata",
}

DENIED_EXACT_PATHS = {
    Path("agent/livekit.toml"),
    Path("agent/.env.local"),
    Path("cloudflare-broker/.dev.vars"),
    Path("cloudflare-broker/.wrangler/cache/wrangler-account.json"),
    Path("ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig"),
    Path("macos/OpenClamStudio/config.json"),
}

DENIED_NAMES = {
    ".DS_Store",
    ".env",
    "active.json",
    "backend.log",
    "id_ed25519",
    "id_rsa",
    "wrangler-account.json",
}

DENIED_SUFFIXES = {
    ".avtr",
    ".bak",
    ".cer",
    ".der",
    ".dmg",
    ".gif",
    ".gz",
    ".heic",
    ".icns",
    ".ipa",
    ".jpeg",
    ".jpg",
    ".key",
    ".log",
    ".mobileprovision",
    ".mov",
    ".mp3",
    ".mp4",
    ".p12",
    ".p8",
    ".pem",
    ".pfx",
    ".pkg",
    ".png",
    ".provisionprofile",
    ".pyc",
    ".resultbundle",
    ".task",
    ".tmp",
    ".wav",
    ".webm",
    ".webp",
    ".xcarchive",
    ".xcresult",
    ".xz",
    ".zip",
}

# Every public binary is an explicit path-and-hash decision. Any new image,
# sound, archive, model, or executable must receive a separate rights review.
ALLOWED_BINARY_HASHES = {
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark.png"):
        "5664249068345a2dda0418fbd9e49f9a9f8aa2cad2d58abd19ace390345d0d36",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@2x.png"):
        "fa32905f43136ae871ec7d26402fba5eb030673b11860bce307c9074788dde98",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@2xDark.png"):
        "75c6be2a4468a66798647c6fbde04237f6aa66d9fbfa2d02e79969274a0fe093",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@3x.png"):
        "576766050ea39efa5dec0d6160c66c131b758e9ac3a3b37894e758814b3bb223",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@3xDark.png"):
        "f5e46dcdec2da0b490b79ba914f11bb3b7c1c63b61022e6c6ccbc9190123ef89",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMarkDark.png"):
        "a3ac4054d207db07a947c4bd02bdb024823a895531bc6652279d05a1a6feec4b",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/live-talk-connection.wav"):
        "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/body.png"):
        "259a8fd460ec81bbd33b92e800277f5a227a3278cca833f8b76b1d2979a60e0a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/brow-left.png"):
        "0725704c4af8b4af0ff4c99f5e616581c92adf380ca9ad32e1bad0525e2127d3",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/brow-right.png"):
        "6a07b668123a2681101877c9ce9cd312ec1bc706fa05fad19395a28c3db26f54",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/eye-left.png"):
        "5acd87fb5af386dcf5f47b1c5cc360d1e6d32335b04e1155fdea4df8ad0f68f8",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/eye-right.png"):
        "3229a97da75a31653bd8c1cb88509d90c5e46783d3ee47ae1e23301f33a8e35e",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/gaze-left-atlas.png"):
        "f5227a7328fc5433f5baeb51f948eb63b5a568171453f42cf8dddb5b373d282c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/gaze-right-atlas.png"):
        "a4d526adb73f2369ba80595cea0b6eb05c0115c117cdadcf303896294552cf8a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/head-mask.png"):
        "e6b7b21576c23b2a07bbff9fef2fc9114b47bf908519f0eaf7e9a52be7603cdc",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/thumbnail.png"):
        "e1416b287d3b4186445ecc656e907765370570bc2d32424ccd93052f96bc714a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-E.png"):
        "7eeca4eb672f1d4ce1930e01035c5ed2e22be9549ec82565a2c745aa429e7837",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-FF.png"):
        "e81692c50786fdf1b13ae16c31795fed484afe5130c0154545858695744ba3d2",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-RR.png"):
        "cf66a6a38d389c3fbefc9a68ee7f2f35a0dbc9668a80ab45acebf3cfc0e991c4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-TH.png"):
        "a885faa275e06feff6c9947a9ff5e89faced6dce47d4bedd608e5fa8fbb642d1",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-aa.png"):
        "a6ee86eaa90f9e84cd925b26cd2f3e295ab800ba7441f2f51f8b8f6784c09e84",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-ih.png"):
        "9c0af199b5a1030f138ac1bb26b09ca22c3b966192dc4bf39303bedc6fe6a9b8",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-nn.png"):
        "5f4e08a4c94e4e812df176acad4a643737c4fa00dbd2535b402bdb49dfc02da1",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-ou.png"):
        "8b60a213ed4d82e4738f3db16a168f193a609e2a476208d17af2e51bcba9cac4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-sil.png"):
        "655c32ad576de349568fb3bbcbee71f47d8118bb83e02dc781e92e72e14cd381",
    Path("macos/OpenClamStudio/assets/icon.icns"):
        "5bec8b8a81778d5713864c32044eb163613d22c91a5eb56f1aa8bb16fecebd3c",
    Path("macos/OpenClamStudio/assets/icon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("macos/OpenClamStudio/assets/live-talk-connection.wav"):
        "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("macos/OpenClamStudio/assets/openclam-app-icon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("macos/OpenClamStudio/electron/tray-icon.png"):
        "b3c4c8feda8e99023280b61e5cf8fbf508c6cf60e51452dc9d5da26332d397c9",
    Path("macos/OpenClamStudio/electron/tray-icon@2x.png"):
        "e1c524968ad7b7252f462143b95f0764668370dcfb04da240b2b2f7aac80f712",
    Path("macos/OpenClamStudio/electron/tray-icon@3x.png"):
        "f7c01e384bb20625640b18fb2ba83ee3f0b8e75e5f31bb65c5933c86e9303e3b",
    Path("shared/avatar-package-v2/fixtures/ios-light-golden.avtr"):
        "20f46ca9f3160a0d5934202ef5908085f6246e492f8298582e0e12f7411d78cb",
}

PRIVATE_PATH_PATTERNS = {
    "personal home path": re.compile(
        rb"/" + rb"Users/(?!example(?:/|$)|yourname(?:/|$))[^/\s\"']+"
    ),
    "temporary attachment path": re.compile(
        rb"(?:/" + rb"var/folders/|/tmp/codex-remote-" + rb"attachments/|codex-" + rb"clipboard-)"
    ),
    "named private portrait": re.compile(rb"Samantha\.png", re.IGNORECASE),
}

PRIVATE_PATH_PATTERN_DETECTOR_FILES = {
    Path("macos/OpenClamStudio/scripts/opencv-cmake-hooks/STATUS_DUMP_EXTRA.cmake"),
    Path("scripts/public-release-audit.py"),
}

SECRET_PATTERNS = {
    "private key": re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
    ),
    "GitHub credential": re.compile(
        rb"(?:\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b)"
    ),
    "provider credential": re.compile(
        rb"(?:\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b"
        rb"|\bgsk_[A-Za-z0-9_-]{20,}\b"
        rb"|\bxai-[A-Za-z0-9]{24,}\b"
        rb"|\bAIza[A-Za-z0-9_-]{30,}\b)"
    ),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "Slack credential": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "payment credential": re.compile(rb"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b"),
    "agent workspace id": re.compile(rb"\bagent\|[A-Za-z0-9_-]{8,}\b"),
}

HIGH_ENTROPY_RE = re.compile(
    rb"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{40,}={0,2}(?![A-Za-z0-9_+/-])"
)
HIGH_ENTROPY_SKIP_NAMES = {
    "Package.resolved",
    "package-lock.json",
    "requirements-backend.lock",
    "requirements-electron.lock",
    "uv.lock",
}

ALLOWED_SOURCE_BUILD_FILES = {
    Path("macos/OpenClamStudio/build/entitlements.mac.inherit.plist"),
    Path("macos/OpenClamStudio/build/entitlements.mac.plist"),
}

MAX_SOURCE_BYTES = 10 * 1024 * 1024


def shannon_entropy(value: bytes) -> float:
    counts: dict[int, int] = defaultdict(int)
    for byte in value:
        counts[byte] += 1
    length = len(value)
    return -sum(
        (count / length) * math.log2(count / length) for count in counts.values()
    )


def git_root(root: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    discovered = Path(os.fsdecode(result.stdout.strip())).resolve()
    return discovered if discovered == root else None


def denied_directory_findings(root: Path) -> list[str]:
    findings: list[str] = []
    for current, directories, _ in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        kept: list[str] = []
        for name in directories:
            path = current_path / name
            relative = path.relative_to(root)
            if name == ".git":
                continue
            if name == "build" and relative != Path("macos/OpenClamStudio/build"):
                findings.append(f"generated/private directory: {relative}")
            elif name in DENIED_DIR_NAMES or name.startswith("dist-"):
                findings.append(f"generated/private directory: {relative}")
            else:
                kept.append(name)
        directories[:] = kept
    return findings


def candidate_files(root: Path) -> list[Path]:
    if git_root(root) is not None:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            capture_output=True,
            check=True,
        )
        return [
            Path(os.fsdecode(value))
            for value in result.stdout.split(b"\0")
            if value
        ]

    files: list[Path] = []
    for current, directories, names in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories[:] = [
            name
            for name in directories
            if name != ".git"
            and name not in DENIED_DIR_NAMES
            and not name.startswith("dist-")
            and not (
                name == "build"
                and (current_path / name).relative_to(root)
                != Path("macos/OpenClamStudio/build")
            )
        ]
        files.extend((current_path / name).relative_to(root) for name in names)
    return files


def denied_path_reason(relative: Path) -> str | None:
    if not relative.parts:
        return "invalid empty path"
    if relative.parts[0] not in ALLOWED_TOP_LEVEL:
        return "unreviewed top-level path"
    if relative in DENIED_EXACT_PATHS:
        return "runtime/private file"
    if any(part in DENIED_DIR_NAMES or part.startswith("dist-") for part in relative.parts):
        return "generated/private directory"
    if "build" in relative.parts and relative not in ALLOWED_SOURCE_BUILD_FILES:
        if relative == Path("macos/OpenClamStudio/build"):
            return None
        return "generated/private directory"
    lower_name = relative.name.lower()
    if relative.name in DENIED_NAMES or (
        lower_name.startswith(".env.")
        and lower_name not in {".env.example", ".dev.vars.example"}
    ):
        return "runtime/private file"
    if lower_name.endswith(".local.xcconfig"):
        return "runtime/private file"
    lowered = relative.as_posix().lower()
    if "captainayer" in lowered and ".imageset/" in lowered:
        return "quarantined human portrait asset"
    if re.search(
        r"avatarcatalogassets\.bundle/(?:vvn|octavia|cleo|emma)(?:/|$)",
        lowered,
    ):
        return "quarantined human portrait asset"
    if any(
        marker in lowered
        for marker in (
            "codex-remote-attachments",
            "codex-clipboard-",
            "samantha.png",
        )
    ):
        return "private evidence/user asset"
    suffix = relative.suffix.lower()
    if suffix in DENIED_SUFFIXES and relative not in ALLOWED_BINARY_HASHES:
        return "generated/private or unreviewed binary"
    return None


def high_entropy_finding(relative: Path, raw: bytes) -> bool:
    if relative.name in HIGH_ENTROPY_SKIP_NAMES:
        return False
    for match in HIGH_ENTROPY_RE.finditer(raw):
        token = match.group(0)
        stripped = token.rstrip(b"=")
        if b"/" in stripped:
            # Source paths and URLs are not secret literals. Provider-specific
            # credential patterns above still scan their full surrounding text.
            continue
        if stripped.count(b"_") >= 2 and not any(
            byte in b"0123456789" for byte in stripped
        ):
            continue
        if set(stripped) == set(
            b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        ):
            continue
        if len(stripped) in {40, 64, 96, 128} and re.fullmatch(
            rb"[0-9a-fA-F]+", stripped
        ):
            continue
        if token.startswith((b"sha256-", b"sha384-", b"sha512-")):
            continue
        if shannon_entropy(token) >= 4.7:
            return True
    return False


def audit_bytes(relative: Path, raw: bytes) -> list[str]:
    findings: list[str] = []
    if len(raw) > MAX_SOURCE_BYTES:
        return [f"oversized source artifact: {relative}"]

    expected_hash = ALLOWED_BINARY_HASHES.get(relative)
    if expected_hash is not None:
        actual = hashlib.sha256(raw).hexdigest()
        if actual != expected_hash:
            findings.append(f"approved binary hash mismatch: {relative}")
        return findings

    if b"\0" in raw:
        return [f"unreviewed binary source artifact: {relative}"]
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return [f"non-UTF-8 source artifact: {relative}"]

    if relative not in PRIVATE_PATH_PATTERN_DETECTOR_FILES:
        for label, pattern in PRIVATE_PATH_PATTERNS.items():
            if pattern.search(raw):
                findings.append(f"{label}: {relative}")
    for label, pattern in SECRET_PATTERNS.items():
        if pattern.search(raw):
            findings.append(f"{label}: {relative}")
    if high_entropy_finding(relative, raw):
        findings.append(f"unreviewed high-entropy literal: {relative}")
    return findings


def audit_current_tree(root: Path) -> tuple[list[str], int]:
    findings = denied_directory_findings(root)
    candidates = sorted(set(candidate_files(root)))
    for required in sorted(REQUIRED_FILES):
        if not (root / required).is_file():
            findings.append(f"required public file missing: {required}")

    for relative in candidates:
        path = root / relative
        reason = denied_path_reason(relative)
        if reason is not None:
            findings.append(f"{reason}: {relative}")
            continue
        if path.is_symlink():
            findings.append(f"symlink not allowed in public source: {relative}")
            continue
        if not path.is_file():
            findings.append(f"non-regular source entry: {relative}")
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o022:
            findings.append(f"group/world-writable source file: {relative}")
        findings.extend(audit_bytes(relative, path.read_bytes()))
    return findings, len(candidates)


def reachable_objects(root: Path) -> tuple[dict[str, set[Path]], list[str]]:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-list", "--objects", "--all"],
        capture_output=True,
        check=True,
    )
    paths_by_oid: dict[str, set[Path]] = defaultdict(set)
    object_ids: list[str] = []
    for raw_line in result.stdout.splitlines():
        decoded = os.fsdecode(raw_line)
        oid, separator, object_path = decoded.partition(" ")
        if oid not in paths_by_oid:
            object_ids.append(oid)
        if separator and object_path:
            paths_by_oid[oid].add(Path(object_path))
    return paths_by_oid, object_ids


def history_findings(root: Path, require_fresh: bool) -> list[str]:
    repository = git_root(root)
    if repository is None:
        return ["fresh-history check requested but snapshot has no Git history"] if require_fresh else []

    findings: list[str] = []
    if require_fresh:
        count = int(
            subprocess.check_output(
                ["git", "-C", str(root), "rev-list", "--count", "--all"],
                text=True,
            ).strip()
            or "0"
        )
        roots = subprocess.check_output(
            ["git", "-C", str(root), "rev-list", "--max-parents=0", "--all"],
            text=True,
        ).splitlines()
        if count != 1 or len(roots) != 1:
            findings.append(
                "public snapshot must have exactly one fresh root commit before first push"
            )

    identities = subprocess.check_output(
        ["git", "-C", str(root), "log", "--format=%ae%x00%ce%x00", "--all"]
    )
    for identity in identities.split(b"\0"):
        lowered = identity.strip().lower()
        if lowered.endswith(b".local") or b"@localhost" in lowered:
            findings.append("non-public local commit identity in reachable history")
            break

    # ``rev-list --objects`` reports only one path when multiple files share an
    # object ID (the empty blob is the common case). Enumerate commit diffs as
    # well so a deleted private path cannot hide behind an allowed identical
    # blob.
    history_names = subprocess.check_output(
        ["git", "-C", str(root), "log", "--all", "--format=", "--name-only", "-z"]
    )
    for raw_name in history_names.split(b"\0"):
        if not raw_name:
            continue
        relative = Path(os.fsdecode(raw_name).strip("\n"))
        reason = denied_path_reason(relative)
        if reason is not None:
            findings.append(f"reachable history {reason}: {relative}")

    paths_by_oid, object_ids = reachable_objects(root)

    process = subprocess.Popen(
        ["git", "-C", str(root), "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write("".join(f"{oid}\n" for oid in object_ids).encode("ascii"))
    process.stdin.close()
    for oid in object_ids:
        header = process.stdout.readline().rstrip(b"\n")
        fields = header.split()
        if len(fields) != 3 or fields[1] == b"missing":
            findings.append("could not inspect one reachable Git object")
            continue
        object_type = fields[1]
        size = int(fields[2])
        content = process.stdout.read(size)
        process.stdout.read(1)
        if object_type != b"blob":
            continue
        for relative in paths_by_oid.get(oid, set()):
            findings.extend(
                f"reachable history {finding}"
                for finding in audit_bytes(relative, content)
            )
    return findings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-fresh-history",
        action="store_true",
        help="require exactly one root commit (for the first public push)",
    )
    parser.add_argument("root", nargs="?", default=".")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    if not root.is_dir():
        print("Public release audit failed: root is not a directory", file=sys.stderr)
        return 2

    current, inspected = audit_current_tree(root)
    history = history_findings(root, args.require_fresh_history)
    findings = sorted(set(current + history))
    if findings:
        print("Public release audit failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1
    history_label = " and reachable history" if git_root(root) is not None else ""
    print(f"Public release audit passed ({inspected} files{history_label} inspected).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
