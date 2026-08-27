import hashlib
import unittest

from studio import visemes


class StylizedVisemePromptTests(unittest.TestCase):
    def test_photo_prompts_keep_their_existing_cache_bytes(self):
        # generate.generate_one hashes the complete prompt, so these snapshots
        # protect existing photo renders from an accidental cache invalidation.
        expected = {
            "closed": "c83fe8853cae5bda54eddedd5982e1a57b1f2cacb896c7c70ba99e8e5ff8c74f",
            "TH": "951f9941bd8cab46ac412c255bb6402a6df2f5a4b7be38464d4b55260902a6ab",
            "ah": "c59b33726b52f232c667b77c2c55023d30dbe5ff2f5355671612f657f195cb59",
            "blink": "3f57f5f11394883790e2588f6377fb469aa4bd9f293c864736abcf5dc4f7c2ab",
        }
        for name, digest in expected.items():
            prompt = visemes.prompt_for(name, 0.0, 0.0)
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
