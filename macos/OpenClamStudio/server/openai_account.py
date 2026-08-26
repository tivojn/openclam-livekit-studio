"""Shared OpenAI account lane backed by the locally authenticated Codex CLI.

OpenClam never reads or copies ChatGPT OAuth tokens.  Codex owns sign-in and
refresh; this module asks the installed client for status and invokes
``codex exec`` as the authenticated boundary.  API-key mode remains a separate
direct OpenAI Platform lane.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

try:
    import credentials
except ModuleNotFoundError:  # package import in tests and embedded runtimes
    from . import credentials


API_KEY_MODE = "api_key"
CHATGPT_MODE = "chatgpt"
SELECTABLE_MODES = frozenset((API_KEY_MODE, CHATGPT_MODE))
AUTH_MODE_ACCOUNT = "openai.auth_mode"
DATA_ROOT = os.path.abspath(os.environ.get(
    "OPENCLAM_DATA_DIR", Path(__file__).resolve().parents[1]))
MODE_FILE = os.path.join(DATA_ROOT, "openai-account.json")
MAX_PROMPT_CHARS = 32_000
MAX_REFERENCES = 16
MAX_REFERENCE_BYTES = 20 * 1024 * 1024
_login_lock = threading.Lock()
_login_process = None
_mode_lock = threading.Lock()


class OpenAIAccountError(RuntimeError):
    def __init__(self, code, status_code=502):
        self.code = str(code)
        self.status_code = int(status_code)
        super().__init__(self.code)


def _codex():
    candidates = [
        shutil.which("codex"),
        os.path.expanduser("~/.local/bin/codex"),
        os.path.expanduser("~/.codex/packages/standalone/current/bin/codex"),
    ]
    path = next((value for value in candidates
                 if value and os.path.isfile(value) and os.access(value, os.X_OK)), None)
    if not path:
        raise OpenAIAccountError("openai_codex_not_installed", 503)
    return path


def auth_mode():
    # This is a routing preference, not a credential. Keeping it outside the
    # Keychain lets Settings open even when an unrelated protected item is
    # temporarily inaccessible; the actual ChatGPT session remains wholly
    # owned by Codex.
    with _mode_lock:
        try:
            with open(MODE_FILE, encoding="utf-8") as handle:
                value = json.load(handle).get("auth_mode")
        except (OSError, ValueError, TypeError, AttributeError):
            value = ""
    return value if value in SELECTABLE_MODES else API_KEY_MODE


def set_auth_mode(mode):
    if mode not in SELECTABLE_MODES:
        raise OpenAIAccountError("openai_auth_mode_invalid", 422)
    if mode == CHATGPT_MODE and not status()["oauth"]["available"]:
        raise OpenAIAccountError("openai_codex_not_installed", 503)
    directory = os.path.dirname(MODE_FILE)
    with _mode_lock:
        try:
            os.makedirs(directory, mode=0o700, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(
                prefix=".openai-account-", dir=directory)
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    json.dump({"auth_mode": mode}, handle)
                os.chmod(temporary, 0o600)
                os.replace(temporary, MODE_FILE)
            finally:
                if os.path.exists(temporary):
                    os.remove(temporary)
        except OSError:
            raise OpenAIAccountError(
                "openai_account_storage_unavailable", 503) from None
    return status()


def _login_status():
    try:
        result = subprocess.run(
            [_codex(), "login", "status"], capture_output=True, text=True,
            timeout=12, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, ""
    text = re.sub(r"\s+", " ", (result.stdout or "") + " " + (result.stderr or "")).strip()
    return result.returncode == 0 and "Logged in using ChatGPT" in text, text[:200]


def status():
    try:
        _codex()
        available = True
    except OpenAIAccountError:
        available = False
    connected, _detail = _login_status() if available else (False, "")
    mode = auth_mode()
    try:
        has_api_key = bool(credentials.get("keys.openai"))
    except Exception:
        has_api_key = False
    active = has_api_key if mode == API_KEY_MODE else connected
    return {
        "provider": "openai",
        "auth_mode": mode,
        "state": "connected" if active else "disconnected",
        "connected": bool(active),
        "has_api_key": has_api_key,
        "oauth": {
            "available": available,
            "connected": connected,
            "managed_by": "codex",
        },
        "capabilities": {
            "llm": connected,
            "image_generation": connected,
            "image_editing": connected,
            # Codex currently exposes a built-in image tool, not a Sora/video
            # artifact tool. Do not paint a fake green status for video.
            "video_generation": False,
            "video_editing": False,
        },
    }


def start_login():
    global _login_process
    with _login_lock:
        connected, _detail = _login_status()
        if connected:
            return status()
        if _login_process is not None and _login_process.poll() is None:
            return {**status(), "state": "pending"}
        try:
            _login_process = subprocess.Popen(
                [_codex(), "login"], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            raise OpenAIAccountError("openai_login_start_failed", 503) from None
    return {**status(), "state": "pending"}


def logout():
    try:
        result = subprocess.run(
            [_codex(), "logout"], capture_output=True, text=True,
            timeout=20, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise OpenAIAccountError("openai_logout_failed", 503) from None
    if result.returncode:
        raise OpenAIAccountError("openai_logout_failed", 502)
    return status()


def require_chatgpt():
    if auth_mode() != CHATGPT_MODE:
        raise OpenAIAccountError("openai_chatgpt_mode_not_selected", 409)
    connected, _detail = _login_status()
    if not connected:
        raise OpenAIAccountError("openai_chatgpt_not_connected", 401)


def _bounded_text(value, limit=MAX_PROMPT_CHARS):
    text = str(value or "").strip()
    if not text or len(text) > limit:
        raise OpenAIAccountError("openai_codex_prompt_invalid", 422)
    return text


def _exec(arguments, prompt, work, timeout):
    command = [
        _codex(), "exec", "--ephemeral", "--skip-git-repo-check",
        "--ignore-rules", "--ignore-user-config", "-s", "workspace-write",
        "-C", work,
    ] + list(arguments) + [prompt]
    try:
        result = subprocess.run(
            command, cwd=work, capture_output=True, text=True,
            timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired:
        raise OpenAIAccountError("openai_codex_timed_out", 504) from None
    except OSError:
        raise OpenAIAccountError("openai_codex_unavailable", 503) from None
    if result.returncode:
        # Codex output can contain internal diagnostics. Keep the renderer on a
        # stable error code and never return authentication material or logs.
        raise OpenAIAccountError("openai_codex_failed", 502)
    return result


def generate_image(prompt, references=None, *, aspect_ratio="1:1", quality="high"):
    """Generate/edit one image through Codex's built-in signed-in image tool."""
    require_chatgpt()
    prompt = _bounded_text(prompt)
    references = [os.path.abspath(os.fspath(path)) for path in (references or [])]
    if len(references) > MAX_REFERENCES:
        raise OpenAIAccountError("openai_codex_too_many_references", 422)
    for path in references:
        if not os.path.isfile(path) or os.path.getsize(path) > MAX_REFERENCE_BYTES:
            raise OpenAIAccountError("openai_codex_reference_invalid", 422)
    with tempfile.TemporaryDirectory(prefix="openclam-openai-image-") as work:
        arguments = []
        # Codex runs with a workspace-write sandbox rooted at ``work``. Copy
        # owner-selected references into that private workspace so the image
        # tool can read them without granting the agent arbitrary disk access.
        for index, path in enumerate(references):
            suffix = Path(path).suffix.lower()
            if suffix not in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
                suffix = ".png"
            local_reference = os.path.join(
                work, f"reference-{index + 1:02d}{suffix}")
            shutil.copy2(path, local_reference)
            # ``--image`` accepts multiple values. The two-token ``-i path``
            # form is greedy in Codex CLI, so a following positional prompt is
            # mistaken for another filename and Codex falls back to empty
            # stdin. The equals form terminates each image value explicitly.
            arguments.append(f"--image={local_reference}")
        task = (
            "Use the built-in OpenAI image generation tool to "
            + ("edit the attached reference image(s)" if references else "generate one image")
            + ". Preserve every identity invariant explicitly stated below. "
              "Do not draw with code and do not use an API-key fallback. "
              f"Target aspect ratio: {str(aspect_ratio)[:20]}. "
              f"Quality intent: {str(quality)[:20]}.\n\n"
            + prompt
            + "\n\nSave the final bitmap as result.png in the current working directory. "
              "End with exactly the absolute result.png path."
        )
        _exec(arguments, task, work, 1800)
        result = os.path.join(work, "result.png")
        if not os.path.isfile(result) or os.path.getsize(result) <= 4096:
            raise OpenAIAccountError("openai_codex_image_missing", 502)
        # Return bytes because the temporary Codex workspace is deliberately
        # destroyed before control leaves this credential boundary.
        return Path(result).read_bytes()


async def generate_image_async(*args, **kwargs):
    return await asyncio.to_thread(generate_image, *args, **kwargs)


def chat(messages, system="", max_tokens=1024):
    require_chatgpt()
    rows = []
    if system:
        rows.append({"role": "system", "content": str(system)[:16000]})
    for message in list(messages or [])[-64:]:
        if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
            continue
        rows.append({"role": message["role"], "content": str(message.get("content") or "")[:16000]})
    payload = json.dumps(rows, ensure_ascii=False)
    with tempfile.TemporaryDirectory(prefix="openclam-openai-chat-") as work:
        answer_file = os.path.join(work, "answer.txt")
        prompt = (
            "Act only as the conversation model. Do not call tools, inspect files, or "
            "perform actions. Continue the JSON conversation below and return only the "
            f"assistant's next message, at most {max(1, min(int(max_tokens), 8192))} tokens.\n"
            + payload
        )
        _exec(["-o", answer_file], _bounded_text(prompt, 64_000), work, 240)
        try:
            answer = Path(answer_file).read_text(encoding="utf-8").strip()
        except OSError:
            answer = ""
        if not answer:
            raise OpenAIAccountError("openai_codex_empty_response", 502)
        return answer[:128_000]


async def chat_async(*args, **kwargs):
    return await asyncio.to_thread(chat, *args, **kwargs)
