#!/usr/bin/env python3
"""Fail when a staged Mach-O requires a newer macOS than the app promises."""
from __future__ import annotations

import argparse
import pathlib
import re
import subprocess


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
MINOS_PATTERN = re.compile(r"^\s*minos\s+(\d+(?:\.\d+)*)\s*$", re.MULTILINE)


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def is_macho(path: pathlib.Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except (OSError, PermissionError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="+", type=pathlib.Path)
    parser.add_argument("--max", dest="maximum", default="14.0")
    args = parser.parse_args()

    maximum = version_tuple(args.maximum)
    failures: list[str] = []
    checked = 0
    for root in args.roots:
        root = root.resolve()
        if not root.is_dir():
            failures.append(f"staged runtime directory is missing: {root}")
            continue
        for path in root.rglob("*"):
            if not path.is_file() or not is_macho(path):
                continue
            checked += 1
            architectures = subprocess.run(
                ["/usr/bin/lipo", "-archs", str(path)],
                capture_output=True,
                check=False,
                text=True,
            )
            if architectures.returncode != 0:
                failures.append(f"cannot inspect Mach-O architectures: {path}")
                continue
            if "arm64" not in architectures.stdout.split():
                failures.append(f"Mach-O has no arm64 slice: {path}")
                continue
            result = subprocess.run(
                ["/usr/bin/vtool", "-show-build", str(path)],
                capture_output=True,
                check=False,
                text=True,
            )
            if result.returncode != 0:
                failures.append(f"cannot inspect Mach-O deployment target: {path}")
                continue
            versions = MINOS_PATTERN.findall(result.stdout)
            if not versions:
                failures.append(f"Mach-O has no inspectable macOS deployment target: {path}")
                continue
            for version in versions:
                if version_tuple(version) > maximum:
                    failures.append(
                        f"requires macOS {version} (maximum {args.maximum}): {path}"
                    )

    if failures:
        raise SystemExit("\n".join(failures))
    if checked == 0:
        raise SystemExit("no Mach-O binaries were found in the staged runtime")
    print(
        f"macOS deployment-target audit passed "
        f"({checked} arm64 Mach-O binaries <= {args.maximum})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
