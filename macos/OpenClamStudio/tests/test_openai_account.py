import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / "server"))

import credentials
import media_gen
import openai_account as OA


class OpenAIAccountTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_vault = credentials._TEST_VAULT_FILE
        self.original_mode_file = OA.MODE_FILE
        credentials._TEST_VAULT_FILE = os.path.join(
            self.temporary.name, "vault.json")
        OA.MODE_FILE = os.path.join(self.temporary.name, "openai-account.json")
        credentials._memo.clear()

    def tearDown(self):
        credentials._memo.clear()
        credentials._TEST_VAULT_FILE = self.original_vault
        OA.MODE_FILE = self.original_mode_file
        self.temporary.cleanup()

    def test_explicit_mode_never_infers_or_copies_chatgpt_credentials(self):
        credentials.put("keys.openai", "sk-platform-test")
        with mock.patch.object(OA, "_codex", return_value="/test/codex"), \
             mock.patch.object(OA, "_login_status", return_value=(True, "signed in")):
            api_status = OA.status()
            self.assertEqual(api_status["auth_mode"], OA.API_KEY_MODE)
            self.assertTrue(api_status["connected"])
            self.assertTrue(api_status["oauth"]["connected"])
            OA.set_auth_mode(OA.CHATGPT_MODE)
            chatgpt_status = OA.status()
        self.assertEqual(chatgpt_status["auth_mode"], OA.CHATGPT_MODE)
        self.assertTrue(chatgpt_status["connected"])
        self.assertNotIn("token", chatgpt_status["oauth"])
        self.assertEqual(credentials.get("keys.openai"), "sk-platform-test")

    def test_image_job_uses_codex_boundary_and_returns_only_result_bytes(self):
        Path(OA.MODE_FILE).write_text(
            '{"auth_mode":"chatgpt"}', encoding="utf-8")
        seen = {}

        def run(command, **kwargs):
            seen["command"] = list(command)
            seen["prompt"] = command[-1]
            Path(kwargs["cwd"], "result.png").write_bytes(
                b"\x89PNG\r\n\x1a\n" + b"image" * 1024)
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(OA, "_codex", return_value="/test/codex"), \
             mock.patch.object(OA, "_login_status", return_value=(True, "signed in")), \
             mock.patch.object(OA.subprocess, "run", side_effect=run):
            result = OA.generate_image("A calm blue circle")

        self.assertTrue(result.startswith(b"\x89PNG"))
        self.assertIn("--ephemeral", seen["command"])
        self.assertIn("built-in OpenAI image generation tool", seen["prompt"])
        self.assertNotIn("sk-", " ".join(seen["command"]))

    def test_image_edit_copies_reference_inside_private_codex_workspace(self):
        Path(OA.MODE_FILE).write_text(
            '{"auth_mode":"chatgpt"}', encoding="utf-8")
        outside = Path(self.temporary.name, "outside-reference.jpg")
        outside.write_bytes(b"not-a-real-jpeg-but-enough-for-boundary-test")
        seen = {}

        def run(command, **kwargs):
            attached = next(value.split("=", 1)[1] for value in command
                            if value.startswith("--image="))
            seen["attached"] = attached
            seen["work"] = kwargs["cwd"]
            self.assertTrue(Path(attached).is_file())
            Path(kwargs["cwd"], "result.png").write_bytes(
                b"\x89PNG\r\n\x1a\n" + b"edit" * 1200)
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(OA, "_codex", return_value="/test/codex"), \
             mock.patch.object(OA, "_login_status", return_value=(True, "signed in")), \
             mock.patch.object(OA.subprocess, "run", side_effect=run):
            OA.generate_image("Repair the mouth", [outside])

        self.assertEqual(Path(seen["attached"]).parent, Path(seen["work"]))
        self.assertNotEqual(Path(seen["attached"]), outside)

    def test_chat_job_returns_output_file_without_exposing_session_material(self):
        Path(OA.MODE_FILE).write_text(
            '{"auth_mode":"chatgpt"}', encoding="utf-8")
        seen = {}

        def run(command, **_kwargs):
            seen["command"] = list(command)
            output = command[command.index("-o") + 1]
            Path(output).write_text("Hello from the signed-in account.", encoding="utf-8")
            return subprocess.CompletedProcess(command, 0, "", "")

        with mock.patch.object(OA, "_codex", return_value="/test/codex"), \
             mock.patch.object(OA, "_login_status", return_value=(True, "signed in")), \
             mock.patch.object(OA.subprocess, "run", side_effect=run):
            answer = OA.chat([{"role": "user", "content": "Hello"}])

        self.assertEqual(answer, "Hello from the signed-in account.")
        self.assertNotIn("authorization", " ".join(seen["command"]).lower())

    def test_avatar_image_lane_delegates_to_codex_without_http_or_api_key(self):
        class ProviderHelper:
            @staticmethod
            def spec(_kind, provider):
                return {"id": provider, "label": "OpenAI Images", "key": True}

        class Manager:
            CHATGPT_MODE = "chatgpt"
            calls = []

            @staticmethod
            def auth_mode():
                return "chatgpt"

            @classmethod
            async def generate_image_async(cls, prompt, references=None, **options):
                cls.calls.append((prompt, list(references or []), options))
                return b"\x89PNG\r\n\x1a\n" + b"generated" * 1024

        with tempfile.TemporaryDirectory() as output, \
             mock.patch.object(media_gen, "_providers", return_value=ProviderHelper), \
             mock.patch.object(media_gen, "_openai_account_manager", return_value=Manager), \
             mock.patch.object(media_gen.httpx, "AsyncClient",
                               side_effect=AssertionError("HTTP must not run")):
            path = __import__("asyncio").run(media_gen.generate_image(
                "A coherent expressive portrait",
                {"provider": "openai", "model": "gpt-image-2",
                 "size": "1024x1024", "quality": "high"},
                output_dir=output, file_name="portrait"))

        self.assertEqual(Path(path).name, "portrait.png")
        self.assertEqual(Manager.calls[0][0], "A coherent expressive portrait")
        self.assertEqual(Manager.calls[0][2]["aspect_ratio"], "1:1")


if __name__ == "__main__":
    unittest.main()
