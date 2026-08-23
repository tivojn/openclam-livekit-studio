"""Pairing UI backend stays bounded and never returns OpenClaw credentials."""

import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import openclaw_pairing


class OpenClawPairingTests(unittest.TestCase):
    def result(self, value, returncode=0):
        return subprocess.CompletedProcess(
            ["openclaw"], returncode, json.dumps(value).encode(), b"private-error"
        )

    def test_status_returns_only_safe_labels(self):
        value = {
            "paired": True,
            "gatewayLabel": "OpenClam Mac",
            "connectionId": "11111111-1111-4111-8111-111111111111",
            "bridgeUrl": "https://private.example",
            "accounts": [{
                "accountId": "ara",
                "agentId": "research",
                "displayName": "Ara",
                "enabled": True,
                "configured": True,
            }],
        }
        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(subprocess, "run", return_value=self.result(value)):
            result = openclaw_pairing.status()
        self.assertEqual(result, {
            "available": True,
            "channel_installed": True,
            "configured": True,
            "gateway_label": "OpenClam Mac",
            "accounts": [{
                "account_id": "ara",
                "agent_id": "research",
                "display_name": "Ara",
            }],
        })
        self.assertNotIn("connection", json.dumps(result).lower())
        self.assertNotIn("private.example", json.dumps(result))

    def test_create_validates_code_and_restarts_gateway_without_secret_environment(self):
        now = int(time.time() * 1000)
        pairing = {
            "v": 1,
            "code": "OC-2345-6789-ABCD",
            "connectionId": "11111111-1111-4111-8111-111111111111",
            "expiresAt": now + 600_000,
            "gatewayLabel": "OpenClam Mac",
            "accounts": [{
                "accountId": "ara",
                "agentId": "ara",
                "displayName": "Ara",
            }],
        }
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if command[-1] == "--json":
                return self.result(pairing)
            return subprocess.CompletedProcess(command, 0, b"restarted\n", b"")

        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(subprocess, "run", side_effect=run), \
             patch.dict(os.environ, {
                 "OPENCLAM_AUTH_TOKEN": "must-not-reach-child",
                 "OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN": "must-not-reach-child",
             }, clear=False):
            result = openclaw_pairing.create_pairing_code()

        self.assertEqual(calls[0][0], ["/bin/openclaw", "openclam", "pair-device", "--json"])
        self.assertEqual(calls[1][0], ["/bin/openclaw", "gateway", "restart"])
        self.assertNotIn("OPENCLAM_AUTH_TOKEN", calls[0][1]["env"])
        self.assertNotIn("OPENCLAM_BRIDGE_BOOTSTRAP_TOKEN", calls[0][1]["env"])
        self.assertEqual(result["code"], pairing["code"])
        self.assertTrue(result["gateway_restarted"])
        self.assertNotIn("adapter", json.dumps(result).lower())
        self.assertNotIn("token", json.dumps(result).lower())

    def test_child_failure_never_echoes_stderr(self):
        failed = subprocess.CompletedProcess(
            ["openclaw"], 1, b"", b"secret-token /srv/private/config"
        )
        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(subprocess, "run", return_value=failed):
            with self.assertRaises(openclaw_pairing.OpenClawPairingError) as context:
                openclaw_pairing.create_pairing_code()
        self.assertNotIn("secret-token", str(context.exception))
        self.assertNotIn("/srv/private", str(context.exception))

    def test_status_never_stringifies_an_untrusted_gateway_label(self):
        value = {
            "paired": True,
            "gatewayLabel": {"token": "must-not-render"},
            "accounts": [],
        }
        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(subprocess, "run", return_value=self.result(value)):
            result = openclaw_pairing.status()
        self.assertEqual(result["gateway_label"], "")
        self.assertNotIn("must-not-render", json.dumps(result))

    def test_status_accepts_bounded_openclaw_notices_before_its_json(self):
        value = {
            "paired": False,
            "gatewayLabel": "OpenClam Mac",
            "accounts": [],
        }
        output = b"OpenClaw notice: another plugin needs attention\n" + json.dumps(value).encode()
        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
                 ["openclaw"], 0, output, b"private diagnostic"
             )):
            result = openclaw_pairing.status()
        self.assertTrue(result["channel_installed"])
        self.assertFalse(result["configured"])
        self.assertNotIn("attention", json.dumps(result))

    def test_install_channel_uses_setup_key_once_without_storing_or_echoing_it(self):
        now = int(time.time() * 1000)
        pairing = {
            "v": 1,
            "code": "OC-2345-6789-ABCD",
            "connectionId": "11111111-1111-4111-8111-111111111111",
            "expiresAt": now + 600_000,
            "gatewayLabel": "OpenClam Mac",
            "accounts": [{
                "accountId": "ara",
                "agentId": "ara",
                "displayName": "Ara",
            }],
        }
        secret = "safe_setup_key_0123456789_ABCDEFGH"
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            if "pair" in command:
                return self.result(pairing)
            return subprocess.CompletedProcess(command, 0, b"ok\n", b"")

        with patch.object(openclaw_pairing, "_executable", return_value="/bin/openclaw"), \
             patch.object(openclaw_pairing, "_plugin_package", return_value="/tmp/channel.tgz"), \
             patch.object(openclaw_pairing, "_bridge_origin", return_value="https://bridge.example"), \
             patch.object(openclaw_pairing, "status", return_value={
                 "available": True,
                 "channel_installed": False,
                 "configured": False,
                 "gateway_label": "",
                 "accounts": [],
             }), \
             patch.object(subprocess, "run", side_effect=run):
            result = openclaw_pairing.install_channel(secret)

        self.assertEqual(calls[0][0], [
            "/bin/openclaw", "plugins", "install", "/tmp/channel.tgz", "--force"
        ])
        self.assertEqual(calls[1][0][:5], [
            "/bin/openclaw", "openclam", "pair", "--bridge-url", "https://bridge.example"
        ])
        self.assertEqual(calls[1][1]["env"].get("OPENCLAM_STUDIO_SETUP_KEY"), secret)
        self.assertNotIn("OPENCLAM_STUDIO_SETUP_KEY", calls[0][1]["env"])
        self.assertNotIn("OPENCLAM_STUDIO_SETUP_KEY", calls[2][1]["env"])
        self.assertEqual(result["code"], pairing["code"])
        self.assertTrue(result["configured"])
        self.assertNotIn(secret, json.dumps(result))


if __name__ == "__main__":
    unittest.main()
