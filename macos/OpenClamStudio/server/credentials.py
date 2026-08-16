"""OpenClam's credential vault, backed by the macOS Keychain.

The right macOS boundary is not an app-invented cipher but the vault the OS
already guards: the login Keychain. Keys go in
under one service name, config.json keeps only the marker "@keychain",
and the real value is materialised in memory at load. Nothing on disk in
this repo's data root ever holds a secret again - and the settings API
stays write-only (set, clear, has_key; never echoed back).

Migration is automatic and one-way: the first load() that finds a
plaintext key sweeps it into the vault and rewrites the config with
markers. Rollback never leaks: deleting a marker just means "no key".

Off macOS (tests, CI) the vault is a plain JSON file under the data root.
macOS tests inject a temporary path directly into this module; no inherited
environment variable can switch a production Mac away from Keychain.

The macOS path calls Security.framework in-process. Secrets are CFData values:
they never become command arguments, command input, temporary files, or command
output. Keychain queries explicitly disable authentication UI so a locked or
inaccessible item fails instead of stalling the local API server.
"""
import contextlib
import ctypes
import json
import os
import sys
import threading

SERVICE = "com.lionheart.openclam.macos"
# The retired command-line implementation created legacy items owned by
# /usr/bin/security. A differently signed in-process client cannot safely
# modify or delete those ACLs without prompting. Keep the public logical names
# stable while using a fresh internal account namespace; users explicitly
# re-enter keys once after this security migration.
STORAGE_ACCOUNT_PREFIX = "openclam-v2:"
MARKER = "@keychain"
_ERR_SEC_SUCCESS = 0
_ERR_SEC_DUPLICATE_ITEM = -25299
_ERR_SEC_ITEM_NOT_FOUND = -25300
_CORE_FOUNDATION_PATH = (
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
)
_SECURITY_FRAMEWORK_PATH = "/System/Library/Frameworks/Security.framework/Security"
_CF_STRING_ENCODING_UTF8 = 0x08000100
_MAX_ACCOUNT_BYTES = 512
_MAX_SECRET_BYTES = 1024 * 1024
_lock = threading.Lock()
_memo = {}
_NATIVE_KEYCHAIN = None
# Test-only dependency injection. Production code never assigns this value,
# and unlike the old environment switch it cannot leak in from a parent shell.
_TEST_VAULT_FILE = None
_TEST_NATIVE_KEYCHAIN = None


class _MacKeychain:
    """Small ownership-safe binding to Security.framework's SecItem API."""

    def __init__(self):
        try:
            self._core = ctypes.CDLL(_CORE_FOUNDATION_PATH)
            self._security = ctypes.CDLL(_SECURITY_FRAMEWORK_PATH)
        except OSError:
            raise RuntimeError("macOS Keychain is unavailable") from None
        self._configure_functions()

        self._dictionary_key_callbacks = self._symbol_address(
            self._core, "kCFTypeDictionaryKeyCallBacks"
        )
        self._dictionary_value_callbacks = self._symbol_address(
            self._core, "kCFTypeDictionaryValueCallBacks"
        )
        self._true = self._pointer_constant(self._core, "kCFBooleanTrue")
        self._class = self._pointer_constant(self._security, "kSecClass")
        self._generic_password = self._pointer_constant(
            self._security, "kSecClassGenericPassword"
        )
        self._service = self._pointer_constant(self._security, "kSecAttrService")
        self._account = self._pointer_constant(self._security, "kSecAttrAccount")
        self._value_data = self._pointer_constant(self._security, "kSecValueData")
        self._return_data = self._pointer_constant(self._security, "kSecReturnData")
        self._match_limit = self._pointer_constant(self._security, "kSecMatchLimit")
        self._match_limit_one = self._pointer_constant(
            self._security, "kSecMatchLimitOne"
        )
        self._authentication_ui = self._pointer_constant(
            self._security, "kSecUseAuthenticationUI"
        )
        self._authentication_ui_fail = self._pointer_constant(
            self._security, "kSecUseAuthenticationUIFail"
        )

    @staticmethod
    def _pointer_constant(library, name):
        try:
            value = ctypes.c_void_p.in_dll(library, name).value
        except ValueError:
            raise RuntimeError("macOS Keychain is unavailable") from None
        if not value:
            raise RuntimeError("macOS Keychain is unavailable")
        return value

    @staticmethod
    def _symbol_address(library, name):
        try:
            symbol = ctypes.c_ubyte.in_dll(library, name)
        except ValueError:
            raise RuntimeError("macOS Keychain is unavailable") from None
        return ctypes.addressof(symbol)

    def _configure_functions(self):
        cf_index = ctypes.c_long
        cf_type_id = ctypes.c_ulong
        byte_pointer = ctypes.POINTER(ctypes.c_ubyte)

        self._core.CFDictionaryCreateMutable.argtypes = [
            ctypes.c_void_p,
            cf_index,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self._core.CFDictionaryCreateMutable.restype = ctypes.c_void_p
        self._core.CFDictionarySetValue.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self._core.CFDictionarySetValue.restype = None
        self._core.CFStringCreateWithCString.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_uint32,
        ]
        self._core.CFStringCreateWithCString.restype = ctypes.c_void_p
        self._core.CFDataCreate.argtypes = [
            ctypes.c_void_p,
            byte_pointer,
            cf_index,
        ]
        self._core.CFDataCreate.restype = ctypes.c_void_p
        self._core.CFDataGetLength.argtypes = [ctypes.c_void_p]
        self._core.CFDataGetLength.restype = cf_index
        self._core.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
        self._core.CFDataGetBytePtr.restype = byte_pointer
        self._core.CFDataGetTypeID.argtypes = []
        self._core.CFDataGetTypeID.restype = cf_type_id
        self._core.CFGetTypeID.argtypes = [ctypes.c_void_p]
        self._core.CFGetTypeID.restype = cf_type_id
        self._core.CFRelease.argtypes = [ctypes.c_void_p]
        self._core.CFRelease.restype = None

        pointer_result = ctypes.POINTER(ctypes.c_void_p)
        self._security.SecItemCopyMatching.argtypes = [ctypes.c_void_p, pointer_result]
        self._security.SecItemCopyMatching.restype = ctypes.c_int32
        self._security.SecItemAdd.argtypes = [ctypes.c_void_p, pointer_result]
        self._security.SecItemAdd.restype = ctypes.c_int32
        self._security.SecItemUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self._security.SecItemUpdate.restype = ctypes.c_int32
        self._security.SecItemDelete.argtypes = [ctypes.c_void_p]
        self._security.SecItemDelete.restype = ctypes.c_int32

    def _new_string(self, value):
        try:
            encoded = value.encode("utf-8")
        except UnicodeEncodeError:
            raise ValueError("Keychain account must be valid UTF-8") from None
        if b"\0" in encoded:
            raise ValueError("Keychain account contains a null byte")
        if not encoded or len(encoded) > _MAX_ACCOUNT_BYTES:
            raise ValueError("Keychain account has an invalid length")
        result = self._core.CFStringCreateWithCString(
            None, encoded, _CF_STRING_ENCODING_UTF8
        )
        if not result:
            raise RuntimeError("macOS Keychain allocation failed")
        return result

    def _new_data(self, raw):
        buffer = (ctypes.c_ubyte * len(raw)).from_buffer_copy(raw)
        result = self._core.CFDataCreate(None, buffer, len(raw))
        if not result:
            raise RuntimeError("macOS Keychain allocation failed")
        return result

    @contextlib.contextmanager
    def _dictionary(self, pairs):
        dictionary = self._core.CFDictionaryCreateMutable(
            None,
            0,
            self._dictionary_key_callbacks,
            self._dictionary_value_callbacks,
        )
        if not dictionary:
            raise RuntimeError("macOS Keychain allocation failed")
        owned = []
        try:
            for key, value in pairs:
                if isinstance(value, str):
                    pointer = self._new_string(value)
                    owned.append(pointer)
                elif isinstance(value, bytes):
                    pointer = self._new_data(value)
                    owned.append(pointer)
                else:
                    pointer = value
                self._core.CFDictionarySetValue(dictionary, key, pointer)
            yield dictionary
        finally:
            self._core.CFRelease(dictionary)
            for pointer in owned:
                self._core.CFRelease(pointer)

    def _item_pairs(self, account):
        return [
            (self._class, self._generic_password),
            (self._service, SERVICE),
            (self._account, account),
        ]

    def _query_pairs(self, account):
        return self._item_pairs(account) + [
            (self._authentication_ui, self._authentication_ui_fail),
        ]

    @staticmethod
    def _failure(action, status):
        raise RuntimeError(f"OpenClam Keychain {action} failed (OSStatus {status})")

    def get(self, account):
        result = ctypes.c_void_p()
        pairs = self._query_pairs(account) + [
            (self._return_data, self._true),
            (self._match_limit, self._match_limit_one),
        ]
        with self._dictionary(pairs) as query:
            status = self._security.SecItemCopyMatching(query, ctypes.byref(result))
        try:
            if status == _ERR_SEC_ITEM_NOT_FOUND:
                return ""
            if status != _ERR_SEC_SUCCESS or not result.value:
                self._failure("read", status)
            if self._core.CFGetTypeID(result) != self._core.CFDataGetTypeID():
                raise RuntimeError("OpenClam Keychain returned invalid data")
            length = self._core.CFDataGetLength(result)
            pointer = self._core.CFDataGetBytePtr(result)
            if length < 0 or length > _MAX_SECRET_BYTES or (length and not pointer):
                raise RuntimeError("OpenClam Keychain returned invalid data")
            raw = ctypes.string_at(pointer, length) if length else b""
            try:
                return raw.decode("utf-8")
            except UnicodeDecodeError:
                raise RuntimeError("OpenClam Keychain returned invalid data") from None
        finally:
            if result.value:
                self._core.CFRelease(result)

    def put(self, account, value):
        try:
            raw = value.encode("utf-8")
        except UnicodeEncodeError:
            raise ValueError("Keychain value must be valid UTF-8") from None
        if not raw or len(raw) > _MAX_SECRET_BYTES:
            raise ValueError("Keychain value has an invalid length")
        query_pairs = self._query_pairs(account)
        add_pairs = [
            (self._class, self._generic_password),
            (self._service, SERVICE),
            (self._account, account),
            (self._value_data, raw),
            (self._authentication_ui, self._authentication_ui_fail),
        ]
        # A concurrent writer can create or delete between update and add.
        # Retry this atomic pair a small fixed number of times; never delete a
        # duplicate and never weaken its access control to win the race.
        for _attempt in range(3):
            with self._dictionary(query_pairs) as query, self._dictionary(
                [(self._value_data, raw)]
            ) as updates:
                status = self._security.SecItemUpdate(query, updates)
            if status == _ERR_SEC_SUCCESS:
                return
            if status != _ERR_SEC_ITEM_NOT_FOUND:
                self._failure("write", status)
            with self._dictionary(add_pairs) as attributes:
                status = self._security.SecItemAdd(attributes, None)
            if status == _ERR_SEC_SUCCESS:
                return
            if status != _ERR_SEC_DUPLICATE_ITEM:
                self._failure("write", status)
        if status != _ERR_SEC_SUCCESS:
            self._failure("write", status)

    def clear(self, account):
        # SecItemDelete accepts item attributes/search keys, but macOS rejects
        # kSecUseAuthenticationUI in its delete dictionary with errSecParam.
        # Items in this fresh namespace are created by this process without an
        # authentication ACL; reads and update lookups retain UI-fail behavior.
        with self._dictionary(self._item_pairs(account)) as query:
            status = self._security.SecItemDelete(query)
        if status not in (_ERR_SEC_SUCCESS, _ERR_SEC_ITEM_NOT_FOUND):
            self._failure("deletion", status)


def _native_keychain():
    global _NATIVE_KEYCHAIN
    if _TEST_NATIVE_KEYCHAIN is not None:
        return _TEST_NATIVE_KEYCHAIN
    if _NATIVE_KEYCHAIN is None:
        _NATIVE_KEYCHAIN = _MacKeychain()
    return _NATIVE_KEYCHAIN


def _storage_account(account):
    return STORAGE_ACCOUNT_PREFIX + account


def _fallback_path():
    from providers import DATA_ROOT
    return os.path.join(DATA_ROOT, "vault.json")


def _is_mac():
    return sys.platform == "darwin" and _TEST_VAULT_FILE is None


def _file_vault_read():
    path = _TEST_VAULT_FILE or _fallback_path()
    try:
        with open(path) as handle:
            return json.load(handle)
    except Exception:
        return {}


def _file_vault_write(data):
    path = _TEST_VAULT_FILE or _fallback_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(data, handle)


def get(account):
    """The secret for one account, such as ``llm.api_key``."""
    if not isinstance(account, str) or not account:
        raise ValueError("Keychain account must be a non-empty string")
    with _lock:
        if account in _memo:
            return _memo[account]
        if _is_mac():
            value = _native_keychain().get(_storage_account(account))
        else:
            value = _file_vault_read().get(account, "")
        _memo[account] = value
    return value


def put(account, value):
    if not isinstance(account, str) or not account:
        raise ValueError("Keychain account must be a non-empty string")
    if not isinstance(value, str):
        raise TypeError("Keychain values must be strings")
    if not value:
        return clear(account)
    with _lock:
        if _is_mac():
            _native_keychain().put(_storage_account(account), value)
        else:
            data = _file_vault_read()
            data[account] = value
            _file_vault_write(data)
        _memo[account] = value


def clear(account):
    if not isinstance(account, str) or not account:
        raise ValueError("Keychain account must be a non-empty string")
    with _lock:
        if _is_mac():
            _native_keychain().clear(_storage_account(account))
        else:
            data = _file_vault_read()
            data.pop(account, None)
            _file_vault_write(data)
        _memo[account] = ""


# ------------------------------------------------ config <-> vault weaving

# Every field in the config that is a secret, by block.
SECRET_FIELDS = {
    "llm": ("api_key",),
    "tts": ("api_key",),
    "stt": ("api_key",),
    "image": ("api_key",),
    "video": ("api_key",),
    # The shared LiveKit broker authenticates this installation before it
    # mints a one-time room token.  Like provider keys, that bearer must never
    # be written to config.json or exposed through the renderer settings API.
    "livekit": ("pilot_app_token",),
}


def absorb(cfg):
    """Sweep plaintext secrets out of a config dict into the vault,
    leaving markers. Returns True if anything moved (caller persists)."""
    moved = False
    for block_name, fields in SECRET_FIELDS.items():
        block = cfg.get(block_name)
        if not isinstance(block, dict):
            continue
        for field in fields:
            value = block.get(field) or ""
            if value == "__clear__":
                clear(f"{block_name}.{field}")
                block[field] = ""
                moved = True
            elif value and value != MARKER:
                put(f"{block_name}.{field}", value)
                block[field] = MARKER
                moved = True
    # The platform keyring (#25): every field under "keys" is a secret,
    # named by platform rather than fixed in advance. A cleared platform
    # leaves the dict entirely - an empty row is not a setting.
    keys = cfg.get("keys")
    if isinstance(keys, dict):
        for name in list(keys):
            value = keys.get(name) or ""
            if value == "__clear__":
                clear(f"keys.{name}")
                keys.pop(name)
                moved = True
            elif value and value != MARKER:
                put(f"keys.{name}", value)
                keys[name] = MARKER
                moved = True
    return moved


def materialise(cfg):
    """Replace markers with the real secrets, in memory only."""
    for block_name, fields in SECRET_FIELDS.items():
        block = cfg.get(block_name)
        if not isinstance(block, dict):
            continue
        for field in fields:
            if block.get(field) == MARKER:
                block[field] = get(f"{block_name}.{field}")
    keys = cfg.get("keys")
    if isinstance(keys, dict):
        for name, value in keys.items():
            if value == MARKER:
                keys[name] = get(f"keys.{name}")
    return cfg
