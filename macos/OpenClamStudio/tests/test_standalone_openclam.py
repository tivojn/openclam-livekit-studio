"""Regression boundaries for the standalone OpenClam desktop runtime."""
import asyncio
import copy
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import credentials
import providers as P


def route_test_application():
    """Declare app routes without importing the optional avatar ML stack."""
    fake_studio = types.ModuleType("studio")
    fake_studio.__path__ = []
    fake_rig = types.ModuleType("studio.rig")
    fake_rig.CONTROLS = {
        name: {"default": 0, "minimum": 0, "maximum": 150}
        for name in (
            "lips", "jaw", "cheeks", "brows", "forehead",
            "nasolabial", "nose", "teeth",
        )
    }
    fake_rig.DENTAL_DONORS = {"upper": ("SS",), "lower": ("ih",)}
    fake_studio.rig = fake_rig
    name = f"_openclam_standalone_route_app_{id(fake_studio)}"
    spec = importlib.util.spec_from_file_location(name, ROOT / "server" / "app.py")
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {
        "studio": fake_studio,
        "studio.rig": fake_rig,
        name: module,
    }):
        spec.loader.exec_module(module)
    return module


class StandaloneProviderTests(unittest.TestCase):
    def test_fresh_defaults_are_local_and_media_is_explicitly_unconfigured(self):
        self.assertEqual(P.DEFAULTS["llm"]["provider"], "ollama")
        self.assertEqual(P.DEFAULTS["tts"]["provider"], "system")
        self.assertEqual(P.DEFAULTS["stt"]["provider"], "mlx_whisper")
        self.assertEqual(
            P.DEFAULTS["stt"]["model"],
            "mlx-community/whisper-small-mlx-4bit",
        )
        self.assertEqual(P.DEFAULTS["image"]["provider"], "")
        self.assertEqual(P.DEFAULTS["video"]["provider"], "")
        self.assertNotIn("live", P.DEFAULTS)

    def test_catalog_has_direct_providers_only_and_exact_avatar_media_lanes(self):
        catalog = P.catalog()
        for rows in catalog.values():
            self.assertFalse(any(row.get("managed") for row in rows))
        self.assertEqual(
            {row["id"] for row in catalog["image"]},
            {"openai", "gemini", "xai", "stability", "bfl",
             "together_image", "recraft"},
        )
        self.assertEqual(
            {row["id"] for row in catalog["video"]},
            {"openai", "gemini", "xai", "luma", "runway"},
        )
        self.assertEqual(P.spec("image", "gemini")["label"],
                         "Google Gemini Image")

    def test_removed_persisted_choices_are_normalized_before_use(self):
        stale = {
            "llm": {"provider": "retired-desktop-gateway"},
            "image": {"provider": "managed-default"},
            "live": {"provider": "retired-realtime"},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(stale, handle)
            with patch.object(P, "CONFIG", path):
                loaded = P._read_config_file()
        self.assertEqual(loaded["llm"]["provider"], "ollama")
        self.assertEqual(loaded["image"]["provider"], "")
        self.assertNotIn("live", loaded)

    def test_load_atomically_rewrites_removed_blocks_out_of_the_config_file(self):
        stale = {
            "llm": {"provider": "ollama"},
            "live": {"api_key": "retired-plaintext-secret"},
            "relay": {"url": "https://retired.example"},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "config.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(stale, handle)
            with patch.object(P, "CONFIG", path), \
                 patch.object(P, "_migrated", [False]), \
                 patch.object(P, "_normalization_pending", [False]), \
                 patch.object(credentials, "absorb", return_value=False), \
                 patch.object(credentials, "materialise", side_effect=lambda cfg: cfg):
                loaded = P.load()
            persisted = json.loads(Path(path).read_text(encoding="utf-8"))
        self.assertNotIn("live", loaded)
        self.assertNotIn("live", persisted)
        self.assertNotIn("relay", persisted)
        self.assertNotIn("retired-plaintext-secret", json.dumps(persisted))

    def test_unconfigured_media_and_unknown_llm_fail_closed_without_network(self):
        with self.assertRaisesRegex(RuntimeError, "Choose a direct image provider"):
            asyncio.run(P.list_models("image", {"provider": ""}))
        with self.assertRaisesRegex(RuntimeError, "Choose a direct language model"):
            asyncio.run(P.chat([], {"provider": "managed-default"}))

    def test_media_model_catalogues_filter_out_language_models(self):
        self.assertEqual(
            P._filter_models("image", "openai", [
                "gpt-5-mini", "gpt-image-1", "gpt-image-2",
            ]),
            ["gpt-image-1", "gpt-image-2"],
        )
        self.assertEqual(
            P._filter_models("image", "gemini", [
                "gemini-3.1-flash", "gemini-3.1-flash-image",
                "imagen-4.0-generate-001",
            ]),
            ["gemini-3.1-flash-image"],
        )
        self.assertEqual(
            P._filter_models("video", "xai", [
                "grok-3-mini", "grok-imagine-image", "grok-imagine-video-1.5",
            ]),
            ["grok-imagine-video-1.5"],
        )
        self.assertEqual(
            P._filter_models("video", "gemini", [
                "gemini-3.1-flash-image", "veo-3.1-generate-preview",
            ]),
            ["veo-3.1-generate-preview"],
        )

    def test_keychain_contract_has_no_legacy_realtime_secret_block(self):
        self.assertNotIn("live", credentials.SECRET_FIELDS)
        self.assertIn("livekit", credentials.SECRET_FIELDS)
        self.assertEqual(credentials.SERVICE, "com.lionheart.openclam.macos")


class StandaloneRouteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = route_test_application()
        cls.routes = {
            getattr(route, "path", ""): set(getattr(route, "methods", ()) or ())
            for route in cls.application.app.routes
        }

    def test_required_local_and_livekit_surfaces_remain(self):
        expected = {
            "/reply", "/say", "/stt", "/stt/stream",
            "/api/livekit/catalog", "/api/livekit/config",
            "/api/livekit/session", "/api/avatars", "/api/avatar/upload",
            "/api/avatar/body/generate", "/api/avatar/motion/generate",
            "/api/avatar/activate", "/api/avatar/companion",
            "/api/avatar/export", "/api/avatar/import",
        }
        self.assertTrue(expected.issubset(self.routes), expected - self.routes.keys())

    def test_retired_coupling_and_direct_realtime_routes_are_absent(self):
        retired = {
            "/api/pairing",
            "/api/avatar/store", "/api/avatar/store/art",
            "/api/avatar/store/install", "/api/sync/solo",
            "/api/live/voices", "/api/live/voice-preview", "/live/voice",
            "/api/enconvo/file", "/api/enconvo/agents",
            "/api/enconvo/chat", "/api/enconvo/photo",
        }
        self.assertTrue(retired.isdisjoint(self.routes), retired & self.routes.keys())
        self.assertFalse(any(path.startswith("/api/enconvo") for path in self.routes))

    def test_second_avatar_state_is_mac_local_and_rejects_the_active_avatar(self):
        selected = []

        class Registry:
            @staticmethod
            def read_manifest(slug):
                return {"slug": slug, "status": "ready"}

            @staticmethod
            def set_companion(slug):
                selected.append(slug)

        with patch.object(self.application, "reg", return_value=Registry()), \
             patch.object(self.application, "active_slug", return_value="captain"), \
             patch.object(self.application, "_publish_runtime") as publish:
            result = asyncio.run(self.application.api_companion(
                self.application.CompanionRequest(slug="emma")
            ))
            cleared = asyncio.run(self.application.api_companion(
                self.application.CompanionRequest(slug="")
            ))
            with self.assertRaises(self.application.HTTPException) as caught:
                asyncio.run(self.application.api_companion(
                    self.application.CompanionRequest(slug="captain")
                ))
        self.assertEqual(result, {"companion": "emma"})
        self.assertEqual(cleared, {"companion": None})
        self.assertEqual(selected, ["emma", None])
        publish.assert_called_once_with("emma", "publishing second avatar")
        self.assertEqual(caught.exception.status_code, 400)

    def test_config_rejects_legacy_live_and_non_catalog_provider(self):
        cfg = copy.deepcopy(P.DEFAULTS)
        with patch.object(self.application.P, "load", return_value=cfg):
            with self.assertRaises(self.application.HTTPException) as caught:
                asyncio.run(self.application.api_config_set({
                    "live": {"provider": "retired-realtime"},
                }))
            self.assertEqual(caught.exception.status_code, 422)
            with self.assertRaises(self.application.HTTPException) as caught:
                asyncio.run(self.application.api_config_set({
                    "llm": {"provider": "managed-default"},
                }))
            self.assertEqual(caught.exception.status_code, 422)
            with self.assertRaises(self.application.HTTPException) as caught:
                asyncio.run(self.application.api_config_set({
                    "relay": {"url": "https://retired.example"},
                }))
            self.assertEqual(caught.exception.status_code, 422)

    def test_regular_chat_uses_direct_provider_and_keeps_media_contract(self):
        cfg = copy.deepcopy(P.DEFAULTS)
        spoken = {"text": "Hello", "audio": "", "track": [],
                  "dur": 0.0, "tier": "none"}
        with patch.object(self.application.P, "load", return_value=cfg), \
             patch.object(self.application.P, "chat",
                          new=AsyncMock(return_value="Hello")) as chat, \
             patch.object(self.application, "effective_persona",
                          return_value="OpenClam persona"), \
             patch.object(self.application, "_say",
                          new=AsyncMock(return_value=spoken)):
            result = asyncio.run(self.application.reply(
                self.application.Turn(history=[{"role": "user", "content": "Hi"}])
            ))
        chat.assert_awaited_once()
        self.assertEqual(result["text"], "Hello")
        self.assertEqual(result["media"], [])

    def test_runtime_sources_contain_no_retired_cross_app_hooks(self):
        banned = (
            "relay_agent", "mail_hands", "0.0.0.0", "VIVIEEN_",
            "/api/pairing", "/api/sync/solo", "/live/voice",
            "/api/avatar/store",
        )
        for relative in ("server/app.py", "server/providers.py"):
            source = (ROOT / relative).read_text(encoding="utf-8")
            for value in banned:
                self.assertNotIn(value, source, f"{relative}: {value}")
        retired_brand = "en" + "convo"
        for relative in ("server/app.py", "server/providers.py"):
            source = (ROOT / relative).read_text(encoding="utf-8").lower()
            self.assertNotIn(retired_brand, source, relative)


if __name__ == "__main__":
    unittest.main()
