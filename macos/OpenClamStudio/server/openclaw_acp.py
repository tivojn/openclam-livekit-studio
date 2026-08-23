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
ALLOWED_ARTIFACT_SUFFIXES = {
    ".csv", ".gif", ".jpeg", ".jpg", ".md", ".mov", ".mp4", ".pdf",
    ".png", ".ppt", ".pptx", ".txt", ".webp", ".xls", ".xlsx", ".zip",
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
        title = _safe_title(update.get("title"), "Using a tool")
        if call_id:
            tool_titles[call_id] = title
        return ("work", _work(
            f"tool:{call_id or hashlib.sha256(title.encode()).hexdigest()[:16]}",
            "tool", _state(update.get("status")), title,
            tool=_safe_text(update.get("kind"), 80),
        ))
    if kind == "tool_call_update":
        call_id = _safe_text(update.get("toolCallId"), 64)
        title = tool_titles.get(call_id, "Updating a tool")
        return ("work", _work(
            f"tool:{call_id or hashlib.sha256(title.encode()).hexdigest()[:16]}",
            "tool", _state(update.get("status")), title,
            tool=_safe_text(update.get("kind"), 80),
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
    size = os.path.getsize(candidate)
    if size <= 0 or size > MAX_ARTIFACT_BYTES:
        return None
    handle = secrets.token_urlsafe(18)
    while len(_ARTIFACTS) >= MAX_ARTIFACT_HANDLES:
        _ARTIFACTS.popitem(last=False)
    _ARTIFACTS[handle] = candidate
    return {
        "url": f"api/openclaw/artifacts/{handle}",
        "name": os.path.basename(candidate)[:160],
        "media_type": mimetypes.guess_type(candidate)[0] or "application/octet-stream",
        "byte_count": size,
    }


def artifact_path(handle: str) -> str | None:
    if not re.fullmatch(r"[A-Za-z0-9_-]{20,32}", handle):
        return None
    path = _ARTIFACTS.get(handle)
    if not path or not os.path.isfile(path):
        _ARTIFACTS.pop(handle, None)
        return None
    _ARTIFACTS.move_to_end(handle)
    return path


async def _write(process: asyncio.subprocess.Process, value: dict) -> None:
    if process.stdin is None:
        raise OpenClawACPError("OpenClaw connection closed.")
    encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
    process.stdin.write(encoded)
    await process.stdin.drain()


async def stream_turn(agent_id: str, session_id: str, prompt: str) -> AsyncIterator[dict]:
    if SESSION_ID.fullmatch(session_id) is None:
        raise OpenClawACPError("Start a fresh OpenClaw chat.")
    text = prompt.strip()
    if not text or len(text) > 12_000 or CONTROL.search(text):
        raise OpenClawACPError("Enter a shorter plain-text message.")
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
                "clientInfo": {"name": "OpenClam Studio", "version": "1.0.3"},
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
                        "prompt": [{"type": "text", "text": text}],
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
