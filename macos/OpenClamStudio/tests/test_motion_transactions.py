import asyncio
import copy
import importlib
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np
from fastapi import HTTPException

from studio import export as runtime_export, motion, rig


ROOT = Path(__file__).resolve().parents[1]
server_app = importlib.import_module("server.app")


def _selected_kinds(arguments, default=("walk", "idle")):
    """The kinds tuple a studio.motion generator was called with.

    The fakes below stand in for functions whose signatures keep gaining
    trailing parameters, so the tuple cannot be found by position: when
    _generate_videos gained walk_frame, arguments[-1] silently stopped being
    the kinds tuple and every partial build looked like a full one. Match it by
    shape instead, since it is the only argument that is a tuple of clip kinds.
    """
    for argument in reversed(arguments):
        if isinstance(argument, tuple) and set(argument) <= set(default):
            return argument
    return default


class FakeRegistry:
    def __init__(self, directory, manifest):
        self.directory = directory
        self.manifest = copy.deepcopy(manifest)

    def adir(self, _slug):
        return self.directory

    def read_manifest(self, _slug):
        return copy.deepcopy(self.manifest)

    def write_manifest(self, _slug, manifest):
        self.manifest = copy.deepcopy(manifest)
        return copy.deepcopy(self.manifest)


class MotionBuildTransactionTests(unittest.TestCase):
    def _build(
            self, avatar_dir, process_clip, keep_previous=False, progress=None,
            kinds=None, walk_style=None):
        cache_root = os.path.join(avatar_dir, ".motion-cache")
        cache = os.path.join(cache_root, "signature")
        source = os.path.join(avatar_dir, "body-source.png")
        Path(source).write_bytes(b"source")
        generations = {"walk": 0, "idle": 0}

        def generate_keyframes(*arguments):
            directory = os.path.join(cache, "keyframes")
            os.makedirs(directory, exist_ok=True)
            outputs = {}
            selected = _selected_kinds(arguments)
            for kind in selected:
                destination = os.path.join(directory, f"{kind}.png")
                if not os.path.exists(destination):
                    Path(destination).write_bytes((kind + "-keyframe").encode())
                outputs[kind] = destination
            return outputs

        def generate_videos(*arguments):
            directory = os.path.join(cache, "videos")
            os.makedirs(directory, exist_ok=True)
            outputs = {}
            selected = _selected_kinds(arguments)
            for kind in selected:
                destination = os.path.join(directory, f"{kind}.mp4")
                if not os.path.exists(destination):
                    generations[kind] += 1
                    Path(destination).write_bytes(
                        (kind + f"-video-{generations[kind]}").encode())
                outputs[kind] = destination
            return outputs

        context = {
            "body_source": source,
            "image_provider": {"name": "image", "title": "Image"},
            "video_provider": {"name": "video", "title": "Video"},
            "prompts": {
                "walk_keyframe": "walk keyframe",
                "idle_keyframe": "idle keyframe",
                "walk_video": "walk video",
                "idle_video": "idle video",
            },
            "signature": "a" * 64,
            "cache_root": cache_root,
            "cache": cache,
        }
        with (
                mock.patch.object(motion, "_build_context", return_value=context),
                mock.patch.object(motion, "_generate_keyframes", side_effect=generate_keyframes),
                mock.patch.object(motion, "_generate_videos", side_effect=generate_videos),
                mock.patch.object(motion, "_process_clip", side_effect=process_clip)):
            metadata = motion.build(
                avatar_dir,
                log=lambda _message: None,
                progress=progress,
                keep_previous=keep_previous,
                kinds=kinds,
                walk_style=walk_style,
            )
        return metadata, generations

    @staticmethod
    def _valid_clip(kind, _video, fps, stage, _log):
        sheet = f"{kind}-sheet.png"
        poster = f"{kind}-poster.png"
        Path(stage, sheet).write_bytes(b"sheet")
        Path(stage, poster).write_bytes(b"poster")
        return {
            "frames": 1,
            "fps": fps,
            "sheets": [{"image": sheet, "start": 0, "frames": 1}],
            "poster": poster,
        }

    def test_rejected_walk_gets_one_fresh_video_candidate(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            calls = []

            def process(kind, video, fps, stage, log):
                calls.append(kind)
                if kind == "walk" and calls.count("walk") == 1:
                    raise RuntimeError("walk gait did not close")
                return self._valid_clip(kind, video, fps, stage, log)

            metadata, generations = self._build(avatar_dir, process)

            self.assertEqual(["walk", "walk", "idle"], calls)
            self.assertEqual({"walk": 2, "idle": 1}, generations)
            self.assertEqual(1, len(os.listdir(os.path.join(avatar_dir, ".motion-rejected"))))
            self.assertTrue(os.path.isfile(os.path.join(avatar_dir, "motion", "motion.json")))
            self.assertEqual(1, metadata["walk"]["frames"])

    def test_retry_limit_preserves_last_good_motion(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            original = os.path.join(avatar_dir, "motion")
            os.makedirs(original)
            Path(original, "original.txt").write_text("last good")
            calls = []

            def reject_walk(kind, _video, _fps, _stage, _log):
                calls.append(kind)
                raise RuntimeError("walk gait did not close")

            attempts = motion.MAX_CANDIDATE_ATTEMPTS
            with self.assertRaisesRegex(
                    RuntimeError,
                    f"failed quality gates after {attempts} candidates"):
                self._build(avatar_dir, reject_walk)

            self.assertEqual(["walk"] * attempts, calls)
            self.assertEqual(
                attempts,
                len(os.listdir(os.path.join(avatar_dir, ".motion-rejected"))))
            self.assertEqual(
                "last good", Path(avatar_dir, "motion", "original.txt").read_text())
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion.previous")))

    def test_partial_builds_preserve_the_other_clip(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            self._build(avatar_dir, self._valid_clip)
            motion_dir = Path(avatar_dir, "motion")

            idle_before = json.loads(
                Path(motion_dir, "motion.json").read_text())["idle"]
            Path(motion_dir, "idle-sheet.png").write_bytes(b"preserved idle")
            metadata, generations = self._build(
                avatar_dir, self._valid_clip, kinds=("walk",))
            self.assertEqual({"walk": 1, "idle": 0}, generations)
            self.assertEqual(idle_before, metadata["idle"])
            self.assertEqual(
                b"preserved idle", Path(motion_dir, "idle-sheet.png").read_bytes())

            walk_before = metadata["walk"]
            Path(motion_dir, "walk-sheet.png").write_bytes(b"preserved walk")
            metadata, generations = self._build(
                avatar_dir, self._valid_clip, kinds=("idle",))
            self.assertEqual({"walk": 0, "idle": 1}, generations)
            self.assertEqual(walk_before, metadata["walk"])
            self.assertEqual(
                b"preserved walk", Path(motion_dir, "walk-sheet.png").read_bytes())

    def test_remove_deletes_only_the_selected_clip(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            self._build(avatar_dir, self._valid_clip)
            motion_dir = Path(avatar_dir, "motion")

            metadata = motion.remove(avatar_dir, "walk")
            self.assertNotIn("walk", metadata)
            self.assertIn("idle", metadata)
            self.assertFalse(Path(motion_dir, "walk-sheet.png").exists())
            self.assertTrue(Path(motion_dir, "idle-sheet.png").is_file())

            self.assertIsNone(motion.remove(avatar_dir, "idle"))
            self.assertFalse(motion_dir.exists())

    def test_unknown_clip_selection_is_rejected_before_generation(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            with self.assertRaisesRegex(ValueError, "unknown motion clip selection"):
                motion.build(avatar_dir, kinds=("moonwalk",))

    def test_pending_motion_can_rollback_or_commit(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            original = os.path.join(avatar_dir, "motion")
            os.makedirs(original)
            Path(original, "original.txt").write_text("last good")

            self._build(avatar_dir, self._valid_clip, keep_previous=True)
            self.assertTrue(os.path.isfile(
                os.path.join(avatar_dir, "motion.previous", "original.txt")))
            motion.rollback_pending_build(avatar_dir)
            self.assertEqual(
                "last good", Path(avatar_dir, "motion", "original.txt").read_text())

            self._build(avatar_dir, self._valid_clip, keep_previous=True)
            motion.commit_pending_build(avatar_dir)
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion.previous")))
            self.assertTrue(os.path.isfile(os.path.join(avatar_dir, "motion", "motion.json")))

    def test_first_motion_candidate_can_be_rolled_back(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            self._build(avatar_dir, self._valid_clip, keep_previous=True)
            self.assertTrue(os.path.isdir(os.path.join(avatar_dir, "motion")))
            motion.rollback_pending_build(avatar_dir)
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion")))
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion.previous")))

    def test_post_swap_failure_restores_last_good_motion(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            original = os.path.join(avatar_dir, "motion")
            os.makedirs(original)
            Path(original, "original.txt").write_text("last good")

            def progress(stage, _value, _label):
                if stage == "done":
                    raise RuntimeError("status channel failed")

            with self.assertRaisesRegex(RuntimeError, "status channel failed"):
                self._build(avatar_dir, self._valid_clip, progress=progress)

            self.assertEqual(
                "last good", Path(avatar_dir, "motion", "original.txt").read_text())
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion.previous")))


class MotionServerTransactionTests(unittest.TestCase):
    def setUp(self):
        with server_app._jlock:
            server_app._jobs.clear()

    def tearDown(self):
        with server_app._jlock:
            server_app._jobs.clear()

    def test_motion_thread_rolls_back_when_runtime_publish_fails(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            original_manifest = {
                "slug": slug,
                "status": "ready",
                "motion": {"signature": "last-good"},
            }
            registry = FakeRegistry(avatar_dir, original_manifest)
            motion_dir = os.path.join(avatar_dir, "motion")
            os.makedirs(motion_dir)
            Path(motion_dir, "original.txt").write_text("last good")
            reference = os.path.join(avatar_dir, "reference.png")
            Path(reference).write_bytes(b"reference")
            job_id = server_app._reserve_job(slug, "motion")

            def fake_build(directory, **arguments):
                self.assertTrue(arguments["keep_previous"])
                os.replace(
                    os.path.join(directory, "motion"),
                    os.path.join(directory, "motion.previous"),
                )
                os.makedirs(os.path.join(directory, "motion"))
                Path(directory, "motion", "new.txt").write_text("candidate")
                return {"signature": "candidate"}

            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(
                        server_app, "jlog",
                        return_value=lambda _message: None),
                    mock.patch.object(motion, "build", side_effect=fake_build),
                    mock.patch.object(
                        server_app, "_publish_runtime_atomic",
                        side_effect=RuntimeError("runtime export failed"))):
                server_app._motion_thread(slug, reference, job_id)

            self.assertEqual(original_manifest, registry.manifest)
            self.assertEqual(
                "last good", Path(avatar_dir, "motion", "original.txt").read_text())
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "motion.previous")))
            self.assertFalse(os.path.exists(reference))
            with server_app._jlock:
                job = dict(server_app._jobs[slug])
            self.assertTrue(job["done"])
            self.assertIn("runtime export failed", job["error"])

    def test_job_reservation_is_atomic(self):
        slug = "openclam"
        workers = 12
        barrier = threading.Barrier(workers)
        results = []
        result_lock = threading.Lock()

        def reserve():
            barrier.wait()
            result = server_app._reserve_job(slug, "motion")
            with result_lock:
                results.append(result)

        threads = [threading.Thread(target=reserve) for _ in range(workers)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        winners = [result for result in results if result]
        self.assertEqual(1, len(winners))

    def test_duplicate_motion_request_is_rejected_before_worker_start(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            server_app._reserve_job(slug, "motion")
            request = server_app.MotionRequest(
                slug=slug, pose="folded-cross")

            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(server_app.threading, "Thread") as worker):
                response = asyncio.run(
                    server_app.api_motion_generate(request))

            self.assertFalse(response["started"])
            self.assertEqual("already building", response["reason"])
            self.assertTrue(response["job_id"])
            worker.assert_not_called()

    def test_motion_request_starts_with_selected_pose(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            request = server_app.MotionRequest(
                slug=slug, pose="folded-cross")

            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(server_app.threading, "Thread") as worker):
                response = asyncio.run(
                    server_app.api_motion_generate(request))

            self.assertTrue(response["started"])
            self.assertEqual("folded-cross", response["pose"])
            worker.assert_called_once()
            arguments = worker.call_args.kwargs["args"]
            self.assertEqual(slug, arguments[0])
            self.assertIsNone(arguments[1])
            self.assertEqual("folded-cross", arguments[3]["id"])
            self.assertEqual("edge", arguments[3]["validation"])
            worker.return_value.start.assert_called_once()

    def test_walk_request_starts_with_selected_style_only(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            request = server_app.MotionRequest(
                slug=slug, kind="walk", walk_style="runway")

            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(server_app.threading, "Thread") as worker):
                response = asyncio.run(
                    server_app.api_motion_generate(request))

            self.assertTrue(response["started"])
            self.assertEqual("walk", response["kind"])
            self.assertEqual("runway", response["walk_style"])
            self.assertIsNone(response["pose"])
            arguments = worker.call_args.kwargs["args"]
            self.assertIsNone(arguments[3])
            self.assertEqual(("walk",), arguments[4])
            self.assertEqual("runway", arguments[5]["id"])
            self.assertEqual("stylized-gait", arguments[5]["validation"])

    def test_invalid_walk_style_does_not_reserve_a_job(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            request = server_app.MotionRequest(
                slug=slug, kind="walk", walk_style="moonwalk")

            with mock.patch.object(server_app, "reg", return_value=registry):
                with self.assertRaises(HTTPException) as caught:
                    asyncio.run(server_app.api_motion_generate(request))

            self.assertEqual(422, caught.exception.status_code)
            with server_app._jlock:
                self.assertNotIn(slug, server_app._jobs)

    def test_invalid_custom_pose_does_not_reserve_a_job(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            request = server_app.MotionRequest(
                slug=slug, pose="custom", pose_prompt="lean")

            with mock.patch.object(server_app, "reg", return_value=registry):
                with self.assertRaises(HTTPException) as caught:
                    asyncio.run(server_app.api_motion_generate(request))

            self.assertEqual(422, caught.exception.status_code)
            with server_app._jlock:
                self.assertNotIn(slug, server_app._jobs)

    def test_remove_is_blocked_while_generation_runs(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready", "motion": {}})
            server_app._reserve_job(slug, "motion")
            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(motion, "remove") as remove,
                    mock.patch.object(server_app, "_publish_runtime_atomic") as publish):
                with self.assertRaises(HTTPException) as caught:
                    asyncio.run(server_app.api_motion_remove(server_app.Slug(slug=slug)))
            self.assertEqual(409, caught.exception.status_code)
            remove.assert_not_called()
            publish.assert_not_called()

    def test_targeted_remove_preserves_the_other_motion_metadata(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            idle = {"sheets": [{"image": "idle-sheet.png"}]}
            registry = FakeRegistry(avatar_dir, {
                "slug": slug,
                "status": "ready",
                "motion": {"walk": {"sheets": []}, "idle": idle},
            })
            remaining = {"v": motion.MOTION_VERSION, "idle": idle}
            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(motion, "remove", return_value=remaining) as remove,
                    mock.patch.object(server_app, "_publish_runtime_atomic") as publish):
                response = asyncio.run(server_app.api_motion_remove(
                    server_app.MotionRemoveRequest(slug=slug, kind="walk")))

            self.assertEqual("walk", response["kind"])
            self.assertEqual(remaining, registry.manifest["motion"])
            remove.assert_called_once_with(avatar_dir, "walk")
            publish.assert_called_once()

    def test_body_status_reports_partial_motion(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            os.makedirs(os.path.join(avatar_dir, "body"))
            os.makedirs(os.path.join(avatar_dir, "motion"))
            Path(avatar_dir, "body", "body.json").write_text("{}")
            Path(avatar_dir, "motion", "walk-sheet.png").write_bytes(b"walk")
            registry = FakeRegistry(avatar_dir, {
                "slug": slug,
                "status": "ready",
                "motion": {
                    "walk": {"sheets": [{"image": "walk-sheet.png"}]},
                },
            })
            with mock.patch.object(server_app, "reg", return_value=registry):
                response = asyncio.run(server_app.api_body(slug))

            self.assertTrue(response["has_motion"])
            self.assertTrue(response["has_walk"])
            self.assertFalse(response["has_idle"])

    def test_body_status_lists_each_retained_motion_stage(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            body_dir = Path(avatar_dir, "body")
            motion_dir = Path(avatar_dir, "motion")
            raw_dir = motion_dir / "raw"
            body_dir.mkdir()
            raw_dir.mkdir(parents=True)
            Path(body_dir, "body.json").write_text("{}")
            for relative in (
                    "raw/walk-keyframe.png", "raw/walk-source.mp4",
                    "walk-0.png", "walk-poster.png", "walk-alpha.mov"):
                Path(motion_dir, relative).write_bytes(relative.encode())
            Path(motion_dir, "motion.json").write_text("{}")
            walk = {
                "frames": 24,
                "fps": 24,
                "frame_width": 256,
                "frame_height": 384,
                "sheets": [{
                    "image": "walk-0.png", "first": 0, "count": 24,
                    "columns": 8, "rows": 3,
                }],
                "poster": "walk-poster.png",
                "alpha_video": "walk-alpha.mov",
            }
            registry = FakeRegistry(avatar_dir, {
                "slug": slug, "status": "ready", "motion": {"walk": walk},
            })
            with mock.patch.object(server_app, "reg", return_value=registry):
                response = asyncio.run(server_app.api_body(slug))

            assets = response["motion_assets"]
            self.assertEqual(
                ["keyframe", "raw-video", "alpha-frames", "poster", "alpha-video"],
                [asset["role"] for asset in assets["walk"]])
            self.assertEqual(
                "raw/walk-source.mp4", assets["walk"][1]["relative_path"])
            self.assertEqual(24, assets["walk"][2]["frame_count"])
            self.assertEqual(
                ["receipt"], [asset["role"] for asset in assets["shared"]])

    def test_runtime_validator_accepts_a_single_motion_clip(self):
        with tempfile.TemporaryDirectory() as runtime_dir:
            Path(runtime_dir, "motion-walk-0.png").write_bytes(b"atlas")
            Path(runtime_dir, "manifest.json").write_text(json.dumps({
                "motion": {
                    "v": motion.MOTION_VERSION,
                    "walk": {
                        "sheets": [{"image": "assets/motion-walk-0.png"}],
                    },
                },
            }))
            manifest = server_app._validate_runtime_bundle(
                runtime_dir, expect_motion=True)
            self.assertIn("walk", manifest["motion"])
            self.assertNotIn("idle", manifest["motion"])

    def test_runtime_swap_recovers_and_rejects_invalid_stage(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "openclam"
            registry = FakeRegistry(
                avatar_dir, {"slug": slug, "status": "ready"})
            previous = os.path.join(avatar_dir, "runtime.previous")
            os.makedirs(previous)
            Path(previous, "manifest.json").write_text(json.dumps({"motion": None}))
            with mock.patch.object(server_app, "reg", return_value=registry):
                live = server_app._recover_runtime_swap(slug)
            self.assertTrue(os.path.isfile(os.path.join(live, "manifest.json")))
            original = Path(live, "manifest.json").read_bytes()

            def invalidate_stage(_slug, staged, log=None):
                os.remove(os.path.join(staged, "manifest.json"))

            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch(
                        "studio.export.publish_pet_assets",
                        side_effect=invalidate_stage)):
                with self.assertRaisesRegex(ValueError, "runtime manifest is missing"):
                    server_app._publish_runtime_atomic(slug, log=lambda _message: None)
            self.assertEqual(original, Path(live, "manifest.json").read_bytes())
            self.assertFalse(os.path.exists(os.path.join(avatar_dir, "runtime.previous")))

    @staticmethod
    def _legacy_upper_face_layers(runtime_dir):
        """Build the minimal preserved sprite contract accepted by v18."""
        layers = {}
        for name, positions, values in (
                ("eyes", "states", [0, 1]),
                ("brow", "dys", [0, 1]),
                ("forehead", "dys", [0, 1]),
                ("eyebag", "ups", [0, 1])):
            layer = {positions: values}
            if name == "brow":
                layer["sqs"] = [0]
            for side in ("l", "r"):
                filename = f"{name}_{side}.png"
                Path(runtime_dir, filename).write_bytes(f"{name}-{side}".encode())
                layer[side] = {
                    "src": f"assets/{filename}", "box": [0, 0, 1, 1],
                }
            layers[name] = layer
        return layers

    def test_runtime_only_v16_refresh_migrates_normalized_under_eye_target(self):
        """No-viseme refreshes must not keep copying a v16 face bundle.

        Imported/runtime-only avatars legitimately have no retained visemes,
        so the atomic publisher preserves their proven face strips and merely
        refreshes Pet layers.  That path still needs the current control schema
        so forehead and independent under-eye targets reach the renderer.
        """
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "runtime-only"
            live = os.path.join(avatar_dir, "runtime")
            os.makedirs(live)
            Path(live, "face-strip.png").write_bytes(b"preserved-face-bank")
            layers = self._legacy_upper_face_layers(live)
            Path(live, "manifest.json").write_text(json.dumps({
                "v": 16,
                "avatar": {"slug": slug, "name": "Runtime only"},
                "motion": None,
                **layers,
                # This legacy profile predates the independent target.  Its
                # existing tuning must survive and only safe new fields fill.
                "rig_profile": {"brows": 7, "cheeks": 40},
            }))
            registry = FakeRegistry(avatar_dir, {
                "slug": slug, "status": "ready", "name": "Runtime only",
            })
            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(runtime_export.reg, "adir", return_value=avatar_dir),
                    mock.patch.object(runtime_export.reg, "read_manifest",
                                      return_value=registry.manifest),
                    mock.patch.object(runtime_export.cutout, "render",
                                      return_value={"image": "assets/cutout.png"}),
                    mock.patch.object(runtime_export, "_publish_motion", return_value=None)):
                self.assertEqual(server_app.ensure_runtime(slug, log=lambda _line: None), live)

            migrated = json.loads(Path(live, "manifest.json").read_text())
            self.assertEqual(migrated["v"], server_app.RUNTIME_VERSION)
            self.assertEqual(migrated["v"], runtime_export.RUNTIME_VERSION)
            self.assertEqual(migrated["rig_profile"]["version"], rig.VERSION)
            self.assertEqual(migrated["rig_profile"]["brows"], 7)
            self.assertEqual(migrated["rig_profile"]["cheeks"], 40)
            self.assertEqual(migrated["rig_profile"]["eyebags"],
                             rig.PRESETS["natural"]["eyebags"])
            self.assertEqual(Path(live, "face-strip.png").read_bytes(),
                             b"preserved-face-bank")
            self.assertFalse(os.path.exists(live + ".previous"))

    def test_runtime_only_v16_missing_under_eye_stays_legacy(self):
        """A preserved bank cannot claim v18 when its under-eye strip is gone."""
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "missing-under-eye"
            live = os.path.join(avatar_dir, "runtime")
            os.makedirs(live)
            Path(live, "face-strip.png").write_bytes(b"preserved-face-bank")
            layers = self._legacy_upper_face_layers(live)
            layers.pop("eyebag")
            Path(live, "manifest.json").write_text(json.dumps({
                "v": 16,
                "avatar": {"slug": slug, "name": "Missing under-eye"},
                "motion": None,
                **layers,
            }))
            original = Path(live, "manifest.json").read_bytes()
            registry = FakeRegistry(avatar_dir, {
                "slug": slug, "status": "ready", "name": "Missing under-eye",
            })
            logs = []
            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(runtime_export.reg, "adir", return_value=avatar_dir),
                    mock.patch.object(runtime_export.reg, "read_manifest",
                                      return_value=registry.manifest),
                    mock.patch.object(runtime_export.cutout, "render",
                                      return_value={"image": "assets/cutout.png"}),
                    mock.patch.object(runtime_export, "_publish_motion", return_value=None)):
                self.assertEqual(server_app.ensure_runtime(slug, log=logs.append), live)

            self.assertEqual(Path(live, "manifest.json").read_bytes(), original)
            self.assertFalse(os.path.exists(live + ".previous"))
            self.assertTrue(any(
                "runtime under-eye layer is missing; cannot migrate to v18" in line
                for line in logs))

    def test_runtime_only_v17_missing_forehead_stays_legacy(self):
        """A v17 bank needs a source rebuild before it can claim v18."""
        with tempfile.TemporaryDirectory() as avatar_dir:
            slug = "missing-forehead"
            live = os.path.join(avatar_dir, "runtime")
            os.makedirs(live)
            layers = self._legacy_upper_face_layers(live)
            layers.pop("forehead")
            Path(live, "manifest.json").write_text(json.dumps({
                "v": 17,
                "avatar": {"slug": slug, "name": "Missing forehead"},
                "motion": None,
                **layers,
            }))
            original = Path(live, "manifest.json").read_bytes()
            registry = FakeRegistry(avatar_dir, {
                "slug": slug, "status": "ready", "name": "Missing forehead",
            })
            logs = []
            with (
                    mock.patch.object(server_app, "reg", return_value=registry),
                    mock.patch.object(runtime_export.reg, "adir", return_value=avatar_dir),
                    mock.patch.object(runtime_export.reg, "read_manifest",
                                      return_value=registry.manifest),
                    mock.patch.object(runtime_export.cutout, "render",
                                      return_value={"image": "assets/cutout.png"}),
                    mock.patch.object(runtime_export, "_publish_motion", return_value=None)):
                self.assertEqual(server_app.ensure_runtime(slug, log=logs.append), live)

            self.assertEqual(Path(live, "manifest.json").read_bytes(), original)
            self.assertTrue(any(
                "runtime forehead layer is missing; cannot migrate to v18" in line
                for line in logs))

    def test_settings_resumes_and_tracks_the_reserved_job(self):
        settings = (ROOT / "web" / "settings.html").read_text()
        self.assertIn("const [bodyState, progressState] = await Promise.all([", settings)
        self.assertIn("setBodyBusy(true);", settings)
        self.assertIn("pollBody(response.job_id);", settings)
        self.assertIn("response.reason === 'already building'", settings)
        self.assertIn("BODY_SLUG = null;", settings)
        self.assertIn("setTimeout(() => pollBody(expectedJobId), 1100)", settings)
        self.assertIn("BODY_STATE = await api('/api/avatar/body?slug='", settings)




class WalkCycleContractTests(unittest.TestCase):
    # The loop gate needs a full two-step cycle. These lock the generation
    # prompt to what the validator accepts: gait styles are authored in-place
    # loops (first frame = final frame), traversal styles cross the runway.

    def test_every_gait_style_demands_an_in_place_two_step_cycle(self):
        for style_id, preset in motion.WALK_STYLE_PRESETS.items():
            if preset["validation"] == "traversal":
                continue
            with self.subTest(style=style_id):
                self.assertEqual(motion.walk_mode(style_id), "loop")
                prompt = motion._walk_video_prompt(style_id)
                self.assertIn("TWO-STEP GAIT CYCLE", prompt)
                self.assertIn("one step is not a cycle", prompt)
                self.assertIn("BEHIND its hip", prompt)
                self.assertIn("EXACT first frame and the EXACT final frame",
                              prompt)
                self.assertIn("IN PLACE", prompt)
                self.assertIn("pure white", prompt)

    def test_traversal_styles_keep_the_runway_contract(self):
        self.assertEqual(motion.walk_mode("cartwheel"), "traversal")
        prompt = motion._walk_video_prompt("cartwheel")
        self.assertNotIn("TWO-STEP GAIT CYCLE", prompt)
        self.assertIn("camera-left to camera-right", prompt)

    def test_office_loop_window_can_hold_the_prompted_cadence(self):
        # the office prompt asks for 108-114 steps per minute, so a two-step
        # cycle lasts 60/114*2 = 1.05s to 60/108*2 = 1.11s; the loop search has
        # to be able to select that window or every candidate is rejected.
        loop = motion.WALK_STYLE_PRESETS["office"]["loop"]
        self.assertLessEqual(loop["minimum"], 1.05)
        self.assertGreaterEqual(loop["maximum"], 1.11)

    def test_production_walk_prompts_keep_both_arms_trackable(self):
        keyframe = motion._walk_keyframe_prompt("the referenced outfit", "office")
        video = motion._walk_video_prompt("office")

        for prompt in (keyframe, video):
            lowered = prompt.lower()
            self.assertIn("right-facing 25–30 degree three-quarter", lowered)
            self.assertIn("never a flat side profile", lowered)
            self.assertIn("both complete arms, elbows, wrists, and hands", lowered)
            self.assertIn("spatially separated from the torso", lowered)
            self.assertIn("white-background gap", lowered)

        self.assertIn("first and final frame of a seamless in-place loop", keyframe)
        self.assertIn("full alternating contralateral cycle", video)
        self.assertIn("EXACT first frame and the EXACT final frame", video)
        self.assertIn("locked camera", video)
        self.assertIn("complete full body", video)
        self.assertIn("canonical FRONT full-body plate", keyframe)
        self.assertIn("secondary side-body geometry only", keyframe)
        self.assertIn("not a camera-angle instruction", keyframe)

    def test_walk_tracking_contract_does_not_leak_into_idle_or_move(self):
        idle = motion._idle_video_prompt("back-heel")
        move = motion._move_video_prompt()

        self.assertIn("subtle living hold", idle)
        self.assertIn("exact same silhouette", idle)
        self.assertIn("SEAMLESS IN-PLACE LOOP", move)
        self.assertIn("THE ACT", move)
        for prompt in (idle, move):
            self.assertNotIn("TRACKABLE THREE-QUARTER GAIT", prompt)
            self.assertNotIn("full alternating contralateral cycle", prompt)

    def test_front_plus_side_authority_is_scoped_to_standard_gaits(self):
        cartwheel = motion._walk_keyframe_prompt(
            "the referenced outfit", "cartwheel")
        custom = motion._walk_keyframe_prompt(
            "the referenced outfit",
            {"id": "custom", "prompt": "walk backward with small careful steps"},
        )
        for prompt in (cartwheel, custom):
            self.assertIn("canonical RIGHT-SIDE full-body plate", prompt)
            self.assertNotIn("secondary side-body geometry only", prompt)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            body_dir = root / "body"
            body_dir.mkdir()
            front = body_dir / "source-front.jpg"
            side = body_dir / "source-side.jpg"
            head = root / "head.png"
            for path, payload in (
                    (front, b"front"), (side, b"side"), (head, b"head")):
                path.write_bytes(payload)
            (body_dir / "body.json").write_text(json.dumps({
                "views": {
                    "front": {"source": front.name},
                    "side": {"source": side.name},
                },
            }))
            image_selection = (
                {"provider": "xai", "model": "image"},
                {"route": "xai", "name": "xai", "title": "Image", "model": "image"},
            )
            video_selection = (
                {"provider": "xai", "model": "video"},
                {"route": "xai", "name": "xai", "title": "Video", "model": "video"},
            )
            with (
                    mock.patch.object(motion.body, "_identity_reference", return_value=str(head)),
                    mock.patch.object(motion.body, "image_provider_selection", return_value=image_selection),
                    mock.patch.object(motion.body, "video_provider_selection", return_value=video_selection)):
                office_context = motion._build_context(
                    str(root), None, walk_style="office")
                cartwheel_context = motion._build_context(
                    str(root), None, walk_style="cartwheel")

            self.assertEqual(
                office_context["body_sources"]["walk"],
                (str(front), str(side)),
            )
            self.assertEqual(
                cartwheel_context["body_sources"]["walk"], str(side))
            self.assertEqual(office_context["body_sources"]["idle"], str(front))
            self.assertEqual(office_context["body_sources"]["move"], str(front))


class WalkKeyframeWardrobeGateTests(unittest.TestCase):
    @staticmethod
    def _plate(path, garment_bgr, brightness=1.0, jpeg_quality=None):
        image = np.full((720, 480, 3), 248, np.uint8)
        color = np.clip(
            np.asarray(garment_bgr, dtype=np.float32) * brightness,
            0, 255,
        ).astype(np.uint8)
        cv2.circle(image, (240, 105), 52, (105, 145, 190), -1)
        cv2.rectangle(image, (175, 155), (305, 470), color.tolist(), -1)
        cv2.rectangle(image, (190, 470), (230, 660), (55, 55, 62), -1)
        cv2.rectangle(image, (250, 470), (290, 660), (55, 55, 62), -1)
        options = [] if jpeg_quality is None else [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality]
        self_ok = cv2.imwrite(str(path), image, options)
        if not self_ok:
            raise AssertionError(f"could not write synthetic plate {path}")

    def test_major_wardrobe_hue_drift_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "front.png"
            drifted = root / "walk.png"
            self._plate(reference, (190, 70, 25))
            self._plate(drifted, (55, 150, 55))

            quality = motion._wardrobe_color_quality(drifted, (reference,))

            self.assertTrue(quality["available"])
            self.assertFalse(quality["valid"])
            self.assertGreater(quality["hue_distance"], quality["hue_limit"])

    def test_lighting_and_jpeg_variation_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "front.png"
            varied = root / "walk.jpg"
            self._plate(reference, (190, 70, 25))
            self._plate(varied, (190, 70, 25), brightness=0.82, jpeg_quality=72)

            quality = motion._wardrobe_color_quality(varied, (reference,))

            self.assertTrue(quality["available"])
            self.assertTrue(quality["valid"])
            self.assertLessEqual(quality["hue_distance"], quality["hue_limit"])

    def test_hue_drift_stops_before_video_provider(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            reference = root / "front.png"
            drifted = root / "walk.png"
            self._plate(reference, (190, 70, 25))
            self._plate(drifted, (55, 150, 55))
            provider = {"title": "Video", "model": "test"}
            with mock.patch.object(
                    motion.media_gen, "generate_video_from_image_sync") as generate:
                with self.assertRaisesRegex(RuntimeError, "wardrobe color failed"):
                    motion._generate_videos(
                        str(cache), {}, provider, {"walk": str(drifted)},
                        {"walk": "walk"}, log=lambda _message: None,
                        kinds=("walk",), walk_style="office",
                        body_sources={"walk": (str(reference),)},
                    )
            generate.assert_not_called()

if __name__ == "__main__":
    unittest.main()
