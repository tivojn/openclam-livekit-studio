"""Regressions for current-frame, pose-guided arm and hand recovery."""
import unittest

import cv2
import numpy as np

from studio import motion


def _arm_pose(include_wrist=True):
    points = {
        "nose": (140, 20),
        "neck": (140, 45),
        "root": (140, 145),
        "left_hip": (120, 145),
        "right_hip": (160, 145),
        "left_knee": (120, 185),
        "right_knee": (160, 185),
        "left_ankle": (120, 220),
        "right_ankle": (160, 220),
        "right_shoulder": (150, 65),
        "right_elbow": (106, 71),
    }
    if include_wrist:
        points["right_wrist"] = (64, 76)
    return {
        "width": 240,
        "height": 240,
        "joints": {
            name: {"x": x, "y": y, "confidence": 0.95}
            for name, (x, y) in points.items()
        },
    }


def _arm_fixture():
    source = np.full((240, 240, 3), 255, np.uint8)
    subject = np.zeros(source.shape[:2], np.uint8)
    # Torso anchors the arm to a reliable semantic-mask component.
    cv2.rectangle(subject, (120, 52), (180, 170), 255, cv2.FILLED)
    cv2.line(subject, (150, 65), (106, 71), 255, 13, cv2.LINE_8)
    cv2.line(subject, (106, 71), (64, 76), 255, 13, cv2.LINE_8)
    cv2.line(subject, (64, 76), (46, 78), 255, 11, cv2.LINE_8)
    cv2.circle(subject, (43, 78), 7, 255, cv2.FILLED)
    source[subject > 0] = (72, 126, 188)

    # A dark plate mark lies inside the broad pose capsule but is not connected
    # to the true arm and therefore must never be admitted.
    source[84:87, 103:106] = (25, 35, 55)
    # A pure-white opening inside the lost band represents visible background
    # between fingers/limbs; source authority must keep it transparent.
    source[72:75, 91:94] = 255

    alpha = subject.copy()
    alpha[62:88, 82:120] = 0
    current = np.zeros((240, 240, 4), np.uint8)
    current[:, :, 3] = alpha
    current[:, :, :3][alpha > 0] = source[alpha > 0]
    return source, current


class ArmAlphaRecovery(unittest.TestCase):
    def test_current_source_restores_connected_forearm_without_plate_marks(self):
        source, current = _arm_fixture()
        current[67:73, 120:129, :3] = (2, 3, 4)
        before = current[:, :, 3].copy()

        repaired = motion._recover_source_upper_limbs(
            current, before, source, _arm_pose())

        self.assertGreaterEqual(int(repaired[70, 110]), 24)
        self.assertGreaterEqual(int(repaired[76, 72]), 24)
        self.assertEqual(tuple(source[70, 110]), tuple(current[70, 110, :3]))
        self.assertEqual(tuple(source[69, 124]), tuple(current[69, 124, :3]))
        self.assertEqual(0, int(repaired[84, 104]))
        self.assertEqual(0, int(repaired[73, 92]))

    def test_full_stabiliser_repairs_from_current_frame_without_temporal_trail(self):
        source, current = _arm_fixture()
        repaired = motion._stabilise_segmented(
            [current], poses=[_arm_pose()], source_frames=[source])[0]

        self.assertGreaterEqual(int(repaired[70, 110, 3]), 24)
        self.assertEqual(tuple(source[70, 110]), tuple(repaired[70, 110, :3]))
        self.assertEqual(0, int(repaired[84, 104, 3]))
        self.assertEqual(0, int(repaired[73, 92, 3]))

    def test_hard_limb_gate_rejects_broken_center_and_accepts_recovery(self):
        source, current = _arm_fixture()
        source_alpha = motion._white_plate_source_alpha(source)
        broken = motion._source_upper_limb_quality(
            current[:, :, 3], source_alpha, _arm_pose())

        recovered_alpha = motion._recover_source_upper_limbs(
            current, current[:, :, 3].copy(), source, _arm_pose(),
            source_alpha=source_alpha)
        recovered = motion._source_upper_limb_quality(
            recovered_alpha, source_alpha, _arm_pose(),
            baseline_alpha=current[:, :, 3])

        self.assertTrue(broken["available"])
        self.assertFalse(broken["valid"])
        self.assertTrue(any(
            not segment["output_connected"]
            or segment["alpha_recall"] < 0.90
            or segment["cross_section_recall_p10"] < 0.75
            for segment in broken["segments"].values()
        ))
        self.assertTrue(recovered["available"])
        self.assertTrue(recovered["valid"], recovered)

    def test_recovery_never_introduces_core_outside_current_source_support(self):
        source, current = _arm_fixture()
        before = current[:, :, 3].copy()
        source_alpha = motion._white_plate_source_alpha(source)
        repaired = motion._recover_source_upper_limbs(
            current, before, source, _arm_pose(), source_alpha=source_alpha)

        introduced_core = (
            (repaired >= 96) & (before < 96) & (source_alpha < 24))
        self.assertEqual(0, int(np.count_nonzero(introduced_core)))

    def test_incomplete_arm_pose_leaves_matte_unchanged(self):
        source, current = _arm_fixture()
        before = current[:, :, 3].copy()

        repaired = motion._recover_source_upper_limbs(
            current, before, source, _arm_pose(include_wrist=False))

        np.testing.assert_array_equal(before, repaired)


if __name__ == "__main__":
    unittest.main()
