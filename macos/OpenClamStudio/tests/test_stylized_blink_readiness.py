"""Compact soft-3D eyes need real full-eye blinks, never silent static eyes."""
from contextlib import ExitStack
import inspect
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import blink, export, face


def _compact_fixture():
    key = np.full((200, 400, 3), (110, 159, 215), np.uint8)
    shut = key.copy()
    landmarks = np.full((478, 2), (200, 100), np.float32)
    glasses = np.zeros(key.shape[:2], np.uint8)
    eyes = {}
    for side, (cx, cy) in zip(blink.SIDES, ((112, 89), (285, 86))):
        cv2.ellipse(key, (cx, cy), (42, 17), 0, 0, 360,
                    (241, 241, 241), -1)
        # The iris touches both lids and splits the white into two crescents.
        cv2.ellipse(key, (cx, cy), (16, 19), 0, 0, 360, (38, 58, 22), -1)
        cv2.circle(key, (cx, cy), 9, (12, 12, 12), -1)
        curve = np.array([
            (cx - 44, cy), (cx - 27, cy + 15), (cx, cy + 20),
            (cx + 27, cy + 15), (cx + 44, cy),
        ], np.int32)
        cv2.polylines(shut, [curve], False, (25, 25, 25), 3, cv2.LINE_AA)
        for direction in (-1, 1):
            for distance in (24, 30, 36):
                cv2.line(shut, (cx + direction * distance, cy + 14),
                         (cx + direction * (distance + 3), cy + 20),
                         (25, 25, 25), 2, cv2.LINE_AA)
        cv2.rectangle(glasses, (cx - 64, cy - 40),
                      (cx + 64, cy + 46), 255, 6)
        angles = np.linspace(0, 2 * np.pi, len(blink.EYE[side]), endpoint=False)
        landmarks[blink.EYE[side], 0] = cx + np.cos(angles) * 44
        landmarks[blink.EYE[side], 1] = cy + np.sin(angles) * 19
        eyes[side] = {"box": [cx - 84, cy - 49, 168, 106]}
    key[glasses > 0] = (18, 18, 18)
    shut[glasses > 0] = key[glasses > 0]
    return key, shut, landmarks, eyes, glasses


def _registration_mocks(stack, landmarks):
    identity = np.array([[1., 0., 0.], [0., 1., 0.]])
    stack.enter_context(mock.patch.object(
        face, "detect_for_intake", return_value=(landmarks, np.eye(4), {})))
    stack.enter_context(mock.patch.object(
        cv2, "estimateAffine2D", return_value=(identity, None)))
    stack.enter_context(mock.patch.object(
        cv2, "estimateAffinePartial2D", return_value=(identity, None)))
    stack.enter_context(mock.patch.object(blink, "_aperture", return_value=12.))


class CompactSoft3DBlinkTests(unittest.TestCase):
    def test_compact_masks_keep_both_crescents_and_exclude_white_background(self):
        key, _, landmarks, eyes, _ = _compact_fixture()
        key[:, 373:] = 250  # outside the head, not a third eye crescent
        self.assertTrue(any(export._stylized_eye_alpha(key, item) is None
                            for item in eyes.values()))
        masks = export._soft3d_compact_eye_masks(key, landmarks)
        self.assertIsNotNone(masks)
        for side in blink.SIDES:
            box, alpha = masks[side]
            x, y, width, height = box
            points = landmarks[blink.EYE[side]]
            centre = (points.min(0) + points.max(0)) * .5
            rows, columns = np.nonzero(alpha > 96)
            self.assertLess(columns.min() + x, centre[0] - 20)
            self.assertGreater(columns.max() + x, centre[0] + 20)
            self.assertLess(x + width, 373)
            self.assertGreater(rows.max() - rows.min(), 20)

    def test_compact_masks_fail_on_one_crescent_missing_eye_or_bad_landmarks(self):
        key, _, landmarks, _, _ = _compact_fixture()
        invalid = [None, np.zeros((3, 2)), np.full((478, 2), np.nan),
                   np.zeros((478, 3)), np.zeros((478, 2))]
        for points in invalid:
            with self.subTest(points=None if points is None else points.shape):
                self.assertIsNone(export._soft3d_compact_eye_masks(key, points))
        for x0, x1 in ((0, 200), (112, 200)):
            incomplete = key.copy()
            incomplete[60:115, x0:x1] = (110, 159, 215)
            self.assertIsNone(
                export._soft3d_compact_eye_masks(incomplete, landmarks))

    def test_compact_topology_accepts_full_sparse_lash_not_nested_eye_or_block(self):
        alpha = np.zeros((120, 160), np.uint8)
        cv2.ellipse(alpha, (80, 44), (47, 19), 0, 0, 360, 255, -1)
        patch = np.full((120, 160, 3), (110, 159, 215), np.uint8)
        curve = np.array([(28, 41), (47, 65), (80, 70),
                          (113, 65), (132, 41)], np.int32)
        cv2.polylines(patch, [curve], False, (22, 22, 22), 3, cv2.LINE_AA)
        self.assertIsNone(export._stylized_lid_topology(patch, alpha))
        self.assertIsNotNone(export._stylized_lid_topology(
            patch, alpha, compact_eye=True))
        block = np.full_like(patch, (110, 159, 215))
        cv2.rectangle(block, (29, 49), (131, 71), (22, 22, 22), -1)
        self.assertIsNone(export._stylized_lid_topology(
            block, alpha, compact_eye=True))
        small = np.full_like(patch, (110, 159, 215))
        cv2.line(small, (59, 60), (101, 60), (22, 22, 22), 3)
        self.assertIsNone(export._stylized_lid_topology(
            small, alpha, compact_eye=True))

    def test_static_glasses_mask_excludes_brown_shadow_and_open_lashes(self):
        key = np.full((60, 80, 3), (110, 159, 215), np.uint8)
        shut = key.copy()
        # Both the frame and open lash touch the crop boundary. Dark brown
        # upper-eye shadow in the closed source used to preserve both, which
        # left an old upper-lash arc around the new closed lid.
        key[7:11] = (18, 18, 18)
        shut[7:11] = (18, 18, 18)
        key[23:27] = (12, 12, 12)
        shut[23:27] = (15, 27, 62)
        self.assertLess(int(cv2.cvtColor(shut, cv2.COLOR_BGR2GRAY)[24, 30]), 45)
        guard = np.zeros((60, 80), np.uint8)
        guard[7:11, 40:50] = 255
        result = export._compact_static_eye_art(key, shut, guard)
        self.assertTrue(np.all(result[8:10, 5:35] == 255))
        self.assertEqual(0, np.count_nonzero(result[23:27]))
        self.assertEqual(0, np.count_nonzero(result[guard > 0]))

    def test_compact_publisher_closes_both_eyes_without_changing_glasses(self):
        key, shut, landmarks, eyes, glasses = _compact_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration_mocks(stack, landmarks)
            stack.enter_context(mock.patch.object(
                export, "_harmonic_stylized_skin",
                side_effect=AssertionError("registered 3D eyelids need authored skin")))
            logs = []
            result = export.preflight_stylized_blink(
                directory, "3d render", neutral=key, eyes=eyes, log=logs.append)
            self.assertTrue(any("compact-eye contours" in line for line in logs))
            rendered = key.copy()
            for side in blink.SIDES:
                entry = result["metadata"][side]
                x, y, width, height = entry["box"]
                plate = cv2.imdecode(np.frombuffer(
                    result["assets"][f"stylized-blink-{side}.png"], np.uint8),
                    cv2.IMREAD_UNCHANGED)
                opacity = plate[:, :, 3:4].astype(np.float32) / 255
                old = rendered[y:y + height, x:x + width].copy()
                rendered[y:y + height, x:x + width] = np.clip(
                    plate[:, :, :3] * opacity + old * (1 - opacity),
                    0, 255).astype(np.uint8)
            hsv = cv2.cvtColor(rendered, cv2.COLOR_BGR2HSV)
            self.assertEqual(0, np.count_nonzero((hsv[:, :, 1] < 72)
                                               & (hsv[:, :, 2] > 155)))
            self.assertTrue(np.array_equal(rendered[glasses > 0], key[glasses > 0]))
            self.assertTrue(np.array_equal(rendered[145:], key[145:]))
            self.assertEqual(["raw"], os.listdir(directory))

    def test_compact_unregistered_skin_rejects_instead_of_flat_oval_fallback(self):
        key, shut, landmarks, eyes, _ = _compact_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration_mocks(stack, landmarks)
            stack.enter_context(mock.patch.object(
                export, "_stylized_flat_skin_registration", return_value=None))
            harmonic = stack.enter_context(mock.patch.object(
                export, "_harmonic_stylized_skin", side_effect=AssertionError))
            logs = []
            with self.assertRaises(export.StylizedBlinkNotReady):
                export.preflight_stylized_blink(
                    directory, "3d render", neutral=key, eyes=eyes, log=logs.append)
            harmonic.assert_not_called()
            self.assertTrue(any("skin is not registered" in line for line in logs))

    def test_illustrations_do_not_enter_compact_soft3d_fallback(self):
        key, shut, landmarks, eyes, _ = _compact_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration_mocks(stack, landmarks)
            fallback = stack.enter_context(mock.patch.object(
                export, "_soft3d_compact_eye_masks",
                side_effect=AssertionError("compact fallback is soft3D-only")))
            result = export._publish_stylized_blink_source(
                key, directory, eyes, directory, "illustration", log=lambda _: None)
            self.assertIsNone(result)
            fallback.assert_not_called()


class StylizedBlinkReadinessTests(unittest.TestCase):
    def test_photo_and_unknown_preflight_are_noop_before_reading_assets(self):
        with mock.patch.object(export.cv2, "imread", side_effect=AssertionError):
            for medium in ("photograph", "unknown", "corrupt-future-value"):
                self.assertIsNone(export.preflight_stylized_blink(
                    "/nonexistent", medium, log=lambda _: None))

    def test_preflight_rejection_is_actionable_and_cleans_scratch(self):
        seen = []

        def reject(_neutral, _home, _eyes, destination, _medium, **_kwargs):
            seen.append(destination)
            self.assertTrue(os.path.isdir(destination))
            return None

        with mock.patch.object(export, "_publish_stylized_blink_source",
                               side_effect=reject):
            with self.assertRaisesRegex(export.StylizedBlinkNotReady,
                                        "Blink not ready.*Regenerate.*rebuild"):
                export.preflight_stylized_blink(
                    "/nonexistent", "illustration", neutral=np.zeros((96, 96, 3),
                                                                       np.uint8),
                    eyes={}, log=lambda _: None)
        self.assertEqual(1, len(seen))
        self.assertFalse(os.path.exists(seen[0]))

    def test_preflight_rejects_missing_or_malformed_published_plate(self):
        key = np.zeros((96, 96, 3), np.uint8)
        metadata = {"mode": "semantic-eye-switch", **{
            side: {"src": f"assets/stylized-blink-{side}.png",
                   "box": [10, 10, 20, 20]} for side in blink.SIDES}}
        for defect in ("missing", "rgb", "transparent", "size", "wrong-path"):
            def publish(_neutral, _home, _eyes, destination, _medium, **_kwargs):
                for side in blink.SIDES:
                    if defect == "missing" and side == "l":
                        continue
                    shape = ((20, 20, 3) if defect == "rgb" else
                             (10, 20, 4) if defect == "size" else (20, 20, 4))
                    pixels = np.full(shape, 0 if defect == "transparent" else 255,
                                     np.uint8)
                    cv2.imwrite(os.path.join(destination,
                                             f"stylized-blink-{side}.png"), pixels)
                return (dict(metadata, l={"src": "assets/other.png",
                                          "box": [10, 10, 20, 20]})
                        if defect == "wrong-path" else metadata)
            with self.subTest(defect=defect), mock.patch.object(
                    export, "_publish_stylized_blink_source", side_effect=publish):
                with self.assertRaises(export.StylizedBlinkNotReady):
                    export.preflight_stylized_blink(
                        "/unused", "3d render", neutral=key, eyes={},
                        log=lambda _: None)

    def test_fresh_export_failure_preserves_existing_destination_bytes(self):
        key, _, _, eyes, _ = _compact_fixture()
        with tempfile.TemporaryDirectory() as directory:
            visemes = os.path.join(directory, "visemes")
            destination = os.path.join(directory, "runtime")
            os.mkdir(visemes)
            os.mkdir(destination)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), key)
            cv2.imwrite(os.path.join(visemes, "v_blink.jpg"), key)
            old = {"manifest.json": b'{"approved":true}',
                   "sil_open.jpg": b"approved face", "body.png": b"approved body"}
            for name, payload in old.items():
                with open(os.path.join(destination, name), "wb") as handle:
                    handle.write(payload)
            with mock.patch.object(export.reg, "adir", return_value=directory), \
                    mock.patch.object(export.blink, "build", return_value={"eyes": eyes}), \
                    mock.patch.object(export, "_publish_stylized_blink_source",
                                      return_value=None), \
                    mock.patch.object(export.expression, "build",
                                      side_effect=AssertionError("must fail before rendering")):
                with self.assertRaises(export.StylizedBlinkNotReady):
                    export.export("fixture", destination, source_dir=directory,
                                  manifest_data={"status": "ready",
                                                 "source_metrics": {
                                                     "source_medium": "3d render"}},
                                  require_stylized_blink=True, log=lambda _: None)
            self.assertEqual(set(old), set(os.listdir(destination)))
            for name, payload in old.items():
                with open(os.path.join(destination, name), "rb") as handle:
                    self.assertEqual(payload, handle.read())

    def test_legacy_export_defaults_do_not_enable_gate(self):
        self.assertIs(False, inspect.signature(export.export).parameters[
            "require_stylized_blink"].default)
        self.assertNotIn("preflight_stylized_blink(",
                         inspect.getsource(export.publish_pet_assets))


if __name__ == "__main__":
    unittest.main()
