"""A rejected canonical-head rebuild must leave the published avatar usable."""
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import build, visemes


def _image(value):
    return np.full((96, 96, 3), value, dtype=np.uint8)


def _metrics(medium="illustration"):
    return {
        "yaw": 0.0,
        "pitch": 0.0,
        "roll": 0.0,
        "foreshortening": 1.0,
        "mouth_width_px": 180.0,
        "source_medium": medium,
        "warnings": [],
    }


def _write(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(payload)


def _read(path):
    with open(path, "rb") as handle:
        return handle.read()


class FaceRebuildTransactionTests(unittest.TestCase):
    def test_failed_headwear_toggle_restores_face_body_and_motion(self):
        with tempfile.TemporaryDirectory() as directory:
            old_head = _image(31)
            old_keyframe = _image(47)
            cv2.imwrite(os.path.join(directory, "head.png"), old_head)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), old_keyframe)
            cv2.imwrite(
                os.path.join(directory, "source-keyframe.png"), _image(63))
            _write(os.path.join(directory, "raw", "old-render.bin"), b"old raw")
            _write(os.path.join(directory, "visemes", "old-bank.bin"), b"old bank")
            _write(os.path.join(directory, "diag", "old-qa.bin"), b"old qa")
            _write(os.path.join(directory, "preview.mp4"), b"old preview")
            _write(os.path.join(directory, "sheet.jpg"), b"old sheet")
            _write(os.path.join(directory, "body", "front.png"), b"old body")
            _write(os.path.join(directory, "motion", "walk.rgba"), b"old motion")
            _write(os.path.join(directory, ".body-cache", "approved.bin"), b"body cache")
            _write(os.path.join(directory, ".motion-cache", "approved.bin"), b"motion cache")

            prior = {
                "slug": "transaction-avatar",
                "name": "Transaction Avatar",
                "status": "ready",
                "source_keyframe": "source-keyframe.png",
                "source_metrics": _metrics(),
                "metrics": _metrics(),
                "head": {
                    "image": "head.png",
                    "source_medium": "illustration",
                    "remove_headwear": False,
                    "headwear_policy": "preserve",
                },
                "body": {"front": "body/front.png", "identity": "old-head"},
                "motion": {"walk": "motion/walk.rgba", "identity": "old-head"},
                "preview": "preview.mp4",
                "sheet": "sheet.jpg",
                "progress": {"done": len(visemes.ORDER),
                             "total": len(visemes.ORDER), "stage": "done"},
            }

            repair = {
                "kind": "viseme_fallback",
                "profile": {},
                "changes": [],
                "rejected_items": ["ah"],
                "reasons": ["ah has no composable speech plate"],
            }

            def generate_head(_source, destination, **_kwargs):
                cv2.imwrite(destination, _image(211))
                return destination

            def prepare_head(_source, destination, **_kwargs):
                cv2.imwrite(destination, _image(193))
                return _metrics()

            def generate_set(_keyframe, raw_dir, **_kwargs):
                _write(os.path.join(raw_dir, "new-render.bin"), b"new raw")
                return {
                    name: os.path.join(raw_dir, f"v_{name}.png")
                    for name in visemes.ORDER
                }

            def reject_composition(_keyframe, _raw, output, **kwargs):
                _write(os.path.join(output, "new-bank.bin"), b"new bank")
                _write(os.path.join(kwargs["diag_dir"], "new-qa.bin"), b"new qa")
                raise build.CalibrationRejected(
                    "required speech shape ah was rejected", repair)

            with mock.patch.object(build, "adir", return_value=directory):
                build.write_manifest("transaction-avatar", prior)
                with mock.patch.object(
                        build.generate, "default_head_provider",
                        return_value={"name": "test", "model": "test"}), \
                        mock.patch.object(
                            build.generate, "generate_head",
                            side_effect=generate_head), \
                        mock.patch.object(
                            build.prep, "build_keyframe",
                            side_effect=prepare_head), \
                        mock.patch.object(
                            build.generate, "generate_set",
                            side_effect=generate_set), \
                        mock.patch.object(
                            build.measure, "th_tongue_issue",
                            return_value=None), \
                        mock.patch.object(
                            build.compose, "compose_all",
                            side_effect=reject_composition):
                    with self.assertRaisesRegex(
                            build.CalibrationRejected,
                            "required speech shape ah"):
                        build.build_avatar(
                            "transaction-avatar",
                            remove_headwear=True,
                            log=lambda _message: None)

                restored = build.read_manifest("transaction-avatar")

            self.assertEqual(restored["status"], "ready")
            self.assertEqual(restored["head"], prior["head"])
            self.assertEqual(restored["body"], prior["body"])
            self.assertEqual(restored["motion"], prior["motion"])
            self.assertEqual(restored["rig_repair"], repair)
            self.assertIn("required speech shape ah", restored["error"])
            np.testing.assert_array_equal(
                cv2.imread(os.path.join(directory, "head.png")), old_head)
            np.testing.assert_array_equal(
                cv2.imread(os.path.join(directory, "keyframe.png")),
                old_keyframe)
            self.assertEqual(
                _read(os.path.join(directory, "raw", "old-render.bin")),
                b"old raw")
            self.assertEqual(
                _read(os.path.join(directory, "visemes", "old-bank.bin")),
                b"old bank")
            self.assertEqual(
                _read(os.path.join(directory, "diag", "old-qa.bin")),
                b"old qa")
            self.assertFalse(
                os.path.exists(os.path.join(directory, "raw", "new-render.bin")))
            self.assertFalse(
                os.path.exists(os.path.join(directory, "visemes", "new-bank.bin")))
            self.assertFalse(
                os.path.exists(os.path.join(directory, "diag", "new-qa.bin")))
            for path in (
                    "body/front.png", "motion/walk.rgba",
                    ".body-cache/approved.bin", ".motion-cache/approved.bin"):
                self.assertTrue(os.path.isfile(os.path.join(directory, path)), path)
            self.assertFalse(any(
                name.startswith(".face-rebuild-")
                for name in os.listdir(directory)))
            for relative in build.FACE_REBUILD_TRANSIENTS:
                self.assertFalse(os.path.exists(os.path.join(directory, relative)))


if __name__ == "__main__":
    unittest.main()
