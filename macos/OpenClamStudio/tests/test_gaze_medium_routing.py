"""Actual expression-build routing, including measured flat-art crop ownership."""
import unittest
from unittest import mock

import numpy as np

from studio import authored_gaze, button3d_gaze, expression, rigid_gaze, soft3d_gaze
from studio.blink import SIDES, _box
from tests.test_authored_gaze import fixture
from tests.test_button3d_gaze import fixture as button_fixture
from tests.test_soft3d_gaze import shaded_eye_fixture, tissue_stubs


class AuthoredMediumRoutingTests(unittest.TestCase):
    def test_explicit_flat_art_uses_observed_box_and_keeps_source_pixels(self):
        image, lm, _requested, _masks = fixture()
        before = image.copy()
        with tissue_stubs(), \
                mock.patch.object(rigid_gaze, "prepare", side_effect=AssertionError("photo policy on art")), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=AssertionError("3D policy on flat art")), \
                mock.patch.object(expression, "gaze_state", side_effect=AssertionError("radial warp on art")), \
                mock.patch.object(authored_gaze, "prepare", wraps=authored_gaze.prepare) as prepare:
            result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                      source_medium="illustration", log=lambda *_: None)
        self.assertEqual(prepare.call_count, 2)
        self.assertEqual(result["gaze"]["mode"], authored_gaze.MODE)
        self.assertEqual(set(result["gaze"]["geometry"]), {"r", "l"})
        for side in SIDES:
            layer = result["gaze"][side]
            x, y, w, h = layer["box"]
            old = _box(expression._eyeball_mask(image.shape, lm, side, 1), 7, image.shape)
            self.assertGreater(y + h, old[1] + old[3])
            self.assertEqual(layer["box"], result["gaze"]["geometry"][side]["box"])
            for tile in layer["patches"]:
                self.assertEqual(tile.shape, (h, w, 4))
            neutral = layer["patches"][1]
            self.assertFalse(neutral[..., 3].any())
            np.testing.assert_array_equal(neutral[..., :3], image[y:y+h, x:x+w])
        np.testing.assert_array_equal(image, before)

    def test_legacy_explicit_anime_is_same_authored_policy(self):
        image, lm, _, _ = fixture()
        with tissue_stubs():
            expected = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                        source_medium="illustration", log=lambda *_: None)
            actual = expression.build(image, lm, dxs=[-9, 0, 9], dys=[0],
                                      source_medium=" Anime ", log=lambda *_: None)
        self.assertEqual(actual["gaze"]["mode"], authored_gaze.MODE)
        for side in SIDES:
            self.assertEqual(actual["gaze"][side]["box"], expected["gaze"][side]["box"])
            for a, b in zip(actual["gaze"][side]["patches"], expected["gaze"][side]["patches"]):
                np.testing.assert_array_equal(a, b)

    def test_partial_detection_keeps_both_eyes_neutral_not_legacy_warp(self):
        image, lm, box, _ = fixture()
        measured = authored_gaze.prepare(image, lm, "r", box)
        with tissue_stubs(), \
                mock.patch.object(authored_gaze, "prepare", side_effect=[
                    measured, authored_gaze.UnsupportedAuthoredIris("ambiguous second eye")]), \
                mock.patch.object(expression, "gaze_state", side_effect=AssertionError("unsafe fallback")):
            result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[-3.5, 0, 3.5],
                                      source_medium="illustration", log=lambda *_: None)
        self.assertEqual(result["gaze"]["mode"], authored_gaze.NEUTRAL_MODE)
        self.assertIn("ambiguous second eye", result["gaze"]["geometry"]["fallback_reason"])
        for side in SIDES:
            x, y, w, h = result["gaze"][side]["box"]
            for tile in result["gaze"][side]["patches"]:
                self.assertFalse(tile[..., 3].any())
                np.testing.assert_array_equal(tile[..., :3], image[y:y+h, x:x+w])

    def test_ambiguous_media_are_not_guessed_into_cartoon_policies(self):
        image, lm, _, _ = fixture()
        with tissue_stubs(), \
                mock.patch.object(authored_gaze, "prepare", side_effect=AssertionError("guessed flat art")), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=AssertionError("guessed 3D art")):
            for medium in ("unknown", "game art", "", None):
                with self.subTest(medium=medium):
                    result = expression.build(image, lm, dxs=[0], dys=[0],
                                              source_medium=medium, log=lambda *_: None)
                    self.assertNotIn("mode", result["gaze"])


class Button3DMediumRoutingTests(unittest.TestCase):
    def test_typed_shaded_rejection_restarts_both_eyes_with_native_3d_button_policy(self):
        image, lm, _, _, _ = button_fixture()
        original, landmarks = image.copy(), lm.copy()
        native_prepare, native_state = button3d_gaze.prepare, button3d_gaze.state
        for failed_side in SIDES:
            with self.subTest(failed_side=failed_side):
                events, prepared = [], {}

                def shade(_key, _lm, side, _box):
                    events.append(f"shaded-{side}")
                    if side == failed_side:
                        raise soft3d_gaze.UnsupportedSoft3DIris("no shaded limbus")
                    return object()  # Must be discarded, never rendered/mixed.

                def button(key, points, side, box):
                    events.append(f"button-{side}")
                    prepared[side] = native_prepare(key, points, side, box)
                    return prepared[side]

                def state(eye, dx, dy):
                    self.assertEqual(set(prepared), set(SIDES), "render only a complete pair")
                    return native_state(eye, dx, dy)

                with tissue_stubs(), \
                        mock.patch.object(soft3d_gaze, "prepare", side_effect=shade), \
                        mock.patch.object(soft3d_gaze, "state", side_effect=AssertionError("mixed shaded eye")), \
                        mock.patch.object(button3d_gaze, "prepare", side_effect=button), \
                        mock.patch.object(button3d_gaze, "state", side_effect=state), \
                        mock.patch.object(rigid_gaze, "prepare", side_effect=AssertionError("3D relabeled photo")), \
                        mock.patch.object(authored_gaze, "prepare", side_effect=AssertionError("3D relabeled flat art")), \
                        mock.patch.object(expression, "gaze_state", side_effect=AssertionError("unsafe radial fallback")):
                    result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[-3.5, 0, 3.5],
                                              source_medium="3d render", log=lambda *_: None)
                attempts = list(SIDES)[:list(SIDES).index(failed_side) + 1]
                self.assertEqual(events, [f"shaded-{s}" for s in attempts]
                                 + [f"button-{s}" for s in SIDES])
                gaze = result["gaze"]
                self.assertEqual(gaze["mode"], button3d_gaze.MODE)
                self.assertEqual(set(gaze["geometry"]), set(SIDES))
                for side in SIDES:
                    p = prepared[side]
                    self.assertEqual(gaze[side]["box"], list(p.box))
                    self.assertEqual(gaze["geometry"][side], p.metadata())
                    self.assertEqual(gaze["geometry"][side]["source_medium"], "3d render")
                    self.assertEqual(gaze["geometry"][side]["shape_fit"], "none")
                    expected = [native_state(p, dx, dy) for dy in gaze["dys"] for dx in gaze["dxs"]]
                    self.assertEqual(len(gaze[side]["patches"]), len(expected))
                    for actual, wanted in zip(gaze[side]["patches"], expected):
                        np.testing.assert_array_equal(actual, wanted)
                np.testing.assert_array_equal(image, original)
                np.testing.assert_array_equal(lm, landmarks)

    def test_button_rejection_on_either_eye_keeps_both_transparent_neutral(self):
        image, lm, boxes, _, _ = button_fixture()
        native_prepare = button3d_gaze.prepare
        for failed_side in SIDES:
            with self.subTest(failed_side=failed_side):
                def button(key, points, side, _box):
                    if side == failed_side:
                        raise button3d_gaze.UnsupportedButtonIris("uncertain native rim")
                    return native_prepare(key, points, side, boxes[side])

                with tissue_stubs(), \
                        mock.patch.object(soft3d_gaze, "prepare", side_effect=soft3d_gaze.UnsupportedSoft3DIris("no shaded limbus")), \
                        mock.patch.object(button3d_gaze, "prepare", side_effect=button), \
                        mock.patch.object(button3d_gaze, "state", side_effect=AssertionError("partial pair rendered")), \
                        mock.patch.object(expression, "gaze_state", side_effect=AssertionError("radial fallback")):
                    result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[-3.5, 0, 3.5],
                                              source_medium="3d render", log=lambda *_: None)
                self.assertEqual(result["gaze"]["mode"], soft3d_gaze.NEUTRAL_MODE)
                reason = result["gaze"]["geometry"]["fallback_reason"]
                self.assertIn("no shaded limbus", reason)
                self.assertIn("uncertain native rim", reason)
                for side in SIDES:
                    x, y, width, height = result["gaze"][side]["box"]
                    for patch in result["gaze"][side]["patches"]:
                        self.assertFalse(patch[..., 3].any())
                        np.testing.assert_array_equal(patch[..., :3], image[y:y+height, x:x+width])

    def test_successful_shaded_pair_never_tries_buttons_and_keeps_exact_states(self):
        image, lm, _, _ = shaded_eye_fixture()
        with tissue_stubs(), \
                mock.patch.object(button3d_gaze, "prepare", side_effect=AssertionError("changed successful shaded policy")):
            result = expression.build(image, lm, dxs=[-9, 0, 9], dys=[-3.5, 0, 3.5],
                                      source_medium="3d render", log=lambda *_: None)
        gaze = result["gaze"]
        self.assertEqual(gaze["mode"], soft3d_gaze.MODE)
        for side in SIDES:
            box = _box(expression._eyeball_mask(image.shape, lm, side, 1), 7, image.shape)
            prepared = soft3d_gaze.prepare(image, lm, side, box)
            self.assertEqual(gaze[side]["box"], list(prepared.box))
            self.assertEqual(gaze["geometry"][side], prepared.metadata())
            expected = [soft3d_gaze.state(prepared, dx, dy)
                        for dy in gaze["dys"] for dx in gaze["dxs"]]
            for actual, wanted in zip(gaze[side]["patches"], expected):
                np.testing.assert_array_equal(actual, wanted)

    def test_no_button_dispatch_for_photo_flat_art_or_unspecified_media(self):
        image, lm, _, _ = shaded_eye_fixture()
        with tissue_stubs(), \
                mock.patch.object(button3d_gaze, "prepare", side_effect=AssertionError("wrong-medium button policy")):
            for medium in ("photograph", "illustration", "anime", "unknown", "game art", "3D", "", None):
                with self.subTest(medium=medium):
                    result = expression.build(image, lm, dxs=[0], dys=[0],
                                              source_medium=medium, log=lambda *_: None)
                    self.assertNotEqual(result["gaze"].get("mode"), button3d_gaze.MODE)

    def test_unexpected_errors_are_not_hidden_as_neutral_or_button_fallback(self):
        image, lm, _, _, _ = button_fixture()
        with tissue_stubs(), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=RuntimeError("shaded bug")), \
                mock.patch.object(button3d_gaze, "prepare", side_effect=AssertionError("not a typed rejection")):
            with self.assertRaisesRegex(RuntimeError, "shaded bug"):
                expression.build(image, lm, dxs=[0], dys=[0], source_medium="3d render", log=lambda *_: None)
        with tissue_stubs(), \
                mock.patch.object(soft3d_gaze, "prepare", side_effect=soft3d_gaze.UnsupportedSoft3DIris("unsupported")), \
                mock.patch.object(button3d_gaze, "prepare", side_effect=RuntimeError("button bug")):
            with self.assertRaisesRegex(RuntimeError, "button bug"):
                expression.build(image, lm, dxs=[0], dys=[0], source_medium="3d render", log=lambda *_: None)


if __name__ == "__main__":
    unittest.main()
