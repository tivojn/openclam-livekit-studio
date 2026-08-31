"""Pre-publication visual-medium gates for generated motion footage."""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from studio import motion


def _samples(count=5):
    return [
        {
            "index": 10 + index * 20,
            "position": round((index + 1) / (count + 1), 4),
            "frame": np.full((24, 24, 3), index, np.uint8),
        }
        for index in range(count)
    ]


class MotionSourceMediumVideoGateTests(unittest.TestCase):
    def test_owner_selected_clip_requires_current_successful_audit_receipt(self):
        clip = {
            "sheets": [{"image": "move-0.png"}],
            "source_medium": "illustration",
        }
        self.assertFalse(motion.motion_clip_compatible(
            clip, "illustration", require_receipt=True))
        clip["source_medium_quality"] = {
            "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
            "strict": True,
            "valid": True,
            "expected": "illustration",
        }
        self.assertFalse(motion.motion_clip_compatible(
            clip, "illustration", require_receipt=True))
        clip["source_medium_quality"].update({
            "available": True,
            "matching_samples": 3,
        })
        self.assertTrue(motion.motion_clip_compatible(
            clip, "illustration", require_receipt=True))
        for field, value in (
                ("v", 0), ("strict", False), ("valid", False),
                ("expected", "3d render")):
            broken = dict(clip)
            broken["source_medium_quality"] = dict(
                clip["source_medium_quality"], **{field: value})
            self.assertFalse(motion.motion_clip_compatible(
                broken, "illustration", require_receipt=True))

    def test_photo_and_3d_receipts_keep_their_existing_compatibility_contract(self):
        for expected in ("photograph", "3d render"):
            with self.subTest(expected=expected):
                clip = {
                    "sheets": [{"image": "move-0.png"}],
                    "source_medium": expected,
                    "source_medium_quality": {
                        "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
                        "strict": True,
                        "valid": True,
                        "expected": expected,
                    },
                }
            self.assertTrue(motion.motion_clip_compatible(
                clip, expected, require_receipt=True))

    def test_malformed_illustration_evidence_fails_closed_without_raising(self):
        clip = {
            "sheets": [{"image": "move-0.png"}],
            "source_medium": "illustration",
            "source_medium_quality": {
                "v": motion.MOTION_SOURCE_MEDIUM_AUDIT_VERSION,
                "strict": True,
                "valid": True,
                "expected": "illustration",
                "available": True,
                "matching_samples": "five",
            },
        }
        self.assertFalse(motion.motion_clip_compatible(
            clip, "illustration", require_receipt=True))

    def test_celine_style_illustration_to_soft_3d_drift_is_rejected(self):
        """Repeated mid-take repainting outranks clean/unknown endpoints."""
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["illustration", "illustration"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=[None, "3d render", "3d render",
                                 "3d render", None]):
            quality = motion._motion_video_medium_quality(
                "celine-move.mp4", "celine-move.png", "celine-front.png",
                "illustration", strict=True)

        self.assertTrue(quality["available"])
        self.assertFalse(quality["valid"])
        self.assertEqual("3d render", quality["dominant_medium"])
        self.assertEqual(3, quality["dominant_mismatch_samples"])
        self.assertIn("changed from illustration", quality["reason"])

    def test_ambiguous_celine_reference_still_rejects_soft_3d_video_drift(self):
        """A mistaken reference classification must not disable 2-D video QA."""
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["photograph", "3d render"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=[None, "3d render", "3d render",
                                 "3d render", None]):
            quality = motion._motion_video_medium_quality(
                "celine-move.mp4", "celine-move.png", "celine-front.png",
                "illustration", strict=True)

        self.assertTrue(quality["available"])
        self.assertFalse(quality["valid"])
        self.assertEqual("3d render", quality["dominant_medium"])
        self.assertEqual(3, quality["dominant_mismatch_samples"])
        self.assertIn("changed from illustration", quality["reason"])

    def test_ambiguous_celine_reference_accepts_classified_2d_video(self):
        """Owner-selected 2-D stays usable when the rendered evidence agrees."""
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["photograph", "3d render"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=["illustration"] * 5):
            quality = motion._motion_video_medium_quality(
                "celine-move.mp4", "celine-move.png", "celine-front.png",
                "illustration", strict=True)

        self.assertTrue(quality["available"])
        self.assertTrue(quality["valid"])
        self.assertEqual(5, quality["matching_samples"])
        self.assertIsNone(quality["dominant_medium"])

    def test_one_temporal_outlier_does_not_reject_a_matching_take(self):
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["illustration", "illustration"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=["illustration", "illustration", "3d render",
                                 "illustration", None]):
            quality = motion._motion_video_medium_quality(
                "take.mp4", "keyframe.png", "front.png",
                "illustration", strict=True)

        self.assertTrue(quality["available"])
        self.assertTrue(quality["valid"])
        self.assertEqual(3, quality["matching_samples"])
        self.assertEqual(1, quality["mismatch_samples"])

    def test_two_soft_3d_frames_reject_even_when_not_a_majority(self):
        """Repeated visible 3-D drift cannot hide behind three clean samples."""
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["illustration", "illustration"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=["illustration", "3d render", "illustration",
                                 "3d render", "illustration"]):
            quality = motion._motion_video_medium_quality(
                "take.mp4", "keyframe.png", "front.png",
                "illustration", strict=True)

        self.assertTrue(quality["available"])
        self.assertFalse(quality["valid"])
        self.assertEqual(2, quality["dominant_mismatch_samples"])
        self.assertIn("repeatedly changed", quality["reason"])

    def test_unclassifiable_illustration_take_cannot_publish_a_false_receipt(self):
        with mock.patch.object(
                motion, "_plate_face_medium",
                side_effect=["illustration", "illustration"]), \
                mock.patch.object(
                    motion, "_representative_video_frames",
                    return_value=_samples()), \
                mock.patch.object(
                    motion, "_frame_face_medium",
                    side_effect=[None] * 5):
            quality = motion._motion_video_medium_quality(
                "take.mp4", "keyframe.png", "front.png",
                "illustration", strict=True)

        self.assertFalse(quality["available"])
        self.assertFalse(quality["valid"])
        self.assertIn("could not verify", quality["reason"])

    def test_matching_photo_and_3d_takes_remain_valid(self):
        for expected in ("photograph", "3d render"):
            with self.subTest(expected=expected), \
                    mock.patch.object(
                        motion, "_plate_face_medium",
                        side_effect=[expected, expected]), \
                    mock.patch.object(
                        motion, "_representative_video_frames",
                        return_value=_samples()), \
                    mock.patch.object(
                        motion, "_frame_face_medium",
                        side_effect=[expected] * 5):
                quality = motion._motion_video_medium_quality(
                    "take.mp4", "keyframe.png", "front.png",
                    expected, strict=True)
            self.assertTrue(quality["available"])
            self.assertTrue(quality["valid"])
            self.assertEqual(5, quality["matching_samples"])

    def test_ambiguous_3d_and_photo_baselines_do_not_false_reject(self):
        for expected, detected in (
                ("3d render", "photograph"),
                ("photograph", "3d render")):
            with self.subTest(expected=expected), \
                    mock.patch.object(
                        motion, "_plate_face_medium",
                        side_effect=[detected, detected]), \
                    mock.patch.object(
                        motion, "_representative_video_frames") as sample:
                quality = motion._motion_video_medium_quality(
                    "take.mp4", "keyframe.png", "front.png",
                    expected, strict=True)
            self.assertFalse(quality["available"])
            self.assertTrue(quality["valid"])
            sample.assert_not_called()

    def test_auto_mode_does_not_run_medium_classification(self):

        with mock.patch.object(
                motion, "_plate_face_medium") as classify, \
                mock.patch.object(
                    motion, "_representative_video_frames") as sample:
            quality = motion._motion_video_medium_quality(
                "legacy.mp4", "legacy.png", "front.png",
                "illustration", strict=False)
        self.assertFalse(quality["available"])
        self.assertTrue(quality["valid"])
        classify.assert_not_called()
        sample.assert_not_called()

    def test_representative_sampler_spans_the_take(self):
        with tempfile.TemporaryDirectory() as directory:
            video = str(Path(directory, "samples.avi"))
            writer = cv2.VideoWriter(
                video, cv2.VideoWriter_fourcc(*"MJPG"), 24.0, (64, 64))
            if not writer.isOpened():
                self.skipTest("OpenCV MJPG writer unavailable")
            for index in range(25):
                writer.write(np.full((64, 64, 3), index * 5, np.uint8))
            writer.release()

            samples = motion._representative_video_frames(video)

        self.assertEqual([2, 7, 12, 17, 22], [item["index"] for item in samples])
        self.assertLess(samples[0]["position"], .1)
        self.assertGreater(samples[-1]["position"], .9)

    def test_build_quarantines_drift_before_local_cutout_or_publication(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            cache_root = os.path.join(avatar_dir, ".motion-cache")
            cache = os.path.join(cache_root, "signature")
            body_source = os.path.join(avatar_dir, "source-front.png")
            Path(body_source).write_bytes(b"body")
            keyframe = os.path.join(cache, "keyframes", "move.png")
            generations = []

            def generate_keyframes(*_arguments):
                os.makedirs(os.path.dirname(keyframe), exist_ok=True)
                Path(keyframe).write_bytes(b"keyframe")
                return {"move": keyframe}

            def generate_videos(*_arguments, **_options):
                directory = os.path.join(cache, "videos")
                os.makedirs(directory, exist_ok=True)
                destination = os.path.join(directory, "move.mp4")
                generations.append(len(generations) + 1)
                Path(destination).write_bytes(
                    f"candidate-{len(generations)}".encode())
                return {"move": destination}

            context = {
                "body_source": body_source,
                "body_sources": {"move": body_source},
                "body_reference_views": {"move": "front"},
                "identity_reference": None,
                "image_provider": {"name": "image", "title": "Image"},
                "video_provider": {"name": "video", "title": "Video"},
                "prompts": {
                    "move_keyframe": "flat illustration move",
                    "move_video": "flat illustration video",
                },
                "source_medium": "illustration",
                "strict_source_medium": True,
                "signature": "c" * 64,
                "cache_root": cache_root,
                "cache": cache,
            }
            rejected = {
                "available": True,
                "valid": False,
                "reason": "3/3 classifiable representative frames changed "
                          "from illustration to 3d render",
            }
            with mock.patch.object(
                    motion, "_build_context", return_value=context), \
                    mock.patch.object(
                        motion, "_generate_keyframes",
                        side_effect=generate_keyframes), \
                    mock.patch.object(
                        motion, "_motion_keyframe_medium_failures",
                        return_value=[]), \
                    mock.patch.object(
                        motion, "_generate_videos",
                        side_effect=generate_videos), \
                    mock.patch.object(
                        motion, "_motion_video_medium_quality",
                        return_value=rejected), \
                    mock.patch.object(motion, "_process_clip") as process:
                with self.assertRaisesRegex(
                        RuntimeError,
                        "changed the owner-selected source medium"):
                    motion.build(avatar_dir, kinds=("move",),
                                 log=lambda _message: None)

            self.assertEqual(
                motion.MAX_CANDIDATE_ATTEMPTS, len(generations))
            process.assert_not_called()
            rejected_root = Path(avatar_dir, ".motion-rejected")
            receipts = sorted(rejected_root.glob("*/rejection.json"))
            self.assertEqual(motion.MAX_CANDIDATE_ATTEMPTS, len(receipts))
            self.assertTrue(all(
                "changed the owner-selected source medium"
                in json.loads(path.read_text())["error"]
                for path in receipts))
            self.assertFalse(Path(avatar_dir, "motion").exists())

    def test_keyframe_preview_still_blocks_drift_before_copying(self):
        with tempfile.TemporaryDirectory() as avatar_dir:
            context = {
                "cache": os.path.join(avatar_dir, ".motion-cache", "sig"),
                "image_config": {},
                "image_provider": {"title": "Image"},
                "body_sources": {"move": "front.png"},
                "identity_reference": "head.png",
                "prompts": {"move_keyframe": "move"},
                "source_medium": "illustration",
                "strict_source_medium": True,
            }
            with mock.patch.object(
                    motion, "_build_context", return_value=context), \
                    mock.patch.object(
                        motion, "_generate_keyframes",
                        return_value={"move": "move.png"}), \
                    mock.patch.object(
                        motion, "_motion_keyframe_medium_failures",
                        return_value=["move"]), \
                    mock.patch.object(
                        motion, "_discard_medium_drift_keyframes"):
                with self.assertRaisesRegex(
                        RuntimeError, "keyframe changed"):
                    motion.preview_keyframes(
                        avatar_dir, kinds=("move",),
                        log=lambda _message: None)
            self.assertFalse(Path(avatar_dir, ".motion-preview").exists())


if __name__ == "__main__":
    unittest.main()
