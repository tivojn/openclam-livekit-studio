"""Exact reviewed-fixture exceptions must not become source-path exemptions."""

import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "public_release_audit", ROOT / "scripts" / "public-release-audit.py"
)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)

FIXTURE_PATH = Path("ios/OpenClamLiveKit/Tests/OpenClamAvatarPackageTests.swift")
PREVIOUS_HASH = "2cf53f32d71c5ac5928dd871711e0663aaa132bbdab72d8e67d0c7d5005a6108"
CURRENT_HASH = "0e94993bbb8cea1bbba6d0f726fdeebf13717f16c168bc5d3785fda002e12c9d"
GOLDEN_HASH = "79c21dedb5c93b126e04b38df09e41aabd8375d7048cbcc3e5be39186f5545a3"


class ReviewedEntropyFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / FIXTURE_PATH).read_bytes()

    def test_only_two_exact_reviewed_revisions_are_pinned(self):
        self.assertEqual(
            AUDIT.REVIEWED_HIGH_ENTROPY_TEXT_HASHES,
            {FIXTURE_PATH: frozenset({PREVIOUS_HASH, CURRENT_HASH})},
        )
        self.assertEqual(hashlib.sha256(self.source).hexdigest(), CURRENT_HASH)

    def test_current_reviewed_source_passes_current_and_history_scans(self):
        self.assertFalse(AUDIT.high_entropy_finding(FIXTURE_PATH, self.source))
        self.assertEqual(AUDIT.audit_bytes(FIXTURE_PATH, self.source), [])
        self.assertEqual(AUDIT.audit_history_bytes(FIXTURE_PATH, self.source), [])

    def test_both_pins_use_exact_digest_membership(self):
        # Historical source need not be available in a shallow CI checkout.
        # Exercise both pins with a mocked digest; the real historical fixture
        # comparison is part of the explicit review that established the pins.
        raw = base64.urlsafe_b64encode(
            hashlib.sha512(b"deterministic non-secret audit test fixture").digest()
        )
        self.assertTrue(AUDIT.high_entropy_finding(FIXTURE_PATH, raw))
        for digest in (PREVIOUS_HASH, CURRENT_HASH):
            with self.subTest(digest=digest):
                result = mock.Mock()
                result.hexdigest.return_value = digest
                with mock.patch.object(AUDIT.hashlib, "sha256", return_value=result):
                    self.assertFalse(AUDIT.high_entropy_finding(FIXTURE_PATH, raw))

    def test_surrounding_source_mutation_is_not_reviewed(self):
        changed = self.source + b"\n// unreviewed synthetic mutation\n"
        self.assertTrue(AUDIT.high_entropy_finding(FIXTURE_PATH, changed))
        expected = [f"unreviewed high-entropy literal: {FIXTURE_PATH}"]
        self.assertEqual(AUDIT.audit_bytes(FIXTURE_PATH, changed), expected)
        self.assertEqual(AUDIT.audit_history_bytes(FIXTURE_PATH, changed), expected)

    def test_fixture_mutation_is_not_reviewed(self):
        pattern = rb'(private static let pythonExporterV4GoldenBase64 = """\s*)(.)'
        match = re.search(pattern, self.source, re.S)
        self.assertIsNotNone(match)
        offset = match.start(2)
        replacement = b"A" if self.source[offset:offset + 1] != b"A" else b"B"
        changed = self.source[:offset] + replacement + self.source[offset + 1:]
        self.assertTrue(AUDIT.high_entropy_finding(FIXTURE_PATH, changed))
        self.assertIn(
            f"unreviewed high-entropy literal: {FIXTURE_PATH}",
            AUDIT.audit_bytes(FIXTURE_PATH, changed),
        )

    def test_reviewed_source_does_not_exempt_other_paths(self):
        other = FIXTURE_PATH.with_name("UnreviewedPackageTests.swift")
        self.assertTrue(AUDIT.high_entropy_finding(other, self.source))
        self.assertEqual(
            AUDIT.audit_bytes(other, self.source),
            [f"unreviewed high-entropy literal: {other}"],
        )

    def test_credential_patterns_still_scan_reviewed_entropy_bytes(self):
        # Construct an unmistakably synthetic AWS-pattern value rather than
        # putting a credential-shaped literal in this test's public source.
        raw = b"// synthetic only: " + b"AKIA" + b"Z" * 16 + b"\n"
        digest = hashlib.sha256(raw).hexdigest()
        with mock.patch.dict(
            AUDIT.REVIEWED_HIGH_ENTROPY_TEXT_HASHES,
            {FIXTURE_PATH: frozenset({digest})},
        ):
            self.assertFalse(AUDIT.high_entropy_finding(FIXTURE_PATH, raw))
            expected = [f"AWS access key: {FIXTURE_PATH}"]
            self.assertEqual(AUDIT.audit_bytes(FIXTURE_PATH, raw), expected)
            self.assertEqual(AUDIT.audit_history_bytes(FIXTURE_PATH, raw), expected)

    def test_decoded_fixture_is_the_reviewed_synthetic_avatar_archive(self):
        pattern = rb'private static let pythonExporterV4GoldenBase64 = """\s*(.*?)\s*"""'
        match = re.search(pattern, self.source, re.S)
        self.assertIsNotNone(match)
        encoded = b"".join(match.group(1).split())
        decoded = base64.b64decode(encoded, validate=True)
        self.assertEqual(len(encoded), 20172)
        self.assertEqual(len(decoded), 15128)
        self.assertEqual(hashlib.sha256(decoded).hexdigest(), GOLDEN_HASH)
        with zipfile.ZipFile(io.BytesIO(decoded)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(len(archive.namelist()), 33)
            self.assertTrue(all(
                name == "manifest.json" or (
                    name.startswith("assets/") and name.endswith((".jpg", ".png"))
                )
                for name in archive.namelist()
            ))
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["format"], "openclam-avatar")
            self.assertEqual(manifest["id"], "python-v4-guide")
            self.assertEqual(manifest["displayName"], "Python v4 Guide")
            self.assertEqual(manifest["version"], 4)
            self.assertEqual(manifest["variant"], "ios-light")

    def test_regression_source_itself_passes_the_public_byte_audit(self):
        path = Path(__file__).resolve()
        self.assertEqual(AUDIT.audit_bytes(path.relative_to(ROOT), path.read_bytes()), [])


if __name__ == "__main__":
    unittest.main()
