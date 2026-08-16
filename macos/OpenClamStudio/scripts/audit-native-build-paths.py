#!/usr/bin/env python3
"""Reject build-machine temporary paths embedded in staged native artifacts."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys


BROAD_TEMP_PATTERNS = (
    (
        re.compile(rb"/(?:private/)?var/folders/"),
        "a macOS per-user temporary root",
    ),
    (
        re.compile(rb"/(?:private/)?(?:tmp|var/tmp)/openclam-(?:ffmpeg|opencv)-build(?:[./])"),
        "an OpenClam native temporary build root",
    ),
    (
        re.compile(rb"openclam-(?:ffmpeg|opencv)-build\.[A-Za-z0-9]+"),
        "an OpenClam native temporary build directory name",
    ),
    (re.compile(rb"/TemporaryItems/"), "a macOS TemporaryItems root"),
)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reject-prefix",
        action="append",
        default=[],
        metavar="PATH",
        help="also reject this exact build prefix (may be repeated)",
    )
    parser.add_argument("targets", nargs="+", metavar="PATH")
    return parser.parse_args()


def regular_files(target: Path) -> list[Path]:
    if not target.exists():
        raise SystemExit(f"native path audit target is missing: {target}")
    if target.is_file():
        return [target]
    if not target.is_dir():
        raise SystemExit(f"native path audit target is not a file or directory: {target}")
    return sorted(path for path in target.rglob("*") if path.is_file())


def exact_prefixes(values: list[str]) -> tuple[bytes, ...]:
    prefixes: set[bytes] = set()
    for value in values:
        if not value:
            continue
        raw = os.path.normpath(value)
        resolved = os.path.realpath(raw)
        for candidate in (raw, resolved):
            if not os.path.isabs(candidate) or candidate == "/":
                raise SystemExit(f"refusing unsafe build-prefix audit value: {value!r}")
            prefixes.add(candidate.encode())
            if candidate.startswith("/private/"):
                prefixes.add(candidate.removeprefix("/private").encode())
    return tuple(sorted(prefixes))


def audit_file(path: Path, prefixes: tuple[bytes, ...]) -> list[str]:
    data = path.read_bytes()
    findings = [label for pattern, label in BROAD_TEMP_PATTERNS if pattern.search(data)]
    if any(prefix in data for prefix in prefixes):
        findings.append("the exact native build root")
    return sorted(set(findings))


def main() -> None:
    arguments = parse_arguments()
    prefixes = exact_prefixes(arguments.reject_prefix)
    failures: list[tuple[Path, list[str]]] = []
    scanned = 0
    for target_value in arguments.targets:
        for path in regular_files(Path(target_value)):
            scanned += 1
            findings = audit_file(path, prefixes)
            if findings:
                failures.append((path, findings))
    if failures:
        for path, findings in failures[:20]:
            print(
                f"native path audit rejected {path}: {', '.join(findings)}",
                file=sys.stderr,
            )
        if len(failures) > 20:
            print(
                f"native path audit rejected {len(failures) - 20} additional files",
                file=sys.stderr,
            )
        raise SystemExit(1)
    print(f"native build-path audit passed ({scanned} files)")


if __name__ == "__main__":
    main()
