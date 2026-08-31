"""New cartoon gaze owns wet-eye pixels even in older iOS render order."""
from __future__ import annotations

import copy
import hashlib
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from PIL import Image

from server import avatar_package as package
from tests.test_avatar_package_v2 import (
    add_full_expression_runtime,
    configure_stylized_body_replacement,
    make_authoring,
    make_runtime,
)


MODES = (
    "soft-3d-rigid-iris-v1",
    "authored-2d-rigid-iris-v1",
    "soft-3d-authored-iris-v1",
)


def decoded(data: bytes) -> Image.Image:
    with Image.open(io.BytesIO(data)) as image:
        return image.convert("RGBA")


class GazeExportOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="openclam-gaze-export-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.authoring = make_authoring(self.root)
        self.runtime = make_runtime(self.authoring)
        configure_stylized_body_replacement(self.authoring, self.runtime)
        add_full_expression_runtime(self.runtime)
        self.meta = json.loads((self.runtime / "manifest.json").read_text())
        self.meta["gaze"]["mode"] = MODES[1]
        for side in ("l", "r"):
            x, y, width, height = self.meta["gaze"][side]["box"]
            strip = Image.new("RGBA", (width, height * 275))
            for index in range(275):
                tile = Image.new("RGBA", (width, height), (30, index % 256, 90, 0))
                if index != 137:  # canonical zero-displacement tile
                    tile.putpixel((2, 2), (10, 15, 25, 255))
                    tile.putpixel((3, 2), (10, 15, 25, 1))
                if index == 274:  # only the final state owns this pixel
                    tile.putpixel((5, 4), (10, 15, 25, 128))
                strip.paste(tile, (0, index * height))
            strip.save(self.runtime / f"gaze_{side}.png")
            self.meta["eyebag"][side]["box"] = [x - 2, y - 2, 10, 10]
            bag = Image.new("RGBA", (10, 50))
            for yy in range(50):
                for xx in range(10):
                    bag.putpixel((xx, yy), (80 + xx, 100 + yy, 150, (xx + yy * 13) % 256))
            bag.save(self.runtime / f"eyebag_{side}.png")
        self.save()

    def save(self):
        (self.runtime / "manifest.json").write_text(json.dumps(self.meta))

    def own(self, medium="illustration"):
        return package._ios_cartoon_gaze_ownership(self.runtime, self.meta, medium)

    def export(self, filename):
        destination = self.root / filename
        manifest = package.export_ios_light(
            "nova", "Nova", self.authoring, self.runtime, destination
        )
        with zipfile.ZipFile(destination) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        return manifest, files

    def test_only_three_new_modes_opt_in_photograph_and_unknown_never_read_images(self):
        missing = self.root / "does-not-exist"
        for mode in MODES:
            self.meta["gaze"]["mode"] = mode
            self.assertIsNone(package._ios_cartoon_gaze_ownership(
                missing, self.meta, "photograph"))
            self.assertIsNone(package._ios_cartoon_gaze_ownership(
                missing, self.meta, "unclassified"))
        for mode in (None, [], {}, "legacy-radial-warp", "rigid-photographic-iris-v1",
                     "authored-2d-neutral-gaze-v1", "future-gaze"):
            self.meta["gaze"]["mode"] = mode
            self.assertIsNone(package._ios_cartoon_gaze_ownership(
                missing, self.meta, "illustration"))

    def test_union_uses_all_states_nonzero_alpha_without_filling_sprite_rectangle(self):
        for mode in MODES:
            with self.subTest(mode=mode):
                self.meta["gaze"]["mode"] = mode
                owned = self.own()
                self.assertEqual(owned.size, (1024, 1024))
                self.assertEqual(owned.histogram()[255], 6)
                for side in ("l", "r"):
                    x, y, _, _ = self.meta["gaze"][side]["box"]
                    self.assertEqual(owned.getpixel((x + 2, y + 2)), 255)
                    self.assertEqual(owned.getpixel((x + 3, y + 2)), 255)
                    self.assertEqual(owned.getpixel((x + 5, y + 4)), 255)
                    self.assertEqual(owned.getpixel((x, y)), 0)

    def test_every_under_eye_cell_preserves_rgb_and_all_unowned_alpha(self):
        owned = self.own()
        geometry = package._expression_geometry(self.meta)
        for side, key in (("l", "leftUnderEye"), ("r", "rightUnderEye")):
            source = self.runtime / f"eyebag_{side}.png"
            original_bytes = source.read_bytes()
            output = self.root / f"exported-under-eye-{side}.png"
            package._copy_under_eye_with_gaze_ownership(source, output, geometry[key], owned)
            original, result = decoded(original_bytes), decoded(output.read_bytes())
            self.assertEqual(original.convert("RGB").tobytes(), result.convert("RGB").tobytes())
            x, y, width, height = self.meta["eyebag"][side]["box"]
            for frame in range(5):
                for yy in range(height):
                    for xx in range(width):
                        position = xx, yy + height * frame
                        if owned.getpixel((x + xx, y + yy)):
                            self.assertEqual(result.getpixel(position)[3], 0)
                        else:
                            self.assertEqual(result.getpixel(position), original.getpixel(position))
            self.assertEqual(source.read_bytes(), original_bytes)

    def test_export_changes_only_two_under_eye_assets_no_schema_or_gaze_pixel_change(self):
        self.meta["gaze"].pop("mode")
        self.save()
        legacy_manifest, legacy = self.export("legacy.avtr")
        for mode in MODES:
            with self.subTest(mode=mode):
                self.meta["gaze"]["mode"] = mode
                self.save()
                source_hashes = {
                    str(path.relative_to(self.authoring)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.authoring.rglob("*") if path.is_file()
                }
                manifest, files = self.export(f"{mode}.avtr")
                self.assertEqual(set(files), set(legacy))
                self.assertEqual(manifest["version"], 4)
                self.assertEqual(manifest["rig"], legacy_manifest["rig"])
                self.assertEqual(manifest["expression"], legacy_manifest["expression"])
                self.assertEqual(set(manifest), set(legacy_manifest))
                changed = {
                    name for name in files if files[name] != legacy[name]
                }
                self.assertEqual(changed, {
                    "manifest.json", "assets/under-eye-left.png", "assets/under-eye-right.png"
                })
                for side, name, rig_key in (("l", "left", "leftGaze"), ("r", "right", "rightGaze")):
                    atlas = decoded(files[f"assets/gaze-{name}-atlas.png"])
                    strip = decoded((self.runtime / f"gaze_{side}.png").read_bytes())
                    x, y, w, h = self.meta["gaze"][side]["box"]
                    self.assertEqual(manifest["rig"][rig_key]["box"], {
                        "x": x, "y": y, "width": w, "height": h
                    })
                    for index in range(275):
                        tile = atlas.crop(((index % 25) * w, (index // 25) * h,
                                           (index % 25 + 1) * w, (index // 25 + 1) * h))
                        self.assertEqual(tile.tobytes(), strip.crop((0, index*h, w, (index+1)*h)).tobytes())
                        if index == 137:
                            self.assertIsNone(tile.getchannel("A").getbbox())
                self.assertEqual(source_hashes, {
                    str(path.relative_to(self.authoring)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.authoring.rglob("*") if path.is_file()
                })

    def test_photograph_and_legacy_modes_keep_identical_export_bytes(self):
        for medium in ("photograph", "illustration"):
            authoring_meta = json.loads((self.authoring / "manifest.json").read_text())
            authoring_meta["source_metrics"]["source_medium"] = medium
            (self.authoring / "manifest.json").write_text(json.dumps(authoring_meta))
            self.meta["gaze"].pop("mode", None)
            self.save()
            _, baseline = self.export(f"{medium}-baseline.avtr")
            modes = (*MODES, "future-gaze") if medium == "photograph" else (
                "legacy-radial-warp", "authored-2d-neutral-gaze-v1", "future-gaze")
            for mode in modes:
                with self.subTest(medium=medium, mode=mode):
                    self.meta["gaze"]["mode"] = mode
                    self.save()
                    _, files = self.export(f"{medium}-{mode}.avtr")
                    self.assertEqual(files, baseline)

    def test_existing_ios_order_preserves_new_gaze_even_at_neutral_and_max_under_eye(self):
        owned = self.own()
        geometry = package._expression_geometry(self.meta)["leftUnderEye"]
        source = self.runtime / "eyebag_l.png"
        output = self.root / "protected.png"
        package._copy_under_eye_with_gaze_ownership(source, output, geometry, owned)
        old_bag = decoded(source.read_bytes()).crop((0, 40, 10, 50))
        new_bag = decoded(output.read_bytes()).crop((0, 40, 10, 50))
        strip = decoded((self.runtime / "gaze_l.png").read_bytes())
        gx, gy, w, h = self.meta["gaze"]["l"]["box"]
        ux, uy, _, _ = self.meta["eyebag"]["l"]["box"]
        mask = owned.crop((ux, uy, ux + 10, uy + 10))
        for index in (0, 137, 274):
            tile = strip.crop((0, index * h, w, (index + 1) * h))
            expected = Image.new("RGBA", (10, 10), (245, 242, 234, 255))
            expected.alpha_composite(tile, (gx - ux, gy - uy))
            after = Image.alpha_composite(expected, new_bag)
            before = Image.alpha_composite(expected, old_bag)
            changed_before = 0
            for y in range(10):
                for x in range(10):
                    if mask.getpixel((x, y)):
                        self.assertEqual(after.getpixel((x, y)), expected.getpixel((x, y)))
                        changed_before += before.getpixel((x, y)) != expected.getpixel((x, y))
                    else:
                        self.assertEqual(after.getpixel((x, y)), before.getpixel((x, y)))
            self.assertGreater(changed_before, 0)
            # Existing semantic full-eye blink still paints last, unchanged.
            closed = Image.new("RGBA", (10, 10), (180, 130, 100, 255))
            self.assertEqual(Image.alpha_composite(after, closed).tobytes(), closed.tobytes())

    def test_fractional_gaze_coordinates_fail_without_guessing_pixel_ownership(self):
        for slot in range(4):
            metadata = copy.deepcopy(self.meta)
            metadata["gaze"]["l"]["box"][slot] += 0.25
            with self.subTest(slot=slot), self.assertRaisesRegex(package.AvatarPackageError, "integer"):
                package._ios_cartoon_gaze_ownership(self.runtime, metadata, "illustration")

    def test_invalid_gaze_strip_aborts_export_without_output(self):
        Image.new("RGBA", (6, 5 * 274)).save(self.runtime / "gaze_l.png")
        destination = self.root / "invalid.avtr"
        with self.assertRaisesRegex(package.AvatarPackageError, "strip dimensions"):
            package.export_ios_light("nova", "Nova", self.authoring, self.runtime, destination)
        self.assertFalse(destination.exists())

    def test_invalid_under_eye_strip_rejected_before_export(self):
        source = self.runtime / "eyebag_l.png"
        Image.new("RGBA", (10, 49)).save(source)
        destination = self.root / "invalid.avtr"
        with self.assertRaisesRegex(package.AvatarPackageError, "under-eye strip dimensions"):
            package.export_ios_light("nova", "Nova", self.authoring, self.runtime, destination)
        self.assertFalse(destination.exists())

    def test_no_overlap_keeps_exact_original_clean_png(self):
        source = self.runtime / "eyebag_l.png"
        baseline, output = self.root / "baseline.png", self.root / "no-overlap.png"
        package._copy_clean_image(source, baseline)
        package._copy_under_eye_with_gaze_ownership(
            source, output, package._expression_geometry(self.meta)["leftUnderEye"],
            Image.new("L", (1024, 1024), 0)
        )
        self.assertEqual(output.read_bytes(), baseline.read_bytes())


if __name__ == "__main__":
    unittest.main()
