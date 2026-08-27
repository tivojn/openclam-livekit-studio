"""HTTP route wiring for the two non-synchronizing AVTR v2 profiles."""
from __future__ import annotations

import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from tests.test_standalone_openclam import route_test_application


class _Registry:
    AVATARS = "/private/openclam-test-avatars"

    @staticmethod
    def read_manifest(slug):
        return {"slug": slug, "name": "Captain Ayer", "status": "ready"}

    @staticmethod
    def adir(slug):
        return f"/private/openclam-test-avatars/{slug}"


class _Archive:
    def __init__(self, data: bytes, filename: str = "avatar.avtr"):
        self.filename = filename
        self._file = io.BytesIO(data)
        self.closed = False

    async def read(self, size: int):
        return self._file.read(size)

    async def close(self):
        self.closed = True


class AvatarRouteV2Tests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = route_test_application()

    async def test_mac_export_uses_only_the_full_authoring_profile(self):
        written = {}

        def export(identifier, directory, destination):
            written.update(identifier=identifier, directory=directory)
            with open(destination, "wb") as output:
                output.write(b"mac-full")

        with patch.object(self.application, "reg", return_value=_Registry()), \
             patch.object(self.application, "_avatar_is_busy", return_value=False), \
             patch.object(self.application.AVTR, "export_macos_full", side_effect=export), \
             patch.object(self.application.AVTR, "export_ios_light") as ios_export:
            response = await self.application.api_avatar_export(
                "captain-ayer", self.application.AVTR.MAC_VARIANT
            )
        self.assertEqual(written, {
            "identifier": "captain-ayer",
            "directory": "/private/openclam-test-avatars/captain-ayer",
        })
        ios_export.assert_not_called()
        self.assertEqual(response.media_type, "application/vnd.openclam.avatar+zip")
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(Path(response.path).read_bytes(), b"mac-full")
        await response.background()
        self.assertFalse(os.path.exists(response.path))

    async def test_ios_export_publishes_runtime_then_uses_light_profile(self):
        calls = {}

        def export(
            identifier,
            name,
            authoring,
            runtime,
            destination,
            *,
            require_full_expression=False,
        ):
            calls.update(identifier=identifier, name=name, authoring=authoring,
                         runtime=runtime,
                         require_full_expression=require_full_expression)
            with open(destination, "wb") as output:
                output.write(b"ios-light")

        with patch.object(self.application, "reg", return_value=_Registry()), \
             patch.object(self.application, "_avatar_is_busy", return_value=False), \
             patch.object(self.application, "ensure_runtime",
                          return_value="/private/runtime") as ensure, \
             patch.object(self.application.AVTR, "export_ios_light", side_effect=export), \
             patch.object(self.application.AVTR, "export_macos_full") as mac_export:
            response = await self.application.api_avatar_export(
                "captain-ayer", self.application.AVTR.IOS_VARIANT
            )
        ensure.assert_called_once_with("captain-ayer")
        mac_export.assert_not_called()
        self.assertEqual(calls, {
            "identifier": "captain-ayer",
            "name": "Captain Ayer",
            "authoring": "/private/openclam-test-avatars/captain-ayer",
            "runtime": "/private/runtime",
            "require_full_expression": True,
        })
        await response.background()

    async def test_import_privately_stages_and_accepts_only_mac_full(self):
        archive = _Archive(b"strict-mac-package")
        observed = {}

        def install(path, root):
            observed["data"] = Path(path).read_bytes()
            observed["root"] = root
            return {"slug": "captain-ayer-2", "variant": "macos-full"}

        with patch.object(self.application, "reg", return_value=_Registry()), \
             patch.object(self.application.AVTR, "import_macos_full", side_effect=install):
            response = await self.application.api_avatar_import(archive)
        self.assertTrue(archive.closed)
        self.assertEqual(observed, {
            "data": b"strict-mac-package",
            "root": "/private/openclam-test-avatars",
        })
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertIn(b'"variant":"macos-full"', response.body)

    async def test_import_rejects_wrong_extension_and_oversize_before_install(self):
        wrong = _Archive(b"payload", "avatar.zip")
        with self.assertRaises(self.application.HTTPException) as caught:
            await self.application.api_avatar_import(wrong)
        self.assertEqual(caught.exception.status_code, 422)

        oversized = _Archive(b"four", "avatar.avtr")
        with patch.object(self.application.AVTR, "MAX_MAC_ARCHIVE_BYTES", 3), \
             patch.object(self.application.AVTR, "import_macos_full") as install:
            with self.assertRaises(self.application.HTTPException) as caught:
                await self.application.api_avatar_import(oversized)
        self.assertEqual(caught.exception.status_code, 422)
        self.assertTrue(oversized.closed)
        install.assert_not_called()


if __name__ == "__main__":
    unittest.main()
