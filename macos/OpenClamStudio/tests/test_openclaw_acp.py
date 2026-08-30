import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from server import openclaw_acp


class OpenClawACPTests(unittest.TestCase):
    def setUp(self):
        self.media_directory = tempfile.TemporaryDirectory()
        self.environment = mock.patch.dict(
            os.environ, {"OPENCLAM_DATA_DIR": self.media_directory.name}
        )
        self.environment.start()
        openclaw_acp._ARTIFACTS.clear()

    def tearDown(self):
        openclaw_acp._ARTIFACTS.clear()
        self.environment.stop()
        self.media_directory.cleanup()

    def test_executable_finds_supported_user_install_without_shell_path(self):
        with tempfile.TemporaryDirectory() as directory:
            launcher = Path(directory) / ".openclaw" / "bin" / "openclaw"
            launcher.parent.mkdir(parents=True)
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")
            launcher.chmod(0o700)
            with mock.patch.object(openclaw_acp.shutil, "which", return_value=None), \
                 mock.patch.object(openclaw_acp.Path, "home", return_value=Path(directory)):
                self.assertEqual(openclaw_acp._executable(), str(launcher.resolve()))

    def test_public_agents_excludes_workspace(self):
        with mock.patch.object(openclaw_acp, "_run_json", return_value=[{
            "id": "ara",
            "identityName": "Ara",
            "workspace": "/srv/openclaw/ara",
            "isDefault": True,
        }]):
            self.assertEqual(openclaw_acp.public_agents(), [{
                "agent_id": "ara",
                "display_name": "Ara",
                "is_default": True,
            }])

    def test_private_thought_raw_tool_fields_paths_and_secrets_never_project(self):
        workspace = "/srv/openclaw/ara"
        self.assertIsNone(openclaw_acp.project_update(
            {"sessionUpdate": "agent_thought_chunk", "content": {
                "type": "text", "text": "private reasoning"
            }},
            workspace,
            {},
        ))
        kind, step = openclaw_acp.project_update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call-1",
            "title": "bash: command: /srv/openclaw/ara/private-script --token secret-value",
            "kind": "execute",
            "status": "in_progress",
            "rawInput": {"Authorization": "Bearer secret-value"},
            "rawOutput": "password=do-not-show",
            "locations": [{"path": "/etc/passwd"}],
        }, workspace, {})
        self.assertEqual(kind, "work")
        self.assertEqual(step["title"], "Ran commands")
        self.assertEqual(step["tool"], "command")
        self.assertNotIn("path", step)
        encoded = repr(step).lower()
        self.assertNotIn("authorization", encoded)
        self.assertNotIn("password", encoded)
        self.assertNotIn("/etc", encoded)
        self.assertNotIn("private-script", encoded)
        self.assertNotIn("secret-value", encoded)

    def test_safe_text_redacts_generic_private_paths_and_secret_labels(self):
        value = openclaw_acp._safe_text(
            "Read /etc/private.conf then API_KEY=abc123; keep https://example.com/report",
            1_000,
        )
        self.assertNotIn("/etc/private.conf", value)
        self.assertNotIn("abc123", value)
        self.assertIn("https://example.com/report", value)

    def test_plan_is_bounded_safe_and_drillable(self):
        result = openclaw_acp.project_update({
            "sessionUpdate": "plan",
            "entries": [
                {"content": "Inspect the request", "status": "completed"},
                {"content": "Create the image", "status": "in_progress"},
            ],
        }, "/srv/openclaw/ara", {})
        self.assertIsNotNone(result)
        kind, steps = result
        self.assertEqual(kind, "plan")
        self.assertEqual([step["state"] for step in steps], ["completed", "running"])
        self.assertEqual([step["step_id"] for step in steps], ["plan:0", "plan:1"])

    def test_agent_text_chunks_remain_incremental_protocol_events(self):
        first = openclaw_acp.project_update({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "Hello "},
        }, "/srv/openclaw/ara", {})
        second = openclaw_acp.project_update({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "there."},
        }, "/srv/openclaw/ara", {})
        self.assertEqual(first, ("text_chunk", "Hello "))
        self.assertEqual(second, ("text_chunk", "there."))

    def test_tool_updates_keep_one_step_identity_and_real_state(self):
        tool_titles = {}
        opened = openclaw_acp.project_update({
            "sessionUpdate": "tool_call",
            "toolCallId": "call-42",
            "kind": "search",
            "status": "in_progress",
        }, "/srv/openclaw/ara", tool_titles)
        completed = openclaw_acp.project_update({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "call-42",
            "kind": "search",
            "status": "completed",
        }, "/srv/openclaw/ara", tool_titles)
        self.assertEqual(opened[0], "work")
        self.assertEqual(completed[0], "work")
        self.assertEqual(opened[1]["step_id"], "tool:call-42")
        self.assertEqual(completed[1]["step_id"], "tool:call-42")
        self.assertEqual(opened[1]["state"], "running")
        self.assertEqual(completed[1]["state"], "completed")

    def test_artifact_handle_only_accepts_regular_workspace_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "portrait.png"
            output.write_bytes(b"safe-image")
            outside = root.parent / f"{root.name}-outside.png"
            outside.write_bytes(b"outside")
            try:
                attachment = openclaw_acp._artifact(str(output), directory)
                self.assertIsNotNone(attachment)
                self.assertEqual(attachment["name"], "portrait.png")
                self.assertNotIn(directory, repr(attachment))
                handle = str(attachment["url"]).rsplit("/", 1)[-1]
                persisted = openclaw_acp.artifact_path(handle)
                self.assertIsNotNone(persisted)
                self.assertNotEqual(persisted, os.path.realpath(output))
                self.assertEqual(Path(persisted).read_bytes(), b"safe-image")
                openclaw_acp._ARTIFACTS.clear()
                self.assertEqual(openclaw_acp.artifact_path(handle), persisted)
                self.assertIsNone(openclaw_acp._artifact(str(outside), directory))
            finally:
                outside.unlink(missing_ok=True)

    def test_artifact_handles_are_lru_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            handles = []
            for index in range(openclaw_acp.MAX_ARTIFACT_HANDLES + 1):
                output = root / f"file-{index}.txt"
                output.write_text(f"safe-{index}", encoding="utf-8")
                attachment = openclaw_acp._artifact(str(output), directory)
                self.assertIsNotNone(attachment)
                paths.append(output)
                handles.append(str(attachment["url"]).rsplit("/", 1)[-1])

            self.assertEqual(
                len(openclaw_acp._ARTIFACTS),
                openclaw_acp.MAX_ARTIFACT_HANDLES,
            )
            # The in-memory lookup stays bounded, while a history card can
            # rehydrate its private on-disk handle after eviction or restart.
            self.assertIsNotNone(openclaw_acp.artifact_path(handles[0]))
            self.assertEqual(len(openclaw_acp._ARTIFACTS), openclaw_acp.MAX_ARTIFACT_HANDLES)
            self.assertEqual(
                Path(openclaw_acp.artifact_path(handles[-1])).read_text(encoding="utf-8"),
                paths[-1].read_text(encoding="utf-8"),
            )

    def test_uploaded_file_is_private_durable_and_bound_to_agent_chat(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "notes.md"
            source.write_text("# Private input\nReview this.", encoding="utf-8")
            attachment = openclaw_acp.stage_upload(
                str(source), "notes.md", "text/markdown", "ara", "a" * 32
            )
            handle = str(attachment["handle"])
            persisted = openclaw_acp.upload_path(handle)
            self.assertIsNotNone(persisted)
            self.assertNotEqual(persisted, os.path.realpath(source))
            self.assertEqual(Path(persisted).read_text(encoding="utf-8"), source.read_text())
            self.assertEqual(os.stat(persisted).st_mode & 0o777, 0o600)

            blocks, visible = openclaw_acp._input_blocks([handle], "ara", "a" * 32)
            self.assertEqual(blocks[0]["type"], "resource_link")
            self.assertEqual(blocks[0]["name"], "notes.md")
            self.assertEqual(visible[0]["url"], attachment["url"])
            with self.assertRaises(openclaw_acp.OpenClawACPError):
                openclaw_acp._input_blocks([handle], "other", "a" * 32)
            with self.assertRaises(openclaw_acp.OpenClawACPError):
                openclaw_acp._input_blocks([handle], "ara", "b" * 32)

            self.assertTrue(openclaw_acp.delete_upload(handle))
            self.assertIsNone(openclaw_acp.upload_path(handle))
            self.assertFalse(openclaw_acp.delete_upload(handle))
            self.assertFalse(openclaw_acp.delete_upload("../outside"))

    def test_upload_rejects_unsupported_or_oversized_files(self):
        with tempfile.TemporaryDirectory() as directory:
            unsupported = Path(directory) / "payload.bin"
            unsupported.write_bytes(b"not accepted")
            with self.assertRaises(openclaw_acp.OpenClawACPError):
                openclaw_acp.stage_upload(
                    str(unsupported), unsupported.name, "application/octet-stream",
                    "ara", "a" * 32,
                )


if __name__ == "__main__":
    unittest.main()
