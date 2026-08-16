"""Security.framework credential persistence and exposure regressions."""

import contextlib
import ctypes
import hashlib
import io
import os
from pathlib import Path
import secrets
import subprocess
import sys
import unittest
import uuid
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))

import credentials


class _FakeCore:
    def __init__(self, raw=b"value", type_id=7, length=None, pointer=True):
        self.raw = raw
        self.type_id = type_id
        self.length = len(raw) if length is None else length
        self.pointer = pointer
        self.released = []
        self.buffer = (ctypes.c_ubyte * max(1, len(raw)))(*raw)

    def CFRelease(self, value):
        self.released.append(value.value if isinstance(value, ctypes.c_void_p) else value)

    def CFGetTypeID(self, _value):
        return self.type_id

    def CFDataGetTypeID(self):
        return 7

    def CFDataGetLength(self, _value):
        return self.length

    def CFDataGetBytePtr(self, _value):
        if not self.pointer:
            return ctypes.POINTER(ctypes.c_ubyte)()
        return ctypes.cast(self.buffer, ctypes.POINTER(ctypes.c_ubyte))


class _FakeSecurity:
    def __init__(self, copy_status=0, result=0x1234, updates=None, adds=None, delete=0):
        self.copy_status = copy_status
        self.result = result
        self.updates = list(updates or [])
        self.adds = list(adds or [])
        self.delete = delete
        self.update_calls = 0
        self.add_calls = 0

    def SecItemCopyMatching(self, _query, result):
        result._obj.value = self.result
        return self.copy_status

    def SecItemUpdate(self, _query, _updates):
        self.update_calls += 1
        return self.updates.pop(0)

    def SecItemAdd(self, _attributes, _result):
        self.add_calls += 1
        return self.adds.pop(0)

    def SecItemDelete(self, _query):
        return self.delete


def _fake_binding(core, security):
    binding = credentials._MacKeychain.__new__(credentials._MacKeychain)
    binding._core = core
    binding._security = security
    for value, name in enumerate((
        "_class", "_generic_password", "_service", "_account", "_value_data",
        "_return_data", "_match_limit", "_match_limit_one", "_true",
        "_authentication_ui", "_authentication_ui_fail",
    ), start=1):
        setattr(binding, name, value)

    @contextlib.contextmanager
    def dictionary(_pairs):
        yield object()

    binding._dictionary = dictionary
    return binding


class SecurityBindingFailureTests(unittest.TestCase):
    def test_delete_uses_only_apple_supported_item_attributes(self):
        binding = _fake_binding(_FakeCore(), _FakeSecurity(delete=0))
        captured = []

        @contextlib.contextmanager
        def dictionary(pairs):
            captured.append(list(pairs))
            yield object()

        binding._dictionary = dictionary
        binding.clear("openclam-v2:qa")

        keys = {key for key, _value in captured[0]}
        self.assertEqual(
            keys, {binding._class, binding._service, binding._account}
        )
        self.assertNotIn(binding._authentication_ui, keys)

    def test_copy_result_is_released_on_every_error_path(self):
        cases = [
            (_FakeCore(), _FakeSecurity(copy_status=-50), RuntimeError),
            (_FakeCore(type_id=8), _FakeSecurity(), RuntimeError),
            (_FakeCore(raw=b"\xff"), _FakeSecurity(), RuntimeError),
            (_FakeCore(length=credentials._MAX_SECRET_BYTES + 1), _FakeSecurity(), RuntimeError),
            (_FakeCore(raw=b"x", pointer=False), _FakeSecurity(), RuntimeError),
        ]
        for core, security, error in cases:
            with self.subTest(status=security.copy_status, type_id=core.type_id), \
                 self.assertRaises(error):
                _fake_binding(core, security).get("openclam-v2:qa")
            self.assertEqual(core.released, [security.result])

        core = _FakeCore()
        missing = _FakeSecurity(
            copy_status=credentials._ERR_SEC_ITEM_NOT_FOUND, result=0x4321
        )
        self.assertEqual(_fake_binding(core, missing).get("openclam-v2:qa"), "")
        self.assertEqual(core.released, [0x4321])

    def test_duplicate_add_race_retries_update_without_delete(self):
        security = _FakeSecurity(
            updates=[credentials._ERR_SEC_ITEM_NOT_FOUND, credentials._ERR_SEC_SUCCESS],
            adds=[credentials._ERR_SEC_DUPLICATE_ITEM],
        )
        binding = _fake_binding(_FakeCore(), security)
        binding.put("openclam-v2:qa", "synthetic-value")
        self.assertEqual(security.update_calls, 2)
        self.assertEqual(security.add_calls, 1)

    def test_failures_are_sanitized_and_never_downgraded_to_missing(self):
        account = "openclam-v2:private-account"
        value = "private-synthetic-value"
        security = _FakeSecurity(updates=[-25308])
        with self.assertRaises(RuntimeError) as raised:
            _fake_binding(_FakeCore(), security).put(account, value)
        visible = str(raised.exception)
        self.assertNotIn(account, visible)
        self.assertNotIn(value, visible)
        self.assertIn("OSStatus -25308", visible)

        security = _FakeSecurity(delete=-25308)
        with self.assertRaises(RuntimeError) as raised:
            _fake_binding(_FakeCore(), security).clear(account)
        self.assertNotIn(account, str(raised.exception))

    def test_value_and_account_bounds_fail_before_framework_calls(self):
        security = _FakeSecurity(updates=[0])
        binding = _fake_binding(_FakeCore(), security)
        with self.assertRaisesRegex(ValueError, "invalid length"):
            binding.put("openclam-v2:qa", "x" * (credentials._MAX_SECRET_BYTES + 1))
        self.assertEqual(security.update_calls, 0)
        self.assertEqual(
            credentials._storage_account("keys.openai"), "openclam-v2:keys.openai"
        )


class DirectKeychainTests(unittest.TestCase):
    def setUp(self):
        self.original_file = credentials._TEST_VAULT_FILE
        self.original_test_backend = credentials._TEST_NATIVE_KEYCHAIN
        self.original_backend = credentials._NATIVE_KEYCHAIN
        credentials._TEST_VAULT_FILE = None
        credentials._TEST_NATIVE_KEYCHAIN = None
        credentials._memo.clear()

    def tearDown(self):
        credentials._memo.clear()
        credentials._TEST_VAULT_FILE = self.original_file
        credentials._TEST_NATIVE_KEYCHAIN = self.original_test_backend
        credentials._NATIVE_KEYCHAIN = self.original_backend

    def test_source_has_no_command_or_argv_credential_path(self):
        source = Path(credentials.__file__).read_text(encoding="utf-8")
        for forbidden in (
            "import subprocess",
            "subprocess.run",
            "SECURITY_TOOL",
        ):
            self.assertNotIn(forbidden, source)
        self.assertNotRegex(source, r'''["']/usr/bin/security["']''')
        for required in (
            "Security.framework",
            "CFDataCreate",
            "SecItemCopyMatching",
            "SecItemAdd",
            "SecItemUpdate",
            "SecItemDelete",
            "kSecUseAuthenticationUIFail",
            'STORAGE_ACCOUNT_PREFIX = "openclam-v2:"',
        ):
            self.assertIn(required, source)

    @unittest.skipUnless(sys.platform == "darwin", "requires the macOS Keychain")
    def test_real_keychain_persists_after_memo_reset_without_process_exposure(self):
        account = "qa.security-framework." + uuid.uuid4().hex
        first = "qa-" + secrets.token_urlsafe(40) + "\nUnicode-密钥\0tail"
        second = "qa-" + secrets.token_urlsafe(48)
        output = io.StringIO()

        def subprocess_forbidden(*_args, **_kwargs):
            raise AssertionError("credential access attempted to start a process")

        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                 patch.object(subprocess, "Popen", side_effect=subprocess_forbidden), \
                 patch.object(subprocess, "run", side_effect=subprocess_forbidden), \
                 patch.object(subprocess, "call", side_effect=subprocess_forbidden), \
                 patch.object(subprocess, "check_call", side_effect=subprocess_forbidden), \
                 patch.object(subprocess, "check_output", side_effect=subprocess_forbidden):
                credentials.clear(account)
                credentials.put(account, first)
                credentials._memo.clear()
                credentials._NATIVE_KEYCHAIN = None
                self.assertTrue(
                    credentials.get(account) == first,
                    "Keychain value did not survive an in-memory cache reset",
                )
                credentials.put(account, second)
                credentials._memo.clear()
                credentials._NATIVE_KEYCHAIN = None
                self.assertTrue(
                    credentials.get(account) == second,
                    "Keychain update did not survive an in-memory cache reset",
                )
                credentials.clear(account)
                credentials._memo.clear()
                self.assertEqual(credentials.get(account), "")
        finally:
            credentials._memo.clear()
            credentials.clear(account)
            credentials._memo.clear()

        visible = output.getvalue() + "\0".join(sys.argv)
        self.assertNotIn(first, visible)
        self.assertNotIn(second, visible)

    @unittest.skipUnless(sys.platform == "darwin", "requires the macOS Keychain")
    def test_real_keychain_persists_across_a_new_process_and_clear(self):
        account = "qa.cross-process." + uuid.uuid4().hex
        secret = "qa-" + secrets.token_urlsafe(56)
        expected = hashlib.sha256(secret.encode("utf-8")).hexdigest()
        empty = hashlib.sha256(b"").hexdigest()
        child_code = """
import hashlib
import hmac
import os
import sys
sys.path.insert(0, os.environ['OPENCLAM_QA_SERVER'])
import credentials
credentials._memo.clear()
actual = hashlib.sha256(credentials.get(os.environ['OPENCLAM_QA_ACCOUNT']).encode('utf-8')).hexdigest()
raise SystemExit(0 if hmac.compare_digest(actual, os.environ['OPENCLAM_QA_DIGEST']) else 19)
"""
        child_args = [sys.executable, "-I", "-c", child_code]

        def child_environment(digest):
            environment = {
                "HOME": os.environ["HOME"],
                "PATH": "/usr/bin:/bin",
                "OPENCLAM_QA_ACCOUNT": account,
                "OPENCLAM_QA_DIGEST": digest,
                "OPENCLAM_QA_SERVER": str(ROOT / "server"),
            }
            if os.environ.get("LANG"):
                environment["LANG"] = os.environ["LANG"]
            return environment

        try:
            credentials.clear(account)
            credentials.put(account, secret)
            credentials._memo.clear()
            credentials._NATIVE_KEYCHAIN = None
            environment = child_environment(expected)
            self.assertNotIn(secret, repr(child_args) + repr(environment))
            persisted = subprocess.run(
                child_args,
                env=environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(persisted.returncode, 0, "new process could not read Keychain value")
            self.assertNotIn(secret, persisted.stdout + persisted.stderr)

            credentials.clear(account)
            credentials._memo.clear()
            cleared_environment = child_environment(empty)
            cleared = subprocess.run(
                child_args,
                env=cleared_environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(cleared.returncode, 0, "new process still found cleared Keychain value")
            self.assertNotIn(secret, cleared.stdout + cleared.stderr)
        finally:
            credentials._memo.clear()
            credentials.clear(account)
            credentials._memo.clear()

    def test_file_fallback_reapplies_owner_only_mode(self):
        # The fallback is test/CI-only on macOS, but it must still never leave
        # a secret readable through an accidentally permissive existing file.
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            vault = Path(directory) / "vault.json"
            vault.write_text("{}", encoding="utf-8")
            os.chmod(vault, 0o644)
            credentials._TEST_VAULT_FILE = str(vault)
            credentials.put("keys.test", "synthetic-secret")
            self.assertEqual(vault.stat().st_mode & 0o777, 0o600)

    def test_framework_failures_never_commit_or_erase_memoized_values(self):
        class FailingKeychain:
            def get(self, _account):
                raise RuntimeError("OpenClam Keychain read failed (OSStatus -25308)")

            def put(self, _account, _value):
                raise RuntimeError("OpenClam Keychain write failed (OSStatus -25308)")

            def clear(self, _account):
                raise RuntimeError("OpenClam Keychain deletion failed (OSStatus -25308)")

        logical = "keys.failure-test"
        with patch.object(credentials, "_is_mac", return_value=True), patch.object(
            credentials, "_TEST_NATIVE_KEYCHAIN", FailingKeychain()
        ):
            credentials._memo.clear()
            with self.assertRaisesRegex(RuntimeError, "read failed"):
                credentials.get(logical)
            self.assertNotIn(logical, credentials._memo)

            credentials._memo[logical] = "previous-synthetic-value"
            with self.assertRaisesRegex(RuntimeError, "write failed"):
                credentials.put(logical, "replacement-synthetic-value")
            self.assertEqual(credentials._memo[logical], "previous-synthetic-value")

            with self.assertRaisesRegex(RuntimeError, "deletion failed"):
                credentials.clear(logical)
            self.assertEqual(credentials._memo[logical], "previous-synthetic-value")


if __name__ == "__main__":
    unittest.main()
