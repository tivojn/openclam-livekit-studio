"""Owner-selected source categories outrank heuristic medium detection."""
import asyncio
import importlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from studio import body, build, export, face, generate, library, motion, prep
from server import avatar_package


server_app = importlib.import_module("server.app")


def _landmarks():
    points = np.full((478, 2), (48.0, 48.0), np.float32)
    for index, landmark_index in enumerate(face.FACE_OVAL):
        angle = 2.0 * np.pi * index / len(face.FACE_OVAL)
        points[landmark_index] = (
            48.0 + 25.0 * np.cos(angle), 48.0 + 30.0 * np.sin(angle))
    for index, landmark_index in enumerate(face.OUTER_LIP):
        angle = 2.0 * np.pi * index / len(face.OUTER_LIP)
        points[landmark_index] = (
            48.0 + 8.0 * np.cos(angle), 62.0 + 3.0 * np.sin(angle))
    return points


class SourceMediumOverrideTests(unittest.TestCase):
    def test_keyframe_retains_detection_but_uses_owner_selection(self):
        image = np.full((96, 96, 3), 128, np.uint8)
        landmarks = _landmarks()
        metrics = {
            "yaw": 0.0, "pitch": 0.0, "roll": 0.0,
            "foreshortening": 1.0,
        }
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(prep, "read_image_bgr", return_value=image), \
                mock.patch.object(
                    face, "detect_for_intake",
                    return_value=(landmarks, np.eye(4), {
                        "detection_mode": "strict",
                        "source_medium": "photograph",
                        "medium_score": .48,
                    })), \
                mock.patch.object(face, "metrics", return_value=metrics):
            result = prep.build_keyframe(
                "unused.png", os.path.join(directory, "keyframe.png"),
                allow_stylized=True, source_medium="illustration")

        self.assertEqual("illustration", result["source_medium"])
        self.assertEqual("photograph", result["detected_source_medium"])
        self.assertEqual("user", result["source_medium_source"])
        self.assertEqual(.48, result["medium_score"])

    def test_absent_selection_preserves_automatic_result(self):
        manifest = {
            "status": "draft",
            "source_metrics": {"source_medium": "3d render"},
            "metrics": {"source_medium": "3d render"},
        }
        original = json.loads(json.dumps(manifest))
        self.assertIs(manifest, build.apply_source_medium_override(
            manifest, None))
        self.assertEqual(original, manifest)

    def test_ready_override_preserves_detected_evidence_and_head_metrics(self):
        head_metrics = {"roll": 1.25, "mouth_width_px": 184}
        manifest = {
            "status": "ready",
            "source_metrics": {
                "source_medium": "photograph", "medium_score": .481606},
            "metrics": dict(head_metrics),
            "head": {"source_medium": "photograph"},
        }
        build.apply_source_medium_override(manifest, "3d render")
        self.assertEqual("3d render", manifest["source_medium_override"])
        self.assertEqual(
            "3d render", manifest["source_metrics"]["source_medium"])
        self.assertEqual(
            "photograph",
            manifest["source_metrics"]["detected_source_medium"])
        self.assertEqual("user", manifest["source_metrics"][
            "source_medium_source"])
        self.assertEqual(head_metrics, manifest["metrics"])
        self.assertEqual(
            "3d render", export._source_medium(manifest))

    def test_override_drives_body_style_cutout_and_ios_package_lane(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = {
                "source_medium_override": "3d render",
                "source_metrics": {
                    "source_medium": "3d render",
                    "detected_source_medium": "photograph",
                    "source_medium_source": "user",
                },
            }
            with open(os.path.join(directory, "manifest.json"), "w") as handle:
                json.dump(manifest, handle)
            requested = {"style": "photorealistic", "medium": "photograph"}
            effective = body._source_override_options(directory, requested)

            self.assertEqual("soft-3d", effective["style"])
            self.assertEqual("3d render", effective["medium"])
            self.assertTrue(body._allow_stylized_source(directory))
            self.assertEqual(
                "3d render",
                avatar_package._authoritative_source_medium(Path(directory)))

    def test_without_override_body_treatment_remains_independently_selectable(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "manifest.json"), "w") as handle:
                json.dump({
                    "source_metrics": {"source_medium": "illustration"},
                }, handle)
            requested = {"style": "photorealistic", "medium": "photograph"}
            self.assertEqual(
                requested, body._source_override_options(directory, requested))

    def test_override_is_persisted_atomically_for_existing_draft(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "AVATARS", directory):
            avatar = os.path.join(directory, "sarah")
            os.makedirs(avatar)
            build.write_manifest("sarah", {
                "slug": "sarah", "status": "draft",
                "source_metrics": {"source_medium": "photograph"},
                "metrics": {"source_medium": "photograph"},
            })
            result = build.set_source_medium_override("sarah", "3d render")
            persisted = build.read_manifest("sarah")

        self.assertEqual("3d render", result["source_medium_override"])
        self.assertEqual("3d render", persisted["source_metrics"][
            "source_medium"])
        self.assertEqual("3d render", persisted["metrics"]["source_medium"])
        self.assertEqual("photograph", persisted["source_metrics"][
            "detected_source_medium"])
        self.assertTrue(persisted["source_keyframe_refresh_required"])

    def test_face_rebuild_keeps_override_on_every_keyframe_crop(self):
        """A manual 2-D lane must survive legacy and generated-head recrops."""
        seen = []

        def fake_keyframe(_source, destination, **options):
            seen.append(options.get("source_medium"))
            if len(seen) == 2:
                raise RuntimeError("stop after canonical-head crop")
            Path(destination).write_bytes(b"keyframe")
            return {"source_medium": options.get("source_medium")}

        def fake_generate_head(_source, destination, **_options):
            Path(destination).write_bytes(b"head")

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "AVATARS", directory), \
                mock.patch.object(
                    build.prep, "build_keyframe", side_effect=fake_keyframe), \
                mock.patch.object(
                    build.generate, "default_head_provider",
                    return_value={"name": "test", "model": "test"}), \
                mock.patch.object(
                    build.generate, "generate_head",
                    side_effect=fake_generate_head):
            avatar = os.path.join(directory, "sarah")
            os.makedirs(avatar)
            Path(avatar, "source.png").write_bytes(b"source")
            Path(avatar, "keyframe.png").write_bytes(b"old-keyframe")
            build.write_manifest("sarah", {
                "slug": "sarah",
                "status": "draft",
                "source": "source.png",
                # Deliberately omit source-keyframe.png to cover the legacy
                # recovery crop as well as the newly generated head crop.
                "source_metrics": {"source_medium": "illustration"},
                "source_medium_override": "illustration",
            })
            result = build.build_avatar("sarah")

        self.assertEqual(["illustration", "illustration"], seen)
        self.assertEqual("error", result["status"])

    def test_rejected_ready_rebuild_restores_prior_medium_and_authored_set(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(build, "AVATARS", directory), \
                mock.patch.object(
                    build.prep, "build_keyframe",
                    side_effect=RuntimeError("owner lane rejected")):
            avatar = Path(directory, "sarah")
            avatar.mkdir()
            (avatar / "source.png").write_bytes(b"source")
            (avatar / "source-keyframe.png").write_bytes(b"source-keyframe")
            (avatar / "keyframe.png").write_bytes(b"old-keyframe")
            (avatar / "head.png").write_bytes(b"old-head")
            build.write_manifest("sarah", {
                "slug": "sarah",
                "status": "ready",
                "source": "source.png",
                "source_keyframe": "source-keyframe.png",
                "source_keyframe_medium": "photograph",
                "source_metrics": {"source_medium": "photograph"},
                "metrics": {"source_medium": "photograph"},
                "head": {
                    "source_medium": "photograph",
                    "remove_headwear": False,
                },
                "body": {"front": "body/front.png"},
                "motion": {"move": {"frames": 73}},
            })

            with self.assertRaisesRegex(RuntimeError, "owner lane rejected"):
                build.build_avatar("sarah", source_medium="illustration")
            restored = build.read_manifest("sarah")
            restored_head = (avatar / "head.png").read_bytes()
            restored_source_keyframe = (
                avatar / "source-keyframe.png").read_bytes()
            transient_exists = (
                avatar / ".source-keyframe.override.png").exists()

        self.assertEqual("ready", restored["status"])
        self.assertEqual(
            "photograph", restored["source_metrics"]["source_medium"])
        self.assertNotIn("source_medium_override", restored)
        self.assertNotIn("source_keyframe_refresh_required", restored)
        self.assertEqual("photograph", restored["head"]["source_medium"])
        self.assertIn("body", restored)
        self.assertIn("motion", restored)
        self.assertEqual(b"old-head", restored_head)
        self.assertEqual(b"source-keyframe", restored_source_keyframe)
        self.assertFalse(transient_exists)

    def test_invalid_override_is_rejected_instead_of_lowering_gates(self):
        with self.assertRaisesRegex(ValueError, "source medium must be"):
            build.apply_source_medium_override({}, "cartoon-ish")
        with self.assertRaisesRegex(ValueError, "source medium must be"):
            prep._source_medium_override("soft-3d")

    def test_explicit_medium_change_invalidates_same_version_stylized_head(self):
        manifest = {
            "status": "ready",
            "source_medium_override": "3d render",
            "source_metrics": {"source_medium": "3d render"},
            "head": {
                # Illustration and 3-D currently share a prompt version, so
                # version-only cache validation cannot notice this correction.
                "prompt_version": generate.head_prompt_version("3d render"),
                "source_medium": "illustration",
                "remove_headwear": False,
                "headwear_policy": "preserve",
            },
        }
        self.assertTrue(server_app._pipeline_face_needs_rebuild(
            manifest, "", False))
        manifest["head"]["source_medium"] = "3d render"
        self.assertFalse(server_app._pipeline_face_needs_rebuild(
            manifest, "", False))

    def test_rejected_pipeline_does_not_mutate_medium_under_active_worker(self):
        events = []
        registry = mock.Mock()
        registry.read_manifest.return_value = {"slug": "sarah"}
        registry.set_source_medium_override.side_effect = (
            lambda *_args: events.append("mutated"))
        request = server_app.PipelineRequest(
            slug="sarah", source_medium="3d render")
        with mock.patch.object(server_app, "reg", return_value=registry), \
                mock.patch.object(
                    server_app, "_reserve_job",
                    side_effect=lambda *_args: events.append("reserved") \
                    or None), \
                mock.patch.object(
                    server_app, "_already_running",
                    return_value={"started": False, "already": True}):
            result = asyncio.run(server_app.api_pipeline(request))

        self.assertEqual(["reserved"], events)
        self.assertEqual({"started": False, "already": True}, result)
        registry.set_source_medium_override.assert_not_called()

    def test_rejected_build_does_not_mutate_medium_under_active_worker(self):
        events = []
        registry = mock.Mock()
        registry.read_manifest.return_value = {"slug": "sarah"}
        registry.set_source_medium_override.side_effect = (
            lambda *_args: events.append("mutated"))
        request = server_app.Slug(
            slug="sarah", source_medium="3d render")
        with mock.patch.object(server_app, "reg", return_value=registry), \
                mock.patch.object(
                    server_app, "_reserve_job",
                    side_effect=lambda *_args: events.append("reserved") \
                    or None), \
                mock.patch.object(
                    server_app, "_already_running",
                    return_value={"started": False, "already": True}):
            result = asyncio.run(server_app.api_build(request))

        self.assertEqual(["reserved"], events)
        self.assertEqual({"started": False, "already": True}, result)
        registry.set_source_medium_override.assert_not_called()

    def test_build_dispatches_override_to_transactional_worker(self):
        registry = mock.Mock()
        registry.read_manifest.return_value = {"slug": "sarah"}
        request = server_app.Slug(
            slug="sarah", source_medium="3d render")
        worker_thread = mock.Mock()
        with mock.patch.object(server_app, "reg", return_value=registry), \
                mock.patch.object(
                    server_app, "_reserve_job", return_value="job-1"), \
                mock.patch.object(
                    server_app.threading, "Thread",
                    return_value=worker_thread) as constructor:
            result = asyncio.run(server_app.api_build(request))

        self.assertTrue(result["started"])
        registry.set_source_medium_override.assert_not_called()
        constructor.assert_called_once_with(
            target=server_app._build_thread,
            args=("sarah", "job-1", None, "", None, "3d render"),
            daemon=True)
        worker_thread.start.assert_called_once_with()

    def test_pipeline_dispatches_override_without_pre_mutating_registry(self):
        registry = mock.Mock()
        registry.read_manifest.return_value = {"slug": "sarah"}
        request = server_app.PipelineRequest(
            slug="sarah", source_medium="illustration")
        worker_thread = mock.Mock()
        with mock.patch.object(server_app, "reg", return_value=registry), \
                mock.patch.object(
                    server_app, "_reserve_job", return_value="job-1"), \
                mock.patch.object(
                    server_app.threading, "Thread",
                    return_value=worker_thread) as constructor:
            result = asyncio.run(server_app.api_pipeline(request))

        self.assertTrue(result["started"])
        registry.set_source_medium_override.assert_not_called()
        constructor.assert_called_once_with(
            target=server_app._pipeline_thread,
            args=("sarah", "job-1", "", None, "illustration"),
            daemon=True)
        worker_thread.start.assert_called_once_with()

    def test_failed_pipeline_face_stage_never_persists_candidate_override(self):
        original = {
            "slug": "sarah",
            "status": "ready",
            "source_metrics": {"source_medium": "photograph"},
            "head": {
                "source_medium": "photograph",
                "remove_headwear": False,
            },
        }
        registry = mock.Mock()
        registry.read_manifest.return_value = original
        registry.apply_source_medium_override.side_effect = (
            build.apply_source_medium_override)
        registry.repair_source_medium_from_source.side_effect = (
            lambda _slug, manifest, log: manifest)
        registry.build_avatar.side_effect = RuntimeError("face rejected")
        job = {
            "id": "job-1", "done": False, "error": "", "log": [],
        }
        with mock.patch.object(server_app, "reg", return_value=registry), \
                mock.patch.object(server_app, "_jobs", {"sarah": job}), \
                mock.patch.object(
                    server_app, "_pipeline_face_needs_rebuild",
                    return_value=True), \
                mock.patch.object(server_app, "_finish_job") as finish:
            server_app._pipeline_thread(
                "sarah", "job-1", source_medium="illustration")

        self.assertEqual(
            "photograph", original["source_metrics"]["source_medium"])
        self.assertNotIn("source_medium_override", original)
        registry.set_source_medium_override.assert_not_called()
        registry.build_avatar.assert_called_once_with(
            "sarah", notes="", remove_headwear=False,
            source_medium="illustration")
        finish.assert_called_once_with("sarah", "job-1", "face rejected")

    def test_motion_receipt_is_strict_only_after_owner_selection(self):
        legacy = {"sheets": [{"image": "move-0.png"}]}
        wrong = {**legacy, "source_medium": "3d render"}
        right = {**legacy, "source_medium": "illustration"}
        audited = {**right, "source_medium_quality": {
            "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
            "strict": True,
            "valid": True,
            "expected": "illustration",
            "available": True,
            "matching_samples": 3,
        }}
        self.assertTrue(motion.motion_clip_compatible(
            legacy, "illustration", require_receipt=False))
        self.assertFalse(motion.motion_clip_compatible(
            legacy, "illustration", require_receipt=True))
        self.assertFalse(motion.motion_clip_compatible(
            wrong, "illustration", require_receipt=True))
        self.assertFalse(motion.motion_clip_compatible(
            right, "illustration", require_receipt=True))
        self.assertTrue(motion.motion_clip_compatible(
            audited, "illustration", require_receipt=True))

    def test_motion_prompt_places_owner_medium_after_legacy_wardrobe_words(self):
        contract = motion._motion_source_medium_lock("illustration")
        self.assertIn("flat 2-D illustration", contract)
        self.assertIn("photorealistic", contract)
        self.assertIn("overrides", contract)

    def test_motion_keyframe_gate_rejects_only_correlated_known_drift(self):
        keyframes = {"move": "/tmp/move.png"}
        sources = {"move": "/tmp/body.png"}
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["illustration", "photograph"]):
            self.assertEqual(
                ["move"],
                motion._motion_keyframe_medium_failures(
                    keyframes, sources, "illustration", strict=True))
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=[None, "photograph"]):
            self.assertEqual(
                [],
                motion._motion_keyframe_medium_failures(
                    keyframes, sources, "illustration", strict=True))
        self.assertEqual(
            [], motion._motion_keyframe_medium_failures(
                keyframes, sources, "illustration", strict=False))

    def test_one_click_does_not_skip_unlabelled_motion_after_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "body").mkdir()
            Path(directory, "motion").mkdir()
            Path(directory, "body", "body.json").write_text(json.dumps({
                "options": {"medium": "illustration"},
            }))
            Path(directory, "motion", "motion.json").write_text(json.dumps({
                "move": {"sheets": [{"image": "move-0.png"}]},
            }))
            manifest = {
                "source_medium_override": "illustration",
                "motion": {"move": {"frames": 73}},
            }
            self.assertEqual(
                set(), server_app._pipeline_existing_motion_kinds(
                    directory, manifest))
            metadata = json.loads(
                Path(directory, "motion", "motion.json").read_text())
            metadata["move"]["source_medium"] = "illustration"
            Path(directory, "motion", "motion.json").write_text(
                json.dumps(metadata))
            self.assertEqual(
                set(), server_app._pipeline_existing_motion_kinds(
                    directory, manifest))
            metadata["move"]["source_medium_quality"] = {
                "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
                "strict": True,
                "valid": True,
                "expected": "illustration",
                "available": True,
                "matching_samples": 3,
            }
            Path(directory, "motion", "motion.json").write_text(
                json.dumps(metadata))
            self.assertEqual(
                {"move"}, server_app._pipeline_existing_motion_kinds(
                    directory, manifest))

    def test_explicit_stylized_body_requires_current_handoff_before_skip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "body.json")
            path.write_text(json.dumps({
                "options": {"medium": "illustration"},
                "head_composite": "replace",
                "head_handoff_version": 2,
            }))
            manifest = {"source_medium_override": "illustration"}

            # Marker-v2 predates the medium-aware jaw. Marker-v3 has that jaw
            # but mismatched portrait/body lateral fields that slice hair.
            # Neither may be silently skipped by an explicit cartoon build.
            self.assertFalse(server_app._pipeline_body_is_compatible(
                manifest, str(path)))

            authored = json.loads(path.read_text())
            authored["head_handoff_version"] = 3
            path.write_text(json.dumps(authored))
            self.assertFalse(server_app._pipeline_body_is_compatible(
                manifest, str(path)))
            authored["head_handoff_version"] = \
                body.STYLIZED_HEAD_HANDOFF_VERSION
            path.write_text(json.dumps(authored))
            self.assertTrue(server_app._pipeline_body_is_compatible(
                manifest, str(path)))

            authored["options"]["medium"] = "3d render"
            path.write_text(json.dumps(authored))
            self.assertFalse(server_app._pipeline_body_is_compatible(
                manifest, str(path)))

            manifest["source_medium_override"] = "3d render"
            self.assertTrue(server_app._pipeline_body_is_compatible(
                manifest, str(path)))
            authored["head_handoff_version"] = 2
            path.write_text(json.dumps(authored))
            self.assertFalse(server_app._pipeline_body_is_compatible(
                manifest, str(path)))

    def test_body_handoff_migration_preserves_photo_and_legacy_2d_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "body.json")
            path.write_text(json.dumps({
                "options": {"medium": "illustration"},
                "head_composite": "replace",
                "head_handoff_version": 2,
            }))

            # Automatic legacy 2-D projects did not make an owner selection;
            # preserve their established cache behavior until the owner opts
            # into an explicit lane or requests a rebuild.
            self.assertTrue(server_app._pipeline_body_is_compatible(
                {}, str(path)))

            # Photographic bodies never author or consume the stylized
            # replacement-head handoff, so no marker is required.
            path.write_text(json.dumps({
                "options": {"medium": "photograph"},
                "head_composite": "blend",
            }))
            self.assertTrue(server_app._pipeline_body_is_compatible(
                {"source_medium_override": "photograph"}, str(path)))

    def test_owner_medium_change_invalidates_existing_body(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "body.json")
            path.write_text(json.dumps({
                "options": {"medium": "3d render"},
                "head_composite": "replace",
                "head_handoff_version": body.STYLIZED_HEAD_HANDOFF_VERSION,
            }))
            manifest = {"source_medium_override": "illustration"}
            self.assertFalse(server_app._pipeline_body_is_compatible(
                manifest, str(path)))
            manifest.pop("source_medium_override")
            self.assertTrue(server_app._pipeline_body_is_compatible(
                manifest, str(path)))

    def test_runtime_omits_incompatible_motion_and_removes_stale_assets(self):
        with tempfile.TemporaryDirectory() as directory, \
                tempfile.TemporaryDirectory() as destination:
            Path(directory, "body").mkdir()
            Path(directory, "motion").mkdir()
            Path(directory, "manifest.json").write_text(json.dumps({
                "source_medium_override": "illustration",
            }))
            Path(directory, "body", "body.json").write_text(json.dumps({
                "options": {"medium": "illustration"},
            }))
            Path(directory, "motion", "motion.json").write_text(json.dumps({
                "v": 17,
                "move": {
                    "source_medium": "illustration",
                    "sheets": [{"image": "move-0.png"}],
                },
            }))
            stale = Path(destination, "motion-move-0.png")
            stale.write_bytes(b"stale")
            messages = []

            result = export._publish_motion(
                directory, destination, messages.append)

            self.assertIsNone(result)
            self.assertFalse(stale.exists())
            self.assertTrue(any("skipped move motion" in item
                                for item in messages))

    def test_atomic_publish_allows_an_all_quarantined_motion_library(self):
        """A legacy motion.json is not a promise of publishable runtime motion."""
        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory)
            (avatar / "visemes").mkdir()
            (avatar / "visemes" / "v_blink.jpg").write_bytes(b"face-bank")
            (avatar / "body").mkdir()
            (avatar / "body" / "body.json").write_text(json.dumps({
                "options": {"medium": "illustration"},
            }))
            (avatar / "motion").mkdir()
            (avatar / "motion" / "motion.json").write_text(json.dumps({
                "v": 17,
                # A label without the frame-audit receipt must be quarantined.
                "move": {
                    "source_medium": "illustration",
                    "sheets": [{"image": "move-0.png"}],
                },
            }))
            (avatar / "manifest.json").write_text(json.dumps({
                "slug": "celine",
                "source_medium_override": "illustration",
            }))

            registry = mock.Mock()
            registry.adir.return_value = directory

            def publish_without_quarantined_motion(_slug, destination, log=None):
                Path(destination, "manifest.json").write_text(json.dumps({
                    "v": 24,
                    "motion": None,
                }))

            with mock.patch.object(server_app, "reg", return_value=registry), \
                    mock.patch(
                        "studio.export.export",
                        side_effect=publish_without_quarantined_motion):
                server_app._publish_runtime_atomic(
                    "celine", log=lambda _message: None)

            runtime = json.loads(
                (avatar / "runtime" / "manifest.json").read_text())
            self.assertIsNone(runtime["motion"])
            self.assertFalse(server_app._source_has_publishable_motion(directory))

    def test_library_refuses_legacy_set_after_owner_medium_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory)
            body_dir = avatar / "body"
            motion_dir = avatar / "motion"
            body_dir.mkdir()
            motion_dir.mkdir()
            (body_dir / "source-front.png").write_bytes(b"body")
            (body_dir / "body.json").write_text(json.dumps({
                "motion_reference": {"move_source": "source-front.png"},
            }))
            (motion_dir / "move-0.png").write_bytes(b"sheet")
            (motion_dir / "motion.json").write_text(json.dumps({
                "move": {
                    "sheets": [{"image": "move-0.png"}],
                    # A label alone is not proof the rendered take was audited.
                    "source_medium": "illustration",
                },
                "body_references": {"move": {
                    "sha256": library._sha256(
                        str(body_dir / "source-front.png")),
                }},
            }))
            set_id = library.archive_motion(directory, "move")
            (avatar / "manifest.json").write_text(json.dumps({
                "source_medium_override": "illustration",
            }))
            records = library.list_motion_sets(directory, "move")
            self.assertFalse(records[0]["compatible"])
            with self.assertRaisesRegex(ValueError, "incompatible"):
                library.activate_motion(directory, "move", set_id)
            record_path = (avatar / "library" / "motion" / "move"
                           / set_id / "set.json")
            record = json.loads(record_path.read_text())
            record["clip"]["source_medium_quality"] = {
                "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
                "strict": True,
                "valid": True,
                "expected": "illustration",
            }
            record_path.write_text(json.dumps(record))
            records = library.list_motion_sets(directory, "move")
            self.assertFalse(records[0]["compatible"])
            record["clip"]["source_medium_quality"].update({
                "available": True,
                "matching_samples": 3,
            })
            record_path.write_text(json.dumps(record))
            records = library.list_motion_sets(directory, "move")
            self.assertTrue(records[0]["compatible"])
            activated = library.activate_motion(directory, "move", set_id)
            self.assertEqual("illustration", activated["move"]["source_medium"])


if __name__ == "__main__":
    unittest.main()
