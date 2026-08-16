#!/usr/bin/env python3
"""Build the OpenClam Studio macOS and menu-bar icons."""

from pathlib import Path
import shutil
import subprocess

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
ELECTRON = ROOT / "electron"
ICONSET = ASSETS / "icon.iconset"
MASTER = ASSETS / "openclam-app-icon.png"
SIZE = 1024


def build() -> Image.Image:
    if not MASTER.is_file():
        raise SystemExit(f"missing copied OpenClam iOS icon: {MASTER}")
    image = Image.open(MASTER).convert("RGBA")
    if image.size != (SIZE, SIZE):
        raise SystemExit(f"OpenClam iOS icon must be {SIZE}×{SIZE}, got {image.size}")
    return image


def build_tray(scale: int) -> Image.Image:
    size = 22 * scale
    source = Image.open(MASTER).convert("RGB")
    grayscale = ImageOps.grayscale(source)
    # The iOS artwork is black linework on white. Its inverted luminance is a
    # native macOS template alpha mask, preserving the exact OpenClam mark.
    alpha = ImageOps.invert(grayscale).point(lambda value: 0 if value < 26 else value)
    alpha.thumbnail((size - 2 * scale, size - 2 * scale), Image.Resampling.LANCZOS)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mark = Image.new("RGBA", alpha.size, (0, 0, 0, 255))
    mark.putalpha(alpha)
    image.alpha_composite(mark, ((size - alpha.width) // 2, (size - alpha.height) // 2))
    return image


def main() -> None:
    ASSETS.mkdir(exist_ok=True)
    ELECTRON.mkdir(exist_ok=True)
    ICONSET.mkdir(exist_ok=True)
    image = build()
    # Keep the published PNG byte-for-byte identical to the iOS source.  The
    # ICNS and menu template are derived formats, but the primary artwork is
    # not redrawn or re-encoded.
    shutil.copy2(MASTER, ASSETS / "icon.png")
    for size in (16, 32, 128, 256, 512):
        image.resize((size, size), Image.Resampling.LANCZOS).save(
            ICONSET / f"icon_{size}x{size}.png"
        )
        image.resize((size * 2, size * 2), Image.Resampling.LANCZOS).save(
            ICONSET / f"icon_{size}x{size}@2x.png"
        )
    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ASSETS / "icon.icns")],
        check=True,
    )
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        build_tray(scale).save(ELECTRON / f"tray-icon{suffix}.png", optimize=True)
    print("Generated OpenClam Studio app and menu-bar icons.")


if __name__ == "__main__":
    main()
