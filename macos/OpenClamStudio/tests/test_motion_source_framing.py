"""Raw I2V clipping must not become a padded, apparently complete avatar."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from studio import motion


def _subject(*, background=(255, 255, 255), clipped=None):
    source = np.full((192, 128, 3), background, np.uint8)
    cv2.circle(source, (64, 34), 18, (25, 35, 55), -1)
    cv2.rectangle(source, (52, 44), (76, 58), (95, 149, 220), -1)
    cv2.rectangle(source, (40, 56), (88, 126), (40, 45, 205), -1)
    for x in (44, 70):
        cv2.rectangle(source, (x, 121), (x + 14, 177), (32, 32, 32), -1)
    cv2.line(source, (48, 176), (48, 182), (12, 12, 12), 1)
    if clipped == "left":
        cv2.rectangle(source, (0, 66), (42, 79), (95, 149, 220), -1)
    elif clipped == "right":
        cv2.rectangle(source, (86, 66), (127, 79), (95, 149, 220), -1)
    elif clipped == "top":
        cv2.rectangle(source, (58, 0), (70, 21), (25, 35, 55), -1)
    elif clipped == "bottom":
        cv2.rectangle(source, (44, 170), (58, 191), (32, 32, 32), -1)
    return source


class MotionSourceFramingTests(unittest.TestCase):
    def test_white_and_near_white_clean_sources_pass_without_pixel_changes(self):
        for plate in ((255, 255, 255), (245, 245, 246)):
            with self.subTest(plate=plate):
                source = _subject(background=plate)
                before = source.copy()
                quality = motion._motion_source_framing_quality([source])
                self.assertTrue(quality["available"])
                self.assertTrue(quality["valid"], quality)
                self.assertEqual([], quality["affected_frames"])
                np.testing.assert_array_equal(before, source)

    def test_green_screen_uses_its_background_not_a_white_assumption(self):
        clean = motion._motion_source_framing_quality([
            _subject(background=(20, 240, 20))])
        self.assertTrue(clean["available"])
        self.assertTrue(clean["valid"], clean)
        self.assertEqual(["green"], clean["plates"])
        clipped = motion._motion_source_framing_quality([
            _subject(background=(20, 240, 20), clipped="right")])
        self.assertFalse(clipped["valid"], clipped)

    def test_connected_hand_head_and_shoe_clips_are_rejected(self):
        for edge in ("left", "right", "top", "bottom"):
            with self.subTest(edge=edge):
                quality = motion._motion_source_framing_quality([
                    _subject(), _subject(clipped=edge)], source_fps=24)
                self.assertTrue(quality["available"])
                self.assertFalse(quality["valid"], quality)
                self.assertEqual([2], quality["affected_frames"])
                self.assertIn(edge, quality["edge_contacts"][0]["edges"])
                self.assertEqual(.0417, quality["edge_contacts"][0]["time_seconds"])

    def test_detached_border_marks_do_not_implicate_the_subject(self):
        source = _subject()
        source[74, 0] = 0  # lone compression pixel
        source[100:109, 0:9] = (10, 40, 190)  # detached, not a hand
        source[186, :] = 30  # one-pixel registration line
        quality = motion._motion_source_framing_quality([source])
        self.assertTrue(quality["valid"], quality)
        self.assertEqual([], quality["edge_contacts"])

    def test_uniform_borders_are_not_detected_as_cut_off_anatomy(self):
        for value in (0, 128, 255):
            with self.subTest(value=value):
                source = np.full((192, 128, 3), value, np.uint8)
                quality = motion._motion_source_framing_quality([source])
                self.assertTrue(quality["valid"], quality)
                self.assertEqual([], quality["affected_frames"])
                if value != 255:
                    self.assertFalse(quality["available"])
                    self.assertIn("unverified", quality["reason"])

    def test_unknown_background_does_not_claim_verified_framing(self):
        quality = motion._motion_source_framing_quality([
            _subject(background=(100, 120, 140))])
        self.assertFalse(quality["available"])
        self.assertEqual(0, quality["measurable_frames"])
        self.assertEqual(1, quality["frames_checked"])

    def test_native_scan_sees_a_clipped_frame_runtime_downsampling_omits(self):
        with tempfile.TemporaryDirectory() as directory:
            video = str(Path(directory, "source.avi"))
            writer = cv2.VideoWriter(
                video, cv2.VideoWriter_fourcc(*"MJPG"), 24.0, (128, 192))
            if not writer.isOpened():
                self.skipTest("OpenCV MJPG writer unavailable")
            try:
                for index in range(24):
                    writer.write(_subject(clipped="left" if index == 1 else None))
            finally:
                writer.release()
            quality = {}
            runtime_frames = motion._decode_video(
                video, 12, framing_receipt=quality)
        self.assertEqual(12, len(runtime_frames))
        self.assertEqual(24, quality["frames_checked"])
        self.assertTrue(quality["all_native_frames"])
        self.assertEqual([2], quality["affected_frames"])
        self.assertFalse(quality["valid"])
        sampled_only = motion._motion_source_framing_quality(runtime_frames)
        self.assertTrue(sampled_only["valid"], sampled_only)

    def test_decoder_releases_capture_if_the_audit_raises(self):
        capture = mock.Mock()
        capture.isOpened.return_value = True
        capture.get.return_value = 24.0
        capture.read.return_value = (True, _subject())
        with mock.patch.object(motion.cv2, "VideoCapture", return_value=capture), \
                mock.patch.object(
                    motion, "_source_frame_edge_contacts",
                    side_effect=RuntimeError("audit interrupted")):
            with self.assertRaisesRegex(RuntimeError, "audit interrupted"):
                motion._decode_video("unused.mov", 12, framing_receipt={})
        capture.release.assert_called_once()

    def test_receipt_is_bounded_but_records_every_affected_frame(self):
        source = _subject(clipped="left")
        quality = motion._motion_source_framing_quality([source] * 100)
        self.assertEqual(100, len(quality["affected_frames"]))
        self.assertEqual(64, len(quality["edge_contacts"]))
        self.assertEqual(100, quality["frames_checked"])

    def test_clip_is_rejected_before_matting_or_normalization_in_every_lane(self):
        for medium in ("photograph", "illustration", "3d render"):
            with self.subTest(medium=medium), tempfile.TemporaryDirectory() as stage, \
                    mock.patch.object(
                        motion, "_decode_video",
                        return_value=[_subject(clipped="left")] * 12), \
                    mock.patch.object(motion, "_segment_frames") as segment, \
                    mock.patch.object(motion, "_normalise_frames") as normalize, \
                    mock.patch.object(motion, "RELAXED_LOOP_SHIPPING", True):
                with self.assertRaises(motion.GeneratedMotionFramingError) as caught:
                    motion._process_clip(
                        "move", "candidate.mp4", 12, stage, lambda _message: None,
                        idle_validation="free", source_medium=medium)
                self.assertFalse(caught.exception.source_framing_quality["valid"])
                self.assertIn("Regenerate only this video", str(caught.exception))
                segment.assert_not_called()
                normalize.assert_not_called()

    def test_padding_cannot_make_the_source_cut_valid(self):
        source = _subject(clipped="left")
        quality = motion._motion_source_framing_quality([source])
        alpha = np.where(np.min(source, axis=2) < 230, 255, 0).astype(np.uint8)
        normalized, bounds = motion._normalise_frames([np.dstack((source, alpha))])
        self.assertGreater(bounds[0], 0)
        self.assertEqual(0, int(np.max(normalized[0][:, 0, 3])))
        self.assertFalse(quality["valid"], quality)

    def test_successful_clip_carries_the_native_framing_receipt(self):
        source = _subject()
        alpha = np.where(np.min(source, axis=2) < 230, 255, 0).astype(np.uint8)
        rgba = np.dstack((source, alpha))
        receipt = motion._motion_source_framing_quality([source] * 24, source_fps=24)
        receipt["all_native_frames"] = True

        def decode(_video, _fps, *, framing_receipt):
            framing_receipt.update(receipt)
            return [source] * 12

        with tempfile.TemporaryDirectory() as stage, \
                mock.patch.object(motion, "_decode_video", side_effect=decode), \
                mock.patch.object(motion, "_segment_frames", return_value=(
                    [rgba] * 12, [None] * 12, "chroma-key-green-screen",
                    {"available": True, "valid": True})), \
                mock.patch.object(motion, "_normalise_frames", return_value=(
                    [rgba] * 12, [40, 16, 49, 167], 1.0)), \
                mock.patch.object(motion, "_pack_sheets", return_value=[]), \
                mock.patch.object(motion, "_encode_alpha_preview", return_value=None), \
                mock.patch.object(motion, "_encode_alpha_stream", return_value=False), \
                mock.patch.object(motion, "RELAXED_LOOP_SHIPPING", True):
            clip = motion._process_clip(
                "move", "clean.mp4", 12, stage, lambda _message: None,
                idle_validation="free")
        self.assertEqual(receipt, clip["source_framing_quality"])
        self.assertEqual(24, clip["source_framing_quality"]["frames_checked"])
        self.assertTrue(clip["source_framing_quality"]["all_native_frames"])

    def test_a_recorded_failure_is_never_reused_but_legacy_clips_still_load(self):
        clip = {"sheets": [{"image": "move-0.png"}]}
        self.assertTrue(motion.motion_clip_compatible(clip, "photograph"))
        clip["source_framing_quality"] = {"valid": False, "available": True}
        self.assertFalse(motion.motion_clip_compatible(clip, "photograph"))
        clip["source_framing_quality"] = {"valid": True, "available": True}
        self.assertTrue(motion.motion_clip_compatible(clip, "photograph"))
        clip["source_framing_quality"] = "broken"
        self.assertFalse(motion.motion_clip_compatible(clip, "photograph"))


class MotionFramingRetryTests(unittest.TestCase):
    def test_retry_invalidates_only_bad_i2v_and_archives_source_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / ".motion-cache" / "signature"
            source = root / "front.png"
            source.write_bytes(b"canonical-body")
            video_generations = {"walk": 0, "move": 0}
            keyframe_generations = {"walk": 0, "move": 0}
            context = {
                "body_source": str(source),
                "image_provider": {"name": "image", "title": "Image"},
                "video_provider": {"name": "video", "title": "Video"},
                "prompts": {
                    f"{kind}_{suffix}": f"{kind} {suffix}"
                    for kind in ("walk", "move") for suffix in ("keyframe", "video")},
                "signature": "a" * 64,
                "cache_root": str(cache.parent), "cache": str(cache),
            }

            def keyframes(*_args):
                (cache / "keyframes").mkdir(parents=True, exist_ok=True)
                outputs = {}
                for kind in keyframe_generations:
                    path = cache / "keyframes" / f"{kind}.png"
                    if not path.exists():
                        keyframe_generations[kind] += 1
                        path.write_bytes(b"keep-the-approved-keyframe")
                    outputs[kind] = str(path)
                return outputs

            def videos(*_args, **_kwargs):
                outputs = {}
                for kind in video_generations:
                    provider = cache / "videos" / f"{kind}-provider"
                    path = provider.parent / f"{kind}.mp4"
                    if not path.exists():
                        self.assertFalse(provider.exists())
                        provider.mkdir(parents=True)
                        video_generations[kind] += 1
                        path.write_bytes(f"{kind}-{video_generations[kind]}".encode())
                        (provider / "cached-response.json").write_text("{}")
                    outputs[kind] = str(path)
                return outputs

            good_receipt = motion._motion_source_framing_quality([_subject()])
            bad_receipt = motion._motion_source_framing_quality([
                _subject(clipped="left")], source_fps=24)

            def process(kind, _video, fps, stage, _log, **_kwargs):
                if kind == "move" and video_generations[kind] == 1:
                    raise motion.GeneratedMotionFramingError(kind, bad_receipt)
                Path(stage, f"{kind}-0.png").write_bytes(b"complete-sheet")
                return {
                    "frames": 1, "fps": fps,
                    "sheets": [{"image": f"{kind}-0.png", "start": 0, "frames": 1}],
                    "source_framing_quality": good_receipt,
                }

            with mock.patch.object(motion, "_build_context", return_value=context), \
                    mock.patch.object(motion, "_generate_keyframes", side_effect=keyframes), \
                    mock.patch.object(motion, "_generate_videos", side_effect=videos), \
                    mock.patch.object(motion, "_process_clip", side_effect=process):
                metadata = motion.build(
                    str(root), kinds=("walk", "move"), log=lambda _message: None)
            self.assertEqual({"walk": 1, "move": 2}, video_generations)
            self.assertEqual({"walk": 1, "move": 1}, keyframe_generations)
            self.assertTrue(metadata["move"]["source_framing_quality"]["valid"])
            self.assertEqual(b"move-2", (root / "motion/raw/move-source.mp4").read_bytes())
            rejections = list((root / ".motion-rejected").glob("*/rejection.json"))
            self.assertEqual(1, len(rejections))
            rejection = json.loads(rejections[0].read_text())
            self.assertEqual("move", rejection["kind"])
            self.assertEqual(bad_receipt, rejection["source_framing_quality"])
            self.assertEqual(b"move-1", rejections[0].with_name("move-source.mp4").read_bytes())


if __name__ == "__main__":
    unittest.main()
