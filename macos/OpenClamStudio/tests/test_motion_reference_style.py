"""Motion-only 2-D evidence recovery; no model downloads or provider calls."""
import base64
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from studio import face, motion


def _decode(value):
    return cv2.imdecode(np.frombuffer(base64.b64decode(value), np.uint8), cv2.IMREAD_COLOR)


def _evidence(image, medium="unknown", eye_span=48):
    landmarks = np.zeros((478, 2), np.float32)
    landmarks[face.EYE_R] = (64-eye_span/2, 55)
    landmarks[face.EYE_L] = (64+eye_span/2, 55)
    landmarks[face.NOSE_TIP] = (64, 88)
    return {"metadata": {"source_medium": medium},
            "native_landmarks": landmarks, "native_crop": image}


def _samples(start=0, count=5):
    return [{"index": index, "position": index / 12,
             "frame": np.full((24, 24, 3), index, np.uint8)}
            for index in range(start, start+count)]


class MotionReferencePixelsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((Path(__file__).parent / "fixtures" /
                                  "celine_motion_reference.json").read_text())
        cls.reference = _decode(cls.fixture["reference"]["jpeg_base64"])

    def test_real_compressed_2d_matches_but_actual_3d_drift_does_not(self):
        """These are retained actual frames, not circular synthetic labels."""
        for candidate in self.fixture["candidates"]:
            with self.subTest(label=candidate["label"], index=candidate["source_index"]):
                quality = motion._motion_reference_similarity(
                    self.reference, _decode(candidate["jpeg_base64"]))
                self.assertTrue(quality["available"])
                self.assertEqual(candidate["expected_match"], quality["valid"])

    def test_actual_3d_drift_still_fails_when_classifier_is_forced_unknown(self):
        reference = _evidence(self.reference, "illustration")
        for candidate in self.fixture["candidates"]:
            if candidate["expected_match"]:
                continue
            with self.subTest(index=candidate["source_index"]), \
                    mock.patch.object(motion, "_frame_face_evidence", return_value=
                                      _evidence(_decode(candidate["jpeg_base64"]))):
                quality = motion._motion_illustration_reference_match(reference, self.reference)
            self.assertTrue(quality["available"])
            self.assertFalse(quality["valid"])
            self.assertEqual("unknown", quality["classifier_medium"])

    def test_similar_palette_or_blurred_reference_is_not_positive_evidence(self):
        blank = np.full_like(self.reference, (110, 170, 220))
        blurred = cv2.GaussianBlur(self.reference, (31, 31), 8)
        for candidate in (blank, blurred):
            self.assertFalse(motion._motion_reference_similarity(
                self.reference, candidate)["valid"])
        self.assertFalse(motion._motion_reference_similarity(blank, blank)["valid"])

    def test_missing_or_incompatible_pixels_fail_closed(self):
        for candidate in (None, np.zeros((10, 10, 3), np.uint8),
                          np.zeros((144, 128), np.uint8)):
            self.assertFalse(motion._motion_reference_similarity(
                self.reference, candidate)["valid"])

    def test_known_other_medium_is_never_rescued(self):
        reference = _evidence(self.reference, "illustration")
        for medium in ("photograph", "3d render", "illustration", ""):
            with self.subTest(medium=medium), \
                    mock.patch.object(motion, "_frame_face_evidence", return_value=
                                      _evidence(self.reference, medium)), \
                    mock.patch.object(motion, "_motion_reference_similarity") as compare:
                quality = motion._motion_illustration_reference_match(reference, self.reference)
            self.assertFalse(quality["valid"])
            compare.assert_not_called()

    def test_too_small_native_face_cannot_be_upscaled_into_proof(self):
        with mock.patch.object(motion, "_frame_face_evidence", return_value=
                               _evidence(self.reference, eye_span=12)):
            quality = motion._motion_illustration_reference_match(
                _evidence(self.reference, "illustration"), self.reference)
        self.assertFalse(quality["available"])
        self.assertFalse(quality["valid"])

    def test_native_resolution_budget_is_shared_by_both_faces(self):
        with mock.patch.object(motion, "_frame_face_evidence", return_value=
                               _evidence(self.reference, eye_span=30)), \
                mock.patch.object(motion, "_motion_reference_face", return_value=
                                  np.zeros((90, 80, 3), np.uint8)) as register:
            quality = motion._motion_illustration_reference_match(
                _evidence(self.reference, "illustration", eye_span=70), self.reference)
        self.assertEqual([80, 80], [call.args[1] for call in register.call_args_list])
        self.assertEqual([80, 90], quality["comparison_size"])

    def test_unknown_reference_or_missing_face_never_becomes_positive_evidence(self):
        for reference in (None, _evidence(self.reference)):
            with mock.patch.object(motion, "_frame_face_evidence") as detect:
                quality = motion._motion_illustration_reference_match(reference, self.reference)
            self.assertFalse(quality["valid"])
            detect.assert_not_called()
        with mock.patch.object(motion, "_frame_face_evidence", return_value=None):
            quality = motion._motion_illustration_reference_match(
                _evidence(self.reference, "illustration"), self.reference)
        self.assertFalse(quality["valid"])


class MotionReferenceGateTests(unittest.TestCase):
    def _audit(self, labels, matches, references=("illustration", "illustration"),
               extra=None, expected="illustration"):
        samples = _samples()
        def classify(image):
            return labels[int(image[0,0,0])]
        def compare(_reference, image):
            return {"v": 1, "available": True,
                    "valid": int(image[0,0,0]) in matches}
        with mock.patch.object(motion, "_plate_face_medium", side_effect=references), \
                mock.patch.object(motion, "_motion_2d_reference_evidence",
                                  return_value={"reference": True}) as load, \
                mock.patch.object(motion, "_motion_source_sha256", return_value="a"*64), \
                mock.patch.object(motion, "_frame_face_medium", side_effect=classify), \
                mock.patch.object(motion, "_motion_illustration_reference_match",
                                  side_effect=compare) as compare_call, \
                mock.patch.object(motion, "_representative_video_frames",
                                  side_effect=[samples, extra or samples]) as decode:
            quality = motion._motion_video_medium_quality(
                "source.mp4", "keyframe.png", "body.png", expected, strict=True)
        return quality, load, compare_call, decode

    def test_unknown_labels_stay_unknown_while_two_reference_matches_are_recorded(self):
        quality, _load, _compare, decode = self._audit([None]*5, {0,4})
        self.assertTrue(quality["valid"])
        self.assertTrue(quality["available"])
        self.assertEqual(2, quality["matching_samples"])
        self.assertEqual(2, quality["reference_matching_samples"])
        self.assertEqual(0, quality["classifier_known_samples"])
        self.assertEqual([None]*5, [sample["source_medium"] for sample in quality["samples"]])
        self.assertEqual("a"*64, quality["reference_comparison"]["source_video_sha256"])
        self.assertEqual(1, decode.call_count)

    def test_a_lone_match_cannot_publish_even_with_one_mismatch(self):
        quality, _load, _compare, decode = self._audit([None, "photograph", None, None, None], {0})
        self.assertFalse(quality["valid"])
        self.assertEqual("insufficient-evidence", quality["failure_kind"])
        self.assertEqual(1, quality["matching_samples"])
        self.assertEqual(2, decode.call_count)
        self.assertEqual(5, len(quality["samples"]))  # never double count a decoded frame

    def test_extra_temporal_samples_can_supply_a_second_match(self):
        quality, _load, _compare, decode = self._audit([None]*11, {0,10}, extra=_samples(5,6))
        self.assertTrue(quality["valid"])
        self.assertEqual(2, quality["matching_samples"])
        self.assertEqual(11, len(quality["samples"]))
        self.assertEqual(motion.MOTION_MEDIUM_REFERENCE_EXTRA_FRACTIONS,
                         decode.call_args_list[-1].kwargs["fractions"])

    def test_zero_primary_matches_do_not_starve_bounded_extra_samples(self):
        # Installed AVFoundation decoding put Celine's sole primary match
        # below the unchanged native-reference threshold. The two strong
        # matches were both among the six positions the old gate never read.
        labels = [None]*11
        labels[1] = "photograph"
        quality, _load, _compare, decode = self._audit(
            labels, {5,10}, extra=_samples(5,6))
        self.assertTrue(quality["valid"])
        self.assertTrue(quality["available"])
        self.assertEqual(2, quality["reference_matching_samples"])
        self.assertEqual(1, quality["mismatch_samples"])
        self.assertTrue(all(not sample.get("reference_match", {}).get("valid")
                            for sample in quality["samples"][:5]))
        self.assertEqual(11, len(quality["samples"]))
        self.assertEqual(2, decode.call_count)
        self.assertEqual(motion.MOTION_MEDIUM_REFERENCE_EXTRA_FRACTIONS,
                         decode.call_args_list[-1].kwargs["fractions"])

    def test_no_primary_classifications_can_recover_bounded_positive_evidence(self):
        quality, _load, _compare, decode = self._audit(
            [None]*11, {5,10}, extra=_samples(5,6))
        self.assertTrue(quality["valid"])
        self.assertEqual(2, quality["matching_samples"])
        self.assertEqual(0, quality["classifier_known_samples"])
        self.assertEqual(2, decode.call_count)

    def test_inconclusive_extra_samples_still_fail_closed(self):
        for matches in (set(), {10}):
            with self.subTest(matches=matches):
                quality, _load, _compare, decode = self._audit(
                    [None]*11, matches, extra=_samples(5,6))
            self.assertFalse(quality["valid"])
            self.assertEqual("insufficient-evidence", quality["failure_kind"])
            self.assertEqual(len(matches), quality["matching_samples"])
            self.assertEqual(11, len(quality["samples"]))
            self.assertEqual(2, decode.call_count)

    def test_zero_primary_matches_cannot_rescue_repeated_3d_in_extra_samples(self):
        labels = [None]*11
        labels[6] = labels[8] = "3d render"
        quality, _load, _compare, decode = self._audit(
            labels, {5,10}, extra=_samples(5,6))
        self.assertFalse(quality["valid"])
        self.assertEqual("source-medium-drift", quality["failure_kind"])
        self.assertEqual(2, quality["matching_samples"])
        self.assertEqual(2, quality["dominant_mismatch_samples"])
        self.assertEqual(2, decode.call_count)

    def test_decisive_primary_mismatch_is_not_retried_into_success(self):
        for medium in ("3d render", "photograph"):
            with self.subTest(medium=medium):
                quality, _load, _compare, decode = self._audit(
                    [medium]*5 + [None]*6, set(range(5,11)), extra=_samples(5,6))
            self.assertFalse(quality["valid"])
            self.assertEqual("source-medium-drift", quality["failure_kind"])
            self.assertEqual(0, quality["matching_samples"])
            self.assertEqual(1, decode.call_count)

    def test_added_samples_do_not_disregard_repeated_3d_drift(self):
        labels = [None]*11
        labels[6] = labels[8] = "3d render"
        quality, _load, _compare, _decode = self._audit(labels, {0,10}, extra=_samples(5,6))
        self.assertFalse(quality["valid"])
        self.assertEqual("source-medium-drift", quality["failure_kind"])
        self.assertEqual(2, quality["matching_samples"])

    def test_ref_comparison_requires_both_independently_positive_2d_references(self):
        for references in ((None,"illustration"), ("illustration",None),
                           ("3d render","illustration"), ("illustration","photograph")):
            with self.subTest(references=references):
                quality, load, compare, _decode = self._audit([None]*5, {0,4}, references)
            self.assertFalse(quality["valid"])
            load.assert_not_called()
            compare.assert_not_called()

    def test_reference_match_does_not_override_known_mismatch(self):
        quality, _load, compare, _decode = self._audit(["3d render"]*5, set(range(5)))
        self.assertFalse(quality["valid"])
        self.assertEqual(0, quality["reference_matching_samples"])
        compare.assert_not_called()

    def test_photo_and_soft_3d_lanes_do_not_use_the_new_matcher(self):
        for medium in ("photograph", "3d render"):
            quality, load, compare, _decode = self._audit(
                [medium]*5, set(), (medium,medium), expected=medium)
            self.assertTrue(quality["valid"])
            load.assert_not_called()
            compare.assert_not_called()


class MotionInconclusiveReceiptTests(unittest.TestCase):
    def test_unknown_audit_retains_raw_cache_and_stops_without_new_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / ".motion-cache/sig"
            keyframe = cache / "keyframes/idle.png"
            video = cache / "videos/idle.mp4"
            keyframe.parent.mkdir(parents=True)
            video.parent.mkdir(parents=True)
            keyframe.write_bytes(b"exact-original-keyframe")
            video.write_bytes(b"exact-original-video")
            quality = {"available": False, "valid": False,
                       "failure_kind": "insufficient-evidence",
                       "reason": "only 0 representative frames were classifiable"}
            context = {
                "body_source": str(root / "body.png"),
                "image_provider": {"name": "image", "title": "Image"},
                "video_provider": {"name": "video", "title": "Video"},
                "prompts": {"idle_keyframe": "2d", "idle_video": "2d"},
                "source_medium": "illustration", "strict_source_medium": True,
                "signature": "c"*64, "cache_root": str(cache.parent), "cache": str(cache),
            }
            with mock.patch.object(motion, "_build_context", return_value=context), \
                    mock.patch.object(motion, "_generate_keyframes", return_value={"idle":str(keyframe)}), \
                    mock.patch.object(motion, "_motion_keyframe_medium_failures", return_value=[]), \
                    mock.patch.object(motion, "_generate_videos", return_value={"idle":str(video)}) as generate, \
                    mock.patch.object(motion, "_motion_video_medium_quality", return_value=quality), \
                    mock.patch.object(motion, "_invalidate_cached_video") as invalidate, \
                    mock.patch.object(motion, "_process_clip") as process:
                with self.assertRaisesRegex(motion.GeneratedMotionMediumError,
                                            "no automatic new provider generation"):
                    motion.build(directory, kinds=("idle",), log=lambda _message: None)
            self.assertEqual(1, generate.call_count)
            invalidate.assert_not_called()
            process.assert_not_called()
            self.assertEqual(b"exact-original-video", video.read_bytes())
            self.assertEqual(b"exact-original-keyframe", keyframe.read_bytes())
            records = list((root / ".motion-rejected").glob("*/rejection.json"))
            self.assertEqual(1, len(records))
            receipt = json.loads(records[0].read_text())
            self.assertEqual(quality, receipt["source_medium_quality"])
            self.assertFalse(receipt["automatic_retry_allowed"])
            self.assertEqual(b"exact-original-video", (records[0].parent / "idle-source.mp4").read_bytes())
            self.assertFalse((root / "motion").exists())


if __name__ == "__main__":
    unittest.main()
