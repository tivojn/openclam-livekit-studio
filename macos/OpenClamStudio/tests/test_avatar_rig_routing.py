"""Facial-calibration detector routing for photo and illustrated avatars."""
import asyncio
import copy
import importlib
import json
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, compose, face, rig


server_app = importlib.import_module("server.app")


def _landmarks():
    points = np.full((478, 2), 32.0, np.float32)
    points[:, 0] += np.linspace(-4.0, 4.0, 478, dtype=np.float32)
    points[:, 1] += np.linspace(-3.0, 3.0, 478, dtype=np.float32)
    return points


class _Registry:
    def __init__(self, directory, manifest):
        self.directory = directory
        self.manifest = copy.deepcopy(manifest)
        self.repair_calls = 0

    def adir(self, _slug):
        return self.directory

    def read_manifest(self, _slug):
        return copy.deepcopy(self.manifest)

    def repair_source_medium_from_source(self, _slug, manifest=None, log=None):
        self.repair_calls += 1
        return copy.deepcopy(manifest if manifest is not None else self.manifest)

    @staticmethod
    def raw_render_gaps(_slug):
        return []


class AvatarRigDetectorRoutingTests(unittest.TestCase):
    def _rig(self, source_medium, *, original_report=True):
        manifest = {"slug": "routing-avatar", "status": "ready"}
        report_key = "source_metrics" if original_report else "metrics"
        manifest[report_key] = {"source_medium": source_medium}
        landmarks = _landmarks()
        with tempfile.TemporaryDirectory() as directory:
            cv2.imwrite(
                os.path.join(directory, "keyframe.png"),
                np.full((64, 64, 3), 127, np.uint8))
            with open(os.path.join(directory, "manifest.json"), "w",
                      encoding="utf-8") as handle:
                json.dump(manifest, handle)

            registry = _Registry(directory, manifest)
            masks = {"mouth": np.zeros((64, 64), np.float32)}
            face_mask = np.ones((64, 64), np.float32)
            alpha = np.ones((64, 64), np.float32)
            with mock.patch.object(server_app, "reg", return_value=registry), \
                    mock.patch.object(compose, "_masks",
                                      return_value=(masks, face_mask)), \
                    mock.patch.object(compose, "_alpha_ring",
                                      return_value=(alpha, None)), \
                    mock.patch.object(rig, "from_manifest", return_value={}), \
                    mock.patch.object(rig, "inspector_payload", return_value={}), \
                    mock.patch.object(rig, "sampled_weights", return_value={}), \
                    mock.patch.object(rig, "public_schema", return_value={}), \
                    mock.patch.object(compose, "_scan_tooth_donors",
                                      return_value=[]) as dental_scan:
                yield landmarks, dental_scan

    def test_explicit_illustration_uses_topology_gated_intake_detector(self):
        for landmarks, dental_scan in self._rig("illustration"):
            with mock.patch.object(
                    face, "detect",
                    side_effect=AssertionError(
                        "illustrated calibration used strict-only detection")) \
                    as strict, mock.patch.object(
                        face, "detect_for_intake",
                        return_value=(landmarks, np.eye(4), {
                            "detection_mode": "crop-fallback",
                            "source_medium": "illustration",
                        })) as intake:
                payload = asyncio.run(server_app.api_rig("routing-avatar"))
        self.assertEqual(payload["raw_gaps"], [])
        intake.assert_called_once()
        strict.assert_not_called()
        self.assertEqual(dental_scan.call_count, len(compose.DENTAL_ROWS))
        self.assertTrue(all(
            call.kwargs["allow_stylized"]
            for call in dental_scan.call_args_list))

    def test_photograph_never_uses_permissive_intake_detector(self):
        for landmarks, dental_scan in self._rig("photograph"):
            with mock.patch.object(
                    face, "detect", return_value=(landmarks, np.eye(4))) \
                    as strict, mock.patch.object(
                        face, "detect_for_intake",
                        side_effect=AssertionError(
                            "photo calibration invoked cartoon fallback")) \
                    as intake:
                payload = asyncio.run(server_app.api_rig("routing-avatar"))
        self.assertEqual(payload["raw_gaps"], [])
        strict.assert_called_once()
        intake.assert_not_called()
        self.assertEqual(dental_scan.call_count, len(compose.DENTAL_ROWS))
        self.assertTrue(all(
            not call.kwargs["allow_stylized"]
            for call in dental_scan.call_args_list))

    def test_unknown_original_report_cannot_inherit_stylized_head_report(self):
        manifest = {
            "source_metrics": {"source_medium": "unknown"},
            "metrics": {"source_medium": "illustration"},
        }
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "manifest.json"), "w",
                      encoding="utf-8") as handle:
                json.dump(manifest, handle)
            self.assertFalse(body._allow_stylized_source(directory))


if __name__ == "__main__":
    unittest.main()
