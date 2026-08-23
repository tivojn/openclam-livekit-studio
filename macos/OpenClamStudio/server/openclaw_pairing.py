"""Safe local OpenClaw pairing control for the macOS Settings surface."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit


PAIRING_CODE = re.compile(
    r"^OC-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$"
)
UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
MAX_OUTPUT_BYTES = 64 * 1024
MAX_PLUGIN_BYTES = 5 * 1024 * 1024
SETUP_KEY = re.compile(r"^[A-Za-z0-9_-]{32,256}$")


class OpenClawPairingError(RuntimeError):
    """A bounded user-facing failure; child-process output is never echoed."""


def _executable() -> str | None:
    for candidate in (
        shutil.which("openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.realpath(candidate)
    return None


def _safe_environment() -> dict[str, str]:
    allowed = {
        "HOME",
        "LANG",
        "LC_ALL",
        "LOGNAME",
        "OPENCLAW_CONFIG_PATH",
        "OPENCLAW_HOME",
        "OPENCLAW_STATE_DIR",
        "PATH",
        "TMPDIR",
        "USER",
    }
    environment = {key: value for key, value in os.environ.items() if key in allowed}
    environment["NO_COLOR"] = "1"
    return environment


def _run(
    arguments: list[str],
    timeout: float = 25,
    extra_environment: dict[str, str] | None = None,
) -> str:
    executable = _executable()
    if not executable:
        raise OpenClawPairingError(
            "OpenClaw is not installed on this Mac. Install and configure OpenClaw first."
        )
    try:
        environment = _safe_environment()
        if extra_environment:
            environment.update(extra_environment)
        result = subprocess.run(
            [executable, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
            env=environment,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OpenClawPairingError(
            "OpenClaw did not respond. Make sure its gateway is running, then try again."
        ) from error
    if len(result.stdout) > MAX_OUTPUT_BYTES or len(result.stderr) > MAX_OUTPUT_BYTES:
        raise OpenClawPairingError("OpenClaw returned an oversized response.")
    if result.returncode != 0:
        raise OpenClawPairingError(
            "OpenClaw could not create the iPhone pairing. Check its OpenClam channel, then try again."
        )
    try:
        return result.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError as error:
        raise OpenClawPairingError("OpenClaw returned an invalid response.") from error


def _plugin_package() -> str:
    candidates = [
        os.environ.get("OPENCLAM_OPENCLAW_PLUGIN_PACKAGE", ""),
        str(Path(__file__).resolve().parents[1]
            / ".electron-openclaw-plugin" / "openclam-channel.tgz"),
    ]
    for raw in candidates:
        if not raw:
            continue
        path = Path(raw).expanduser()
        try:
            resolved = path.resolve(strict=True)
            stat = resolved.stat()
        except OSError:
            continue
        if (
            resolved.suffix == ".tgz"
            and resolved.is_file()
            and not path.is_symlink()
            and 0 < stat.st_size <= MAX_PLUGIN_BYTES
        ):
            return str(resolved)
    raise OpenClawPairingError(
        "This OpenClam Studio build does not include the OpenClaw channel package."
    )


def _bridge_origin() -> str:
    raw_path = os.environ.get("OPENCLAM_OPENCLAW_INSTALL_CONFIG", "")
    if not raw_path:
        raise OpenClawPairingError(
            "This OpenClam Studio build is not provisioned for OpenClaw setup."
        )
    path = Path(raw_path).expanduser()
    try:
        resolved = path.resolve(strict=True)
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise OpenClawPairingError(
            "This OpenClam Studio build has an invalid OpenClaw setup configuration."
        ) from error
    if not isinstance(value, dict) or set(value) != {"v", "bridge_origin"}:
        raise OpenClawPairingError(
            "This OpenClam Studio build has an invalid OpenClaw setup configuration."
        )
    origin = value.get("bridge_origin")
    if value.get("v") != 1 or not isinstance(origin, str) or len(origin) > 512:
        raise OpenClawPairingError(
            "This OpenClam Studio build has an invalid OpenClaw setup configuration."
        )
    parsed = urlsplit(origin)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or origin.rstrip("/") != f"https://{parsed.netloc}"
    ):
        raise OpenClawPairingError(
            "This OpenClam Studio build has an invalid OpenClaw setup configuration."
        )
    return origin.rstrip("/")


def _account(value: object) -> dict[str, str]:
    if not isinstance(value, dict):
        raise OpenClawPairingError("OpenClaw returned an invalid agent list.")
    account_id = value.get("accountId")
    agent_id = value.get("agentId")
    display_name = value.get("displayName")
    if not all(isinstance(item, str) and item for item in (
        account_id, agent_id, display_name
    )):
        raise OpenClawPairingError("OpenClaw returned an invalid agent list.")
    if len(account_id) > 64 or len(agent_id) > 64 or len(display_name) > 80:
        raise OpenClawPairingError("OpenClaw returned an invalid agent list.")
    return {
        "account_id": account_id,
        "agent_id": agent_id,
        "display_name": display_name,
    }


def _parse_json_object(output: str) -> dict[str, object]:
    decoder = json.JSONDecoder()
    for index, character in enumerate(output):
        if character != "{":
            continue
        try:
            value, end = decoder.raw_decode(output, index)
        except json.JSONDecodeError:
            continue
        if output[end:].strip() or not isinstance(value, dict):
            continue
        return value
    raise OpenClawPairingError("OpenClaw returned an invalid response.")


def status() -> dict[str, object]:
    executable = _executable()
    if not executable:
        return {
            "available": False,
            "channel_installed": False,
            "configured": False,
            "gateway_label": "",
            "accounts": [],
        }
    try:
        value = _parse_json_object(_run(["openclam", "status"]))
    except OpenClawPairingError:
        return {
            "available": True,
            "channel_installed": False,
            "configured": False,
            "gateway_label": "",
            "accounts": [],
        }
    if not isinstance(value, dict):
        raise OpenClawPairingError("OpenClaw returned an invalid status response.")
    accounts = value.get("accounts")
    gateway_label = value.get("gatewayLabel")
    if not isinstance(accounts, list) or len(accounts) > 32:
        raise OpenClawPairingError("OpenClaw returned an invalid agent list.")
    return {
        "available": True,
        "channel_installed": True,
        "configured": bool(value.get("paired")),
        "gateway_label": (
            gateway_label.strip()[:80]
            if isinstance(gateway_label, str)
            else ""
        ),
        "accounts": [_account(account) for account in accounts],
    }


def _pairing_result(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or set(value) != {
        "v", "code", "connectionId", "expiresAt", "gatewayLabel", "accounts"
    }:
        raise OpenClawPairingError("OpenClaw returned an invalid pairing response.")
    code = value.get("code")
    connection_id = value.get("connectionId")
    expires_at = value.get("expiresAt")
    gateway_label = value.get("gatewayLabel")
    accounts = value.get("accounts")
    now = int(time.time() * 1000)
    if (
        value.get("v") != 1
        or not isinstance(code, str)
        or PAIRING_CODE.fullmatch(code) is None
        or not isinstance(connection_id, str)
        or UUID.fullmatch(connection_id) is None
        or not isinstance(expires_at, int)
        or expires_at <= now
        or expires_at > now + 60 * 60 * 1000
        or not isinstance(gateway_label, str)
        or not gateway_label.strip()
        or len(gateway_label) > 80
        or not isinstance(accounts, list)
        or not 1 <= len(accounts) <= 32
    ):
        raise OpenClawPairingError("OpenClaw returned an invalid pairing response.")
    return {
        "code": code,
        "connection_id": connection_id,
        "expires_at": expires_at,
        "gateway_label": gateway_label,
        "accounts": [_account(account) for account in accounts],
    }


def install_channel(setup_key: str = "") -> dict[str, object]:
    if not _executable():
        raise OpenClawPairingError(
            "OpenClaw is not installed on this Mac. Install OpenClaw first."
        )
    package = _plugin_package()
    existing = status()
    _run(["plugins", "install", package, "--force"], timeout=90)
    if existing.get("configured") is True:
        _run(["gateway", "restart"], timeout=35)
        updated = status()
        return {
            **updated,
            "updated": True,
            "gateway_restarted": True,
        }
    key = setup_key.strip()
    if SETUP_KEY.fullmatch(key) is None:
        raise OpenClawPairingError(
            "Enter the OpenClam bridge setup key to connect this OpenClaw installation."
        )
    try:
        value = _parse_json_object(_run(
            [
                "openclam", "pair", "--bridge-url", _bridge_origin(),
                "--bootstrap-secret-env", "OPENCLAM_STUDIO_SETUP_KEY", "--json",
            ],
            timeout=60,
            extra_environment={"OPENCLAM_STUDIO_SETUP_KEY": key},
        ))
    except OpenClawPairingError as error:
        raise OpenClawPairingError("OpenClaw returned an invalid pairing response.") from error
    result = _pairing_result(value)
    _run(["gateway", "restart"], timeout=35)
    return {
        **result,
        "available": True,
        "channel_installed": True,
        "configured": True,
        "updated": False,
        "gateway_restarted": True,
    }


def create_pairing_code() -> dict[str, object]:
    try:
        value = _parse_json_object(_run(["openclam", "pair-device", "--json"]))
    except OpenClawPairingError as error:
        raise OpenClawPairingError("OpenClaw returned an invalid pairing response.") from error
    result = _pairing_result(value)

    restart_warning = ""
    try:
        _run(["gateway", "restart"], timeout=35)
    except OpenClawPairingError:
        restart_warning = (
            "The code is ready, but OpenClaw could not restart its gateway automatically. "
            "Restart the OpenClaw gateway before sending a message."
        )
    return {
        **result,
        "gateway_restarted": not restart_warning,
        "warning": restart_warning,
    }
