"""Standalone face builds keep their approved runtime until export is valid."""
from contextlib import contextmanager
from pathlib import Path
import json
import tempfile
import unittest
from unittest import mock

from studio import export
from tests.test_standalone_openclam import route_test_application


class FaceRuntimePublicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = route_test_application()

    def _fixture(self, root):
        directory = Path(root) / "avatar"
        (directory / "visemes").mkdir(parents=True)
        (directory / "visemes" / "v_blink.jpg").write_bytes(b"blink source")
        live = directory / "runtime"
        live.mkdir()
        (live / "manifest.json").write_text('{"version":"approved"}')
        (live / "face.png").write_bytes(b"approved face")
        return directory, live

    def test_failed_child_export_preserves_published_runtime_and_inherits_lease(self):
        app = self.application
        with tempfile.TemporaryDirectory() as root:
            directory, live = self._fixture(root)
            registry = mock.Mock()
            registry.adir.return_value = str(directory)

            def failed_export(args, _log, *, lock_fd):
                self.assertEqual(lock_fd, 73)
                self.assertIn("--require-stylized-blink", args)
                staged = Path(args[args.index("--dest") + 1])
                self.assertNotEqual(staged, live)
                self.assertEqual((live / "face.png").read_bytes(), b"approved face")
                (staged / "partial.png").write_bytes(b"incomplete")
                raise RuntimeError("closed eyelid rejected")

            with mock.patch.object(app, "reg", return_value=registry), \
                    mock.patch.object(app, "_run_avatar_worker", side_effect=failed_export):
                with self.assertRaisesRegex(RuntimeError, "closed eyelid"):
                    app._publish_runtime_atomic(
                        "avatar", log=lambda _line: None,
                        face_worker_lock_fd=73, require_stylized_blink=True)

            self.assertEqual((live / "face.png").read_bytes(), b"approved face")
            self.assertEqual(json.loads((live / "manifest.json").read_text()),
                             {"version": "approved"})
            self.assertFalse(list(directory.glob(".runtime-stage-*")))

    def test_invalid_staged_manifest_never_replaces_approved_runtime(self):
        app = self.application
        with tempfile.TemporaryDirectory() as root:
            directory, live = self._fixture(root)
            registry = mock.Mock()
            registry.adir.return_value = str(directory)

            def incomplete_export(args, _log, **_kwargs):
                staged = Path(args[args.index("--dest") + 1])
                (staged / "manifest.json").write_text(
                    '{"motion":{"walk":{"alpha_stream":"assets/missing.mov"}}}')

            with mock.patch.object(app, "reg", return_value=registry), \
                    mock.patch.object(app, "_source_has_publishable_motion", return_value=True), \
                    mock.patch.object(app, "_run_avatar_worker", side_effect=incomplete_export):
                with self.assertRaisesRegex(ValueError, "runtime asset is missing"):
                    app._publish_runtime_atomic("avatar", face_worker_lock_fd=73)

            self.assertEqual((live / "face.png").read_bytes(), b"approved face")
            self.assertFalse(list(directory.glob(".runtime-stage-*")))

    def test_successful_child_is_validated_then_atomically_installed(self):
        app = self.application
        with tempfile.TemporaryDirectory() as root:
            directory, live = self._fixture(root)
            registry = mock.Mock()
            registry.adir.return_value = str(directory)

            def successful_export(args, _log, **_kwargs):
                staged = Path(args[args.index("--dest") + 1])
                (staged / "manifest.json").write_text('{"version":"new"}')
                (staged / "face.png").write_bytes(b"new face")
                self.assertEqual((live / "face.png").read_bytes(), b"approved face")

            with mock.patch.object(app, "reg", return_value=registry), \
                    mock.patch.object(app, "_source_has_publishable_motion", return_value=False), \
                    mock.patch.object(app, "_run_avatar_worker", side_effect=successful_export):
                app._publish_runtime_atomic("avatar", face_worker_lock_fd=73)

            self.assertEqual((live / "face.png").read_bytes(), b"new face")
            self.assertFalse(Path(str(live) + ".previous").exists())
            self.assertFalse(list(directory.glob(".runtime-stage-*")))

    def test_standalone_build_uses_atomic_publisher_inside_inherited_lease(self):
        app = self.application
        events = []

        @contextmanager
        def lease(_slug, blocking=True):
            self.assertTrue(blocking)
            events.append("lock")
            yield 73
            events.append("unlock")

        registry = mock.Mock()
        registry.avatar_face_build_lock = lease

        def publish(*_args, **kwargs):
            self.assertEqual(kwargs["face_worker_lock_fd"], 73)
            self.assertTrue(kwargs["require_stylized_blink"])
            self.assertNotIn("unlock", events)
            events.append("publish")

        with mock.patch.object(app, "reg", return_value=registry), \
                mock.patch.dict(app._jobs, {"avatar": {"id": "job"}}, clear=True), \
                mock.patch.object(app, "jlog", return_value=lambda _line: None), \
                mock.patch.object(app, "_run_avatar_worker") as worker, \
                mock.patch.object(app, "_publish_runtime_atomic", side_effect=publish), \
                mock.patch.object(app, "_finish_job") as finish:
            app._build_thread("avatar", "job", source_medium="3d render")

        self.assertEqual(events, ["lock", "publish", "unlock"])
        self.assertEqual(worker.call_count, 1)
        self.assertEqual(worker.call_args.kwargs["lock_fd"], 73)
        finish.assert_called_once_with("avatar", "job", "")


if __name__ == "__main__":
    unittest.main()
