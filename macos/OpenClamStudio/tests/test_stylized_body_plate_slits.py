"""Reject ambiguous hair plate slits without erasing authored white anatomy."""
import base64
import hashlib
import json
import os
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from studio import body, cutout


def _body_plate(background=(255, 255, 255)):
    image = np.full((480, 320, 3), background, np.uint8)
    # A tall subject makes upper-silhouette scope independent of absolute y.
    image[28:160, 72:252] = (38, 65, 100)
    image[160:420, 95:229] = (35, 40, 180)
    image[420:462, 95:140] = (25, 30, 35)
    image[420:462, 184:229] = (25, 30, 35)
    return image


def _hair_slit():
    image = _body_plate()
    image[55:87, 75:79] = 255
    return image


def _fragmented_hair_slit():
    image = _body_plate()
    # Just outside the strict removable-white core, but still pale pixels.
    image[55:88, 75:79] = 240
    for y in (55, 62, 69, 76, 83):
        image[y:y + 5, 75:79] = 255
    return image


def _sarah_native_slit_fixture():
    fixture = json.loads((Path(__file__).parent / "fixtures"
                          / "sarah_fragmented_side_slit.json").read_text())
    width, height = fixture["source_dimensions_wh"]
    image = np.full((height, width, 3), 255, np.uint8)
    # A distant synthetic marker supplies full-body extent. The defect and
    # all neighbours inspected by the diagnostic retain exact native pixels;
    # so does the source's border, preserving its colour/noise calibration.
    image[650:1390, 600:760] = (38, 65, 100)
    border = zlib.decompress(base64.b64decode(fixture["border_pixels_zlib_base64"]))
    if hashlib.sha256(border).hexdigest() != fixture["border_pixels_sha256"]:
        raise AssertionError("native border fixture changed")
    image[cutout._border_mask(height, width)] = np.frombuffer(border, np.uint8).reshape(-1, 3)
    roi = cv2.imdecode(np.frombuffer(base64.b64decode(fixture["roi_png_base64"]),
                                   np.uint8), cv2.IMREAD_COLOR)
    if hashlib.sha256(roi.tobytes()).hexdigest() != fixture["roi_pixels_sha256"]:
        raise AssertionError("native hair fixture changed")
    x, y, width, height = fixture["roi_xywh"]
    image[y:y + height, x:x + width] = roi
    return image, fixture


class StylizedSlitTests(unittest.TestCase):
    def assert_strict_unchanged(self, source):
        before = source.copy()
        ordinary = cutout._flat_plate_cutout(source)
        strict = cutout._flat_plate_cutout(source, reject_enclosed_plate=True)
        self.assertIsNotNone(ordinary)
        self.assertIsNotNone(strict)
        np.testing.assert_array_equal(ordinary[0], strict[0])
        np.testing.assert_array_equal(before, source)
        return strict[0]

    def test_exact_slender_upper_hair_failure_is_rejected_not_erased(self):
        source = _hair_slit()
        before = source.copy()
        rgba, _, _ = cutout._flat_plate_cutout(source)
        self.assertEqual(255, int(rgba[66, 76, 3]))
        with self.assertRaises(cutout.AmbiguousStylizedPlateError) as raised:
            cutout._flat_plate_cutout(source, reject_enclosed_plate=True)
        self.assertEqual([75, 55, 4, 32], raised.exception.components[0]["bounds"])
        self.assertIn("pixels were preserved", str(raised.exception))
        np.testing.assert_array_equal(source, before)

    def test_exact_sarah_native_fragments_are_rejected_with_unchanged_pixels(self):
        source, fixture = _sarah_native_slit_fixture()
        before = source.copy()
        rgba, _, _ = cutout._flat_plate_cutout(source)
        self.assertEqual((255, 255, 254, 255), tuple(rgba[207, 403]))
        with self.assertRaises(cutout.AmbiguousStylizedPlateError) as raised:
            cutout._flat_plate_cutout(source, reject_enclosed_plate=True)
        risk = raised.exception.components[0]
        self.assertEqual(fixture["expected_bounds_xywh"], risk["bounds"])
        self.assertEqual(fixture["expected_strict_fragments"], risk["strict_fragment_count"])
        self.assertTrue(risk["fragmented"])
        self.assertEqual(73, risk["plate_pixels"])
        np.testing.assert_array_equal(source, before)
        # The quality diagnostic cannot silently "repair" authored pixels.
        np.testing.assert_array_equal(cutout._flat_plate_cutout(source)[0], rgba)

    def test_pale_connections_group_tiny_fragments_for_rejection_only(self):
        source = _fragmented_hair_slit()
        before = source.copy()
        with self.assertRaises(cutout.AmbiguousStylizedPlateError) as raised:
            cutout._flat_plate_cutout(source, reject_enclosed_plate=True)
        self.assertEqual(5, raised.exception.components[0]["strict_fragment_count"])
        np.testing.assert_array_equal(source, before)

    def test_separate_highlights_are_not_grouped_through_dark_hair(self):
        source = _body_plate()
        for y in (55, 62, 69, 76, 83):
            source[y:y + 5, 75:79] = 255
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual(255, int(rgba[57, 76, 3]))

    def test_fragmented_profile_eye_with_glasses_keeps_white_and_dark_details(self):
        source = _fragmented_hair_slit()
        source[52:91, 74:89] = (205, 205, 205)
        source[55:88, 75:79] = 240
        for y in (55, 62, 69, 76, 83):
            source[y:y + 5, 75:79] = 255
        source[67:77, 81:85] = (8, 8, 8)
        cv2.rectangle(source, (73, 51), (91, 93), (18, 18, 18), 1)
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual((255, 255, 255, 255), tuple(rgba[57, 76]))
        self.assertEqual((8, 8, 8, 255), tuple(rgba[70, 83]))
        self.assertEqual((18, 18, 18, 255), tuple(rgba[51, 81]))

    def test_fragmented_white_surface_and_lower_heel_detail_are_untouched(self):
        source = _fragmented_hair_slit()
        source[45:97, 73:88] = (200, 200, 200)
        source[55:88, 75:79] = 240
        for y in (55, 62, 69, 76, 83):
            source[y:y + 5, 75:79] = 255
        source[430:459, 98:100] = 255
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual((255, 255, 255, 255), tuple(rgba[57, 76]))
        self.assertEqual((255, 255, 255, 255), tuple(rgba[454, 99]))

    def test_lower_body_white_clothing_trim_is_untouched(self):
        source = _body_plate()
        source[230:262, 98:102] = 255
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual(255, int(rgba[242, 99, 3]))

    def test_horizontal_teeth_and_small_glints_are_untouched(self):
        source = _body_plate()
        source[82:86, 75:107] = 255
        source[44:51, 75:78] = 255
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual(255, int(rgba[84, 77, 3]))
        self.assertEqual(255, int(rgba[46, 76, 3]))

    def test_eye_white_and_pupil_are_untouched_near_silhouette(self):
        source = _body_plate()
        cv2.ellipse(source, (88, 75), (12, 20), 0, 0, 360, (255, 255, 255), -1)
        cv2.circle(source, (88, 75), 5, (12, 12, 12), -1)
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual(255, int(rgba[75, 79, 3]))
        self.assertEqual((12, 12, 12, 255), tuple(rgba[75, 88]))

    def test_profile_sclera_fragments_recover_pale_surface_and_pupil(self):
        source = _body_plate()
        source[52:91, 74:89] = (205, 205, 205)
        source[55:87, 75:79] = 255
        source[67:77, 81:85] = (8, 8, 8)
        rgba = self.assert_strict_unchanged(source)
        self.assertEqual(255, int(rgba[66, 76, 3]))

    def test_shaded_white_surface_is_untouched(self):
        source = _body_plate()
        source[45:97, 73:88] = (200, 200, 200)
        source[55:87, 75:79] = 255
        self.assert_strict_unchanged(source)

    def test_dark_field_source_without_flat_plate_is_not_guessed(self):
        source = _hair_slit()
        source[:12] = (30, 60, 80)
        source[-12:] = (60, 50, 30)
        source[:, :12] = (50, 70, 100)
        source[:, -12:] = (20, 20, 20)
        self.assertIsNone(cutout._flat_plate_cutout(
            source, reject_enclosed_plate=True))

    def test_neutral_and_green_extraction_are_byte_identical(self):
        for background in ((207, 207, 208), (0, 255, 0)):
            with self.subTest(background=background):
                source = _body_plate(background)
                source[55:87, 75:79] = 255
                self.assert_strict_unchanged(source)

    def test_render_rejection_never_writes_destination_or_calls_vision(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.png"
            output = Path(temporary) / "existing.png"
            cv2.imwrite(str(source), _hair_slit())
            output.write_bytes(b"approved previous image")
            with mock.patch.object(cutout, "_run_helper") as helper:
                with self.assertRaises(cutout.AmbiguousStylizedPlateError):
                    cutout.render(str(source), str(output), allow_stylized=True,
                                  reject_enclosed_plate=True, log=lambda _: None)
                helper.assert_not_called()
            self.assertEqual(b"approved previous image", output.read_bytes())

    def test_photographic_path_is_byte_identical_even_if_strict_flag_is_set(self):
        image = np.zeros((480, 320, 4), np.uint8)
        image[28:462, 72:252] = (65, 105, 165, 255)
        image[70:75, 72:74] = (90, 130, 195, 64)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.png"
            cv2.imwrite(str(source), _hair_slit())

            def helper(_helper, _source, destination, _pose, _log):
                return cv2.imwrite(destination, image)

            outputs = []
            with mock.patch.object(cutout, "helper_path", return_value="Vision"), \
                    mock.patch.object(cutout, "_run_helper", side_effect=helper), \
                    mock.patch.object(cutout, "_flat_plate_cutout") as plate:
                for strict in (False, True):
                    destination = Path(temporary) / f"photo-{strict}.png"
                    receipt = cutout.render(
                        str(source), str(destination), tight=True,
                        allow_stylized=False, reject_enclosed_plate=strict,
                        log=lambda _: None)
                    self.assertEqual("macos-vision-person-segmentation",
                                     receipt["method"])
                    outputs.append(destination.read_bytes())
                plate.assert_not_called()
            self.assertEqual(outputs[0], outputs[1])


class BodySlitRoutingTests(unittest.TestCase):
    def test_photo_body_call_has_exact_original_arguments(self):
        logger = lambda _: None
        with mock.patch.object(cutout, "render", return_value={"ok": True}) as render:
            body._render_body_cutout(
                "photo.png", "body.png", "side", allow_stylized=False, log=logger)
        render.assert_called_once_with(
            "photo.png", "body.png", log=logger, tight=True, allow_stylized=False)

    def test_cartoon_body_rejection_uses_existing_targeted_alpha_exception(self):
        error = cutout.AmbiguousStylizedPlateError([{"bounds": [75, 55, 4, 32]}])
        with mock.patch.object(cutout, "render", side_effect=error) as render:
            with self.assertRaisesRegex(body.GeneratedBodyAlphaError,
                                        "generated side body failed alpha QA"):
                body._render_body_cutout(
                    "source.png", "body.png", "side", allow_stylized=True)
        self.assertTrue(render.call_args.kwargs["reject_enclosed_plate"])

    def test_side_preflight_rejects_before_existing_body_or_motion_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "manifest.json").write_text(json.dumps({
                "source_medium_override": "3d render",
                "source_metrics": {"source_medium": "3d render"},
            }))
            source = directory / "source-side.png"
            cv2.imwrite(str(source), _hair_slit())
            approved = directory / "body"
            approved.mkdir()
            sentinel = approved / "body.png"
            sentinel.write_bytes(b"approved body bytes")
            with self.assertRaises(body.GeneratedBodyAlphaError):
                body._preflight_alpha_source(
                    str(directory), str(source), "side", log=lambda _: None)
            self.assertEqual(b"approved body bytes", sentinel.read_bytes())
            self.assertFalse(list(directory.glob(".body-side-alpha-preflight-*")))

    def test_targeted_remediation_preserves_white_anatomy(self):
        reason = str(cutout.AmbiguousStylizedPlateError([
            {"bounds": [75, 55, 4, 32]},
        ]))
        prompt = body._alpha_retry_prompt(
            body._prompt({"style": "soft-3d"}, view="side"), reason, "side")
        self.assertIn("Regenerate only this side plate", prompt)
        self.assertIn("do not trap white crescents inside the hair", prompt)
        self.assertIn("Preserve the original eyes, teeth", prompt)
        self.assertNotIn("clearly non-white material", prompt)


class TargetedBodyRepairTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        (root / "body").mkdir()
        sources = {}
        for index, view in enumerate(body.BODY_VIEWS):
            path = root / "body" / f"source-{view}.png"
            cv2.imwrite(str(path), np.full((48, 32, 3), 40 + index, np.uint8))
            sources[view] = str(path)
        (root / "head.png").write_bytes(b"approved canonical face")
        (root / "keyframe.png").write_bytes(b"approved keyframe")
        (root / "motion").mkdir()
        (root / "motion" / "walk.hevc.mov").write_bytes(b"approved motion")
        current = {"options": {"style": "soft-3d", "pose": "relaxed"}}
        return root, sources, current

    def test_side_only_provider_call_keeps_head_front_back_and_motion_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, sources, current = self.fixture(temporary)
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*")
                      if p.is_file()}
            rejected = body.GeneratedBodyAlphaError(
                "ambiguous enclosed white silhouette slit")
            generated_images = []

            def generate(_prompt, _references, _lane, **options):
                path = Path(options["output_dir"]) / "corrected-side.png"
                cv2.imwrite(str(path), np.full((48, 32, 3), 77, np.uint8))
                generated_images.append(path.read_bytes())
                return str(path)

            def install(_avatar, selected, *_args, **kwargs):
                self.assertEqual(sources["front"], selected["front"])
                self.assertEqual(sources["back"], selected["back"])
                self.assertEqual(generated_images[0], Path(selected["side"]).read_bytes())
                self.assertTrue(kwargs["keep_previous"])
                self.assertEqual("side", kwargs["edit_receipt"]["scope"])
                return {"repaired": "side"}

            with mock.patch.object(body, "_allow_stylized_source", return_value=True), \
                    mock.patch.object(body, "_body_metadata", return_value=current), \
                    mock.patch.object(body, "_body_source",
                                      side_effect=lambda _a, _m, v: sources[v]), \
                    mock.patch.object(body, "_preflight_alpha_source",
                                      side_effect=[rejected, {"valid": True}]) as gate, \
                    mock.patch.object(body, "image_provider_selection",
                                      return_value=({}, {"name": "xai"})), \
                    mock.patch.object(body.media_gen, "generate_image_edit_sync",
                                      side_effect=generate) as provider, \
                    mock.patch.object(body, "_install_sources", side_effect=install):
                self.assertEqual({"repaired": "side"}, body.regenerate_view(
                    str(root), "side", log=lambda _: None))
            self.assertEqual(1, provider.call_count)
            self.assertEqual(2, gate.call_count)
            self.assertEqual([str(root / "head.png"), sources["front"], sources["side"]],
                             provider.call_args.args[1])
            self.assertEqual("side", gate.call_args.args[2])
            self.assertEqual(before, {p.relative_to(root): p.read_bytes()
                                     for p in root.rglob("*") if p.is_file()})

    def test_rejected_replacement_never_installs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, sources, current = self.fixture(temporary)
            error = body.GeneratedBodyAlphaError("ambiguous enclosed white silhouette slit")
            with mock.patch.object(body, "_allow_stylized_source", return_value=True), \
                    mock.patch.object(body, "_body_metadata", return_value=current), \
                    mock.patch.object(body, "_body_source",
                                      side_effect=lambda _a, _m, v: sources[v]), \
                    mock.patch.object(body, "_preflight_alpha_source", side_effect=error), \
                    mock.patch.object(body, "image_provider_selection",
                                      return_value=({}, {"name": "xai"})), \
                    mock.patch.object(body.media_gen, "generate_image_edit_sync",
                                      return_value="rejected.png") as provider, \
                    mock.patch.object(body, "_install_sources") as install:
                with self.assertRaises(body.GeneratedBodyAlphaError):
                    body.regenerate_view(str(root), "side", log=lambda _: None)
            self.assertEqual(1, provider.call_count)
            install.assert_not_called()
            self.assertFalse(list(root.glob(".body-side-repair-provider-*")))

    def test_approved_source_is_not_regenerated_and_photo_front_are_disallowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, sources, current = self.fixture(temporary)
            with mock.patch.object(body, "_allow_stylized_source", return_value=True), \
                    mock.patch.object(body, "_body_metadata", return_value=current), \
                    mock.patch.object(body, "_body_source",
                                      side_effect=lambda _a, _m, v: sources[v]), \
                    mock.patch.object(body, "_preflight_alpha_source",
                                      return_value={"valid": True}), \
                    mock.patch.object(body, "image_provider_selection") as provider:
                with self.assertRaisesRegex(RuntimeError, "already passes alpha QA"):
                    body.regenerate_view(str(root), "side", log=lambda _: None)
                with self.assertRaisesRegex(ValueError, "only side or back"):
                    body.regenerate_view(str(root), "front", log=lambda _: None)
                provider.assert_not_called()
            with mock.patch.object(body, "_allow_stylized_source", return_value=False), \
                    mock.patch.object(body, "image_provider_selection") as provider:
                with self.assertRaisesRegex(ValueError, "classified cartoon"):
                    body.regenerate_view(str(root), "side", log=lambda _: None)
                provider.assert_not_called()


if __name__ == "__main__":
    unittest.main()
