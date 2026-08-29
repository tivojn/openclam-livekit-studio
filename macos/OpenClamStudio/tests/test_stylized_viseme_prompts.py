import hashlib
import unittest

from studio import visemes


class StylizedVisemePromptTests(unittest.TestCase):
    def test_photo_prompts_include_headwear_lock_in_their_cache_bytes(self):
        # generate.generate_one hashes the complete prompt, so these snapshots
        # make the intentional headwear-lock cache invalidation deterministic.
        expected = {
            "closed": "084e55f9eac81d739b1de24bb163e9c055b8f1388680daef8ae8cb25d4127c6f",
            "TH": "f063c0a403afcb03e324e1581936e931c298d6f0ec0d052571421f981fd47f42",
            "ah": "d81f19fe5836a126a9a19af1904f30755561d73e48d4de33f02276608a3cc85b",
            "blink": "a9a31fe3249cb3bd5975ba5bcf7c3aff91cfcaf02132e0e2b31becbc4bfb3cc5",
        }
        for name, digest in expected.items():
            prompt = visemes.prompt_for(name, 0.0, 0.0)
            lowered = prompt.lower()
            self.assertIn("headwear state lock", lowered)
            self.assertIn("if the subject is bare-headed", lowered)
            self.assertIn("do not add, remove, replace", lowered)
            self.assertEqual(
                hashlib.sha256(prompt.encode("utf-8")).hexdigest(), digest)
            self.assertEqual(
                prompt,
                visemes.prompt_for(
                    name, 0.0, 0.0, source_medium="photo"))

    def test_every_stylized_shape_preserves_medium_without_photo_assumptions(self):
        forbidden = (
            "portrait photograph", "photographic realism", "skin texture",
            "pores", "freckles", "natural ivory", " her ", " her's ",
        )
        for name in visemes.ORDER:
            prompt = visemes.prompt_for(
                name, 12.0, 8.0, source_medium="stylized-crop")
            lowered = prompt.lower()
            self.assertIn("source medium", lowered, name)
            self.assertIn("linework", lowered, name)
            for phrase in forbidden:
                self.assertNotIn(phrase, lowered, name)

    def test_stylized_blink_changes_only_eyes_in_the_existing_art_style(self):
        prompt = visemes.prompt_for(
            "blink", source_medium="illustration").lower()
        self.assertIn("only thing that may change is the eyes", prompt)
        self.assertIn("mouth and lips", prompt)
        self.assertIn("eyelid, lash, line and shading design", prompt)
        self.assertIn("source medium", prompt)
        self.assertNotIn("photographic realism", prompt)

    def test_rendered_and_game_art_labels_use_the_stylized_mouth_and_blink_contracts(self):
        # These are the exact labels emitted by intake for the two Luffy
        # references.  Falling through to the photo prompt repainted a small
        # realistic mouth/eye inside the character's established 3-D design.
        for medium in ("3d render", "3d-render", "soft-3d",
                       "game art", "game-art",
                       "3d render / game character"):
            with self.subTest(medium=medium, shape="ah"):
                mouth = visemes.prompt_for(
                    "ah", 0.0, 0.0, source_medium=medium).lower()
                self.assertIn("preserve the source medium", mouth)
                self.assertIn("linework", mouth)
                self.assertIn("source illustration's own palette", mouth)
                self.assertNotIn("portrait photograph", mouth)
                self.assertNotIn("photographic realism", mouth)
                self.assertNotIn("visible skin texture", mouth)
            with self.subTest(medium=medium, shape="blink"):
                blink = visemes.prompt_for(
                    "blink", source_medium=medium).lower()
                self.assertIn("only thing that may change is the eyes", blink)
                self.assertIn("preserve the established eye size", blink)
                self.assertIn("eyelid, lash, line and shading design", blink)
                self.assertIn("source medium", blink)
                self.assertNotIn("portrait photograph", blink)
                self.assertNotIn("photographic realism", blink)
                self.assertNotIn("natural soft eyelid crease", blink)

    def test_stylized_th_keeps_art_style_and_centred_tongue_geometry(self):
        prompt = visemes.prompt_for(
            "TH", 0.0, 0.0, source_medium="cartoon").lower()
        self.assertIn("preserve the source medium", prompt)
        self.assertIn("tongue must stay centred", prompt)
        self.assertIn("source illustration's own palette", prompt)
        self.assertIn("the character's own lower-lip thickness", prompt)

    def test_unknown_medium_never_falls_back_to_photo_or_cartoon_assumptions(self):
        forbidden = (
            "portrait photograph", "photographic realism", "pores",
            "natural ivory", "illustrated character", "source illustration",
            "illustrated", "character art", "graphic vocabulary",
        )
        for name in ("closed", "TH", "ah", "blink"):
            prompt = visemes.prompt_for(
                name, 12.0, 8.0, source_medium="unknown").lower()
            self.assertIn("source medium", prompt, name)
            self.assertTrue(
                "source image" in prompt or "supplied face image" in prompt,
                name)
            for phrase in forbidden:
                self.assertNotIn(phrase, prompt, name)


if __name__ == "__main__":
    unittest.main()
