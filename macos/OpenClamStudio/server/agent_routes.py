"""Authenticated app-local agent routes; mounted behind Studio's middleware."""
import asyncio
import json
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request, UploadFile, File
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from pydantic import BaseModel, Field

try:
    from .agent_workspace import Workspace, AgentError
except ImportError:
    from agent_workspace import Workspace, AgentError


class CreateTask(BaseModel):
    cwd: str = Field(default="", max_length=4096)
    title: str = Field(default="New task", max_length=120)
    model: str | None = Field(default=None, max_length=120)
    effort: str | None = Field(default=None, max_length=30)
    access: str = "workspaceWrite"
    permission: str | None = Field(default=None, max_length=30)


class SendTask(BaseModel):
    prompt: str = Field(min_length=1, max_length=100000)
    model: str | None = Field(default=None, max_length=120)
    effort: str | None = Field(default=None, max_length=30)
    attachments: list[str] = Field(default_factory=list, max_length=8)
    permission: str | None = Field(default=None, max_length=30)


class TaskSettings(BaseModel):
    model: str | None = Field(default=None, max_length=120)
    effort: str | None = Field(default=None, max_length=30)
    permission: str | None = Field(default=None, max_length=30)


class TaskAction(BaseModel):
    action: str
    title: str = Field(default="", max_length=120)


class AnswerRequest(BaseModel):
    decision: str = Field(default="", max_length=30)
    answers: dict[str, str] | None = None


def make_router(data_root, web):
    router = APIRouter()
    instance = None

    def workspace():
        nonlocal instance
        if instance is None:
            instance = Workspace(data_root)
        instance.last_used = time.monotonic()
        return instance

    async def close():
        nonlocal instance
        if instance:
            await instance.close()
            instance = None

    async def invoke(fn, *args, **kwargs):
        try:
            result = fn(*args, **kwargs)
            return await result if asyncio.iscoroutine(result) else result
        except (AgentError, OSError, ValueError) as error:
            raise HTTPException(409, str(error)[:1500]) from error

    @router.get("/tasks")
    async def page():
        return HTMLResponse((Path(web) / "tasks.html").read_text())

    @router.get("/tasks/{asset}")
    async def asset(asset: str):
        if asset not in {"tasks.js", "tasks.css"}:
            raise HTTPException(404)
        return FileResponse(Path(web) / asset, media_type="application/javascript" if asset.endswith(".js") else "text/css")

    @router.get("/api/agent/status")
    async def status():
        return await invoke(workspace().status)

    @router.get("/api/agent/tasks")
    async def tasks():
        return {"tasks": workspace().list()}

    @router.post("/api/agent/tasks")
    async def create(body: CreateTask):
        return await invoke(workspace().create, **body.model_dump())

    @router.get("/api/agent/tasks/{identity}")
    async def read(identity: str):
        return await invoke(workspace().snapshot, identity)

    @router.post("/api/agent/tasks/{identity}/send")
    async def send(identity: str, body: SendTask):
        return await invoke(workspace().send, identity, **body.model_dump())

    @router.post("/api/agent/tasks/{identity}/action")
    async def action(identity: str, body: TaskAction):
        return await invoke(workspace().action, identity, **body.model_dump())

    @router.post("/api/agent/tasks/{identity}/settings")
    async def settings(identity: str, body: TaskSettings):
        return await invoke(workspace().settings, identity, **body.model_dump())

    @router.post("/api/agent/tasks/{identity}/attachments")
    async def attach(identity: str, file: UploadFile = File(...)):
        await invoke(workspace().get, identity)
        try:
            content = await file.read(20 * 1024 * 1024 + 1)
            return await invoke(workspace().attach, identity, file.filename or "attachment", content)
        finally:
            await file.close()

    @router.post("/api/agent/tasks/{identity}/requests/{key}")
    async def answer(identity: str, key: str, body: AnswerRequest):
        return await invoke(workspace().answer, identity, key, **body.model_dump())

    @router.get("/api/agent/tasks/{identity}/capabilities")
    async def capabilities(identity: str):
        return await invoke(workspace().capabilities, identity)

    @router.get("/api/agent/tasks/{identity}/files")
    async def files(identity: str, path: str = ""):
        return {"files": await invoke(workspace().files, identity, path)}

    @router.get("/api/agent/tasks/{identity}/file")
    async def file(identity: str, path: str):
        resolved = await invoke(workspace().file, identity, path)
        # Always download user-created HTML/SVG, never execute it in Studio's
        # privileged origin. The UI previews text with textContent only.
        return FileResponse(resolved, media_type="application/octet-stream", filename=resolved.name)

    @router.get("/api/agent/tasks/{identity}/events")
    async def events(identity: str, request: Request):
        await invoke(workspace().get, identity)
        async def stream():
            # Snapshot first on every connection, including reconnects. This
            # avoids gaps if the bounded journal was compacted while closed.
            state = workspace().snapshot(identity)
            cursor = state["cursor"]
            yield "data: " + json.dumps({"type": "snapshot", **state}) + "\n\n"
            heartbeat = 0
            while not await request.is_disconnected():
                rows = workspace().db.execute("SELECT seq,payload FROM events WHERE task=? AND seq>? ORDER BY seq LIMIT 100", (identity, cursor)).fetchall()
                for seq, payload in rows:
                    cursor = seq
                    yield f"id: {seq}\ndata: {payload}\n\n"
                heartbeat += 1
                if heartbeat % 30 == 0:
                    yield ": connected\n\n"
                await asyncio.sleep(.25 if rows else 1)
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})

    return router, close
