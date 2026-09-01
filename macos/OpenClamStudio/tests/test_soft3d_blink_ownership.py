"""A full-eye blink may not erase a soft-3D character's hair or cheek marks."""
from contextlib import ExitStack
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import blink, export, face


def _eye_fixture():
    image = np.full((180, 180, 3), (90, 150, 220), np.uint8)
    sclera = np.zeros(image.shape[:2], np.uint8)
    cv2.ellipse(sclera, (88, 88), (39, 37), 0, 0, 360, 255, -1)
    image[sclera > 0] = 248
    cv2.ellipse(image, (88, 88), (40, 38), 0, 0, 360, (20, 20, 20), 2)
    cv2.circle(image, (88, 88), 11, (18, 18, 18), -1)
    # A fringe enters from the top, including a lighter glossy interior.
    cv2.fillPoly(image, [np.array([(28, 0), (61, 0), (53, 51)], np.int32)],
                 (20, 25, 28))
    cv2.circle(image, (45, 15), 4, (155, 159, 160), -1)
    # The scar is within the previous huge provider/lash guard, but nowhere
    # near the authored eye. It is deliberately disconnected from the crop.
    cv2.line(image, (127, 134), (158, 130), (18, 18, 18), 3, cv2.LINE_AA)
    cv2.line(image, (143, 123), (145, 145), (18, 18, 18), 3, cv2.LINE_AA)
    return image, sclera


def _pair_fixture():
    skin = (90, 150, 220)
    key = np.full((220, 430, 3), skin, np.uint8)
    shut = key.copy()
    art = np.zeros(key.shape[:2], np.uint8)
    white = np.zeros_like(art)
    closed_ink = np.zeros_like(art)
    eyes = {}
    landmarks = np.full((478, 2), (215, 110), np.float32)
    for side, cx in zip(blink.SIDES, (120, 305)):
        cy = 108
        cv2.ellipse(key, (cx, cy), (39, 39), 0, 0, 360, (248, 248, 248), -1)
        cv2.ellipse(white, (cx, cy), (36, 36), 0, 0, 360, 255, -1)
        cv2.ellipse(key, (cx, cy), (40, 40), 0, 0, 360, (20, 20, 20), 2)
        cv2.circle(key, (cx, cy), 10, (18, 18, 18), -1)
        cv2.line(shut, (cx - 36, cy + 20), (cx + 36, cy + 20),
                 (20, 20, 20), 3, cv2.LINE_AA)
        cv2.line(closed_ink, (cx - 34, cy + 20), (cx + 34, cy + 20), 255, 2)
        # Both marks will enter the semantic crop; neither is an eyelash.
        cv2.fillPoly(art, [np.array([
            (cx - 33, 0), (cx - 7, 0), (cx - 22, 66)
        ], np.int32)], 255)
        cv2.line(art, (cx + 20, 164), (cx + 48, 160), 255, 3, cv2.LINE_AA)
        cv2.line(art, (cx + 34, 154), (cx + 36, 174), 255, 3, cv2.LINE_AA)
        # An eye's *own* attached open lash must still disappear.
        cv2.line(key, (cx - 37, cy - 15), (cx - 48, cy - 26), (20, 20, 20), 3)
        angles = np.linspace(0, np.pi * 2, len(blink.EYE[side]), endpoint=False)
        landmarks[blink.EYE[side], 0] = cx + np.cos(angles) * 39
        landmarks[blink.EYE[side], 1] = cy + np.sin(angles) * 39
        eyes[side] = {"box": [cx - 40, cy - 40, 80, 80]}
    key[art > 0] = (18, 18, 18)
    # Keep source art as uploaded. The old harmonic/provider ownership code
    # could still erase it because classification happened after crop masks.
    shut[art > 0] = key[art > 0]
    return key, shut, landmarks, eyes, art, white, closed_ink


def _registration(stack, landmarks):
    identity = np.array([[1., 0., 0.], [0., 1., 0.]])
    stack.enter_context(mock.patch.object(
        face, "detect_for_intake", return_value=(landmarks, np.eye(4), {})))
    stack.enter_context(mock.patch.object(
        cv2, "estimateAffine2D", return_value=(identity, None)))
    stack.enter_context(mock.patch.object(
        cv2, "estimateAffinePartial2D", return_value=(identity, None)))
    stack.enter_context(mock.patch.object(blink, "_aperture", return_value=15.))


class Soft3DBlinkOwnershipTests(unittest.TestCase):
    def test_full_components_preserve_fringe_gloss_and_disconnected_scar(self):
        key, sclera = _eye_fixture()
        protected = export._soft3d_static_blink_art(key, sclera)
        self.assertIsNotNone(protected)
        for x, y in ((45, 15), (52, 41), (143, 132), (145, 145)):
            self.assertEqual(255, int(protected[y, x]), (x, y))
        self.assertEqual(0, int(protected[88, 88]), "pupil is dynamic")
        self.assertEqual(0, int(protected[88, 48]), "eye outline is dynamic")

    def test_attached_open_lash_is_not_misclassified_as_a_scar(self):
        key, sclera = _eye_fixture()
        cv2.line(key, (49, 77), (24, 73), (20, 20, 20), 3)
        protected = export._soft3d_static_blink_art(key, sclera)
        self.assertIsNotNone(protected)
        self.assertEqual(0, int(protected[73, 24]))
        self.assertEqual(0, int(protected[77, 49]))

    def test_antialias_support_does_not_keep_white_sclera_open(self):
        key, sclera = _eye_fixture()
        protected = export._soft3d_static_blink_art(key, sclera)
        hsv = cv2.cvtColor(key, cv2.COLOR_BGR2HSV)
        white = (hsv[:, :, 1] < 85) & (hsv[:, :, 2] > 135) & (sclera > 0)
        self.assertEqual(0, int(np.count_nonzero(protected[white])))
        self.assertEqual(255, int(protected[132, 131]))

    def test_ambiguous_edge_connected_pupil_fails_closed(self):
        key, sclera = _eye_fixture()
        cv2.line(key, (88, 88), (88, 0), (18, 18, 18), 13)
        self.assertIsNone(export._soft3d_static_blink_art(key, sclera))

    def test_malformed_or_empty_ownership_inputs_fail_closed(self):
        key, sclera = _eye_fixture()
        for image, mask in ((None, sclera), (key, None),
                            (key[:, :, 0], sclera), (key, sclera[:20]),
                            (key, np.zeros_like(sclera))):
            with self.subTest(shape=None if image is None else image.shape):
                self.assertIsNone(export._soft3d_static_blink_art(image, mask))

    def _publish(self, medium, forbid_protection=False):
        key, shut, landmarks, eyes, art, white, closed_ink = _pair_fixture()
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            os.mkdir(os.path.join(directory, "raw"))
            cv2.imwrite(os.path.join(directory, "raw", "v_blink.png"), shut)
            _registration(stack, landmarks)
            if forbid_protection:
                stack.enter_context(mock.patch.object(
                    export, "_soft3d_static_blink_art",
                    side_effect=AssertionError("non-soft3D route changed")))
            # Illustrations retain their existing harmonic fallback. Shaded
            # 3-D eyes now require registered authored skin: publishing a flat
            # fallback oval is explicitly forbidden, even with a valid lid.
            if medium == "illustration":
                stack.enter_context(mock.patch.object(
                    export, "_stylized_flat_skin_registration", return_value=None))
            else:
                stack.enter_context(mock.patch.object(
                    export, "_harmonic_stylized_skin", side_effect=AssertionError(
                        "shaded 3-D publication must not synthesize a flat oval")))
            logs = []
            result = export.preflight_stylized_blink(
                directory, medium, neutral=key, eyes=eyes, log=logs.append)
            rendered = key.copy()
            alpha = np.zeros(key.shape[:2], np.uint8)
            for side in blink.SIDES:
                x, y, w, h = result["metadata"][side]["box"]
                plate = cv2.imdecode(np.frombuffer(
                    result["assets"][f"stylized-blink-{side}.png"], np.uint8),
                    cv2.IMREAD_UNCHANGED)
                a = plate[:, :, 3:4].astype(np.float64) / 255
                old = rendered[y:y+h, x:x+w].copy()
                rendered[y:y+h, x:x+w] = np.rint(
                    plate[:, :, :3] * a + old * (1-a)).clip(0, 255).astype(np.uint8)
                alpha[y:y+h, x:x+w] = np.maximum(
                    alpha[y:y+h, x:x+w], plate[:, :, 3])
            self.assertEqual(["raw"], os.listdir(directory))
        return key, rendered, alpha, art, white, closed_ink, result

    def test_publication_preserves_static_art_and_closes_the_whole_eye(self):
        key, rendered, alpha, art, white, closed_ink, result = self._publish("3d render")
        self.assertEqual("semantic-eye-switch", result["metadata"]["mode"])
        self.assertTrue(np.array_equal(rendered[art > 0], key[art > 0]))
        self.assertEqual(0, int(np.count_nonzero(alpha[art > 0])))
        self.assertTrue(np.all(alpha[white > 0] == 255))
        hsv = cv2.cvtColor(rendered, cv2.COLOR_BGR2HSV)
        self.assertFalse(np.any((white > 0) & (hsv[:, :, 1] < 72)
                               & (hsv[:, :, 2] > 155)))
        self.assertTrue(np.all(cv2.cvtColor(rendered, cv2.COLOR_BGR2GRAY)[closed_ink > 0] < 60))

    def test_illustration_publication_never_calls_soft3d_protection(self):
        *_, result = self._publish("illustration", forbid_protection=True)
        self.assertEqual("semantic-eye-switch", result["metadata"]["mode"])

    def test_photo_and_unknown_never_read_or_modify_stylized_assets(self):
        with mock.patch.object(export.cv2, "imread", side_effect=AssertionError), \
                mock.patch.object(export, "_soft3d_static_blink_art", side_effect=AssertionError):
            for medium in ("photograph", "unknown", None):
                self.assertIsNone(export.preflight_stylized_blink("/no-assets", medium))


if __name__ == "__main__":
    unittest.main()
