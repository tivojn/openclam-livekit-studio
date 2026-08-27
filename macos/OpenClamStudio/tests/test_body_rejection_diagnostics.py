"""Private evidence and message regressions for rejected body alpha plates."""

import hashlib
import json
import os
import stat
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, body_alpha


class BodyRejectionDiagnosticTests(unittest.TestCase):
    def test_front_proportion_preflight_archives_private_measurement_evidence(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            keyframe = np.full((80, 80, 3), 128, np.uint8)
            self.assertTrue(cv2.imwrite(
                os.path.join(avatar_dir, "keyframe.png"), keyframe))
            source = np.full((120, 80, 3), 255, np.uint8)
            source[8:115, 27:53] = (45, 30, 210)
            source_path = os.path.join(avatar_dir, "source-front.png")
            self.assertTrue(cv2.imwrite(source_path, source))
            with open(source_path, "rb") as handle:
                source_bytes = handle.read()

            body_dir = os.path.join(avatar_dir, "body")
            os.makedirs(body_dir)
            sentinel = os.path.join(body_dir, "approved.txt")
            with open(sentinel, "w", encoding="utf-8") as handle:
                handle.write("approved body stays installed")

            refined = np.zeros((120, 80, 4), np.uint8)
            refined[8:115, 27:53, :3] = (45, 30, 210)
            refined[8:115, 27:53, 3] = 255
            alpha_report = {"valid": True, "reason": ""}
            alignment = {
                "face_bounds": [31, 10, 18, 27],
                "scale": 0.31,
                "residual_median_px": 1.2,
            }
            proportion_report = {
                "v": 1,
                "valid": False,
                "measurable": True,
                "gate_required": True,
                "gate_trigger": "style:editorial",
                "style": "editorial",
                "person_bounds": [27, 8, 26, 107],
                "face_bounds": [31.0, 10.0, 18.0, 27.0],
                "apparent_heads_tall": 5.91,
                "reason": "generated editorial/runway body is head-heavy",
            }

            def render(_source, destination, **_options):
                return bool(cv2.imwrite(destination, refined))

            messages = []
            with mock.patch.object(
                    body.cutout, "render", side_effect=render), \
                    mock.patch.object(
                        body.body_alpha, "refine",
                        return_value=(refined, alpha_report)), \
                    mock.patch.object(
                        body, "_face_transform",
                        return_value=(np.eye(2, 3), alignment, None)), \
                    mock.patch.object(
                        body.body_proportion, "assess",
                        return_value=proportion_report):
                with self.assertRaisesRegex(
                        body.GeneratedBodyProportionError, "head-heavy"):
                    body._preflight_front_source(
                        avatar_dir, source_path, {"style": "editorial"},
                        log=messages.append)

            with open(sentinel, encoding="utf-8") as handle:
                self.assertEqual(
                    "approved body stays installed", handle.read())
            self.assertEqual(["approved.txt"], os.listdir(body_dir))
            rejected_root = os.path.join(
                avatar_dir, "diag", "body-rejections")
            attempts = [
                os.path.join(rejected_root, name)
                for name in os.listdir(rejected_root)
                if not name.startswith(".")
            ]
            self.assertEqual(1, len(attempts))
            attempt = attempts[0]
            self.assertIn("-front-proportion", os.path.basename(attempt))
            self.assertEqual(
                stat.S_IMODE(os.stat(rejected_root).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(attempt).st_mode), 0o700)

            archived_source = os.path.join(attempt, "source.png")
            archived_refined = os.path.join(attempt, "refined.png")
            archived_report = os.path.join(attempt, "report.json")
            for path in (archived_source, archived_refined, archived_report):
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            with open(archived_source, "rb") as handle:
                self.assertEqual(source_bytes, handle.read())
            np.testing.assert_array_equal(
                refined, cv2.imread(archived_refined, cv2.IMREAD_UNCHANGED))
            with open(archived_report, encoding="utf-8") as handle:
                manifest = json.load(handle)
            self.assertEqual("front", manifest["view"])
            self.assertEqual(
                "body-proportion", manifest["rejection_kind"])
            self.assertFalse(manifest["installed"])
            self.assertEqual(
                proportion_report, manifest["proportion_quality"])
            self.assertEqual(alignment, manifest["alignment"])
            self.assertEqual(alpha_report, manifest["alpha_quality"])
            self.assertEqual("refined.png", manifest["refined_file"])
            self.assertEqual(
                hashlib.sha256(source_bytes).hexdigest(),
                manifest["source_sha256"])
            self.assertTrue(any(
                "archived rejected front proportion diagnostic" in message
                for message in messages))
            self.assertFalse(any(
                name.startswith(".body-front-preflight-")
                for name in os.listdir(avatar_dir)))

    def test_proportion_diagnostic_write_failure_never_masks_hard_gate(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            keyframe = np.full((80, 80, 3), 128, np.uint8)
            cv2.imwrite(os.path.join(avatar_dir, "keyframe.png"), keyframe)
            source_path = os.path.join(avatar_dir, "source-front.png")
            cv2.imwrite(
                source_path, np.full((120, 80, 3), 255, np.uint8))
            rgba = np.zeros((120, 80, 4), np.uint8)
            rgba[8:115, 27:53, 3] = 255

            def render(_source, destination, **_options):
                return bool(cv2.imwrite(destination, rgba))

            report = {
                "valid": False,
                "measurable": True,
                "reason": "real head-heavy proportion failure",
            }
            messages = []
            with mock.patch.object(
                    body.cutout, "render", side_effect=render), \
                    mock.patch.object(
                        body.body_alpha, "refine",
                        return_value=(rgba, {"valid": True})), \
                    mock.patch.object(
                        body, "_face_transform",
                        return_value=(
                            np.eye(2, 3), {"face_bounds": [31, 10, 18, 27]},
                            None)), \
                    mock.patch.object(
                        body.body_proportion, "assess", return_value=report), \
                    mock.patch.object(
                        body, "_archive_rejected_body_proportion",
                        side_effect=OSError("diagnostic disk full")):
                with self.assertRaisesRegex(
                        body.GeneratedBodyProportionError,
                        "real head-heavy proportion failure"):
                    body._preflight_front_source(
                        avatar_dir, source_path, {"style": "editorial"},
                        log=messages.append)

            self.assertTrue(any(
                "diagnostic disk full" in message for message in messages))

    def test_proportion_diagnostics_share_the_twelve_attempt_cap(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            source_path = os.path.join(avatar_dir, "source-front.png")
            cv2.imwrite(
                source_path, np.full((20, 12, 3), 255, np.uint8))
            rejected_root = os.path.join(
                avatar_dir, "diag", "body-rejections")
            os.makedirs(rejected_root)
            for index in range(13):
                os.makedirs(os.path.join(
                    rejected_root, f"0000000000000000000{index:02d}-side-alpha"))

            destination = body._archive_rejected_body_proportion(
                avatar_dir, source_path,
                {"valid": False, "reason": "head-heavy"})

            attempts = sorted(
                name for name in os.listdir(rejected_root)
                if not name.startswith(".")
                and os.path.isdir(os.path.join(rejected_root, name)))
            self.assertEqual(12, len(attempts))
            self.assertIn(os.path.basename(destination), attempts)
            self.assertFalse(any(
                name.endswith("00-side-alpha") for name in attempts))
            with open(
                    os.path.join(destination, "report.json"),
                    encoding="utf-8") as handle:
                manifest = json.load(handle)
            self.assertIsNone(manifest["refined_file"])

    def test_side_preflight_archives_exact_private_evidence_without_installing(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            source = np.full((90, 70, 3), 255, np.uint8)
            source[10:82, 25:45] = (40, 20, 220)
            source_path = os.path.join(avatar_dir, "source-side.png")
            self.assertTrue(cv2.imwrite(source_path, source))
            with open(source_path, "rb") as handle:
                source_bytes = handle.read()

            body_dir = os.path.join(avatar_dir, "body")
            os.makedirs(body_dir)
            sentinel = os.path.join(body_dir, "approved.txt")
            with open(sentinel, "w", encoding="utf-8") as handle:
                handle.write("approved body stays installed")

            raw_rgba = np.zeros((90, 70, 4), np.uint8)
            raw_rgba[10:82, 25:45, :3] = (40, 20, 220)
            raw_rgba[10:82, 25:45, 3] = 255
            refined = raw_rgba.copy()
            refined[78:81, 18:52, :3] = (145, 145, 145)
            refined[78:81, 18:52, 3] = 160
            report = {
                "available": True,
                "valid": False,
                "reason": "neutral floor, wall, or contact shadow remains",
                "floor_shadow_components": [{
                    "kind": "floor-contact", "bounds": [18, 78, 34, 3],
                }],
            }

            def render(_source, destination, **_options):
                return bool(cv2.imwrite(destination, raw_rgba))

            messages = []
            with mock.patch.object(
                    body.cutout, "render", side_effect=render), \
                    mock.patch.object(
                        body.body_alpha, "refine",
                        return_value=(refined, report)):
                with self.assertRaisesRegex(
                        body.GeneratedBodyAlphaError, "contact shadow"):
                    body._preflight_alpha_source(
                        avatar_dir, source_path, "side", log=messages.append)

            with open(sentinel, encoding="utf-8") as handle:
                self.assertEqual(
                    "approved body stays installed", handle.read())
            self.assertEqual(["approved.txt"], os.listdir(body_dir))
            rejected_root = os.path.join(
                avatar_dir, "diag", "body-rejections")
            attempts = [
                os.path.join(rejected_root, name)
                for name in os.listdir(rejected_root)
                if not name.startswith(".")
            ]
            self.assertEqual(1, len(attempts))
            attempt = attempts[0]
            self.assertIn("-side-alpha", os.path.basename(attempt))
            self.assertEqual(
                stat.S_IMODE(os.stat(rejected_root).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(attempt).st_mode), 0o700)

            archived_source = os.path.join(attempt, "source.png")
            archived_refined = os.path.join(attempt, "refined.png")
            archived_report = os.path.join(attempt, "report.json")
            for path in (archived_source, archived_refined, archived_report):
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            with open(archived_source, "rb") as handle:
                self.assertEqual(source_bytes, handle.read())
            np.testing.assert_array_equal(
                refined, cv2.imread(archived_refined, cv2.IMREAD_UNCHANGED))
            with open(archived_report, encoding="utf-8") as handle:
                manifest = json.load(handle)
            self.assertEqual("side", manifest["view"])
            self.assertFalse(manifest["installed"])
            self.assertEqual(report, manifest["alpha_quality"])
            self.assertEqual(
                hashlib.sha256(source_bytes).hexdigest(),
                manifest["source_sha256"])
            self.assertTrue(any(
                "archived rejected side alpha diagnostic" in message
                for message in messages))
            self.assertFalse(any(
                name.startswith(".body-side-alpha-preflight-")
                for name in os.listdir(avatar_dir)))

    def test_diagnostic_write_failure_never_masks_hard_gate(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            source = np.full((60, 40, 3), 255, np.uint8)
            source[5:55, 15:25] = (40, 20, 220)
            source_path = os.path.join(avatar_dir, "source-side.png")
            self.assertTrue(cv2.imwrite(source_path, source))
            rgba = np.zeros((60, 40, 4), np.uint8)
            rgba[5:55, 15:25, :3] = (40, 20, 220)
            rgba[5:55, 15:25, 3] = 255

            def render(_source, destination, **_options):
                return bool(cv2.imwrite(destination, rgba))

            messages = []
            with mock.patch.object(
                    body.cutout, "render", side_effect=render), \
                    mock.patch.object(
                        body.body_alpha, "refine", return_value=(rgba, {
                            "valid": False, "reason": "real alpha failure",
                        })), \
                    mock.patch.object(
                        body, "_archive_rejected_body_alpha",
                        side_effect=OSError("diagnostic disk full")):
                with self.assertRaisesRegex(
                        body.GeneratedBodyAlphaError, "real alpha failure"):
                    body._preflight_alpha_source(
                        avatar_dir, source_path, "side", log=messages.append)

            self.assertTrue(any(
                "diagnostic disk full" in message for message in messages))


class BodyAlphaResidualMessageTests(unittest.TestCase):
    def test_subthreshold_residual_reports_real_count_and_mass_not_zero_visible(self):
        source = np.full((80, 60, 3), 255, np.uint8)
        source[10:70, 25:35] = (40, 20, 220)
        rgba = np.zeros((80, 60, 4), np.uint8)
        rgba[10:70, 25:35, :3] = (40, 20, 220)
        rgba[10:70, 25:35, 3] = 255
        rgba[30:40, 12, :3] = 255
        rgba[30:40, 12, 3] = 12

        report = body_alpha.quality(source, rgba)

        self.assertFalse(report["valid"])
        self.assertEqual(10, report["residual_near_plate_pixels"])
        self.assertEqual(0, report["visible_near_plate_edge_pixels"])
        self.assertAlmostEqual(
            10 * 12 / 255.0,
            report["residual_near_plate_alpha_mass"], places=3)
        self.assertIn("10 sub-threshold px", report["reason"])
        self.assertNotIn("0 visible px", report["reason"])

    def test_refine_still_removes_all_subthreshold_plate_alpha(self):
        source = np.full((80, 60, 3), 255, np.uint8)
        source[10:70, 25:35] = (40, 20, 220)
        rgba = np.zeros((80, 60, 4), np.uint8)
        rgba[10:70, 25:35, :3] = (40, 20, 220)
        rgba[10:70, 25:35, 3] = 255
        rgba[30:40, 12, :3] = 255
        rgba[30:40, 12, 3] = 12

        refined, report = body_alpha.refine(source, rgba)

        self.assertTrue(report["valid"], report)
        self.assertEqual(0, report["residual_near_plate_pixels"])
        self.assertEqual(0, int(np.count_nonzero(refined[30:40, 12, 3])))
        self.assertEqual(10, report["removed_faint_plate_pixels"])


if __name__ == "__main__":
    unittest.main()
