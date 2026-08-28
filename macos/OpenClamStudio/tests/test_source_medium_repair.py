"""Legacy source-medium repair stays local, evidence-based, and fail-closed."""
import importlib
import json
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, build, library, motion


server_app = importlib.import_module("server.app")


def _image():
    return np.full((64, 64, 3), 127, np.uint8)


def _stylized_detection():
    return (
        np.full((478, 2), 32.0, np.float32),
        np.eye(4),
        {
            "detection_mode": "crop-fallback",
            "detection_crop": {
                "x": 3, "y": 4, "width": 55, "height": 54,
                "source": [64, 64],
            },
            "topology": {"face_area": 0.22},
            "source_medium": "3d render",
            "medium_score": 0.68,
            "medium_features": {
                "stylized_eye_evidence": True,
                "eye_white_fraction_right": 0.68,
                "eye_white_fraction_left": 0.71,
            },
        },
    )


class LegacySourceMediumRepairTests(unittest.TestCase):
    def _avatar(self, root, manifest):
        avatars = os.path.join(root, "avatars")
        directory = os.path.join(avatars, "legacy-luffy")
        os.makedirs(directory)
        cv2.imwrite(os.path.join(directory, "source.png"), _image())
        data = dict(manifest)
        data.setdefault("slug", "legacy-luffy")
        data.setdefault("source", "source.png")
        with open(os.path.join(directory, "manifest.json"), "w",
                  encoding="utf-8") as handle:
            json.dump(data, handle)
        return avatars, directory, data

    def test_unknown_original_is_reclassified_from_local_pixels(self):
        with tempfile.TemporaryDirectory() as root:
            avatars, directory, manifest = self._avatar(root, {
                "status": "ready",
                "source_metrics": {
                    "source_medium": "unknown", "eye_span": 312.0},
                "metrics": {"eye_span": 295.0},
                "head": {"source_medium": "photograph"},
            })
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        build.face, "detect_for_intake",
                        return_value=_stylized_detection()) as detect:
                repaired = build.repair_source_medium_from_source(
                    "legacy-luffy")

            detect.assert_called_once()
            self.assertEqual(
                repaired["source_metrics"]["source_medium"], "3d render")
            self.assertEqual(repaired["source_metrics"]["eye_span"], 312.0)
            self.assertTrue(repaired["source_metrics"]
                            ["medium_features"]["stylized_eye_evidence"])
            self.assertEqual(repaired["source_medium_repair"], {
                "method": "local-topology-and-visual-v1",
                "image": "source.png",
                "previous": "unknown",
                "source_medium": "3d render",
            })
            with open(os.path.join(directory, "manifest.json"),
                      encoding="utf-8") as handle:
                persisted = json.load(handle)
            self.assertEqual(
                persisted["source_metrics"]["source_medium"], "3d render")

    def test_ready_legacy_head_metrics_are_not_relabelled_as_source(self):
        with tempfile.TemporaryDirectory() as root:
            avatars, _directory, manifest = self._avatar(root, {
                "status": "ready",
                "metrics": {"eye_span": 999.0},
                "head": {"source_medium": "photograph"},
            })
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        build.face, "detect_for_intake",
                        return_value=_stylized_detection()):
                repaired = build.repair_source_medium_from_source(
                    "legacy-luffy", manifest=manifest)

            self.assertEqual(
                repaired["source_metrics"]["source_medium"], "3d render")
            self.assertNotIn("eye_span", repaired["source_metrics"])
            self.assertEqual(repaired["metrics"]["eye_span"], 999.0)

    def test_explicit_photograph_is_never_reclassified(self):
        with tempfile.TemporaryDirectory() as root:
            avatars, _directory, manifest = self._avatar(root, {
                "source_metrics": {"source_medium": "photograph"},
                "metrics": {"source_medium": "illustration"},
            })
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        build.face, "detect_for_intake",
                        side_effect=AssertionError(
                            "explicit photo should not be reclassified")) as detect, \
                    mock.patch.object(build, "write_manifest") as write:
                repaired = build.repair_source_medium_from_source(
                    "legacy-luffy", manifest=manifest)
            detect.assert_not_called()
            write.assert_not_called()
            self.assertEqual(repaired, manifest)

    def test_corrupt_original_report_remains_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            avatars, _directory, manifest = self._avatar(root, {
                "source_metrics": "damaged-report",
                "metrics": {"source_medium": "illustration"},
            })
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        build.face, "detect_for_intake",
                        side_effect=AssertionError(
                            "corrupt report should remain strict")) as detect:
                repaired = build.repair_source_medium_from_source(
                    "legacy-luffy", manifest=manifest)
            detect.assert_not_called()
            self.assertEqual(repaired, manifest)

    def test_uncertain_or_photographic_reinspection_is_not_persisted(self):
        for medium in ("unknown", "photograph"):
            with self.subTest(medium=medium), \
                    tempfile.TemporaryDirectory() as root:
                avatars, _directory, manifest = self._avatar(root, {
                    "source_metrics": {"source_medium": "unknown"},
                })
                result = (
                    np.full((478, 2), 32.0, np.float32), np.eye(4),
                    {"source_medium": medium, "medium_score": 0.61})
                with mock.patch.object(build, "AVATARS", avatars), \
                        mock.patch.object(build.face, "detect_for_intake",
                                          return_value=result), \
                        mock.patch.object(build, "write_manifest") as write:
                    repaired = build.repair_source_medium_from_source(
                        "legacy-luffy", manifest=manifest)
                write.assert_not_called()
                self.assertEqual(
                    repaired["source_metrics"]["source_medium"], "unknown")

    def test_registry_path_escape_is_not_opened(self):
        with tempfile.TemporaryDirectory() as root:
            avatars = os.path.join(root, "avatars")
            directory = os.path.join(avatars, "legacy-luffy")
            os.makedirs(directory)
            outside = os.path.join(root, "outside.png")
            cv2.imwrite(outside, _image())
            manifest = {
                "slug": "legacy-luffy",
                "source": "../../outside.png",
                "source_metrics": {"source_medium": "unknown"},
            }
            with mock.patch.object(build, "AVATARS", avatars), \
                    mock.patch.object(
                        build.face, "detect_for_intake",
                        side_effect=AssertionError(
                            "escaped source should not be inspected")) as detect:
                repaired = build.repair_source_medium_from_source(
                    "legacy-luffy", manifest=manifest)
            detect.assert_not_called()
            self.assertEqual(repaired, manifest)


class BodyRepairOrderingTests(unittest.TestCase):
    def test_body_stage_repairs_manifest_before_body_selects_qa_route(self):
        class Registry:
            def __init__(self, directory):
                self.directory = directory
                self.repaired = False
                self.manifest = {"slug": "legacy-luffy", "status": "ready"}

            def repair_source_medium_from_source(self, _slug, **_kwargs):
                self.repaired = True
                self.manifest["source_metrics"] = {
                    "source_medium": "3d render"}
                return self.manifest

            def adir(self, _slug):
                return self.directory

            def read_manifest(self, _slug):
                return dict(self.manifest)

            def write_manifest(self, _slug, manifest):
                self.manifest = dict(manifest)
                return manifest

        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)

            def build_body(_directory, _options, **_kwargs):
                self.assertTrue(
                    registry.repaired,
                    "body QA route was selected before legacy repair")
                return {"front": "front.png"}

            with mock.patch.object(server_app, "reg", return_value=registry), \
                    mock.patch.object(server_app,
                                      "_recover_body_edit_transaction"), \
                    mock.patch.object(body, "build", side_effect=build_body), \
                    mock.patch.object(motion, "remove"), \
                    mock.patch.object(library, "clear_active"), \
                    mock.patch.object(library, "archive_body"), \
                    mock.patch.object(server_app, "_publish_runtime_atomic"):
                server_app._body_stage(
                    "legacy-luffy", {}, lambda _message: None,
                    lambda _stage, _value, _label: None)

            self.assertEqual(
                registry.manifest["source_metrics"]["source_medium"],
                "3d render")


if __name__ == "__main__":
    unittest.main()
