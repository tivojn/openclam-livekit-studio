"""A restarted backend must never recover beneath a surviving face worker."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import build


ROOT = Path(__file__).resolve().parents[1]


class FaceWorkerRestartSafetyTests(unittest.TestCase):
    def _probe(self, data_root, slug):
        script = """
import os
import sys
from studio import build
with build.avatar_face_build_lock(sys.argv[1], blocking=False) as descriptor:
    print('acquired' if descriptor is not None else 'busy')
"""
        environment = os.environ.copy()
        environment["OPENCLAM_DATA_DIR"] = str(data_root)
        environment["PYTHONPATH"] = str(ROOT)
        result = subprocess.run(
            [sys.executable, "-c", script, slug],
            cwd=ROOT, env=environment, text=True, capture_output=True,
            check=True, timeout=20)
        return result.stdout.strip()

    def test_inherited_lease_survives_parent_close_until_worker_exits(self):
        with tempfile.TemporaryDirectory() as temporary:
            data_root = Path(temporary)
            avatar_root = data_root / "avatars"
            avatar_root.mkdir()
            (avatar_root / "sarah").mkdir()
            with mock.patch.object(build, "AVATARS", str(avatar_root)):
                with build.avatar_face_build_lock(
                        "sarah", blocking=True) as descriptor:
                    self.assertIsNotNone(descriptor)
                    environment = os.environ.copy()
                    environment[build._FACE_BUILD_LOCK_FD_ENV] = str(descriptor)
                    child = subprocess.Popen(
                        [sys.executable, "-c",
                         "import sys,time; print('ready', flush=True); time.sleep(30)"],
                        cwd=ROOT, env=environment, pass_fds=(descriptor,),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True)
                    self.assertEqual("ready", child.stdout.readline().strip())

                try:
                    # The backend-side descriptor is closed, exactly as on a
                    # restart, but the surviving worker still owns the same
                    # open-file-description lease.
                    self.assertEqual("busy", self._probe(data_root, "sarah"))
                finally:
                    child.terminate()
                    child.wait(timeout=10)
                    child.stdout.close()
                    child.stderr.close()

                self.assertEqual("acquired", self._probe(data_root, "sarah"))

    def test_build_worker_accepts_only_the_matching_inherited_lock_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            avatar_root = Path(temporary) / "avatars"
            avatar_root.mkdir()
            (avatar_root / "sarah").mkdir()
            (avatar_root / "celine").mkdir()
            with mock.patch.object(build, "AVATARS", str(avatar_root)), \
                    build.avatar_face_build_lock(
                        "sarah", blocking=True) as descriptor, \
                    mock.patch.dict(
                        os.environ,
                        {build._FACE_BUILD_LOCK_FD_ENV: str(descriptor)}):
                self.assertTrue(
                    build.inherited_avatar_face_build_lock("sarah"))
                self.assertFalse(
                    build.inherited_avatar_face_build_lock("celine"))

    def test_build_avatar_does_not_relock_a_verified_inherited_lease(self):
        sentinel = {"status": "ready"}
        with mock.patch.object(
                build, "inherited_avatar_face_build_lock",
                return_value=True), \
                mock.patch.object(
                    build, "avatar_face_build_lock",
                    side_effect=AssertionError("worker attempted to relock")), \
                mock.patch.object(
                    build, "_build_avatar_under_lock",
                    return_value=sentinel) as implementation:
            result = build.build_avatar("sarah", source_medium="illustration")

        self.assertIs(sentinel, result)
        implementation.assert_called_once_with(
            "sarah", shapes=None, log=None, quality="high", notes="",
            remove_headwear=None, source_medium="illustration")


if __name__ == "__main__":
    unittest.main()
