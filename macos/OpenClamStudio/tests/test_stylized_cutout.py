"""Focused regressions for explicit non-photographic plate extraction."""
import json
import os
import tempfile
import types
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, cutout, motion


def _white_cartoon(size=112, background=(255, 255, 255)):
    scale = 4
    canvas = np.full(
        (size * scale, size * scale, 3), background, np.uint8)
    cv2.circle(
        canvas, (size * 2, size * 2), size * 5 // 4,
        (35, 55, 185), -1, cv2.LINE_AA)
    # An enclosed white eye/teeth patch is foreground anatomy, not plate.
    cv2.rectangle(
        canvas, (size * 7 // 4, size * 7 // 4),
        (size * 9 // 4, size * 2), (255, 255, 255), -1)
    return cv2.resize(
        canvas, (size, size), interpolation=cv2.INTER_AREA)


class StylizedFlatPlateTests(unittest.TestCase):
    def test_uniform_light_neutral_plate_removes_only_external_background(self):
        source_image = _white_cartoon(background=(226, 227, 230))
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            destination = os.path.join(directory, "cutout.png")
            cv2.imwrite(source, source_image)
            with mock.patch.object(cutout, "helper_path", return_value=None):
                result = cutout.render(
                    source, destination, log=lambda _message: None,
                    tight=True, allow_stylized=True)
            rgba = cv2.imread(destination, cv2.IMREAD_UNCHANGED)

        self.assertEqual(
            "border-connected-light-neutral-plate", result["method"])
        self.assertEqual(0, int(rgba[2, 2, 3]))
        self.assertEqual(255, int(rgba[52, 52, 3]))
        self.assertEqual((255, 255, 255), tuple(rgba[52, 52, :3]))

    def test_white_plate_bypasses_vision_and_preserves_enclosed_white(self):
        source_image = _white_cartoon()
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            destination = os.path.join(directory, "cutout.png")
            cv2.imwrite(source, source_image)
            with mock.patch.object(cutout, "helper_path", return_value=None):
                result = cutout.render(
                    source, destination, log=lambda _message: None,
                    tight=True, allow_stylized=True)
            rgba = cv2.imread(destination, cv2.IMREAD_UNCHANGED)

        self.assertEqual("border-connected-white-plate", result["method"])
        self.assertEqual(0, int(rgba[2, 2, 3]))
        self.assertEqual(255, int(rgba[52, 52, 3]))
        self.assertEqual((255, 255, 255), tuple(rgba[52, 52, :3]))
        soft = rgba[:, :, 3][
            (rgba[:, :, 3] > 8) & (rgba[:, :, 3] < 246)]
        self.assertGreater(soft.size, 0)
        # Tight cleanup repaints partial pixels from opaque subject colour;
        # the white plate cannot survive as a visible contour halo.
        edge_colours = rgba[:, :, :3][
            (rgba[:, :, 3] > 8) & (rgba[:, :, 3] < 246)]
        self.assertLess(float(np.percentile(edge_colours, 95)), 240.0)

    def test_green_plate_is_border_connected_and_despilled_at_soft_edge(self):
        size = 112
        scale = 4
        canvas = np.full((size * scale, size * scale, 3), (0, 255, 0), np.uint8)
        cv2.circle(
            canvas, (size * 2, size * 2), size * 5 // 4,
            (30, 40, 210), -1, cv2.LINE_AA)
        source_image = cv2.resize(
            canvas, (size, size), interpolation=cv2.INTER_AREA)
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            destination = os.path.join(directory, "cutout.png")
            cv2.imwrite(source, source_image)
            with mock.patch.object(cutout, "helper_path", return_value=None):
                result = cutout.render(
                    source, destination, log=lambda _message: None,
                    tight=True, allow_stylized=True)
            rgba = cv2.imread(destination, cv2.IMREAD_UNCHANGED)

        self.assertEqual("border-connected-green-plate", result["method"])
        self.assertEqual(0, int(rgba[2, 2, 3]))
        self.assertEqual(255, int(rgba[56, 56, 3]))
        edge = (rgba[:, :, 3] > 8) & (rgba[:, :, 3] < 246)
        self.assertGreater(int(edge.sum()), 0)
        # Core-colour propagation removes saturated green from the soft rim.
        self.assertLess(
            float(np.percentile(rgba[:, :, 1][edge], 95)), 170.0)

    def test_photo_default_keeps_vision_even_on_a_white_background(self):
        source_image = _white_cartoon()
        helper_image = np.zeros(source_image.shape[:2] + (4,), np.uint8)
        helper_image[8:20, 8:20, :3] = (20, 30, 40)
        helper_image[8:20, 8:20, 3] = 255
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            destination = os.path.join(directory, "cutout.png")
            cv2.imwrite(source, source_image)

            def run(*_args, **_kwargs):
                cv2.imwrite(destination, helper_image)
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(cutout, "helper_path", return_value="helper"), \
                    mock.patch.object(cutout.subprocess, "run", side_effect=run):
                result = cutout.render(
                    source, destination, log=lambda _message: None)
            rgba = cv2.imread(destination, cv2.IMREAD_UNCHANGED)

        self.assertEqual("macos-vision-person-segmentation", result["method"])
        self.assertEqual(255, int(rgba[10, 10, 3]))
        self.assertEqual(0, int(rgba[56, 56, 3]))

    def test_pose_receipt_still_comes_from_vision_when_plate_matte_wins(self):
        source_image = _white_cartoon()
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            destination = os.path.join(directory, "cutout.png")
            pose = os.path.join(directory, "pose.json")
            cv2.imwrite(source, source_image)

            def run(*_args, **_kwargs):
                helper = np.zeros(source_image.shape[:2] + (4,), np.uint8)
                helper[30:80, 30:80, 3] = 255
                cv2.imwrite(destination, helper)
                with open(pose, "w", encoding="utf-8") as handle:
                    json.dump({"width": 112, "height": 112, "joints": {}}, handle)
                return types.SimpleNamespace(returncode=0, stdout="", stderr="")

            with mock.patch.object(cutout, "helper_path", return_value="helper"), \
                    mock.patch.object(cutout.subprocess, "run", side_effect=run):
                result = cutout.render(
                    source, destination, pose_destination=pose,
                    log=lambda _message: None, allow_stylized=True)
            rgba = cv2.imread(destination, cv2.IMREAD_UNCHANGED)
            with open(pose, encoding="utf-8") as handle:
                pose_receipt = json.load(handle)

        self.assertEqual(112, pose_receipt["width"])
        self.assertEqual(112, pose_receipt["height"])
        self.assertEqual("border-connected-white-plate", result["method"])
        self.assertEqual(0, int(rgba[2, 2, 3]))
        self.assertEqual(255, int(rgba[56, 56, 3]))


class StylizedRoutingTests(unittest.TestCase):
    def test_body_medium_comes_only_from_stored_intake_evidence(self):
        with tempfile.TemporaryDirectory() as avatar:
            manifest_path = os.path.join(avatar, "manifest.json")
            self.assertFalse(body._allow_stylized_source(avatar))
            for value, expected in (
                    ("photograph", False),
                    ("unknown", False),
                    ("future-corrupt-label", False),
                    ("illustration", True),
                    ("anime", True)):
                with open(manifest_path, "w", encoding="utf-8") as handle:
                    json.dump({
                        "source_metrics": {"source_medium": value},
                        # Requested/provider style must never lower local gates.
                        "body": {"options": {
                            "style": "anime", "medium": "illustration",
                        }},
                    }, handle)
                self.assertEqual(
                    expected, body._allow_stylized_source(avatar), value)

    def test_body_unknown_original_does_not_inherit_generated_head_style(self):
        with tempfile.TemporaryDirectory() as avatar:
            with open(os.path.join(avatar, "manifest.json"), "w",
                      encoding="utf-8") as handle:
                json.dump({
                    "source_metrics": {"source_medium": "unknown"},
                    "metrics": {"source_medium": "illustration"},
                    "head": {"source_medium": "illustration"},
                }, handle)
            self.assertEqual("photograph", body._stored_source_medium(avatar))
            self.assertFalse(body._allow_stylized_source(avatar))

    def test_body_corrupt_original_report_does_not_fall_through(self):
        with tempfile.TemporaryDirectory() as avatar:
            with open(os.path.join(avatar, "manifest.json"), "w",
                      encoding="utf-8") as handle:
                json.dump({
                    "source_metrics": "damaged-report",
                    "metrics": {"source_medium": "illustration"},
                    "head": {"source_medium": "illustration"},
                }, handle)
            self.assertEqual("photograph", body._stored_source_medium(avatar))
            self.assertFalse(body._allow_stylized_source(avatar))

    def test_body_face_detector_uses_intake_only_when_explicitly_stylized(self):
        image = np.zeros((80, 80, 3), np.uint8)
        landmarks = np.zeros((478, 2), np.float32)
        with mock.patch.object(
                body.face, "detect_for_intake",
                return_value=(landmarks, None, {"source_medium": "illustration"})) \
                as intake, mock.patch.object(body.face, "detect") as strict:
            body._detect(image, "cartoon", allow_stylized=True)
        intake.assert_called_once()
        strict.assert_not_called()

        with mock.patch.object(
                body.face, "detect", return_value=(landmarks, None)) as strict, \
                mock.patch.object(body.face, "detect_for_intake") as intake:
            body._detect(image, "photo")
        strict.assert_called_once()
        intake.assert_not_called()

    def test_stylized_identity_overlay_falls_back_when_cutout_is_unusable(self):
        keyframe = _white_cartoon(80)
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "keyframe.png")
            destination = os.path.join(directory, "identity.png")
            cv2.imwrite(source, keyframe)
            with mock.patch.object(
                    body.cutout, "render", return_value=None) as render:
                rgba = body._identity_cutout(
                    source, keyframe, destination, True,
                    log=lambda _message: None)
            stored = cv2.imread(destination, cv2.IMREAD_UNCHANGED)
        render.assert_called_once_with(
            source, destination, log=mock.ANY, tight=True,
            allow_stylized=True)
        self.assertTrue(np.all(rgba[:, :, 3] == 255))
        self.assertTrue(np.array_equal(rgba, stored))

    def test_stylized_identity_overlay_uses_valid_local_subject_silhouette(self):
        keyframe = _white_cartoon(112)
        landmarks = np.zeros((478, 2), np.float32)
        for point_index, landmark_index in enumerate(body.face.FACE_OVAL):
            angle = 2.0 * np.pi * point_index / len(body.face.FACE_OVAL)
            landmarks[landmark_index] = (
                56.0 + 24.0 * np.cos(angle),
                56.0 + 30.0 * np.sin(angle),
            )
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "keyframe.png")
            destination = os.path.join(directory, "identity.png")
            cv2.imwrite(source, keyframe)
            rgba = body._identity_cutout(
                source, keyframe, destination, True,
                log=lambda _message: None, landmarks=landmarks)
        self.assertEqual(0, int(rgba[0, 0, 3]))
        self.assertEqual(255, int(rgba[56, 56, 3]))
        self.assertTrue(body._stylized_identity_cutout_is_safe(
            rgba, landmarks))

    def test_motion_medium_reader_is_strict_for_legacy_and_photo_manifests(self):
        with tempfile.TemporaryDirectory() as avatar:
            self.assertEqual("photograph", motion.body_source_medium(avatar))
            body_dir = os.path.join(avatar, "body")
            os.makedirs(body_dir)
            for value, expected in (
                    ("photo", "photograph"),
                    ("photograph", "photograph"),
                    ("unknown", "photograph"),
                    ("future-corrupt-label", "photograph"),
                    ("anime", "anime"),
                    ("illustration", "illustration")):
                with open(os.path.join(body_dir, "body.json"), "w") as handle:
                    json.dump({"options": {"medium": value}}, handle)
                self.assertEqual(expected, motion.body_source_medium(avatar))

    def test_stylized_motion_skips_rvm_and_routes_plate_matte_with_pose(self):
        frame = np.full((64, 48, 3), 255, np.uint8)
        frame[10:58, 16:32] = (30, 45, 170)
        rgba = np.dstack((
            frame,
            np.where(np.any(frame < 240, axis=2), 255, 0).astype(np.uint8),
        ))
        calls = []

        def render(_source, destination, **kwargs):
            calls.append(kwargs)
            cv2.imwrite(destination, rgba)
            with open(kwargs["pose_destination"], "w") as handle:
                json.dump({"width": 48, "height": 64, "joints": {}}, handle)
            return {"method": "border-connected-white-plate"}

        with tempfile.TemporaryDirectory() as workspace:
            with (
                mock.patch.object(
                    motion, "_is_green_screen", return_value=False),
                mock.patch.object(motion, "_rvm_matte") as rvm,
                mock.patch.object(
                    motion.cutout, "render", side_effect=render),
                mock.patch.object(
                    motion, "_refine_white_matte",
                    side_effect=lambda _src, matte: matte),
                mock.patch.object(
                    motion, "_stabilise_segmented",
                    side_effect=lambda segmented, _poses,
                    source_frames=None, allow_stylized=False: segmented),
                mock.patch.object(
                    motion.cutout, "_decontaminate_edges",
                    side_effect=lambda image: image),
                mock.patch.object(
                    motion, "_source_alpha_integrity_quality",
                    return_value={"available": True, "valid": True}),
                mock.patch.object(
                    motion, "_color_fidelity_quality",
                    return_value={"available": True, "valid": True}),
            ):
                frames, _poses, method, _quality = motion._segment_frames(
                    [frame], workspace, lambda _message: None,
                    allow_stylized=True)

        rvm.assert_not_called()
        self.assertEqual(1, len(frames))
        self.assertEqual("border-connected-white-plate", method)
        self.assertIs(True, calls[0]["allow_stylized"])
        self.assertIs(False, calls[0]["tight"])


if __name__ == "__main__":
    unittest.main()
