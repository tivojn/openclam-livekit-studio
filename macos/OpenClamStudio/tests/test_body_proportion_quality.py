import json
import os
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np

from studio import body, body_proportion


class BodyProportionQualityTest(unittest.TestCase):
    @staticmethod
    def _fresh_cleo_plate():
        """Synthetic alpha geometry from Cleo's 2026-08-27 fresh front."""
        plate = np.zeros((1448, 1086, 4), dtype=np.uint8)
        # Stored body bounds: x354, y17, width367, height1403.
        plate[17:1420, 354:721, :3] = 160
        plate[17:1420, 354:721, 3] = 255
        return plate

    def test_current_fresh_editorial_case_is_rejected_as_head_heavy(self):
        report = body_proportion.assess(
            self._fresh_cleo_plate(),
            [479, 83, 121, 171],
            {"style": "editorial"},
        )
        self.assertTrue(report["measurable"])
        self.assertTrue(report["gate_required"])
        self.assertEqual(report["gate_trigger"], "style:editorial")
        self.assertAlmostEqual(report["apparent_heads_tall"], 5.92, places=2)
        self.assertFalse(report["valid"])
        self.assertIn("head-heavy", report["reason"])
        self.assertIn("require at least 6.45", report["reason"])
        self.assertEqual(body_proportion.failure(report), report["reason"])

    def test_same_geometry_does_not_reject_an_ordinary_body(self):
        report = body_proportion.assess(
            self._fresh_cleo_plate(),
            [479, 83, 121, 171],
            {
                "style": "photorealistic",
                "prompt": "A natural adult standing portrait in everyday clothes.",
            },
        )
        self.assertTrue(report["measurable"])
        self.assertFalse(report["gate_required"])
        self.assertTrue(report["valid"])
        self.assertIsNone(report["minimum_apparent_heads"])
        self.assertIsNone(body_proportion.failure(report))

    def test_explicit_runway_brief_enables_gate_outside_editorial_style(self):
        report = body_proportion.assess(
            self._fresh_cleo_plate(),
            [479, 83, 121, 171],
            {
                "style": "photorealistic",
                "prompt": "Use realistic 7.5-to-8-head runway-supermodel proportions.",
            },
        )
        self.assertTrue(report["gate_required"])
        self.assertTrue(report["gate_trigger"].startswith("brief:"))
        self.assertFalse(report["valid"])

    def test_balanced_editorial_fixture_passes(self):
        # Face bottom y227 gives a 210px apparent head: 1403/210 = 6.681.
        report = body_proportion.assess(
            self._fresh_cleo_plate(),
            [486, 52, 110, 175],
            {"style": "editorial"},
        )
        self.assertAlmostEqual(report["apparent_heads_tall"], 6.681, places=3)
        self.assertTrue(report["valid"])
        self.assertIn("passed", report["reason"])

    def test_report_is_json_safe_and_shoulder_measurement_is_diagnostic(self):
        pose = {
            "joints": {
                "left_shoulder": {
                    "x": 652.4, "y": 317.9, "confidence": 0.59,
                },
                "right_shoulder": {
                    "x": 415.5, "y": 323.6, "confidence": 0.79,
                },
            },
        }
        report = body_proportion.assess(
            self._fresh_cleo_plate(),
            [479, 83, 121, 171],
            {"style": "editorial"},
            pose=pose,
        )
        encoded = json.dumps(report, sort_keys=True)
        self.assertIn('"apparent_heads_tall": 5.92', encoded)
        self.assertAlmostEqual(report["shoulders"]["span_px"], 236.969, places=3)
        self.assertAlmostEqual(
            report["shoulders"]["span_to_face_width"], 1.958, places=3)
        self.assertAlmostEqual(
            report["shoulders"]["span_to_visual_head_height"], 1.0,
            places=3)
        self.assertTrue(report["shoulders"]["reliable_for_diagnostic"])

    def test_detached_plate_fragment_cannot_make_person_artificially_taller(self):
        plate = self._fresh_cleo_plate()
        plate[1435:1445, 50:60, :3] = 200
        plate[1435:1445, 50:60, 3] = 255
        report = body_proportion.assess(
            plate, [479, 83, 121, 171], {"style": "editorial"})
        self.assertEqual(report["person_bounds"], [354, 17, 367, 1403])
        self.assertAlmostEqual(report["apparent_heads_tall"], 5.92, places=2)

    def test_unmeasurable_ordinary_is_exempt_but_editorial_fails_closed(self):
        empty = np.zeros((120, 80, 4), dtype=np.uint8)
        ordinary = body_proportion.assess(
            empty, [10, 10, 20, 30], {"style": "photorealistic"})
        editorial = body_proportion.assess(
            empty, [10, 10, 20, 30], {"style": "editorial"})
        self.assertTrue(ordinary["valid"])
        self.assertFalse(ordinary["measurable"])
        self.assertFalse(editorial["valid"])
        self.assertFalse(editorial["measurable"])

    def test_body_helper_raises_the_typed_proportion_error(self):
        with self.assertRaises(body.GeneratedBodyProportionError) as raised:
            body._body_proportion_report(
                self._fresh_cleo_plate(), [479, 83, 121, 171],
                {"style": "editorial"}, log=lambda _message: None)
        self.assertIn("head-heavy", str(raised.exception))

    def test_front_preflight_rejection_skips_side_and_back_and_clears_cache(self):
        config = {"provider": "openai", "model": "gpt-image-2", "api_key": "x"}
        public = {
            "name": "openai", "title": "OpenAI Images",
            "model": "gpt-image-2", "route": "direct:openai", "direct": True,
        }

        def generate(_prompt, _references, _lane, **options):
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((180, 120, 3), 255, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), mock.patch.object(
                        body.media_gen, "generate_image_edit_sync",
                        side_effect=generate) as provider_call, mock.patch.object(
                            body, "_preflight_front_source",
                            side_effect=body.GeneratedBodyProportionError(
                                "head-heavy")):
                with self.assertRaises(body.GeneratedBodyProportionError):
                    body.build(
                        directory,
                        {"style": "editorial", "pose": "relaxed"},
                        log=lambda _message: None)
            self.assertEqual(1, provider_call.call_count)
            self.assertFalse(os.path.exists(os.path.join(directory, ".body-cache")))

    def test_plain_preflight_runtime_failure_also_clears_front_cache(self):
        config = {"provider": "openai", "model": "gpt-image-2", "api_key": "x"}
        public = {
            "name": "openai", "title": "OpenAI Images",
            "model": "gpt-image-2", "route": "direct:openai", "direct": True,
        }

        def generate(_prompt, _references, _lane, **options):
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((180, 120, 3), 255, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            portrait = np.full((128, 128, 3), 140, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), portrait)
            cv2.imwrite(os.path.join(directory, "head.png"), portrait)
            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), mock.patch.object(
                        body.media_gen, "generate_image_edit_sync",
                        side_effect=generate) as provider_call, mock.patch.object(
                            body, "_preflight_front_source",
                            side_effect=RuntimeError("front cutout failed")):
                with self.assertRaisesRegex(RuntimeError, "front cutout failed"):
                    body.build(
                        directory,
                        {"style": "editorial", "pose": "relaxed"},
                        log=lambda _message: None)
            self.assertEqual(1, provider_call.call_count)
            self.assertFalse(os.path.exists(os.path.join(directory, ".body-cache")))

    def test_provider_prompt_forbids_closeup_reference_head_scale(self):
        prompt = body._prompt(
            {"style": "editorial", "pose": "relaxed"}, "front").lower()
        self.assertIn("12.5 to 13.3 percent", prompt)
        self.assertIn("never copy the oversized head scale", prompt)
        self.assertIn("head-heavy silhouette", prompt)

    def test_long_owner_direction_survives_every_turnaround_view(self):
        owner = (
            "Keep one coherent vivid fuchsia office dress with clean tailoring. "
            * 20
            + "FINAL OWNER REQUIREMENT: preserve every pure-white silhouette gap."
        )
        owner = " ".join(owner.split())
        self.assertGreater(len(owner.encode("utf-8")), 1300)
        for view in body.BODY_VIEWS:
            with self.subTest(view=view):
                plate = body._prompt({
                    "style": "editorial",
                    "pose": "relaxed",
                    "presentation": "feminine",
                    "medium": "photograph",
                    "prompt": owner,
                }, view)
                self.assertIn(owner, plate)
                self.assertNotIn("…", plate)
                self.assertLessEqual(
                    len(plate.encode("utf-8")),
                    body.FULL_BODY_PROMPT_MAX_BYTES)


if __name__ == "__main__":
    unittest.main()
