"""Headwear and owner-note contracts for generated motion."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from studio import motion


class MotionHeadwearPromptTests(unittest.TestCase):
    @staticmethod
    def _all_prompts(identity_lock):
        return {
            "walk_keyframe": motion._walk_keyframe_prompt(
                "approved wardrobe", "office", True, identity_lock),
            "idle_keyframe": motion._idle_keyframe_prompt(
                "approved wardrobe", False, "folded-cross", identity_lock),
            "move_keyframe": motion._move_keyframe_prompt(
                "approved wardrobe", "viral", identity_lock),
            "walk_video": motion._walk_video_prompt(
                "office", None, identity_lock),
            "idle_video": motion._idle_video_prompt(
                "folded-cross", identity_lock),
            "move_video": motion._move_video_prompt("viral", identity_lock),
        }

    def test_all_six_prompts_preserve_source_headwear_by_default(self):
        prompts = self._all_prompts(motion._motion_identity_lock())
        for name, prompt in prompts.items():
            with self.subTest(prompt=name):
                lowered = prompt.lower()
                self.assertIn("headwear state lock — preserve", lowered)
                self.assertIn("source-worn hat", lowered)
                self.assertIn("in every video frame", lowered)
                self.assertIn("brim and crown geometry", lowered)

    def test_all_six_prompts_keep_bare_head_when_removal_is_enabled(self):
        prompts = self._all_prompts(
            motion._motion_identity_lock(True, "keep his old straw hat"))
        for name, prompt in prompts.items():
            with self.subTest(prompt=name):
                lowered = prompt.lower()
                self.assertIn("owner must-keep note", lowered)
                self.assertIn("keep his old straw hat", lowered)
                self.assertIn("headwear state lock — remove", lowered)
                self.assertIn("keep the subject bare-headed", lowered)
                self.assertIn("overrides any conflicting owner note", lowered)

    @staticmethod
    def _context(root, options):
        body_dir = root / "body"
        body_dir.mkdir(exist_ok=True)
        front = body_dir / "front.png"
        side = body_dir / "side.png"
        head = root / "head.png"
        for path, payload in ((front, b"front"), (side, b"side"),
                              (head, b"head")):
            path.write_bytes(payload)
        (body_dir / "body.json").write_text(json.dumps({
            "views": {
                "front": {"source": front.name},
                "side": {"source": side.name},
            },
            "options": options,
        }))
        image_selection = (
            {"provider": "xai", "model": "image"},
            {"route": "xai", "name": "xai", "model": "image"},
        )
        video_selection = (
            {"provider": "xai", "model": "video"},
            {"route": "xai", "name": "xai", "model": "video"},
        )
        with (
                mock.patch.object(
                    motion.body, "_identity_reference", return_value=str(head)),
                mock.patch.object(
                    motion.body, "image_provider_selection",
                    return_value=image_selection),
                mock.patch.object(
                    motion.body, "video_provider_selection",
                    return_value=video_selection)):
            return motion._build_context(str(root), None, walk_style="office")

    def test_notes_survive_truncated_wardrobe_and_change_cache_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self._context(root, {
                "prompt": "wardrobe detail " * 500,
                "notes": "keep the woven straw hat and its red band",
                "remove_headwear": False,
            })
            second = self._context(root, {
                "prompt": "wardrobe detail " * 500,
                "notes": "keep the woven straw hat and its scarlet band",
                "remove_headwear": False,
            })

            self.assertNotEqual(first["signature"], second["signature"])
            self.assertEqual(
                first["owner_notes"],
                "keep the woven straw hat and its red band")
            for prompt in first["prompts"].values():
                self.assertIn(
                    "OWNER MUST-KEEP NOTE — keep the woven straw hat and its red band",
                    prompt)

    def test_structured_policy_changes_cache_signature_and_every_prompt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            preserve = self._context(root, {
                "prompt": "the exact wardrobe",
                "remove_headwear": False,
            })
            remove = self._context(root, {
                "prompt": "the exact wardrobe",
                "remove_headwear": True,
            })

            self.assertNotEqual(preserve["signature"], remove["signature"])
            self.assertFalse(preserve["remove_headwear"])
            self.assertTrue(remove["remove_headwear"])
            for prompt in preserve["prompts"].values():
                self.assertIn("HEADWEAR STATE LOCK — PRESERVE", prompt)
            for prompt in remove["prompts"].values():
                self.assertIn("HEADWEAR STATE LOCK — REMOVE", prompt)

    def test_non_feminine_default_is_folded_cross(self):
        resolved = motion.resolve_idle_pose(
            None, presentation="masculine", remap_unsafe=True)
        self.assertEqual(resolved["id"], "folded-cross")
        self.assertIn("arms folded calmly", resolved["prompt"])


if __name__ == "__main__":
    unittest.main()
