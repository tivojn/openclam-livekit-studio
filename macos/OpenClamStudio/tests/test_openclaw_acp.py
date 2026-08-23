import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from server import openclaw_acp


class OpenClawACPTests(unittest.TestCase):
    def setUp(self):
        openclaw_acp._ARTIFACTS.clear()

    def tearDown(self):
        openclaw_acp._ARTIFACTS.clear()

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
            "title": "Inspecting the portrait",
            "kind": "read",
            "status": "in_progress",
            "rawInput": {"Authorization": "Bearer secret-value"},
            "rawOutput": "password=do-not-show",
            "locations": [{"path": "/etc/passwd"}],
        }, workspace, {})
        self.assertEqual(kind, "work")
        self.assertEqual(step["title"], "Inspecting the portrait")
        self.assertEqual(step["tool"], "read")
        self.assertNotIn("path", step)
        encoded = repr(step).lower()
        self.assertNotIn("authorization", encoded)
        self.assertNotIn("password", encoded)
        self.assertNotIn("/etc", encoded)

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
                self.assertEqual(openclaw_acp.artifact_path(handle), os.path.realpath(output))
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
            self.assertIsNone(openclaw_acp.artifact_path(handles[0]))
            self.assertEqual(
                openclaw_acp.artifact_path(handles[-1]),
                os.path.realpath(paths[-1]),
            )


if __name__ == "__main__":
    unittest.main()
