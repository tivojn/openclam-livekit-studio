"""Regression boundaries for the standalone OpenClam desktop runtime."""
import asyncio
import copy
import importlib.util
import json
import os
import shutil
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
            "lips", "jaw", "cheeks", "eyebags", "brows", "forehead",
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

    def test_exact_legacy_managed_english_stt_migrates_once_to_multilingual(self):
        config = {
            "livekit": {
                "stt": {
                    "source": "managed",
                    "provider": "livekit",
                    "model": "deepgram/nova-3",
                    "language": "en",
                },
            },
        }

        self.assertTrue(P._migrate_legacy_managed_livekit_stt_default(config))
        self.assertEqual("multi", config["livekit"]["stt"]["language"])
        self.assertTrue(
            config["ui"][P.LIVEKIT_STT_DEFAULT_MIGRATION_KEY]
        )
        self.assertFalse(P._migrate_legacy_managed_livekit_stt_default(config))

        # After the marker exists, a deliberate managed-English choice stays.
        config["livekit"]["stt"]["language"] = "en"
        self.assertFalse(P._migrate_legacy_managed_livekit_stt_default(config))
        self.assertEqual("en", config["livekit"]["stt"]["language"])

    def test_livekit_stt_migration_preserves_byok_and_other_english_choices(self):
        cases = (
            {
                "source": "byok",
                "provider": "deepgram",
                "model": "nova-3",
                "language": "en",
            },
            {
                "source": "byok",
                "provider": "openai",
                "model": "gpt-4o-transcribe",
                "language": "en",
            },
            {
                "source": "managed",
                "provider": "livekit",
                "model": "different-model",
                "language": "en",
            },
        )
        for selection in cases:
            with self.subTest(selection=selection):
                config = {"livekit": {"stt": copy.deepcopy(selection)}}
                self.assertTrue(
                    P._migrate_legacy_managed_livekit_stt_default(config)
                )
                self.assertEqual(selection, config["livekit"]["stt"])
                self.assertTrue(
                    config["ui"][P.LIVEKIT_STT_DEFAULT_MIGRATION_KEY]
                )

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
            "/api/openclaw/pairing",
            "/api/avatar/body/generate", "/api/avatar/body/edit",
            "/api/avatar/motion/generate",
            "/api/avatar/activate", "/api/avatar/companion",
            "/api/avatar/export", "/api/avatar/import",
        }
        self.assertTrue(expected.issubset(self.routes), expected - self.routes.keys())

    def test_already_running_reports_the_current_job_kind(self):
        with patch.object(self.application, "_jobs", {
            "captain": {
                "id": "edit-job-1",
                "kind": "body-edit",
                "done": False,
            },
        }):
            result = self.application._already_running("captain")
        self.assertEqual(result, {
            "started": False,
            "reason": "already building",
            "job_id": "edit-job-1",
            "kind": "body-edit",
        })

    def test_body_edit_thread_redacts_provider_echo_before_persistence(self):
        instruction = 'Change "jacket" to coral'
        job_id = "edit-redaction"
        logs = []
        with self.application._jlock:
            self.application._jobs["captain"] = {
                "id": job_id,
                "kind": "body-edit",
                "done": False,
                "error": "",
                "log": [],
            }
            self.application._failures.pop(("captain", "body-edit"), None)
        try:
            echoed = json.dumps(instruction, ensure_ascii=False)[1:-1]
            with patch.object(
                    self.application, "_body_edit_stage",
                    side_effect=RuntimeError(
                        f"xAI rejected {instruction}; escaped={echoed}")), \
                 patch.object(self.application, "jlog",
                              return_value=logs.append), \
                 patch.object(self.application, "_build_log_write"):
                self.application._body_edit_thread(
                    "captain", instruction, job_id)

            with self.application._jlock:
                stored_job = copy.deepcopy(
                    self.application._jobs["captain"])
                stored_failure = copy.deepcopy(
                    self.application._failures[("captain", "body-edit")])
            persisted = json.dumps(
                {"job": stored_job, "failure": stored_failure, "logs": logs},
                ensure_ascii=False,
            )
            self.assertNotIn(instruction, persisted)
            self.assertNotIn(echoed, persisted)
            self.assertIn("[full-body edit instruction redacted]", persisted)
        finally:
            with self.application._jlock:
                self.application._jobs.pop("captain", None)
                self.application._failures.pop(
                    ("captain", "body-edit"), None)

    def test_body_edit_availability_requires_all_three_source_plates(self):
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_library = types.ModuleType("studio.library")
        fake_wardrobe = types.ModuleType("studio.wardrobe")
        provider = {
            "name": "xai",
            "model": "grok-imagine-image-2.0",
            "title": "xAI Grok Imagine Image 2.0",
        }
        fake_body.default_provider = lambda: provider
        fake_body.default_video_provider = lambda: {
            "name": "xai", "model": "grok-imagine-video-1.5"}
        fake_body.supports_xai_edit = lambda selected: selected == provider
        fake_body.public_body_metadata = lambda metadata: metadata
        fake_body.BODY_VIEWS = ("front", "side", "back")
        fake_body._body_metadata = lambda directory: json.loads(
            Path(directory, "body", "body.json").read_text(encoding="utf-8"))

        def body_source(directory, metadata, view):
            name = ((metadata.get("views") or {}).get(view) or {}).get("source")
            path = Path(directory, "body", str(name or ""))
            if not name or not path.is_file():
                raise RuntimeError(f"the current {view} source plate is missing")
            return str(path)

        fake_body._body_source = body_source
        fake_library.sync_canonical = lambda _directory: None
        fake_library.list_body_sets = lambda _directory: []
        fake_library.list_motion_sets = lambda _directory, _kind: []
        fake_wardrobe.cached_prompt = lambda _directory: None
        fake_wardrobe.preset_prompt = lambda: "Neutral full-body prompt"
        fake_studio.body = fake_body
        fake_studio.library = fake_library
        fake_studio.wardrobe = fake_wardrobe

        with tempfile.TemporaryDirectory() as directory:
            body_dir = Path(directory, "body")
            body_dir.mkdir()
            views = {
                view: {
                    "image": f"body-{view}.png",
                    "source": f"source-{view}.png",
                }
                for view in ("front", "side", "back")
            }
            for view in views:
                Path(body_dir, views[view]["image"]).write_bytes(b"rgba")
            Path(body_dir, "body.json").write_text(
                json.dumps({"views": views}), encoding="utf-8")
            # A complete preview is not sufficient: the provider edits the
            # retained opaque sources, and Side is deliberately missing here.
            Path(body_dir, "source-front.png").write_bytes(b"front")
            Path(body_dir, "source-back.png").write_bytes(b"back")
            manifest = {
                "status": "ready",
                "body": {"views": views},
            }

            class Registry:
                @staticmethod
                def read_manifest(_slug):
                    return copy.deepcopy(manifest)

                @staticmethod
                def adir(_slug):
                    return directory

            modules = {
                "studio": fake_studio,
                "studio.body": fake_body,
                "studio.library": fake_library,
                "studio.wardrobe": fake_wardrobe,
            }
            with patch.dict(sys.modules, modules), \
                 patch.object(self.application, "reg", return_value=Registry()):
                unavailable = asyncio.run(self.application.api_body("captain"))
                Path(body_dir, "source-side.png").write_bytes(b"side")
                available = asyncio.run(self.application.api_body("captain"))

        self.assertFalse(unavailable["body_edit_available"])
        self.assertIn("source", unavailable["body_edit_reason"].lower())
        self.assertTrue(available["body_edit_available"])
        self.assertEqual(available["body_edit_reason"], "")

    def test_body_status_does_not_archive_a_live_edit_before_commit(self):
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_library = types.ModuleType("studio.library")
        fake_wardrobe = types.ModuleType("studio.wardrobe")
        fake_body.default_provider = lambda: {
            "name": "xai", "model": "grok-imagine-image-2.0"}
        fake_body.default_video_provider = lambda: {
            "name": "xai", "model": "grok-imagine-video-1.5"}
        fake_body.supports_xai_edit = lambda _provider: True
        fake_body.public_body_metadata = lambda metadata: metadata
        fake_body.BODY_VIEWS = ("front", "side", "back")
        fake_body._body_metadata = lambda _directory: (_ for _ in ()).throw(
            RuntimeError("sources are not ready"))
        sync_events = []
        fake_library.sync_canonical = lambda _directory: sync_events.append("sync")
        fake_library.list_body_sets = lambda _directory: []
        fake_library.list_motion_sets = lambda _directory, _kind: []
        fake_wardrobe.cached_prompt = lambda _directory: None
        fake_wardrobe.preset_prompt = lambda: "Neutral full-body prompt"
        fake_studio.body = fake_body
        fake_studio.library = fake_library
        fake_studio.wardrobe = fake_wardrobe

        class Registry:
            @staticmethod
            def read_manifest(_slug):
                return {"status": "ready", "body": {"views": {}}}

            @staticmethod
            def adir(_slug):
                return "/private/avatar"

        modules = {
            "studio": fake_studio,
            "studio.body": fake_body,
            "studio.library": fake_library,
            "studio.wardrobe": fake_wardrobe,
        }
        with patch.dict(sys.modules, modules), \
             patch.object(self.application, "reg", return_value=Registry()):
            with self.application._jlock:
                self.application._jobs["captain"] = {
                    "id": "live-edit", "kind": "body-edit", "done": False,
                    "log": [], "error": "", "phase": "editing",
                    "progress": {"stage": "editing", "value": .5},
                }
            try:
                result = asyncio.run(self.application.api_body("captain"))
            finally:
                with self.application._jlock:
                    self.application._jobs.pop("captain", None)

        self.assertEqual(sync_events, [])
        self.assertEqual(result["job"]["kind"], "body-edit")

    def test_body_edit_repeats_exact_xai_model_gate_before_reserving_a_job(self):
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_body.default_provider = lambda: {
            "name": "openai", "model": "gpt-image-1"}
        fake_body.supports_xai_edit = lambda _provider: False
        fake_studio.body = fake_body

        class Registry:
            @staticmethod
            def read_manifest(_slug):
                return {"status": "ready"}

        request = self.application.BodyEditRequest(
            slug="captain", instruction="Change the blazer to coral")
        with patch.dict(sys.modules, {
            "studio": fake_studio, "studio.body": fake_body,
        }), patch.object(self.application, "reg", return_value=Registry()), \
             patch.object(self.application, "_recover_body_edit_transaction"), \
             patch.object(self.application, "_reserve_job") as reserve:
            with self.assertRaises(self.application.HTTPException) as caught:
                asyncio.run(self.application.api_body_edit(request))
        self.assertEqual(caught.exception.status_code, 409)
        reserve.assert_not_called()

    def test_body_edit_transaction_snapshots_restore_state_byte_for_byte(self):
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_body.commit_previous = lambda directory: shutil.rmtree(
            Path(directory, "body.previous"), ignore_errors=True)
        fake_studio.body = fake_body

        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory)
            body_dir = avatar / "body"
            motion_dir = avatar / "motion"
            library_dir = avatar / "library"
            runtime_dir = avatar / "runtime"
            body_dir.mkdir()
            motion_dir.mkdir()
            library_dir.mkdir()
            runtime_dir.mkdir()
            (body_dir / "old-body.bin").write_bytes(b"old body")
            old_manifest = b'{\n "updated": "before-edit",\n "body": "old"\n}\n'
            old_index = b'{\n "active": {"body": "old", "walk": "walk-1"}\n}\n'
            old_motion_metadata = b'{\n "walk": {"sheets": [{"image": "walk-0.png"}]}\n}\n'
            (avatar / "manifest.json").write_bytes(old_manifest)
            (library_dir / "library.json").write_bytes(old_index)
            (motion_dir / "motion.json").write_bytes(old_motion_metadata)
            (motion_dir / "walk-0.png").write_bytes(b"old motion pixels")

            class Registry:
                @staticmethod
                def adir(_slug):
                    return directory

            with patch.dict(sys.modules, {
                "studio": fake_studio, "studio.body": fake_body,
            }), patch.object(self.application, "reg", return_value=Registry()):
                journal = self.application._begin_body_edit_transaction("captain")
                self.assertEqual(journal["phase"], "prepared")

                os.replace(body_dir, avatar / "body.previous")
                body_dir.mkdir()
                (body_dir / "new-body.bin").write_bytes(b"new body")
                shutil.rmtree(motion_dir)
                motion_dir.mkdir()
                (motion_dir / "motion.json").write_bytes(b'{"idle": {}}')
                (motion_dir / "idle-0.png").write_bytes(b"new motion pixels")
                (avatar / "manifest.json").write_bytes(b'{"body": "new"}')
                (library_dir / "library.json").write_bytes(
                    b'{"active": {"body": "new"}}')
                self.application._set_body_edit_transaction_phase(
                    "captain", "state-written")

                outcome = self.application._recover_body_edit_transaction(
                    "captain", log=lambda _message: None)

            self.assertEqual(outcome, "rolled-back")
            self.assertEqual((avatar / "manifest.json").read_bytes(), old_manifest)
            self.assertEqual((library_dir / "library.json").read_bytes(), old_index)
            self.assertEqual(
                (motion_dir / "motion.json").read_bytes(), old_motion_metadata)
            self.assertEqual(
                (motion_dir / "walk-0.png").read_bytes(), b"old motion pixels")
            self.assertFalse((motion_dir / "idle-0.png").exists())
            self.assertEqual((body_dir / "old-body.bin").read_bytes(), b"old body")
            self.assertFalse((body_dir / "new-body.bin").exists())
            self.assertFalse((avatar / "body.previous").exists())
            self.assertFalse((avatar / ".body-edit-transaction").exists())

    def test_uncommitted_body_edit_crash_restores_previous_body_and_runtime(self):
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_body.commit_previous = lambda directory: shutil.rmtree(
            Path(directory, "body.previous"), ignore_errors=True)
        fake_studio.body = fake_body

        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory)
            for name, payload in (
                ("body/new.bin", b"new body"),
                ("body.previous/old.bin", b"old body"),
                ("runtime/new.bin", b"new runtime"),
                ("runtime.previous/old.bin", b"old runtime"),
            ):
                path = avatar / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            transaction = avatar / ".body-edit-transaction"
            transaction.mkdir()
            (transaction / "transaction.json").write_text(json.dumps({
                "v": 1,
                "slug": "captain",
                "phase": "state-written",
                "manifest_existed": False,
                "motion_existed": False,
                "library_index_existed": False,
                "runtime_existed": True,
            }), encoding="utf-8")

            class Registry:
                @staticmethod
                def adir(_slug):
                    return directory

            with patch.dict(sys.modules, {
                "studio": fake_studio, "studio.body": fake_body,
            }), patch.object(self.application, "reg", return_value=Registry()):
                outcome = self.application._recover_body_edit_transaction(
                    "captain", log=lambda _message: None)

            self.assertEqual(outcome, "rolled-back")
            self.assertEqual((avatar / "body" / "old.bin").read_bytes(), b"old body")
            self.assertFalse((avatar / "body" / "new.bin").exists())
            self.assertEqual(
                (avatar / "runtime" / "old.bin").read_bytes(), b"old runtime")
            self.assertFalse((avatar / "runtime" / "new.bin").exists())
            self.assertFalse((avatar / "body.previous").exists())
            self.assertFalse((avatar / "runtime.previous").exists())
            self.assertFalse(transaction.exists())

    def test_committed_body_edit_crash_keeps_new_state_and_finishes_cleanup(self):
        events = []
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_library = types.ModuleType("studio.library")
        fake_body.commit_previous = lambda directory: (
            events.append("body-backup-removed"),
            shutil.rmtree(Path(directory, "body.previous"), ignore_errors=True),
        )
        fake_library.archive_body = lambda _directory: (
            events.append("archived") or "new-body")
        fake_studio.body = fake_body
        fake_studio.library = fake_library

        with tempfile.TemporaryDirectory() as directory:
            avatar = Path(directory)
            for name, payload in (
                ("body/new.bin", b"new body"),
                ("body.previous/old.bin", b"old body"),
                ("runtime/new.bin", b"new runtime"),
                ("runtime.previous/old.bin", b"old runtime"),
            ):
                path = avatar / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            transaction = avatar / ".body-edit-transaction"
            transaction.mkdir()
            (avatar / "manifest.json").write_bytes(b'{"body":"new"}')
            (avatar / "motion").mkdir()
            (avatar / "motion" / "new-motion.bin").write_bytes(b"new motion")
            (avatar / "library").mkdir()
            (avatar / "library" / "library.json").write_bytes(
                b'{"active":{"body":"new"}}')
            (transaction / "manifest.json").write_bytes(b'{"body":"old"}')
            (transaction / "motion").mkdir()
            (transaction / "motion" / "old-motion.bin").write_bytes(b"old motion")
            (transaction / "library.json").write_bytes(
                b'{"active":{"body":"old"}}')
            (transaction / "transaction.json").write_text(json.dumps({
                "v": 1,
                "slug": "captain",
                "phase": "committed",
                "manifest_existed": True,
                "motion_existed": True,
                "library_index_existed": True,
                "runtime_existed": True,
            }), encoding="utf-8")

            class Registry:
                @staticmethod
                def adir(_slug):
                    return directory

            modules = {
                "studio": fake_studio,
                "studio.body": fake_body,
                "studio.library": fake_library,
            }
            with patch.dict(sys.modules, modules), \
                 patch.object(self.application, "reg", return_value=Registry()):
                outcome = self.application._recover_body_edit_transaction(
                    "captain", log=lambda _message: None)

            self.assertEqual(outcome, "committed")
            self.assertEqual((avatar / "body" / "new.bin").read_bytes(), b"new body")
            self.assertEqual(
                (avatar / "runtime" / "new.bin").read_bytes(), b"new runtime")
            self.assertEqual(
                (avatar / "manifest.json").read_bytes(), b'{"body":"new"}')
            self.assertTrue((avatar / "motion" / "new-motion.bin").is_file())
            self.assertEqual(
                (avatar / "library" / "library.json").read_bytes(),
                b'{"active":{"body":"new"}}')
            self.assertFalse((avatar / "body.previous").exists())
            self.assertFalse((avatar / "runtime.previous").exists())
            self.assertFalse(transaction.exists())
            self.assertEqual(events, ["archived", "body-backup-removed"])

    def test_body_edit_publish_failure_runs_exact_recovery_without_archiving(self):
        events = []
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_library = types.ModuleType("studio.library")
        fake_body.edit = lambda *_args, **_kwargs: (
            events.append("edited") or {"image": "new-body.png"})
        fake_body.commit_previous = lambda _directory: events.append("committed")
        fake_library.sync_canonical = lambda _directory: events.append("synced")
        fake_library.archive_body = lambda _directory: (
            events.append("archived-new") or "new-body")
        fake_library.reconcile_motion_with_body = lambda _directory: (
            events.append("reconciled") or None)
        fake_studio.body = fake_body
        fake_studio.library = fake_library
        previous = {"status": "ready", "body": {"image": "old-body.png"},
                    "motion": {"walk": {"sheets": [{}]}}}
        writes = []

        class Registry:
            @staticmethod
            def adir(_slug):
                return "/private/avatar"

            @staticmethod
            def read_manifest(_slug):
                return copy.deepcopy(previous)

            @staticmethod
            def write_manifest(_slug, manifest):
                writes.append(copy.deepcopy(manifest))

        with patch.dict(sys.modules, {
            "studio": fake_studio,
            "studio.body": fake_body,
            "studio.library": fake_library,
        }), patch.object(self.application, "reg", return_value=Registry()), \
             patch.object(self.application, "_begin_body_edit_transaction",
                          side_effect=lambda _slug: events.append("snapshot")), \
             patch.object(self.application, "_set_body_edit_transaction_phase",
                          side_effect=lambda _slug, phase: events.append(phase)), \
             patch.object(self.application, "_recover_body_edit_transaction",
                          side_effect=lambda _slug, **_kwargs: events.append("recovered")) as recover, \
             patch.object(self.application, "_publish_runtime_atomic",
                          side_effect=RuntimeError("publish failed")):
            with self.assertRaisesRegex(RuntimeError, "publish failed"):
                self.application._body_edit_stage(
                    "captain", "Change the blazer to coral",
                    lambda _line: None, lambda *_args: None)
        self.assertEqual(recover.call_count, 2)
        self.assertEqual(events[-1], "recovered")
        self.assertNotIn("committed", events)
        self.assertNotIn("archived-new", events)
        self.assertEqual(writes[-1]["body"], {"image": "new-body.png"})

    def test_body_edit_archives_only_after_runtime_is_committed(self):
        events = []
        fake_studio = types.ModuleType("studio")
        fake_studio.__path__ = []
        fake_body = types.ModuleType("studio.body")
        fake_library = types.ModuleType("studio.library")
        fake_body.edit = lambda *_args, **_kwargs: (
            events.append("edited") or {"image": "new-body.png"})
        fake_body.commit_previous = lambda _directory: events.append("committed")
        fake_library.sync_canonical = lambda _directory: events.append("synced")
        fake_library.reconcile_motion_with_body = lambda _directory: (
            events.append("reconciled") or None)
        fake_library.archive_body = lambda _directory: (
            events.append("archived-new") or "new-body")
        fake_studio.body = fake_body
        fake_studio.library = fake_library

        class Registry:
            @staticmethod
            def adir(_slug):
                return "/private/avatar"

            @staticmethod
            def read_manifest(_slug):
                return {"status": "ready", "body": {"image": "old-body.png"}}

            @staticmethod
            def write_manifest(_slug, _manifest):
                events.append("manifest-written")

        def publish(_slug, **_kwargs):
            events.append("runtime-published")

        with patch.dict(sys.modules, {
            "studio": fake_studio,
            "studio.body": fake_body,
            "studio.library": fake_library,
        }), patch.object(self.application, "reg", return_value=Registry()), \
             patch.object(self.application, "_recover_body_edit_transaction"), \
             patch.object(self.application, "_begin_body_edit_transaction"), \
             patch.object(self.application, "_set_body_edit_transaction_phase"), \
             patch.object(self.application, "_publish_runtime_atomic",
                          side_effect=publish):
            self.application._body_edit_stage(
                "captain", "Change the blazer to coral",
                lambda _line: None, lambda *_args: None)

        self.assertLess(
            events.index("runtime-published"), events.index("archived-new"))
        self.assertLess(events.index("archived-new"), events.index("committed"))

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
             patch.object(
                 self.application, "_recover_body_edit_transaction_if_idle"), \
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
        cfg["llm"]["model"] = "qwen3.8-uncensored:q8_0"
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
        system = chat.await_args.kwargs["system"]
        self.assertIn("HOST RUNTIME FACT", system)
        self.assertIn("Ollama", system)
        self.assertIn("qwen3.8-uncensored:q8_0", system)
        self.assertIn("Do not substitute a model or product name remembered from training", system)
        self.assertEqual(result["text"], "Hello")
        self.assertEqual(result["media"], [])

    def test_llm_test_returns_the_authoritative_route_receipt(self):
        receipt = {
            "provider": "ollama",
            "model": "qwen3.8-uncensored:q8_0",
            "display": "Ollama · qwen3.8-uncensored:q8_0",
            "state": "success",
        }
        with patch.object(
            self.application.P, "load", return_value=copy.deepcopy(P.DEFAULTS)
        ), patch.object(
            self.application.P, "test", new=AsyncMock(
                return_value={"ok": True, "detail": "ok"}
            )
        ), patch.object(self.application.P, "last_route", return_value=receipt):
            result = asyncio.run(self.application.api_test({
                "kind": "llm",
                "cfg": {"provider": "ollama", "model": receipt["model"]},
            }))

        self.assertTrue(result["ok"])
        self.assertEqual(receipt, result["route"])

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
