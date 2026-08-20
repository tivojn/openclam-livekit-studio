"""Re-cut: reprocess retained raw takes through the current local pipeline.

Zero generation spend - the provider footage is already on disk. Verified
live 2026-07-31: the vvn move take re-cut through RVM in 53s, and the
runtime republished with matte_method robust-video-matting.
"""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import motion

ROOT = Path(__file__).resolve().parents[1]


class RecutContract(unittest.TestCase):
    def test_recut_validates_its_inputs(self):
        with self.assertRaisesRegex(ValueError, "unknown motion clip"):
            motion.recut("/nonexistent", "poetry")

    def test_recut_requires_existing_motion(self):
        import tempfile
        with tempfile.TemporaryDirectory() as avatar_dir:
            with self.assertRaisesRegex(RuntimeError, "no motion"):
                motion.recut(avatar_dir, "move")

    def test_recut_requires_the_retained_raw(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            motion_dir = os.path.join(avatar_dir, "motion")
            os.makedirs(motion_dir)
            with open(os.path.join(motion_dir, "motion.json"), "w") as f:
                json.dump({"move": {"frames": 3}}, f)
            with self.assertRaisesRegex(RuntimeError, "retained raw"):
                motion.recut(avatar_dir, "move")

    def test_recut_stamps_the_current_motion_pipeline_version(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            motion_dir = os.path.join(avatar_dir, "motion")
            raw_dir = os.path.join(motion_dir, "raw")
            os.makedirs(raw_dir)
            with open(os.path.join(motion_dir, "motion.json"), "w") as handle:
                json.dump({"v": motion.MOTION_VERSION - 1,
                           "move": {"frames": 3}}, handle)
            with open(os.path.join(raw_dir, "move-source.mp4"), "wb") as handle:
                handle.write(b"retained motion")
            replacement = {"frames": 3, "fps": 12, "sheets": []}

            with mock.patch.object(
                    motion, "_process_clip", return_value=replacement):
                result = motion.recut(avatar_dir, "move")

            self.assertEqual(motion.MOTION_VERSION, result["v"])
            with open(os.path.join(motion_dir, "motion.json")) as handle:
                installed = json.load(handle)
            self.assertEqual(motion.MOTION_VERSION, installed["v"])

    def test_server_and_ui_wiring(self):
        app = (ROOT / "server" / "app.py").read_text()
        self.assertIn('@app.post("/api/avatar/motion/recut")', app)
        self.assertIn("def _recut_thread", app)
        # Same post-steps as generation: manifest, runtime publish, commit,
        # and the library set re-archive.
        marker = app.index("def _recut_thread")
        window = app[marker:marker + 2200]
        self.assertIn("_publish_runtime_atomic", window)
        self.assertIn("commit_pending_build", window)
        self.assertIn("library.archive_motion", window)
        settings = (ROOT / "web" / "settings.html").read_text()
        for kind in ("walk", "idle", "move"):
            self.assertIn(f'id="body-{kind}-recut"', settings)
        self.assertIn("'/api/avatar/motion/recut'", settings)
        self.assertIn("function recutMotion", settings)


if __name__ == "__main__":
    unittest.main()
