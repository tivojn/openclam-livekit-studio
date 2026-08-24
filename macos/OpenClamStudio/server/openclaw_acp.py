"""Bounded OpenClaw ACP streaming for the local macOS conversation.

This adapter deliberately projects a small display contract. ACP thought chunks,
raw tool inputs/outputs, environment data, absolute paths, and credentials never
cross the loopback API.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import mimetypes
import os
import re
import secrets
import shutil
import subprocess
import time
from collections import OrderedDict
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any


AGENT_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
SESSION_ID = re.compile(r"^[0-9a-f]{32}$")
SECRET = re.compile(
    r"(?i)(?:authorization\s*:\s*(?:bearer\s+)?[^\s,;]+|"
    r"\bbearer\s+[A-Za-z0-9._~+/=-]+|"
    r"\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie)"
    r"\s*[:=]\s*[^\s,;]+)"
)
ABSOLUTE_PATH = re.compile(
    r"(?i)(?:file://\S+|(?:^|[\s(\[])/(?!/)[^\s)\]]+|"
    r"(?:^|\s)[A-Za-z]:[\\/]\S+|\\\\[^\s\\]+\\\S*)"
)
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
MAX_LINE_BYTES = 1_048_576
MAX_REPLY_CHARS = 64_000
MAX_WORK_STEPS = 24
MAX_WORK_UPDATES = 160
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
MAX_ARTIFACT_HANDLES = 128
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_INPUT_TOTAL_BYTES = 64 * 1024 * 1024
MAX_INPUT_FILES = 8
MEDIA_HANDLE = re.compile(r"^[A-Za-z0-9_-]{20,32}$")
ALLOWED_ARTIFACT_SUFFIXES = {
    ".aac", ".avi", ".csv", ".doc", ".docx", ".gif", ".heic", ".heif",
    ".jpeg", ".jpg", ".key", ".m4a", ".m4v", ".md", ".mov", ".mp3",
    ".mp4", ".numbers", ".pages", ".pdf", ".png", ".ppt", ".pptx",
    ".rtf", ".txt", ".wav", ".webm", ".webp", ".xls", ".xlsx", ".zip",
}


class OpenClawACPError(RuntimeError):
    """Safe user-facing ACP failure."""


@dataclass(frozen=True)
class Agent:
    agent_id: str
    display_name: str
    workspace: str
    is_default: bool


_ARTIFACTS: OrderedDict[str, str] = OrderedDict()


def _media_root() -> Path:
    data_root = os.path.abspath(os.environ.get(
        "OPENCLAM_DATA_DIR",
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ))
    root = Path(data_root) / "openclaw-media"
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    return root


def _safe_filename(value: object, fallback: str = "OpenClaw file") -> str:
    if not isinstance(value, str):
        return fallback
    name = CONTROL.sub("", os.path.basename(value)).strip().strip(".")
    if not name:
        return fallback
    # Finder and the thread both become difficult to use with pathological
    # names. Keep whole Unicode code points and leave the extension visible.
    suffix = Path(name).suffix[:20]
    stem_limit = max(1, 160 - len(suffix))
    return f"{Path(name).stem[:stem_limit]}{suffix}"[:160]


def _write_private_json(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def _persist_media(
    source: str,
    kind: str,
    name: object,
    media_type: object,
    *,
    agent_id: str = "",
    session_id: str = "",
    maximum: int = MAX_ARTIFACT_BYTES,
) -> dict[str, object] | None:
    if kind not in {"artifacts", "inputs"}:
        return None
    candidate = os.path.realpath(source)
    if not os.path.isfile(candidate) or os.path.islink(candidate):
        return None
    byte_count = os.path.getsize(candidate)
    if byte_count <= 0 or byte_count > maximum:
        return None
    filename = _safe_filename(name, "OpenClaw file")
    suffix = Path(filename).suffix.lower()
    if suffix not in ALLOWED_ARTIFACT_SUFFIXES:
        return None
    handle = secrets.token_urlsafe(18)
    kind_root = _media_root() / kind
    kind_root.mkdir(mode=0o700, exist_ok=True)
    os.chmod(kind_root, 0o700)
    directory = kind_root / handle
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    os.chmod(directory, 0o700)
    destination = directory / f"content{suffix}"
    try:
        shutil.copyfile(candidate, destination)
        os.chmod(destination, 0o600)
        metadata = {
            "v": 1,
            "handle": handle,
            "kind": kind,
            "name": filename,
            "media_type": (
                str(media_type).strip().lower()[:120]
                if isinstance(media_type, str) and media_type.strip()
                else mimetypes.guess_type(filename)[0] or "application/octet-stream"
            ),
            "byte_count": byte_count,
            "created_at": int(time.time()),
            "content": destination.name,
        }
        if kind == "inputs":
            metadata["agent_id"] = agent_id
            metadata["session_id"] = session_id
        _write_private_json(directory / "metadata.json", metadata)
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        return None
    return metadata


def _load_media(handle: str, kind: str) -> tuple[dict[str, object], str] | None:
    if MEDIA_HANDLE.fullmatch(handle) is None or kind not in {"artifacts", "inputs"}:
        return None
    directory = _media_root() / kind / handle
    try:
        metadata = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
        if (
            not isinstance(metadata, dict)
            or metadata.get("v") != 1
            or metadata.get("handle") != handle
            or metadata.get("kind") != kind
            or not isinstance(metadata.get("content"), str)
            or os.path.basename(metadata["content"]) != metadata["content"]
        ):
            return None
        path = os.path.realpath(directory / metadata["content"])
        if os.path.commonpath((path, os.path.realpath(directory))) != os.path.realpath(directory):
            return None
        if not os.path.isfile(path) or os.path.islink(path):
            return None
        if os.path.getsize(path) != metadata.get("byte_count"):
            return None
        return metadata, path
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def _executable() -> str | None:
    for candidate in (
        shutil.which("openclaw"),
        "/opt/homebrew/bin/openclaw",
        "/usr/local/bin/openclaw",
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.realpath(candidate)
    return None


def _environment() -> dict[str, str]:
    allowed = {
        "HOME", "LANG", "LC_ALL", "LOGNAME", "OPENCLAW_CONFIG_PATH",
        "OPENCLAW_HOME", "OPENCLAW_STATE_DIR", "PATH", "TMPDIR", "USER",
    }
    value = {key: item for key, item in os.environ.items() if key in allowed}
    value["NO_COLOR"] = "1"
    value["OPENCLAW_SHELL"] = "openclam-studio"
    return value


def _run_json(arguments: list[str], timeout: float = 20) -> object:
    executable = _executable()
    if not executable:
        raise OpenClawACPError("OpenClaw is not installed on this Mac.")
    try:
        result = subprocess.run(
            [executable, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
            env=_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OpenClawACPError("OpenClaw did not respond.") from error
    if result.returncode != 0 or len(result.stdout) > MAX_LINE_BYTES:
        raise OpenClawACPError("OpenClaw is unavailable. Check its gateway.")
    try:
        return json.loads(result.stdout.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OpenClawACPError("OpenClaw returned an invalid response.") from error


def agents() -> list[dict[str, object]]:
    value = _run_json(["agents", "list", "--json"])
    if not isinstance(value, list) or len(value) > 64:
        raise OpenClawACPError("OpenClaw returned an invalid agent list.")
    output: list[dict[str, object]] = []
    for item in value:
        if not isinstance(item, dict):
            raise OpenClawACPError("OpenClaw returned an invalid agent list.")
        agent_id = item.get("id")
        name = item.get("identityName") or item.get("name") or agent_id
        workspace = item.get("workspace")
        if (
            not isinstance(agent_id, str)
            or AGENT_ID.fullmatch(agent_id) is None
            or not isinstance(name, str)
            or not name.strip()
            or len(name) > 80
            or not isinstance(workspace, str)
            or not os.path.isabs(workspace)
        ):
            raise OpenClawACPError("OpenClaw returned an invalid agent list.")
        output.append({
            "agent_id": agent_id,
            "display_name": name.strip(),
            "is_default": item.get("isDefault") is True,
            "_workspace": os.path.realpath(workspace),
        })
    return output


def public_agents() -> list[dict[str, object]]:
    return [
        {key: value for key, value in item.items() if not key.startswith("_")}
        for item in agents()
    ]


def _agent(agent_id: str) -> Agent:
    if AGENT_ID.fullmatch(agent_id) is None:
        raise OpenClawACPError("Choose a valid OpenClaw agent.")
    for item in agents():
        if item["agent_id"] == agent_id:
            return Agent(
                agent_id=agent_id,
                display_name=str(item["display_name"]),
                workspace=str(item["_workspace"]),
                is_default=bool(item["is_default"]),
            )
    raise OpenClawACPError("That OpenClaw agent is no longer available.")


def _safe_text(value: object, maximum: int) -> str:
    if not isinstance(value, str):
        return ""
    text = CONTROL.sub("", value).strip()
    text = ABSOLUTE_PATH.sub(" [private path]", text)
    text = SECRET.sub("[REDACTED]", text)
    return text[:maximum]


def _safe_title(value: object, fallback: str) -> str:
    return _safe_text(value, 120) or fallback


def _safe_relative_location(value: object, workspace: str) -> str:
    if not isinstance(value, str) or not value:
        return ""
    candidate = os.path.realpath(
        value if os.path.isabs(value) else os.path.join(workspace, value)
    )
    root = os.path.realpath(workspace)
    try:
        if os.path.commonpath((candidate, root)) != root:
            return ""
        relative = os.path.relpath(candidate, root).replace(os.sep, "/")
    except ValueError:
        return ""
    if relative == ".." or relative.startswith("../"):
        return ""
    return _safe_text(relative, 512)


def _state(value: object) -> str:
    return {
        "pending": "waiting",
        "in_progress": "running",
        "running": "running",
        "completed": "completed",
        "failed": "failed",
    }.get(str(value), "running")


def _tool_presentation(kind: object, title: object) -> tuple[str, str]:
    """Project an arbitrary host tool call into a small safe display label."""
    source = f"{kind if isinstance(kind, str) else ''} {title if isinstance(title, str) else ''}".lower()
    presentations = (
        (("search", "find", "grep", "query"), ("Searched files", "search")),
        (("read", "open", "list", "inspect"), ("Read files", "files")),
        (("edit", "write", "patch", "create", "save"), ("Edited files", "files")),
        (("bash", "shell", "terminal", "command", "execute", "exec"), ("Ran commands", "command")),
        (("browser", "web", "page", "navigate"), ("Used the browser", "browser")),
        (("image", "media", "video", "audio"), ("Created media", "media")),
    )
    for needles, presentation in presentations:
        if any(re.search(rf"\b{re.escape(needle)}\b", source) for needle in needles):
            return presentation
    return ("Used a tool", "tool")


def _work(step_id: str, category: str, state: str, title: str, **details: str) -> dict:
    step = {
        "step_id": _safe_text(step_id, 64) or secrets.token_hex(8),
        "category": category,
        "state": state,
        "title": _safe_title(title, "OpenClaw work"),
    }
    # Work is presentation-safe progress, not a diagnostic surface. Raw
    # commands, host paths, and tool output never cross this boundary.
    for key in ("detail", "tool"):
        safe = _safe_text(details.get(key), 1000)
        if safe:
            step[key] = safe
    return step


def project_update(
    update: object,
    workspace: str,
    tool_titles: dict[str, str],
) -> tuple[str, object] | None:
    if not isinstance(update, dict):
        return None
    kind = update.get("sessionUpdate")
    if kind == "agent_thought_chunk":
        return None
    if kind == "agent_message_chunk":
        content = update.get("content")
        if isinstance(content, dict) and content.get("type") == "text":
            return ("text_chunk", str(content.get("text") or ""))
        return None
    if kind == "tool_call":
        call_id = _safe_text(update.get("toolCallId"), 64)
        title, tool = _tool_presentation(update.get("kind"), update.get("title"))
        if call_id:
            tool_titles[call_id] = title
        return ("work", _work(
            f"tool:{call_id or hashlib.sha256(title.encode()).hexdigest()[:16]}",
            "tool", _state(update.get("status")), title,
            tool=tool,
        ))
    if kind == "tool_call_update":
        call_id = _safe_text(update.get("toolCallId"), 64)
        projected_title, tool = _tool_presentation(update.get("kind"), update.get("title"))
        title = tool_titles.get(call_id, projected_title)
        return ("work", _work(
            f"tool:{call_id or hashlib.sha256(title.encode()).hexdigest()[:16]}",
            "tool", _state(update.get("status")), title,
            tool=tool,
        ))
    if kind == "plan":
        entries = update.get("entries")
        if not isinstance(entries, list):
            return None
        return ("plan", [
            _work(
                f"plan:{index}", "plan", _state(entry.get("status")),
                _safe_title(entry.get("content"), "Plan step"),
            )
            for index, entry in enumerate(entries[:12])
            if isinstance(entry, dict)
        ])
    return None


def _artifact(path: object, workspace: str) -> dict[str, object] | None:
    if not isinstance(path, str) or not path:
        return None
    root = os.path.realpath(workspace)
    candidate = os.path.realpath(
        path if os.path.isabs(path) else os.path.join(root, path)
    )
    try:
        if os.path.commonpath((candidate, root)) != root:
            return None
    except ValueError:
        return None
    suffix = Path(candidate).suffix.lower()
    if (
        suffix not in ALLOWED_ARTIFACT_SUFFIXES
        or not os.path.isfile(candidate)
        or os.path.islink(candidate)
    ):
        return None
    stored = _persist_media(
        candidate,
        "artifacts",
        os.path.basename(candidate),
        mimetypes.guess_type(candidate)[0],
    )
    if not stored:
        return None
    handle = str(stored["handle"])
    while len(_ARTIFACTS) >= MAX_ARTIFACT_HANDLES:
        _ARTIFACTS.popitem(last=False)
    persisted = _load_media(handle, "artifacts")
    if not persisted:
        return None
    _ARTIFACTS[handle] = persisted[1]
    return {
        "url": f"api/openclaw/artifacts/{handle}",
        "name": stored["name"],
        "media_type": stored["media_type"],
        "byte_count": stored["byte_count"],
    }


def artifact_path(handle: str) -> str | None:
    if MEDIA_HANDLE.fullmatch(handle) is None:
        return None
    path = _ARTIFACTS.get(handle)
    if path and os.path.isfile(path):
        _ARTIFACTS.move_to_end(handle)
        return path
    _ARTIFACTS.pop(handle, None)
    stored = _load_media(handle, "artifacts")
    if not stored:
        return None
    while len(_ARTIFACTS) >= MAX_ARTIFACT_HANDLES:
        _ARTIFACTS.popitem(last=False)
    _ARTIFACTS[handle] = stored[1]
    return stored[1]


def stage_upload(
    path: str,
    filename: object,
    media_type: object,
    agent_id: str,
    session_id: str,
) -> dict[str, object]:
    if AGENT_ID.fullmatch(agent_id) is None or SESSION_ID.fullmatch(session_id) is None:
        raise OpenClawACPError("Start a fresh OpenClaw chat before adding files.")
    stored = _persist_media(
        path,
        "inputs",
        filename,
        media_type,
        agent_id=agent_id,
        session_id=session_id,
        maximum=MAX_INPUT_BYTES,
    )
    if not stored:
        raise OpenClawACPError("Choose a supported file smaller than 32 MB.")
    return {
        "handle": stored["handle"],
        "url": f"api/openclaw/uploads/{stored['handle']}",
        "name": stored["name"],
        "media_type": stored["media_type"],
        "byte_count": stored["byte_count"],
    }


def upload_path(handle: str) -> str | None:
    stored = _load_media(handle, "inputs")
    return stored[1] if stored else None


def delete_upload(handle: str) -> bool:
    """Remove one staged input without accepting a filesystem path."""
    if MEDIA_HANDLE.fullmatch(handle) is None:
        return False
    root = _media_root() / "inputs"
    directory = root / handle
    try:
        resolved_root = os.path.realpath(root)
        resolved_directory = os.path.realpath(directory)
        if os.path.commonpath((resolved_root, resolved_directory)) != resolved_root:
            return False
        if not os.path.isdir(resolved_directory) or os.path.islink(resolved_directory):
            return False
        shutil.rmtree(resolved_directory)
        return True
    except OSError:
        return False


def _input_blocks(
    handles: list[str], agent_id: str, session_id: str
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    if len(handles) > MAX_INPUT_FILES:
        raise OpenClawACPError("Attach no more than 8 files to one message.")
    blocks: list[dict[str, object]] = []
    attachments: list[dict[str, object]] = []
    total = 0
    for handle in handles:
        stored = _load_media(handle, "inputs")
        if not stored:
            raise OpenClawACPError("One attached file is no longer available.")
        metadata, path = stored
        if metadata.get("agent_id") != agent_id or metadata.get("session_id") != session_id:
            raise OpenClawACPError("That attached file belongs to another chat.")
        total += int(metadata["byte_count"])
        if total > MAX_INPUT_TOTAL_BYTES:
            raise OpenClawACPError("Keep attached files below 64 MB per message.")
        name = str(metadata["name"])
        media_type = str(metadata["media_type"])
        blocks.append({
            "type": "resource_link",
            "uri": Path(path).as_uri(),
            "name": name,
            "title": name,
            "mimeType": media_type,
            "size": int(metadata["byte_count"]),
        })
        attachments.append({
            "handle": handle,
            "url": f"api/openclaw/uploads/{handle}",
            "name": name,
            "media_type": media_type,
            "byte_count": int(metadata["byte_count"]),
        })
    return blocks, attachments


async def _write(process: asyncio.subprocess.Process, value: dict) -> None:
    if process.stdin is None:
        raise OpenClawACPError("OpenClaw connection closed.")
    encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
    process.stdin.write(encoded)
    await process.stdin.drain()


async def stream_turn(
    agent_id: str,
    session_id: str,
    prompt: str,
    input_handles: list[str] | None = None,
) -> AsyncIterator[dict]:
    if SESSION_ID.fullmatch(session_id) is None:
        raise OpenClawACPError("Start a fresh OpenClaw chat.")
    text = prompt.strip()
    if not text or len(text) > 12_000 or CONTROL.search(text):
        raise OpenClawACPError("Enter a shorter plain-text message.")
    input_blocks, _ = _input_blocks(input_handles or [], agent_id, session_id)
    agent = await asyncio.to_thread(_agent, agent_id)
    executable = _executable()
    if not executable:
        raise OpenClawACPError("OpenClaw is not installed on this Mac.")
    session_key = f"agent:{agent.agent_id}:openclam-studio-{session_id}"
    process = await asyncio.create_subprocess_exec(
        executable, "acp", "--no-prefix-cwd", "--session", session_key,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=_environment(),
        limit=MAX_LINE_BYTES,
    )
    stderr_task = asyncio.create_task(process.stderr.read(MAX_LINE_BYTES))
    acp_session_id = ""
    reply = ""
    raw_reply = ""
    tool_titles: dict[str, str] = {}
    artifact_candidates: list[str] = []
    work_steps: dict[str, dict] = {}
    work_updates = 0
    response_started = False

    async def read_message() -> dict:
        if process.stdout is None:
            raise OpenClawACPError("OpenClaw connection closed.")
        line = await asyncio.wait_for(process.stdout.readline(), timeout=900)
        if not line or len(line) > MAX_LINE_BYTES:
            raise OpenClawACPError("OpenClaw connection closed.")
        try:
            value = json.loads(line.decode("utf-8", errors="strict"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise OpenClawACPError("OpenClaw returned an invalid stream.") from error
        if not isinstance(value, dict):
            raise OpenClawACPError("OpenClaw returned an invalid stream.")
        return value

    try:
        await _write(process, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": 1,
                "clientCapabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False},
                    "terminal": False,
                },
                "clientInfo": {"name": "OpenClam Studio", "version": "1.0.4"},
            },
        })
        prompt_sent = False
        while True:
            message = await read_message()
            if message.get("id") == 1:
                if "error" in message:
                    raise OpenClawACPError("OpenClaw could not initialize this chat.")
                await _write(process, {
                    "jsonrpc": "2.0", "id": 2, "method": "session/new",
                    "params": {"cwd": agent.workspace, "mcpServers": []},
                })
                continue
            if message.get("id") == 2:
                result = message.get("result")
                if not isinstance(result, dict) or not isinstance(result.get("sessionId"), str):
                    raise OpenClawACPError("OpenClaw could not create this chat.")
                acp_session_id = result["sessionId"]
                await _write(process, {
                    "jsonrpc": "2.0", "id": 3, "method": "session/prompt",
                    "params": {
                        "sessionId": acp_session_id,
                        "prompt": [{"type": "text", "text": text}, *input_blocks],
                    },
                })
                prompt_sent = True
                yield {"type": "accepted", "agent": agent.display_name}
                yield {"type": "work", "step": _work(
                    "reasoning", "reasoning_summary", "running",
                    "Understanding the request",
                )}
                continue
            if message.get("method") == "session/request_permission" and "id" in message:
                params = message.get("params")
                tool = params.get("toolCall") if isinstance(params, dict) else {}
                title = _safe_title(tool.get("title") if isinstance(tool, dict) else None, "Approval required")
                yield {"type": "work", "step": _work(
                    "approval:host", "approval", "waiting", title,
                    detail="Approval is required on the OpenClaw host.",
                )}
                await _write(process, {
                    "jsonrpc": "2.0", "id": message["id"],
                    "result": {"outcome": {"outcome": "cancelled"}},
                })
                continue
            if "id" in message and isinstance(message.get("method"), str):
                await _write(process, {
                    "jsonrpc": "2.0", "id": message["id"],
                    "error": {"code": -32601, "message": "Method not supported"},
                })
                continue
            if message.get("method") == "session/update":
                params = message.get("params")
                update = params.get("update") if isinstance(params, dict) else None
                projected = project_update(update, agent.workspace, tool_titles)
                if projected is None:
                    continue
                projected_kind, payload = projected
                if projected_kind == "text_chunk":
                    if not response_started:
                        response_started = True
                        yield {"type": "work", "step": _work(
                            "reasoning", "reasoning_summary", "completed",
                            "Request understood",
                        )}
                        yield {"type": "work", "step": _work(
                            "response", "status", "running",
                            "Preparing the response",
                        )}
                    raw_reply = (raw_reply + str(payload))[-(MAX_REPLY_CHARS * 2):]
                    reply = _safe_text(raw_reply, MAX_REPLY_CHARS)
                    yield {"type": "text", "text": reply}
                elif projected_kind == "plan":
                    for step in payload:
                        if work_updates >= MAX_WORK_UPDATES:
                            break
                        work_steps[step["step_id"]] = step
                        work_updates += 1
                        yield {"type": "work", "step": step}
                elif projected_kind == "work" and work_updates < MAX_WORK_UPDATES:
                    step = payload
                    if len(work_steps) < MAX_WORK_STEPS or step["step_id"] in work_steps:
                        work_steps[step["step_id"]] = step
                        work_updates += 1
                        yield {"type": "work", "step": step}
                if isinstance(update, dict):
                    for location in (update.get("locations") or [])[:8]:
                        if isinstance(location, dict) and isinstance(location.get("path"), str):
                            artifact_candidates.append(location["path"])
                continue
            if message.get("id") == 3:
                if not prompt_sent or "error" in message:
                    raise OpenClawACPError("OpenClaw could not complete this turn.")
                result = message.get("result")
                if not isinstance(result, dict) or result.get("stopReason") != "end_turn":
                    raise OpenClawACPError("OpenClaw stopped before completing this turn.")
                if not reply:
                    reply = "OpenClaw completed the turn without a text reply."
                for candidate in dict.fromkeys(artifact_candidates):
                    attachment = _artifact(candidate, agent.workspace)
                    if attachment:
                        yield {"type": "attachment", "attachment": attachment}
                yield {"type": "work", "step": _work(
                    "response", "status", "completed",
                    "Response ready",
                )}
                yield {"type": "complete", "text": reply}
                return
    except asyncio.CancelledError:
        if acp_session_id:
            try:
                await _write(process, {
                    "jsonrpc": "2.0", "method": "session/cancel",
                    "params": {"sessionId": acp_session_id},
                })
            except (OSError, OpenClawACPError):
                pass
        raise
    finally:
        if process.stdin:
            process.stdin.close()
        if process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
        stderr_task.cancel()
