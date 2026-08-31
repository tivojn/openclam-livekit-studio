"""xAI motion prompts stay inside the provider's pre-job request budget."""
import unittest
from unittest import mock

from server import media_gen
from studio import motion


class XaiMotionPromptBudgetTests(unittest.IsolatedAsyncioTestCase):
    @staticmethod
    def _maximum_production_walk_prompt():
        # Illustration is the longest explicit source-medium contract.  Pair it
        # with the longest production gait and the default preserve-headwear
        # policy so this covers the worst generated prompt without user prose.
        identity_lock = (
            motion._motion_identity_lock(False)
            + "\n\n"
            + motion._motion_source_medium_lock("illustration")
        )
        return motion._walk_video_prompt("office", None, identity_lock)

    def test_worst_case_walk_contract_stays_below_retry_budget(self):
        prompt = self._maximum_production_walk_prompt()

        self.assertLessEqual(len(prompt.encode("utf-8")), 3_800)
        self.assertIn("HEADWEAR STATE LOCK — PRESERVE", prompt)
        self.assertIn("SOURCE-MEDIUM LOCK", prompt)
        self.assertIn("COMPLETE TWO-STEP GAIT CYCLE", prompt)
        self.assertIn("full alternating contralateral cycle", prompt)
        self.assertIn("the EXACT first frame and the EXACT final frame", prompt)
        self.assertIn("locked camera", prompt)
        self.assertIn("complete full body", prompt)
        self.assertIn("uniformly pure white", prompt)

    async def test_xai_generation_keeps_the_reviewed_9_16_payload(self):
        prompt = self._maximum_production_walk_prompt()
        execute = mock.AsyncMock(return_value="walk.mp4")
        with (
                mock.patch.object(
                    media_gen, "_require_lane",
                    return_value=("xai", "", {})),
                mock.patch.object(
                    media_gen, "_model",
                    return_value="grok-imagine-video"),
                mock.patch.object(
                    media_gen, "_execute_xai_video_job", new=execute)):
            result = await media_gen._xai_video(
                prompt,
                {"provider": "xai", "model": "grok-imagine-video"},
                aspect_ratio="9:16",
                duration=6,
                resolution="720p",
            )

        self.assertEqual(result, "walk.mp4")
        request = execute.await_args.args[1]
        self.assertEqual(request["model"], "grok-imagine-video")
        self.assertEqual(request["prompt"], prompt)
        self.assertEqual(request["aspect_ratio"], "9:16")
        self.assertEqual(request["duration"], 6)
        self.assertEqual(request["resolution"], "720p")

    async def test_xai_rejects_oversized_utf8_prompt_before_submission(self):
        execute = mock.AsyncMock()
        with (
                mock.patch.object(
                    media_gen, "_require_lane",
                    return_value=("xai", "", {})),
                mock.patch.object(
                    media_gen, "_model",
                    return_value="grok-imagine-video"),
                mock.patch.object(
                    media_gen, "_execute_xai_video_job", new=execute),
                self.assertRaisesRegex(RuntimeError, "4,096 UTF-8 bytes")):
            await media_gen._xai_video(
                "猫" * 1_366,
                {"provider": "xai", "model": "grok-imagine-video"},
                aspect_ratio="9:16",
            )

        execute.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
