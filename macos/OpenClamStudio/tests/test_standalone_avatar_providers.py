"""Security and routing tests for standalone avatar provider work."""
import base64
import builtins
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from server import media_gen


ROOT = Path(__file__).resolve().parents[1]
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + (b"mock-png-payload" * 320)
JPEG_BYTES = b"\xff\xd8\xff\xe0" + (b"mock-jpeg-payload" * 320)


def mock_mp4(duration=5.0):
    def box(kind, payload):
        return (8 + len(payload)).to_bytes(4, "big") + kind + payload
    ftyp = box(b"ftyp", b"isom\x00\x00\x02\x00isommp42")
    timescale = 1000
    ticks = int(duration * timescale)
    mvhd = box(
        b"mvhd",
        b"\x00\x00\x00\x00" + b"\x00" * 8
        + timescale.to_bytes(4, "big") + ticks.to_bytes(4, "big")
        + b"\x00" * 20,
    )
    return ftyp + box(b"moov", mvhd) + box(b"mdat", b"video" * 100)


XAI_TEST_AUTH = (
    "https://api.x.ai/v1",
    {"Authorization": "Bearer global-xai-test-token"},
    "global-xai-test-token",
    "api_key",
)
OWNED_SOURCES = (
    ROOT / "studio" / "body.py",
    ROOT / "studio" / "motion.py",
    ROOT / "studio" / "generate.py",
    ROOT / "studio" / "wardrobe.py",
    ROOT / "studio" / "promptsmith.py",
    ROOT / "server" / "media_gen.py",
)


class _ProviderHelper:
    def __init__(self, config, managed=False):
        self.config = config
        self.managed = managed
        self.loads = 0

    def load(self):
        self.loads += 1
        return self.config

    def spec(self, _kind, provider):
        return {
            "id": provider,
            "label": "Test Direct Provider",
            "key": True,
            "managed": self.managed,
        }


class StandaloneSelectionTests(unittest.TestCase):
    def test_selection_uses_only_the_local_keychain_materialised_helper(self):
        helper = _ProviderHelper({
            "image": {"provider": "xai", "model": "grok-imagine-image-quality",
                      "api_key": "xai-private-test-key"},
        })

        real_open = builtins.open

        def guarded_open(path, *args, **kwargs):
            lowered = os.fspath(path).lower()
            if "preference" in lowered or ".config" in lowered:
                raise AssertionError("a retired preferences path was read")
            return real_open(path, *args, **kwargs)

        with mock.patch.object(media_gen, "_providers", return_value=helper), \
             mock.patch.object(subprocess, "run") as process, \
             mock.patch.object(builtins, "open", side_effect=guarded_open):
            config, public = media_gen.selected_config(
                "image", media_gen.IMAGE_EDIT_PROVIDERS)

        process.assert_not_called()
        self.assertEqual(helper.loads, 1)
        self.assertEqual(config["api_key"], "xai-private-test-key")
        self.assertNotIn("api_key", public)
        self.assertEqual(public["route"], "direct:xai")

    def test_managed_or_unconfigured_lanes_fail_with_an_actionable_message(self):
        helper = _ProviderHelper({
            "image": {"provider": "managed-default", "api_key": ""},
        }, managed=True)
        with mock.patch.object(media_gen, "_providers", return_value=helper):
            with self.assertRaisesRegex(RuntimeError, "Choose a direct image provider"):
                media_gen.selected_config(
                    "image", media_gen.IMAGE_EDIT_PROVIDERS)

    def test_avatar_lanes_reject_a_model_from_the_wrong_catalogue(self):
        with self.assertRaisesRegex(RuntimeError, "compatible Xai image model"):
            media_gen._require_avatar_model("image", "xai", "grok-3-mini")
        with self.assertRaisesRegex(RuntimeError, "compatible Xai video model"):
            media_gen._require_avatar_model(
                "video", "xai", "grok-imagine-image-quality")

    def test_image_model_allowlists_are_exact_and_keep_saved_compatibility(self):
        for model in ("gpt-image-2", "gpt-image-1"):
            media_gen._require_avatar_model("image", "openai", model)
        for model in ("grok-imagine-image-2.0", "grok-imagine-image",
                      "grok-imagine-image-quality"):
            media_gen._require_avatar_model("image", "xai", model)
        for provider, model in (
                ("openai", "gpt-image-2-preview"),
                ("openai", "gpt-image-1.5"),
                ("xai", "grok-imagine-image-2.0-preview"),
                ("xai", "grok-imagine-image-pro")):
            with self.assertRaisesRegex(RuntimeError, "compatible"):
                media_gen._require_avatar_model("image", provider, model)

    def test_explicit_provider_blank_model_gets_only_its_reviewed_default(self):
        cases = (("openai", "gpt-image-2"),
                 ("xai", "grok-imagine-image-2.0"))
        for provider, expected in cases:
            helper = _ProviderHelper({
                "image": {"provider": provider, "model": "",
                          "api_key": "test-private-key"},
            })
            with self.subTest(provider=provider), \
                 mock.patch.object(media_gen, "_providers", return_value=helper):
                config, public = media_gen.selected_config(
                    "image", media_gen.IMAGE_EDIT_PROVIDERS)
            self.assertEqual(config["provider"], provider)
            self.assertEqual(public["model"], expected)

    def test_owned_sources_contain_no_retired_gateway_or_brand_hooks(self):
        retired_brand = "en" + "convo"
        prior_brand = "vivi" + "een"
        for path in OWNED_SOURCES:
            source = path.read_text(encoding="utf-8").lower()
            self.assertNotIn(retired_brand, source, path.name)
            self.assertNotIn(prior_brand, source, path.name)
            self.assertNotIn("installed_preferences", source, path.name)
            self.assertNotIn("127.0.0.1:54535", source, path.name)


class FullBodyDirectWiringTests(unittest.TestCase):
    def test_rejected_identity_plate_invalidates_generated_turnaround_cache(self):
        try:
            import cv2
            import numpy as np
            from studio import body
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")

        config = {"provider": "xai", "model": "grok-imagine-image-quality",
                  "api_key": "private-test-key"}
        public = {"name": "xai", "title": "xAI Grok Image",
                  "model": "grok-imagine-image-quality",
                  "route": "direct:xai", "direct": True}

        def edit(_prompt, _references, _lane, **options):
            path = os.path.join(
                options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((360, 240, 3), 150, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            keyframe = np.full((256, 256, 3), 127, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), keyframe)
            cv2.imwrite(os.path.join(directory, "head.png"), keyframe)
            with mock.patch.object(
                    body, "image_provider_selection",
                    return_value=(config, public)), \
                 mock.patch.object(
                    body.media_gen, "generate_image_edit_sync",
                    side_effect=edit), \
                 mock.patch.object(
                    body, "_preflight_front_source",
                    return_value={"valid": True}), \
                 mock.patch.object(
                    body, "_preflight_alpha_source",
                    return_value={"valid": True}), \
                 mock.patch.object(
                    body, "_install_sources",
                    side_effect=body.GeneratedBodyIdentityError(
                        "generated head is too small")):
                with self.assertRaises(body.GeneratedBodyIdentityError):
                    body.build(
                        directory,
                        {"style": "photorealistic", "pose": "relaxed"},
                        log=lambda _message: None)
            self.assertFalse(Path(directory, ".body-cache").exists())

    def test_three_view_body_build_uses_direct_edits_without_persisting_key(self):
        try:
            import cv2
            import numpy as np
            from studio import body
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")

        secret = "xai-fullbody-private-test-key"
        config = {"provider": "xai", "model": "grok-imagine-image-quality",
                  "api_key": secret}
        public = {"name": "xai", "title": "xAI Grok Image",
                  "model": "grok-imagine-image-quality",
                  "route": "direct:xai", "direct": True}
        calls = []

        def edit(_prompt, references, lane, **options):
            self.assertEqual(lane["api_key"], secret)
            calls.append(tuple(references))
            path = os.path.join(options["output_dir"], options["file_name"] + ".png")
            plate = np.full((360, 240, 3), 255, np.uint8)
            plate[10:350, 40:200] = (150, 30, 220)
            cv2.imwrite(path, plate)
            return path

        def cut(_source, destination, **_options):
            rgba = np.zeros((360, 240, 4), np.uint8)
            rgba[10:350, 40:200, :3] = (150, 30, 220)
            rgba[10:350, 40:200, 3] = 255
            return bool(cv2.imwrite(destination, rgba))

        def head_mask(_image, _landmarks, destination):
            rgba = np.zeros((360, 240, 4), np.uint8)
            rgba[20:120, 70:170, 3] = 255
            cv2.imwrite(destination, rgba)

        with tempfile.TemporaryDirectory() as directory:
            keyframe = np.full((256, 256, 3), 127, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), keyframe)
            cv2.imwrite(os.path.join(directory, "head.png"), keyframe)
            landmarks = np.zeros((478, 2), np.float32)
            with mock.patch.object(
                    body, "image_provider_selection", return_value=(config, public)), \
                 mock.patch.object(
                    body.media_gen, "generate_image_edit_sync", side_effect=edit), \
                 mock.patch.object(body.cutout, "render", side_effect=cut), \
                 mock.patch.object(
                    body, "_face_transform",
                    return_value=(np.array([[1, 0, 0], [0, 1, 0]], np.float32),
                                  {"scale": 1.0}, landmarks)), \
                 mock.patch.object(body, "_head_mask", side_effect=head_mask), \
                 mock.patch.object(body, "_seam_tone_match"):
                metadata = body.build(
                    directory, {
                        "style": "photorealistic",
                        "pose": "relaxed",
                        "presentation": "female",
                        "medium": "photograph",
                    },
                    log=lambda _message: None)
            receipt = Path(directory, "body", "body.json").read_text(encoding="utf-8")

        self.assertNotIn(secret, receipt)
        self.assertEqual(list(metadata["views"]), ["front", "side", "back"])
        self.assertEqual(metadata["options"]["presentation"], "feminine")
        self.assertEqual(metadata["options"]["medium"], "photograph")
        self.assertEqual([len(references) for references in calls], [1, 2, 2])

    def test_xai_edit_rebuilds_all_views_locally_and_keeps_private_rollback(self):
        try:
            import cv2
            import numpy as np
            from studio import body
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")

        secret = "xai-body-edit-private-test-key"
        config = {"provider": "xai", "model": "grok-imagine-image-2.0",
                  "api_key": secret}
        public = {"name": "xai", "title": "xAI Grok Imagine Image 2.0",
                  "model": "grok-imagine-image-2.0",
                  "route": "direct:xai", "direct": True}
        calls = []

        def edit(prompt, references, lane, **options):
            self.assertEqual(lane["api_key"], secret)
            self.assertIn("Precisely edit", prompt)
            calls.append(tuple(references))
            path = os.path.join(options["output_dir"], options["file_name"] + ".jpg")
            plate = np.full((360, 240, 3), 255, np.uint8)
            plate[10:350, 40:200] = (120 + len(calls), 30, 220)
            cv2.imwrite(path, plate)
            return path

        def cut(_source, destination, **_options):
            rgba = np.zeros((360, 240, 4), np.uint8)
            rgba[10:350, 40:200, :3] = (150, 30, 220)
            rgba[10:350, 40:200, 3] = 255
            return bool(cv2.imwrite(destination, rgba))

        def head_mask(_image, _landmarks, destination):
            rgba = np.zeros((256, 256, 4), np.uint8)
            # A compact, proportionate identity overlay for the editorial
            # rollback fixture: 60x50 over a 160x340 person silhouette.
            rgba[20:70, 90:150, 3] = 255
            cv2.imwrite(destination, rgba)

        with tempfile.TemporaryDirectory() as directory:
            keyframe = np.full((256, 256, 3), 127, np.uint8)
            cv2.imwrite(os.path.join(directory, "keyframe.png"), keyframe)
            cv2.imwrite(os.path.join(directory, "head.png"), keyframe)
            body_dir = Path(directory, "body")
            body_dir.mkdir()
            views = {}
            for index, view in enumerate(body.BODY_VIEWS):
                source = body_dir / f"source-{view}.png"
                cv2.imwrite(str(source), np.full((360, 240, 3), 60 + index, np.uint8))
                cv2.imwrite(str(body_dir / f"body-{view}.png"),
                            np.full((360, 240, 4), 90 + index, np.uint8))
                views[view] = {"source": source.name,
                               "image": f"body-{view}.png"}
            cv2.imwrite(str(body_dir / "body.png"),
                        np.full((360, 240, 4), 91, np.uint8))
            cv2.imwrite(str(body_dir / "head-mask.png"),
                        np.full((360, 240, 4), 255, np.uint8))
            Path(body_dir, "body.json").write_text(json.dumps({
                "v": 3, "image": "body.png", "head_mask": "head-mask.png",
                "views": views, "options": {"style": "editorial", "pose": "formal"},
            }))
            original_front = Path(body_dir, "source-front.png").read_bytes()
            landmarks = np.zeros((478, 2), np.float32)
            with mock.patch.object(
                    body, "image_provider_selection", return_value=(config, public)), \
                 mock.patch.object(
                    body.media_gen, "generate_image_edit_sync", side_effect=edit), \
                 mock.patch.object(body.cutout, "render", side_effect=cut), \
                 mock.patch.object(
                    body, "_face_transform",
                    return_value=(np.array([[1, 0, 0], [0, 1, 0]], np.float32),
                                  {"scale": 1.0,
                                   "face_bounds": [90, 20, 60, 30]}, landmarks)), \
                 mock.patch.object(body, "_head_mask", side_effect=head_mask), \
                 mock.patch.object(body, "_seam_tone_match"):
                metadata = body.edit(
                    directory, "Change the blazer to fuchsia and preserve the tailoring",
                    log=lambda _message: None)
            receipt = Path(directory, "body", "body.json").read_text(encoding="utf-8")
            self.assertTrue(Path(directory, "body.previous").is_dir())
            self.assertEqual([len(references) for references in calls], [2, 3, 3])
            self.assertEqual(metadata["edit"]["scope"], "front+side+back")
            self.assertIn("instruction_sha256", metadata["edit"])
            self.assertNotIn("Change the blazer", receipt)
            self.assertNotIn(secret, receipt)
            self.assertEqual(metadata["views"]["front"]["source"], "source-front.jpg")
            self.assertTrue(body.restore_previous(directory))
            self.assertEqual(
                Path(directory, "body", "source-front.png").read_bytes(),
                original_front)

    def test_body_edit_rejects_non_xai_before_any_provider_call(self):
        try:
            from studio import body
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")
        public = {"name": "openai", "title": "OpenAI Images",
                  "model": "gpt-image-1", "direct": True}
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(
                 body, "image_provider_selection", return_value=({}, public)), \
             mock.patch.object(body.media_gen, "generate_image_edit_sync") as generate:
            with self.assertRaisesRegex(RuntimeError, "requires xAI"):
                body.edit(directory, "Change the jacket to coral")
        generate.assert_not_called()


class HeadAndVisemeDirectWiringTests(unittest.TestCase):
    def test_head_and_viseme_bank_share_the_selected_direct_image_lane(self):
        try:
            import cv2
            import numpy as np
            from studio import body, generate
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")

        secret = "openai-head-private-test-key"
        config = {"provider": "openai", "model": "gpt-image-1",
                  "api_key": secret}
        public = {"name": "openai", "title": "OpenAI Images",
                  "model": "gpt-image-1", "route": "direct:openai", "direct": True}
        calls = []

        def edit(prompt, references, lane, **options):
            self.assertEqual(lane["api_key"], secret)
            calls.append((prompt, tuple(references), options["aspect_ratio"]))
            path = os.path.join(options["output_dir"], options["file_name"] + ".png")
            cv2.imwrite(path, np.full((1024, 1024, 3), 145, np.uint8))
            return path

        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.png")
            cv2.imwrite(source, np.full((800, 800, 3), 120, np.uint8))
            head = os.path.join(directory, "head.png")
            raw = os.path.join(directory, "raw")
            with mock.patch.object(
                    body, "image_provider_selection", return_value=(config, public)), \
                 mock.patch.object(
                    generate.media_gen, "generate_image_edit_sync", side_effect=edit):
                generate.generate_head(source, head, log=lambda _message: None)
                viseme = generate.generate_one(
                    head, "ah", raw, log=lambda _message: None)
            receipts = Path(head + ".prompt").read_text(encoding="utf-8")
            receipts += Path(raw, ".ah.prompt").read_text(encoding="utf-8")

        self.assertTrue(viseme.endswith("v_ah.png"))
        self.assertEqual([call[2] for call in calls], ["1:1", "1:1"])
        self.assertNotIn(secret, receipts)


class MotionDirectWiringTests(unittest.TestCase):
    def test_walk_and_edge_idle_use_direct_image_to_video(self):
        try:
            import cv2
            import numpy as np
            from studio import motion
        except ModuleNotFoundError as exc:
            self.skipTest(f"packaged avatar runtime is unavailable: {exc}")

        config = {"provider": "xai", "model": "grok-imagine-video-1.5",
                  "api_key": "xai-motion-private-test-key"}
        public = {"name": "xai", "title": "xAI Grok Imagine",
                  "model": "grok-imagine-video-1.5",
                  "route": "direct:xai", "direct": True}
        calls = []

        def plate(source, destination, *_args):
            Path(destination).write_bytes(Path(source).read_bytes())
            return destination

        def animate(prompt, image, lane, **options):
            self.assertEqual(lane["api_key"], config["api_key"])
            calls.append((prompt, image, options["aspect_ratio"]))
            path = os.path.join(options["output_dir"], options["file_name"] + ".mp4")
            os.makedirs(options["output_dir"], exist_ok=True)
            Path(path).write_bytes(b"direct-video" * 1000)
            return path

        with tempfile.TemporaryDirectory() as directory:
            keyframes = {}
            for kind in ("walk", "idle"):
                path = os.path.join(directory, f"{kind}.png")
                cv2.imwrite(path, np.full((180, 120, 3), 140, np.uint8))
                keyframes[kind] = path
            with mock.patch.object(motion, "_wide_walk_keyframe", side_effect=plate), \
                 mock.patch.object(motion, "_idle_loop_keyframe", side_effect=plate), \
                 mock.patch.object(
                    motion.media_gen, "generate_video_from_image_sync",
                    side_effect=animate):
                outputs = motion._generate_videos(
                    directory, config, public, keyframes,
                    {"walk": "walk naturally", "idle": "breathe subtly"},
                    lambda _message: None, kinds=("walk", "idle"))

        self.assertEqual(set(outputs), {"walk", "idle"})
        self.assertEqual({call[0] for call in calls},
                         {"walk naturally", "breathe subtly"})
        self.assertTrue(all(call[2] in {"16:9", "9:16"} for call in calls))


class _Response:
    def __init__(self, status_code, payload=None, text="", content=b"",
                 headers=None, url=""):
        self.status_code = status_code
        self._payload = payload or {}
        self.text = text
        self.content = content
        self.headers = headers or {}
        self.url = url

    def json(self):
        return self._payload


class _Client:
    response = None
    poll_response = None
    download_response = None
    request_json = None
    request_data = None
    request_files = None
    request_headers = None
    request_url = None
    post_url = None
    init_kwargs = None
    get_count = 0
    request_count = 0

    def __init__(self, *args, **kwargs):
        type(self).init_kwargs = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    async def post(self, _url, headers=None, json=None, data=None, files=None,
                   **_kwargs):
        type(self).request_headers = headers
        type(self).request_json = json
        type(self).request_data = data
        type(self).request_files = files
        type(self).request_url = _url
        type(self).post_url = _url
        return type(self).response

    async def get(self, _url, headers=None, **_kwargs):
        type(self).get_count += 1
        type(self).request_headers = headers
        type(self).request_url = _url
        if "/videos/" in _url and type(self).poll_response is not None:
            return type(self).poll_response
        return type(self).download_response or type(self).response

    async def request(self, _method, _url, headers=None):
        type(self).request_count += 1
        type(self).request_headers = headers
        return type(self).poll_response


class DirectRequestSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        _Client.response = None
        _Client.poll_response = None
        _Client.download_response = None
        _Client.request_json = None
        _Client.request_data = None
        _Client.request_files = None
        _Client.request_headers = None
        _Client.request_url = None
        _Client.post_url = None
        _Client.init_kwargs = None
        _Client.get_count = 0
        _Client.request_count = 0
        self._xai_auth_patch = mock.patch.object(
            media_gen, "_xai_api_auth",
            new=mock.AsyncMock(return_value=XAI_TEST_AUTH))
        self._xai_auth_patch.start()
        # These are public Platform API contract tests. Their route must not
        # depend on whichever shared OpenAI account mode the developer happens
        # to have selected in the running app beside the test process.
        self._openai_mode_patch = mock.patch.object(
            media_gen, "_openai_uses_chatgpt", return_value=False)
        self._openai_mode_patch.start()

    async def asyncTearDown(self):
        self._openai_mode_patch.stop()
        self._xai_auth_patch.stop()

    async def test_provider_rejection_redacts_the_key_and_prints_nothing(self):
        secret = "xai-private-test-key-123456789"
        helper = _ProviderHelper({})
        _Client.response = _Response(
            401, text=f"authorization=Bearer {secret}; api_key={secret}")
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            reference = os.path.join(directory, "reference.png")
            Path(reference).write_bytes(PNG_BYTES)
            with mock.patch.object(media_gen, "_providers", return_value=helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                with self.assertRaises(RuntimeError) as raised:
                    await media_gen.generate_image_edit(
                        "keep the exact identity", [reference],
                        {"provider": "xai", "model": "grok-imagine-image-quality",
                         "api_key": secret}, output_dir=directory,
                        file_name="result")
        self.assertNotIn(secret, str(raised.exception))
        self.assertNotIn(secret, output.getvalue())

    async def test_xai_multi_reference_edit_uses_the_reviewed_direct_shape(self):
        helper = _ProviderHelper({})
        _Client.response = _Response(200, payload={
            "data": [{"b64_json": base64.b64encode(JPEG_BYTES).decode(),
                      "mime_type": "image/jpeg"}],
        })
        with tempfile.TemporaryDirectory() as directory:
            references = []
            for index in range(2):
                path = os.path.join(directory, f"reference-{index}.png")
                Path(path).write_bytes(PNG_BYTES + bytes([index]))
                references.append(path)
            with mock.patch.object(media_gen, "_providers", return_value=helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                result = await media_gen.generate_image_edit(
                    "matched turnaround", references,
                    {"provider": "xai", "model": "grok-imagine-image-quality",
                     "api_key": "xai-private-test-key"},
                    aspect_ratio="3:4", output_dir=directory,
                    file_name="turnaround")
            self.assertTrue(os.path.isfile(result))
            self.assertEqual(len(_Client.request_json["images"]), 2)
            self.assertEqual(_Client.request_json["aspect_ratio"], "3:4")
            self.assertNotIn("n", _Client.request_json)

    async def test_avatar_video_is_direct_image_to_video_with_no_gateway(self):
        helper = _ProviderHelper({})
        _Client.response = _Response(200, payload={"request_id": "job-1"})
        _Client.poll_response = _Response(200, payload={
            "status": "done", "video": {"url": "https://vidgen.x.ai/clip.mp4"},
        })
        with tempfile.TemporaryDirectory() as directory:
            reference = os.path.join(directory, "idle.png")
            Path(reference).write_bytes(PNG_BYTES)
            finished = os.path.join(directory, "idle-source.mp4")
            with mock.patch.object(media_gen, "_providers", return_value=helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 mock.patch.object(media_gen.asyncio, "sleep", new=mock.AsyncMock()), \
                 mock.patch.object(
                     media_gen, "_download_xai_video",
                     new=mock.AsyncMock(return_value=finished)) as download:
                result = await media_gen.generate_video_from_image(
                    "one subtle breathing loop", reference,
                    {"provider": "xai", "model": "grok-imagine-video-1.5",
                     "api_key": "xai-private-test-key"},
                    aspect_ratio="9:16", duration=6, resolution="720p",
                    output_dir=directory, file_name="idle-source")
        self.assertEqual(result, finished)
        self.assertTrue(_Client.request_json["image"]["url"].startswith("data:image/"))
        self.assertEqual(_Client.request_json["aspect_ratio"], "9:16")
        self.assertEqual(_Client.request_json["duration"], 6)
        download.assert_awaited_once()


class CurrentImageProviderContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        _Client.response = None
        _Client.poll_response = None
        _Client.download_response = None
        _Client.request_json = None
        _Client.request_data = None
        _Client.request_files = None
        _Client.request_headers = None
        _Client.request_url = None
        _Client.post_url = None
        _Client.init_kwargs = None
        _Client.get_count = 0
        _Client.request_count = 0
        self.helper = _ProviderHelper({})
        self._xai_auth_patch = mock.patch.object(
            media_gen, "_xai_api_auth",
            new=mock.AsyncMock(return_value=XAI_TEST_AUTH))
        self._xai_auth_patch.start()
        # These are public Platform API contract tests. Their route must not
        # depend on the developer's currently selected shared account mode.
        self._openai_mode_patch = mock.patch.object(
            media_gen, "_openai_uses_chatgpt", return_value=False)
        self._openai_mode_patch.start()

    async def asyncTearDown(self):
        self._openai_mode_patch.stop()
        self._xai_auth_patch.stop()

    def _response(self, data=PNG_BYTES, mime="image/png"):
        return _Response(200, payload={
            "data": [{"b64_json": base64.b64encode(data).decode(),
                      "mime_type": mime}],
        })

    async def test_gpt_image_2_generation_uses_current_bounded_contract(self):
        _Client.response = self._response()
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
            result = await media_gen.generate_image(
                "A clean square character reference",
                {"provider": "openai", "model": "gpt-image-2",
                 "api_key": "openai-private-test-key", "size": "2048x1152",
                 "quality": "medium", "auth_method": "api_key"},
                output_dir=directory, file_name="openai-current")

        self.assertTrue(result.endswith("openai-current.png"))
        self.assertEqual(_Client.request_url,
                         "https://api.openai.com/v1/images/generations")
        self.assertEqual(_Client.request_json, {
            "model": "gpt-image-2",
            "prompt": "A clean square character reference",
            "n": 1,
            "size": "2048x1152",
            "quality": "medium",
            "background": "opaque",
            "output_format": "png",
        })
        self.assertEqual(_Client.init_kwargs["timeout"], 300)
        self.assertIs(_Client.init_kwargs["follow_redirects"], False)
        self.assertIs(_Client.init_kwargs["trust_env"], False)

    async def test_gpt_image_2_blank_saved_fields_use_current_defaults(self):
        _Client.response = self._response()
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
            await media_gen.generate_image(
                "Use the current model defaults",
                {"provider": "openai", "model": "", "api_key": "key"},
                output_dir=directory, file_name="openai-defaults")

        self.assertEqual(_Client.request_json["model"], "gpt-image-2")
        self.assertEqual(_Client.request_json["size"], "auto")
        self.assertEqual(_Client.request_json["quality"], "auto")

    async def test_xai_image_2_generation_uses_current_options(self):
        _Client.response = self._response(JPEG_BYTES, "image/jpeg")
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
            result = await media_gen.generate_image(
                "A full-body turnaround",
                {"provider": "xai", "model": "grok-imagine-image-2.0",
                 "api_key": "xai-private-test-key", "aspect_ratio": "3:4",
                 "resolution": "2k", "quality": "low",
                 "credential_type": "api_key"},
                output_dir=directory, file_name="xai-current")

        self.assertTrue(result.endswith("xai-current.jpg"))
        self.assertEqual(_Client.request_json, {
            "model": "grok-imagine-image-2.0",
            "prompt": "A full-body turnaround",
            "n": 1,
            "aspect_ratio": "3:4",
            "resolution": "2k",
            "quality": "low",
            "response_format": "b64_json",
        })

    async def test_xai_image_2_rejects_oversized_utf8_prompts_before_network(self):
        config = {
            "provider": "xai", "model": "grok-imagine-image-2.0",
            "api_key": "xai-private-test-key",
        }
        boundary = "x" * (8 * 1024)
        self.assertEqual(len(boundary.encode("utf-8")), 8 * 1024)
        media_gen._require_image_prompt_limit(
            boundary, "xai", "grok-imagine-image-2.0")

        # Multibyte text proves that the provider constraint is bytes rather
        # than Python characters.  No client or auth resolver is reached.
        too_large = "界" * 2731
        self.assertLess(len(too_large), 8 * 1024)
        self.assertGreater(len(too_large.encode("utf-8")), 8 * 1024)
        _Client.init_kwargs = None
        with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
             mock.patch.object(
                 media_gen, "_xai_api_auth",
                 new=mock.AsyncMock(side_effect=AssertionError("network auth"))), \
             self.assertRaisesRegex(RuntimeError, "8,192 UTF-8 bytes"):
            await media_gen.generate_image(too_large, config)
        self.assertIsNone(_Client.init_kwargs)

        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory, "reference.png")
            reference.write_bytes(PNG_BYTES)
            with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 mock.patch.object(
                     media_gen, "_xai_api_auth",
                     new=mock.AsyncMock(side_effect=AssertionError("network auth"))), \
                 self.assertRaisesRegex(RuntimeError, "8,192 UTF-8 bytes"):
                await media_gen.generate_image_edit(
                    too_large, [reference], config, output_dir=directory)
        self.assertIsNone(_Client.init_kwargs)

    async def test_gpt_image_2_edit_omits_input_fidelity(self):
        _Client.response = self._response()
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory, "reference.png")
            reference.write_bytes(PNG_BYTES)
            with mock.patch.object(
                    media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                result = await media_gen.generate_image_edit(
                    "Keep the exact face", [reference],
                    {"provider": "openai", "model": "gpt-image-2",
                     "api_key": "openai-private-test-key"},
                    aspect_ratio="1:1", quality="high",
                    output_dir=directory, file_name="gpt2-edit")

        self.assertTrue(result.endswith("gpt2-edit.png"))
        self.assertNotIn("input_fidelity", _Client.request_data)
        self.assertEqual(_Client.request_data["model"], "gpt-image-2")
        self.assertEqual(_Client.request_data["output_format"], "png")
        self.assertEqual(_Client.request_files[0][0], "image[]")
        self.assertEqual(_Client.request_files[0][1][2], "image/png")

    async def test_saved_gpt_image_1_edit_keeps_compatibility_fidelity(self):
        _Client.response = self._response()
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory, "reference.png")
            reference.write_bytes(PNG_BYTES)
            with mock.patch.object(
                    media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                await media_gen.generate_image_edit(
                    "Keep the exact face", [reference],
                    {"provider": "openai", "model": "gpt-image-1",
                     "api_key": "openai-private-test-key"},
                    output_dir=directory, file_name="gpt1-edit")
        self.assertEqual(_Client.request_data["input_fidelity"], "high")

    async def test_xai_current_edit_uses_json_data_urls_and_five_reference_cap(self):
        _Client.response = self._response(JPEG_BYTES, "image/jpeg")
        with tempfile.TemporaryDirectory() as directory:
            references = []
            for index in range(5):
                path = Path(directory, f"reference-{index}.png")
                path.write_bytes(PNG_BYTES + bytes([index]))
                references.append(path)
            config = {
                "provider": "xai", "model": "grok-imagine-image-2.0",
                "api_key": "xai-private-test-key", "resolution": "2k",
                "quality": "medium",
            }
            with mock.patch.object(
                    media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                await media_gen.generate_image_edit(
                    "Make a coherent turnaround", references, config,
                    aspect_ratio="3:4", output_dir=directory,
                    file_name="five-reference-edit")
            self.assertEqual(len(_Client.request_json["images"]), 5)
            self.assertTrue(all(
                item["type"] == "image_url"
                and item["url"].startswith("data:image/png;base64,")
                for item in _Client.request_json["images"]))
            self.assertEqual(_Client.request_json["resolution"], "2k")
            self.assertEqual(_Client.request_json["quality"], "medium")
            self.assertEqual(_Client.request_json["response_format"], "b64_json")

            extra = Path(directory, "reference-5.png")
            extra.write_bytes(PNG_BYTES)
            _Client.init_kwargs = None
            with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 self.assertRaisesRegex(RuntimeError, "at most 5"):
                await media_gen.generate_image_edit(
                    "Too many", references + [extra], config,
                    output_dir=directory)
            self.assertIsNone(_Client.init_kwargs)

            _Client.init_kwargs = None
            legacy = {**config, "model": "grok-imagine-image-quality"}
            legacy.pop("quality", None)
            with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 self.assertRaisesRegex(RuntimeError, "at most 3"):
                await media_gen.generate_image_edit(
                    "Legacy cap", references[:4], legacy,
                    output_dir=directory)
            self.assertIsNone(_Client.init_kwargs)

    async def test_image_auth_rejects_oauth_and_access_token_fields_before_network(self):
        cases = (
            ("openai", {"auth_method": "oauth2_user", "api_key": "not-used"}),
            ("openai", {"auth": {"selected_method": "oauth2"},
                        "api_key": "not-used"}),
            ("openai", {"credential_type": "access_token",
                        "api_key": "not-used"}),
            ("openai", {"access_token": "not-an-api-key"}),
            ("openai", {"bearer": "literal-secret", "api_key": "not-used"}),
            ("openai", {"metadata": {"bearer": "nested-secret"},
                        "api_key": "not-used"}),
            ("xai", {"auth_method": "oauth2_user", "api_key": "not-used"}),
            ("xai", {"metadata": {"refresh_token": "nested-secret"},
                     "api_key": "ignored-lane-key"}),
        )
        for provider, extra in cases:
            model = "gpt-image-2" if provider == "openai" \
                else "grok-imagine-image-2.0"
            config = {"provider": provider, "model": model, **extra}
            _Client.init_kwargs = None
            with self.subTest(provider=provider, extra=extra), \
                 mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 self.assertRaisesRegex(RuntimeError, "API key|API-key|globally"):
                await media_gen.generate_image("No network", config)
            self.assertIsNone(_Client.init_kwargs)

    async def test_unknown_models_and_invalid_options_fail_before_network(self):
        cases = (
            {"provider": "openai", "model": "gpt-image-2-preview",
             "api_key": "key"},
            {"provider": "openai", "model": "gpt-image-2", "api_key": "key",
             "size": "4000x4000"},
            {"provider": "xai", "model": "grok-imagine-image-2.0",
             "api_key": "key", "quality": "high"},
            {"provider": "xai", "model": "grok-imagine-image-quality",
             "api_key": "key", "quality": "medium"},
        )
        for config in cases:
            _Client.init_kwargs = None
            with self.subTest(config=config), \
                 mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                 self.assertRaises(RuntimeError):
                await media_gen.generate_image("No network", config)
            self.assertIsNone(_Client.init_kwargs)

    async def test_strict_image_response_envelopes_and_content_types(self):
        valid = base64.b64encode(PNG_BYTES).decode()
        bad_payloads = (
            ("openai", {"result": {"b64_json": valid}}),
            ("openai", {"data": [{"b64_json": valid}, {"b64_json": valid}]}),
            ("xai", {"data": [{"b64_json": valid,
                               "url": "https://imgen.x.ai/image.png"}]}),
            ("xai", {"data": [{"url": "https://evil.example/image.png"}]}),
        )
        with tempfile.TemporaryDirectory() as directory:
            for provider, payload in bad_payloads:
                with self.subTest(provider=provider, payload=payload), \
                     self.assertRaises(RuntimeError):
                    await media_gen._save_image_response(
                        provider, payload, directory, "bad")
            with self.assertRaisesRegex(RuntimeError, "mismatched"):
                await media_gen._save_image_response(
                    "openai", {"data": [{"b64_json": valid,
                                          "mime_type": "image/jpeg"}]},
                    directory, "bad-mime")

    async def test_xai_image_download_refuses_redirects(self):
        _Client.download_response = _Response(
            302, headers={"location": "https://evil.example/image.jpg"})
        with mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
             self.assertRaisesRegex(RuntimeError, "redirect"):
            await media_gen._download_xai_image(
                "https://imgen.x.ai/xai-imgen/test.jpeg", "image/jpeg")
        self.assertIs(_Client.init_kwargs["follow_redirects"], False)
        self.assertEqual(_Client.init_kwargs["timeout"], 120)

    async def test_xai_url_response_downloads_only_from_the_image_origin(self):
        _Client.download_response = _Response(
            200, content=JPEG_BYTES, headers={"content-type": "image/jpeg"})
        payload = {"data": [{
            "url": "https://imgen.x.ai/xai-imgen/current.jpeg",
            "mime_type": "image/jpeg",
        }]}
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
            result = await media_gen._save_image_response(
                "xai", payload, directory, "xai-url")

        self.assertTrue(result.endswith("xai-url.jpg"))
        self.assertEqual(
            _Client.request_url,
            "https://imgen.x.ai/xai-imgen/current.jpeg",
        )
        self.assertIs(_Client.init_kwargs["follow_redirects"], False)

    async def test_reference_type_is_sniffed_and_prompt_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory, "fake.png")
            fake.write_bytes(b"this is not an image")
            with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
                 self.assertRaisesRegex(RuntimeError, "PNG, JPEG, or WebP"):
                await media_gen.generate_image_edit(
                    "Edit it", [fake],
                    {"provider": "openai", "model": "gpt-image-2",
                     "api_key": "key"}, output_dir=directory)
        with self.assertRaisesRegex(RuntimeError, "32,000"):
            await media_gen.generate_image(
                "x" * 32_001,
                {"provider": "openai", "model": "gpt-image-2",
                 "api_key": "key"})


class XaiDualAuthMediaTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        _Client.response = None
        _Client.poll_response = None
        _Client.download_response = None
        _Client.request_json = None
        _Client.request_headers = None
        _Client.request_url = None
        _Client.post_url = None
        _Client.init_kwargs = None
        _Client.get_count = 0
        _Client.request_count = 0
        self.helper = _ProviderHelper({})

    @staticmethod
    def _auth(mode):
        return (
            "https://api.x.ai/v1",
            {"Authorization": f"Bearer {mode}-global-token"},
            f"{mode}-global-token",
            mode,
        )

    def _image_response(self):
        return _Response(200, payload={
            "data": [{"b64_json": base64.b64encode(PNG_BYTES).decode(),
                      "mime_type": "image/png"}],
        })

    async def test_image_generation_and_editing_share_each_explicit_mode(self):
        for mode in ("api_key", "oauth2"):
            _Client.response = self._image_response()
            with tempfile.TemporaryDirectory() as directory:
                reference = Path(directory, "reference.png")
                reference.write_bytes(PNG_BYTES)
                lane = {
                    "provider": "xai", "model": "grok-imagine-image-2.0",
                    # This stale lane value must never win over global mode.
                    "api_key": "ignored-lane-key",
                    "quality": "medium", "resolution": "1k",
                }
                with self.subTest(mode=mode, operation="generate"), \
                     mock.patch.object(media_gen, "_providers",
                                       return_value=self.helper), \
                     mock.patch.object(media_gen, "_xai_api_auth",
                        new=mock.AsyncMock(return_value=self._auth(mode))), \
                     mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                    await media_gen.generate_image(
                        "Generate", lane, output_dir=directory,
                        file_name=f"{mode}-generate")
                self.assertEqual(
                    "https://api.x.ai/v1/images/generations", _Client.request_url)
                self.assertEqual(
                    f"Bearer {mode}-global-token",
                    _Client.request_headers["Authorization"])
                self.assertNotIn("ignored-lane-key", json.dumps(
                    {"headers": _Client.request_headers,
                     "body": _Client.request_json}))
                self.assertIs(_Client.init_kwargs["follow_redirects"], False)
                self.assertIs(_Client.init_kwargs["trust_env"], False)

                _Client.response = self._image_response()
                with self.subTest(mode=mode, operation="edit"), \
                     mock.patch.object(media_gen, "_providers",
                                       return_value=self.helper), \
                     mock.patch.object(media_gen, "_xai_api_auth",
                        new=mock.AsyncMock(return_value=self._auth(mode))), \
                     mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
                    await media_gen.generate_image_edit(
                        "Edit", [reference], lane, output_dir=directory,
                        file_name=f"{mode}-edit")
                self.assertEqual(
                    "https://api.x.ai/v1/images/edits", _Client.request_url)
                self.assertEqual(
                    f"Bearer {mode}-global-token",
                    _Client.request_headers["Authorization"])

    async def test_video_generation_and_editing_share_each_explicit_mode(self):
        for mode in ("api_key", "oauth2"):
            with tempfile.TemporaryDirectory() as directory:
                video = Path(directory, "source.mp4")
                video.write_bytes(mock_mp4(5.0))
                lane = {"provider": "xai",
                        "model": "grok-imagine-video",
                        "api_key": "ignored-lane-key"}
                for operation in ("generations", "edits"):
                    _Client.response = _Response(
                        200, payload={"request_id": f"job-{mode}-{operation}"})
                    _Client.poll_response = _Response(200, payload={
                        "status": "done",
                        "video": {"url": "https://vidgen.x.ai/final.mp4"},
                    })
                    output = os.path.join(directory, f"{mode}-{operation}.mp4")
                    with self.subTest(mode=mode, operation=operation), \
                         mock.patch.object(media_gen, "_providers",
                                           return_value=self.helper), \
                         mock.patch.object(media_gen, "_xai_api_auth",
                            new=mock.AsyncMock(return_value=self._auth(mode))), \
                         mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                         mock.patch.object(media_gen.asyncio, "sleep",
                                           new=mock.AsyncMock()), \
                         mock.patch.object(
                             media_gen, "_download_xai_video",
                             new=mock.AsyncMock(return_value=output)) as download:
                        if operation == "generations":
                            result = await media_gen.generate_video(
                                "Generate motion", lane, output_dir=directory)
                        else:
                            result = await media_gen.generate_video_edit(
                                "Edit motion", video, lane, output_dir=directory)
                    self.assertEqual(output, result)
                    self.assertEqual(
                        f"https://api.x.ai/v1/videos/{operation}",
                        _Client.post_url)
                    self.assertEqual(
                        f"Bearer {mode}-global-token",
                        _Client.request_headers["Authorization"])
                    self.assertIs(_Client.init_kwargs["follow_redirects"], False)
                    self.assertIs(_Client.init_kwargs["trust_env"], False)
                    if operation == "edits":
                        self.assertTrue(
                            _Client.request_json["video"]["url"].startswith(
                                "data:video/mp4;base64,"))
                    download.assert_awaited_once_with(
                        "https://vidgen.x.ai/final.mp4", directory, None)

    async def test_video_edit_rejects_non_mp4_and_over_8_7_seconds_pre_network(self):
        with tempfile.TemporaryDirectory() as directory:
            webm = Path(directory, "source.webm")
            webm.write_bytes(b"\x1aE\xdf\xa3" + b"video" * 100)
            long_mp4 = Path(directory, "long.mp4")
            long_mp4.write_bytes(mock_mp4(8.71))
            lane = {"provider": "xai", "model": "grok-imagine-video"}
            for path, message in ((webm, "MP4"), (long_mp4, "8.7")):
                _Client.init_kwargs = None
                with self.subTest(path=path.name), \
                     mock.patch.object(media_gen, "_providers",
                                       return_value=self.helper), \
                     mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
                     self.assertRaisesRegex(RuntimeError, message):
                    await media_gen.generate_video_edit("Edit", path, lane)
                self.assertIsNone(_Client.init_kwargs)

    async def test_video_1_5_is_image_to_video_only_pre_network(self):
        lane = {"provider": "xai", "model": "grok-imagine-video-1.5"}
        resolver = mock.AsyncMock()
        with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen, "_xai_api_auth", new=resolver), \
             mock.patch.object(media_gen.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "text-to-video"):
            await media_gen.generate_video("Generate", lane)
        resolver.assert_not_awaited()
        client.assert_not_called()

        with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen, "_xai_api_auth", new=resolver), \
             mock.patch.object(media_gen.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "video-editing"):
            await media_gen.generate_video_edit("Edit", "unused.mp4", lane)
        resolver.assert_not_awaited()
        client.assert_not_called()

    async def test_media_stream_reader_caps_bytes_and_xai_auth_error_is_neutral(self):
        class Upstream:
            status_code = 200
            headers = {}

            @property
            def content(self):
                raise RuntimeError("stream was not buffered")

            async def aiter_bytes(self):
                yield b"abc"
                yield b"def"

        class StreamContext:
            async def __aenter__(self):
                return Upstream()

            async def __aexit__(self, *_args):
                return False

        class StreamClient:
            def stream(self, method, url, **kwargs):
                return StreamContext()

        with self.assertRaisesRegex(RuntimeError, "oversized"):
            await media_gen._bounded_media_request(
                StreamClient(), "GET", "https://vidgen.x.ai/final.mp4",
                provider="xai", max_bytes=5)

        error = str(media_gen._http_failure("xai", _Response(401)))
        self.assertIn("authentication was rejected", error)
        self.assertNotIn("API key", error)

    async def test_media_stream_reader_drops_consumed_content_encoding_headers(self):
        decoded = b'{"ok":true}'

        class Upstream:
            status_code = 200
            headers = {
                "content-encoding": "gzip",
                "content-length": "100",
                "transfer-encoding": "chunked",
                "x-provider-request": "retained",
            }

            async def aiter_bytes(self):
                # httpx has already decompressed this payload.
                yield decoded

        class StreamContext:
            async def __aenter__(self):
                return Upstream()

            async def __aexit__(self, *_args):
                return False

        class StreamClient:
            def stream(self, method, url, **kwargs):
                return StreamContext()

        response = await media_gen._bounded_media_request(
            StreamClient(), "POST", "https://api.x.ai/v1/images/edits",
            provider="xai", max_bytes=1024)

        self.assertEqual({"ok": True}, response.json())
        self.assertNotIn("content-encoding", response.headers)
        self.assertNotIn("transfer-encoding", response.headers)
        self.assertEqual(str(len(decoded)), response.headers["content-length"])
        self.assertEqual("retained", response.headers["x-provider-request"])

    async def test_xai_never_falls_back_to_a_lane_key(self):
        resolver = mock.AsyncMock(side_effect=RuntimeError("global mode disconnected"))
        with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen, "_xai_api_auth", new=resolver), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
             self.assertRaisesRegex(RuntimeError, "global mode disconnected"):
            await media_gen.generate_image(
                "No fallback", {"provider": "xai",
                                "model": "grok-imagine-image-2.0",
                                "api_key": "lane-key-must-not-run"})
        resolver.assert_awaited_once()
        self.assertIsNone(_Client.init_kwargs)

    async def test_xai_video_download_rejects_unapproved_origins_and_redirects(self):
        with mock.patch.object(media_gen.httpx, "AsyncClient") as client, \
             self.assertRaisesRegex(RuntimeError, "unapproved"):
            await media_gen._download_xai_video(
                "https://attacker.example/stolen.mp4")
        client.assert_not_called()

        _Client.download_response = _Response(
            302, headers={"location": "https://attacker.example/stolen.mp4"})
        with mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
             self.assertRaisesRegex(RuntimeError, "redirect"):
            await media_gen._download_xai_video(
                "https://vidgen.x.ai/final.mp4")
        self.assertIs(_Client.init_kwargs["follow_redirects"], False)
        self.assertIs(_Client.init_kwargs["trust_env"], False)

    async def test_bfl_polling_never_sends_key_to_unapproved_origin(self):
        _Client.response = _Response(200, payload={
            "polling_url": "https://api.bfl.ai.attacker.example/status/job",
        })
        with mock.patch.object(media_gen, "_providers", return_value=self.helper), \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client), \
             self.assertRaisesRegex(RuntimeError, "unsafe polling"):
            await media_gen.generate_image(
                "Generate", {"provider": "bfl", "model": "flux-pro-1.1",
                             "api_key": "bfl-private-key"})
        self.assertEqual(0, _Client.get_count)
        self.assertEqual(
            "https://api.bfl.ai/status/job",
            media_gen._bfl_poll_address("https://api.bfl.ai/status/job"))
        self.assertEqual(
            "https://api.eu.bfl.ai/status/job",
            media_gen._bfl_poll_address("https://api.eu.bfl.ai/status/job"))
        self.assertEqual(
            "https://api.us.bfl.ai/status/job",
            media_gen._bfl_poll_address("https://api.us.bfl.ai/status/job"))
        for unsafe in (
                "https://user@api.bfl.ai/status/job",
                "https://api.bfl.ai:444/status/job",
                "http://api.bfl.ai/status/job"):
            with self.subTest(unsafe=unsafe), \
                 self.assertRaisesRegex(RuntimeError, "unsafe polling"):
                media_gen._bfl_poll_address(unsafe)
        with self.assertRaisesRegex(RuntimeError, "unapproved"):
            await media_gen._download_bfl_image(
                "https://delivery.us-east-1.bfl.ai.attacker.example/image.jpg")

        _Client.download_response = _Response(
            200, content=JPEG_BYTES, headers={"content-type": "image/jpeg"})
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(media_gen.httpx, "AsyncClient", _Client):
            result = await media_gen._download_bfl_image(
                "https://delivery.us-east-1.bfl.ai/signed/image.jpg",
                directory, "bfl-safe")
        self.assertTrue(result.endswith("bfl-safe.jpg"))
        self.assertEqual(
            {"User-Agent": "OpenClam-Studio/1.0"}, _Client.request_headers)
        self.assertNotIn("x-key", _Client.request_headers)
        self.assertIs(_Client.init_kwargs["follow_redirects"], False)
        self.assertIs(_Client.init_kwargs["trust_env"], False)


if __name__ == "__main__":
    unittest.main()
