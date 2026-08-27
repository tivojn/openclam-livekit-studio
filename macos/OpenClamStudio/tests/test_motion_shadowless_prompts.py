"""Generation contracts that prevent cast shadows before local alpha cutting."""
import unittest

from studio import motion, promptsmith, wardrobe


class ShadowlessMotionPromptTests(unittest.TestCase):
    def assert_shadowless_plate(self, prompt):
        lowered = prompt.lower()
        self.assertIn("flat shadowless lighting", lowered)
        self.assertIn(
            "no floor shadow beneath either shoe, sole, toe, or high-heel stem",
            lowered,
        )
        self.assertIn(
            "no wall shadow or contact shadow behind hair, head, arms, torso, "
            "clothing, or body",
            lowered,
        )
        self.assertIn("no ambient-occlusion shadow", lowered)
        self.assertIn("pose geometry only, never through shading", lowered)
        self.assertIn("uniformly pure white", lowered)

    def test_walk_image_and_video_prompts_are_explicitly_shadowless(self):
        prompts = (
            motion._walk_keyframe_prompt("the approved wardrobe", "office"),
            motion._walk_video_prompt("office"),
            motion._walk_video_prompt("cartwheel"),
        )
        for prompt in prompts:
            with self.subTest(prompt=prompt[:40]):
                self.assert_shadowless_plate(prompt)

    def test_edge_idle_image_and_video_prompts_ban_wall_contact_shadows(self):
        prompts = (
            motion._idle_keyframe_prompt(
                "the approved wardrobe", True, "back-heel"),
            motion._idle_video_prompt("back-heel"),
        )
        for prompt in prompts:
            with self.subTest(prompt=prompt[:40]):
                self.assert_shadowless_plate(prompt)

    def test_move_image_and_video_prompts_are_explicitly_shadowless(self):
        prompts = (
            motion._move_keyframe_prompt("the approved wardrobe", "viral"),
            motion._move_video_prompt("viral"),
        )
        for prompt in prompts:
            with self.subTest(prompt=prompt[:40]):
                self.assert_shadowless_plate(prompt)

    def test_prompt_expanders_cannot_reintroduce_lighting_direction(self):
        self.assertIn("lighting, lighting rigs, shadows", promptsmith._SHARED)
        self.assertIn(
            "Never prescribe lighting or shadows in a wardrobe direction",
            wardrobe.SYSTEM,
        )
        self.assertNotIn("dramatic practical or rim lighting", wardrobe.SYSTEM)


if __name__ == "__main__":
    unittest.main()
