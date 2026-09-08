"""Optional motion publishing preserves GLB bytes and rejects unsafe paths."""
import json
import os
from pathlib import Path
import tempfile
import unittest

from server import avatar3d


class MotionPublishTests(unittest.TestCase):
    def test_publishes_only_declared_local_clips(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'motions').mkdir()
            (root / 'motions/wave.json').write_text('{"version":1}')
            (root / 'motions/private.fbx').write_bytes(b'not a runtime file')
            library = root / 'motions/library.json'
            library.write_text(json.dumps({'version': 1, 'clips': [{'id': 'wave', 'file': 'wave.json'}]}))
            (root / 'staged').mkdir()
            revision = avatar3d.publish_motion_library(str(root), str(root / 'staged'))
            self.assertEqual(revision, avatar3d.file_revision(library))
            self.assertEqual(sorted(p.name for p in (root / 'staged/motions').iterdir()), ['library.json', 'wave.json'])

    def test_rejects_traversal_and_symlinks(self):
        for file in ('../secret.json', '/secret.json', 'linked.json'):
            with self.subTest(file=file), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / 'motions').mkdir()
                (root / 'secret.json').write_text('private')
                os.symlink(root / 'secret.json', root / 'motions/linked.json')
                (root / 'motions/library.json').write_text(json.dumps({'version': 1, 'clips': [{'id': 'wave', 'file': file}]}))
                (root / 'staged').mkdir()
                with self.assertRaises(ValueError):
                    avatar3d.publish_motion_library(str(root), str(root / 'staged'))

    def test_avatar_without_motions_keeps_legacy_manifest(self):
        self.assertNotIn('motion_library', avatar3d.runtime_manifest({'slug': 'plain'}))
        self.assertEqual(avatar3d.runtime_manifest({'slug': 'tia', 'motion_library': True})['motion_library'], 'assets/motions/library.json')
