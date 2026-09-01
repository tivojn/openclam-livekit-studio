"""A soft-3D jaw feather must not dissolve between offset neck contours."""
import ast
from contextlib import ExitStack
import inspect
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body


def _fixture(offset=4):
    # Same canonical neck, but the generated body has one displaced edge.
    # Every pixel is opaque: this is a neck/hair *interior* boundary, not a
    # request to shrink the figure's cutout or move the approved portrait.
    canonical = np.full((220, 220, 3), (34, 24, 18), np.uint8)
    donor = np.full((220, 220, 4), (34, 24, 18, 255), np.uint8)
    for row in range(220):
        skin = (135 + row // 8, 175 + row // 8, 207 + row // 8)
        canonical[row, 74:127] = skin
        donor[row, 74:127 + offset, :3] = skin
    # A sharply defined collar below the handoff must remain exactly authored.
    canonical[160:] = (92, 26, 192)
    donor[160:, :, :3] = (92, 26, 192)
    mask = np.repeat(np.clip(
        (146 - np.arange(220)) / 20, 0, 1)[:, None], 220, axis=1)
    mask = np.round(mask * 255).astype(np.uint8)
    landmarks = np.zeros((478, 2), np.float32)
    for index, landmark in enumerate(body.face.FACE_OVAL):
        angle = 2 * np.pi * index / len(body.face.FACE_OVAL)
        landmarks[landmark] = (
            100 + 50 * np.cos(angle), 95 + 55 * np.sin(angle))
    affine = np.array([[1, 0, 0], [0, 1, 0]], np.float64)
    return donor, canonical, mask, affine, landmarks


def _composite(donor, canonical, mask):
    weight = mask[:, :, None].astype(np.float32) / 255
    return np.round(
        canonical * weight + donor[:, :, :3] * (1 - weight)
    ).astype(np.uint8)


class StylizedNeckRegistrationTests(unittest.TestCase):
    def test_only_mismatched_donor_edge_is_registered_not_the_portrait(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        originals = [value.copy() for value in (
            donor, canonical, mask, affine, landmarks)]
        corrected, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks,
            source_medium="3d render")
        self.assertTrue(receipt["applied"])
        self.assertEqual(receipt["version"], 3)
        self.assertEqual([edge["side"] for edge in receipt["edges"]
                          if edge["applied"]], ["viewer-right"])
        right = receipt["edges"][1]
        self.assertAlmostEqual(right["offset_x"], -4, places=5)
        # The correspondence is between the exact edges sharing the alpha
        # handoff. After registration there is one edge, not two half-edges.
        before = _composite(donor, canonical, mask)
        after = _composite(corrected, canonical, mask)
        before_positions = [body._neck_row_edge(
            before, row, 116, 138)[0] for row in range(128, 144)]
        after_positions = [body._neck_row_edge(
            after, row, 116, 138)[0] for row in range(128, 144)]
        self.assertGreater(max(abs(np.diff(before_positions))), 3.0)
        self.assertLess(max(abs(np.diff(after_positions))), .2)
        self.assertTrue(np.array_equal(corrected[:, :, 3], donor[:, :, 3]))
        self.assertTrue(np.array_equal(corrected[160:], donor[160:]))
        self.assertTrue(np.array_equal(corrected[:120], donor[:120]))
        self.assertTrue(np.array_equal(corrected[:, :100], donor[:, :100]))
        for value, original in zip(
                (donor, canonical, mask, affine, landmarks), originals):
            self.assertTrue(np.array_equal(value, original))

    def test_aligned_neck_is_byte_identical_and_registration_is_idempotent(self):
        aligned = _fixture(offset=0)
        result, receipt = body._register_soft_3d_neck_seam(
            *aligned, source_medium="soft-3d")
        self.assertIs(result, aligned[0])
        self.assertFalse(receipt["applied"])
        donor, canonical, mask, affine, landmarks = _fixture()
        once, _ = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks, source_medium="3d render")
        twice, receipt = body._register_soft_3d_neck_seam(
            once, canonical, mask, affine, landmarks, source_medium="3d render")
        self.assertTrue(np.array_equal(once, twice))
        self.assertFalse(receipt["applied"])

    def test_registered_edge_returns_without_a_second_step_below_the_jaw(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        corrected, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks,
            source_medium="3d render")
        composite = _composite(corrected, canonical, mask)
        positions = [body._neck_row_edge(
            composite, row, 116, 138)[0] for row in range(144, 160)]
        self.assertLess(max(abs(np.diff(positions))), .60)
        self.assertGreater(positions[-1] - positions[0], 2.5)
        self.assertEqual(receipt["edges"][1]["return_profile"],
                         "contour-supported-smoothstep")
        self.assertTrue(np.array_equal(corrected[160:], donor[160:]))

    def test_extended_return_stops_at_the_end_of_the_neck_contour(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        donor[153:, :, :3] = (92, 26, 192)
        corrected, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks,
            source_medium="3d render")
        right = receipt["edges"][1]
        self.assertTrue(right["applied"])
        self.assertLessEqual(right["correction_row_bounds"][1], 153)
        self.assertTrue(np.array_equal(corrected[153:], donor[153:]))

    def test_photograph_and_ink_routes_are_byte_identical_without_inspection(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        for medium in (None, "photograph", "photorealistic", "illustration",
                       "anime", "2d cartoon", "unknown"):
            with self.subTest(medium=medium), mock.patch.object(
                    body, "_neck_row_edge", side_effect=AssertionError(
                        "non-3D input must not enter neck registration")):
                result, receipt = body._register_soft_3d_neck_seam(
                    donor, canonical, mask, affine, landmarks,
                    source_medium=medium)
            self.assertIs(result, donor)
            self.assertFalse(receipt["applied"])

    def test_large_offset_is_not_a_license_to_warp_anatomy(self):
        inputs = _fixture(offset=10)
        result, receipt = body._register_soft_3d_neck_seam(
            *inputs, source_medium="3d render")
        self.assertIs(result, inputs[0])
        self.assertFalse(receipt["applied"])

    def test_alpha_silhouette_and_interpolation_neighbours_are_protected(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        donor[136, 142, 3] = 0
        original = donor.copy()
        result, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks, source_medium="3d render")
        self.assertTrue(np.array_equal(result, original))
        self.assertFalse(receipt["applied"])
        self.assertEqual(receipt["edges"][1]["reason"], "not-opaque-interior")

    def test_opposite_colour_gradient_cannot_match_a_neck_edge(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        donor[:, :, :3] = 255 - donor[:, :, :3]
        result, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks, source_medium="3d render")
        self.assertIs(result, donor)
        self.assertFalse(receipt["applied"])

    def test_low_contrast_and_nonconsecutive_matches_do_not_modify_pixels(self):
        for low_contrast in (True, False):
            with self.subTest(low_contrast=low_contrast):
                donor, canonical, mask, affine, landmarks = _fixture()
                if low_contrast:
                    canonical[:] = (120, 120, 120)
                else:
                    canonical[136] = (120, 120, 120)
                result, receipt = body._register_soft_3d_neck_seam(
                    donor, canonical, mask, affine, landmarks,
                    source_medium="3d render")
                self.assertIs(result, donor)
                self.assertFalse(receipt["applied"])

    def test_inconsistent_offsets_are_rejected_not_averaged_into_a_new_contour(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        donor[:136, :, :3] = _fixture(offset=1)[0][:136, :, :3]
        donor[136:, :, :3] = _fixture(offset=5)[0][136:, :, :3]
        result, receipt = body._register_soft_3d_neck_seam(
            donor, canonical, mask, affine, landmarks, source_medium="3d render")
        self.assertIs(result, donor)
        self.assertFalse(receipt["applied"])
        self.assertEqual(receipt["edges"][1]["reason"], "ambiguous-offset")

    def test_install_only_registers_verified_soft_3d_replacement_heads(self):
        # Source routing guard: no photographic/ink output is passed through
        # the new helper, including a failed stylized matte's legacy blend.
        tree = ast.parse(inspect.getsource(body._install_sources))
        gates = []
        for node in ast.walk(tree):
            if isinstance(node, ast.If) and any(
                    isinstance(child, ast.Call)
                    and isinstance(child.func, ast.Name)
                    and child.func.id == "_register_soft_3d_neck_seam"
                    for statement in node.body for child in ast.walk(statement)):
                gates.append(ast.unparse(node.test))
        self.assertIn(
            "head_composite == 'replace' and stored_medium == '3d render'", gates)

    def test_install_writes_registered_twins_but_preserves_provider_sources(self):
        donor, canonical, mask, affine, landmarks = _fixture()
        for medium in ("3d render", "illustration", "photograph"):
            with self.subTest(medium=medium), tempfile.TemporaryDirectory() as path:
                avatar = Path(path)
                key_path = avatar / "keyframe.png"
                cv2.imwrite(str(key_path), canonical)
                sources = {}
                for view in body.BODY_VIEWS:
                    source = avatar / f"input-{view}.png"
                    cv2.imwrite(str(source), donor[:, :, :3])
                    sources[view] = str(source)

                def cutout(_source, destination, *_args, **_kwargs):
                    return cv2.imwrite(destination, donor)

                def head_mask(_cutout, _landmarks, destination, **_kwargs):
                    image = np.full((*mask.shape, 4), 255, np.uint8)
                    image[:, :, 3] = mask
                    cv2.imwrite(destination, image)
                    return "full-silhouette"

                def clear_mask(_body, _mask, _affine, _landmarks,
                               _bounds, destination, **_kwargs):
                    cv2.imwrite(destination, np.zeros_like(donor))
                    return {}

                def identity(_path, _keyframe, destination, *_args, **_kwargs):
                    cv2.imwrite(destination, donor)
                    return donor.copy()

                patches = {
                    "_identity_reference": lambda _path: str(key_path),
                    "_stored_source_medium": lambda _path: medium,
                    "_render_body_cutout": cutout,
                    "_face_transform": lambda *_args, **_kwargs: (
                        affine, {"face_bounds": [50, 40, 100, 110]}, landmarks),
                    "_canonical_head_replacement_core": lambda *_args: None,
                    "_identity_cutout": identity,
                    "_stylized_head_mask": head_mask,
                    "_head_mask": head_mask,
                    "_stylized_head_clear_mask": clear_mask,
                    "_constrain_head_mask": lambda *_args: None,
                    "_composite_head_proportion_failure": lambda *_args, **_kw: None,
                    "_seam_tone_match": lambda *_args: None,
                }
                with ExitStack() as stack:
                    for name, value in patches.items():
                        stack.enter_context(mock.patch.object(body, name, value))
                    stack.enter_context(mock.patch.object(
                        body.body_alpha, "refine", side_effect=lambda _src, rgba, **_kw: (
                            rgba, {"valid": True, "removed_plate_pixels": 0})))
                    stack.enter_context(mock.patch.object(
                        body.body_proportion, "assess", return_value={"measurable": False}))
                    stack.enter_context(mock.patch.object(
                        body.body_proportion, "failure", return_value=None))
                    metadata = body._install_sources(
                        path, sources, "fixture", {"style": "soft-3d"},
                        log=lambda _message: None)
                runtime_body = cv2.imread(str(avatar / "body/body.png"), -1)
                front = cv2.imread(str(avatar / "body/body-front.png"), -1)
                self.assertTrue(np.array_equal(runtime_body, front))
                self.assertTrue(np.array_equal(runtime_body[:, :, 3], donor[:, :, 3]))
                self.assertEqual((avatar / "body/source-front.png").read_bytes(),
                                 Path(sources["front"]).read_bytes())
                for view in ("side", "back"):
                    self.assertTrue(np.array_equal(cv2.imread(
                        str(avatar / f"body/body-{view}.png"), -1), donor))
                stored = json.loads((avatar / "body/body.json").read_text())
                if medium == "3d render":
                    self.assertTrue(stored["neck_registration"]["applied"])
                    self.assertFalse(np.array_equal(runtime_body, donor))
                    self.assertEqual(stored["neck_registration"],
                                     metadata["views"]["front"]["neck_registration"])
                else:
                    self.assertNotIn("neck_registration", stored)
                    self.assertTrue(np.array_equal(runtime_body, donor))


if __name__ == "__main__":
    unittest.main()
