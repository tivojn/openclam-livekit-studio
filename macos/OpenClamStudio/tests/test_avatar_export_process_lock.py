"""A live face-build lease is neither an avatar asset nor safe to unlink."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path

from server import avatar_package as package


class AvatarExportProcessLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.avatar = self.root / "avatar"
        self.avatar.mkdir()
        (self.avatar / "manifest.json").write_text(json.dumps({
            "slug": "sarah", "name": "Sarah", "status": "ready",
        }))

    def test_empty_root_process_lock_is_not_exported_or_unlinked(self):
        lock = self.avatar / ".face-build.lock"
        lock.touch(mode=0o600)
        before = lock.stat()
        original_manifest = (self.avatar / "manifest.json").read_bytes()
        archive_path = self.root / "sarah.avtr"

        manifest = package.export_macos_full("sarah", self.avatar, archive_path)

        self.assertEqual(lock.read_bytes(), b"")
        self.assertEqual(lock.stat().st_ino, before.st_ino)
        self.assertEqual(lock.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual((self.avatar / "manifest.json").read_bytes(), original_manifest)
        self.assertNotIn("authoring/.face-build.lock", {
            row["path"] for row in manifest["files"]
        })
        with zipfile.ZipFile(archive_path) as archive:
            self.assertNotIn("authoring/.face-build.lock", archive.namelist())

    def test_nonempty_root_lock_remains_rejected(self):
        (self.avatar / ".face-build.lock").write_text("not a process lease")
        with self.assertRaisesRegex(package.AvatarPackageError, "unsafe authoring path"):
            package._authoring_files(self.avatar)

    def test_unknown_root_hidden_file_is_not_exempted(self):
        (self.avatar / ".face-build.other").touch()
        with self.assertRaisesRegex(package.AvatarPackageError, "unsafe authoring path"):
            package._authoring_files(self.avatar)

    def test_nested_lock_is_not_pruned(self):
        nested = self.avatar / "body" / ".face-build.lock"
        nested.parent.mkdir()
        nested.touch()
        with self.assertRaisesRegex(package.AvatarPackageError, "invalid authoring file size"):
            package._authoring_files(self.avatar)

    def test_symlink_lock_remains_rejected(self):
        target = self.root / "outside.lock"
        target.touch()
        (self.avatar / ".face-build.lock").symlink_to(target)
        with self.assertRaisesRegex(package.AvatarPackageError, "unsafe authoring file"):
            package._authoring_files(self.avatar)

    def test_hardlinked_lock_remains_rejected(self):
        target = self.root / "outside.lock"
        target.touch()
        os.link(target, self.avatar / ".face-build.lock")
        with self.assertRaisesRegex(package.AvatarPackageError, "unsafe authoring file"):
            package._authoring_files(self.avatar)

    def test_no_lock_keeps_archive_byte_identical(self):
        baseline = self.root / "before.avtr"
        with_lock = self.root / "after.avtr"
        package.export_macos_full("sarah", self.avatar, baseline)
        (self.avatar / ".face-build.lock").touch(mode=0o600)
        package.export_macos_full("sarah", self.avatar, with_lock)
        self.assertEqual(baseline.read_bytes(), with_lock.read_bytes())


if __name__ == "__main__":
    unittest.main()
