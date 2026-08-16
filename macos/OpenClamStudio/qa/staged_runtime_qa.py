#!/usr/bin/env python3
"""Smoke the exact Python/native/model tree staged for Electron."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parents[1]).resolve()
PYTHON_RUNTIME = ROOT / ".electron-python-runtime"
PYTHON = PYTHON_RUNTIME / "bin/python"
SITE_PACKAGES = ROOT / ".electron-site-packages"
MODELS = ROOT / ".electron-models"
FFMPEG = ROOT / ".electron-ffmpeg/ffmpeg"
CUTOUT = ROOT / ".electron-native/person-cutout"
NATIVE_PATH_AUDIT = ROOT / "scripts/audit-native-build-paths.py"

for required in (PYTHON, FFMPEG, CUTOUT):
    if not required.is_file() or not os.access(required, os.X_OK):
        raise SystemExit(f"staged executable is missing: {required}")
if not SITE_PACKAGES.is_dir() or not MODELS.is_dir():
    raise SystemExit("staged Python packages or models are missing")

native_path_audit = subprocess.run(
    [
        sys.executable,
        str(NATIVE_PATH_AUDIT),
        str(FFMPEG),
        str(SITE_PACKAGES / "cv2"),
        str(CUTOUT),
    ],
    capture_output=True,
    text=True,
    timeout=60,
)
if native_path_audit.returncode:
    raise SystemExit(
        (native_path_audit.stderr or native_path_audit.stdout or "native path audit failed")[-4000:]
    )
print(native_path_audit.stdout.strip())


def generated_bytecode(root: Path) -> list[Path]:
    return [
        path.relative_to(root)
        for path in root.rglob("*")
        if path.name == "__pycache__"
        or (path.is_file() and path.suffix.lower() in {".pyc", ".pyo"})
    ]


def contains_bytes(path: Path, needle: bytes) -> bool:
    overlap = max(0, len(needle) - 1)
    tail = b""
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            data = tail + chunk
            if needle in data:
                return True
            tail = data[-overlap:] if overlap else b""
    return False


def require_clean_tree(label: str, root: Path) -> None:
    bytecode = generated_bytecode(root)
    if bytecode:
        sample = ", ".join(str(path) for path in bytecode[:5])
        raise SystemExit(
            f"{label} contains generated Python bytecode "
            f"({len(bytecode)} paths; first: {sample})"
        )
    private_home = str(Path.home()).encode()
    private_matches = [
        path.relative_to(root)
        for path in root.rglob("*")
        if path.is_file() and contains_bytes(path, private_home)
    ]
    if private_matches:
        sample = ", ".join(str(path) for path in private_matches[:5])
        raise SystemExit(
            f"{label} embeds the build user's private home path "
            f"({len(private_matches)} files; first: {sample})"
        )


for tree_label, tree in (
    ("staged Python runtime", PYTHON_RUNTIME),
    ("staged Python dependencies", SITE_PACKAGES),
):
    require_clean_tree(tree_label, tree)

environment = {
    **os.environ,
    "HF_HUB_OFFLINE": "1",
    "OPENCLAM_NO_RVM": "1",
    "OPENCLAM_PACKAGED": "0",
    "PYTHONDONTWRITEBYTECODE": "1",
    "PYTHONPATH": os.pathsep.join((str(SITE_PACKAGES), str(ROOT / "server"))),
    "TOKENIZERS_PARALLELISM": "false",
    "TRANSFORMERS_OFFLINE": "1",
    "PATH": os.pathsep.join((str(FFMPEG.parent), "/usr/bin", "/bin")),
}

probe = r"""
import encodings
import importlib.util
import json
from pathlib import Path
import site
import ssl
import sys

import cv2
import edge_tts
import fastapi
import httpx
import mediapipe
import mlx
import mlx_whisper
import numpy
import scipy
import soundfile
import uvicorn
import websockets

import credentials
import providers

if importlib.util.find_spec("torch") is not None:
    raise AssertionError("PyTorch must not be redistributed")
if importlib.util.find_spec("kokoro") is not None:
    raise AssertionError("Kokoro/GPL dependencies must not be redistributed")
credential_source = Path(credentials.__file__).read_text(encoding="utf-8")
if "import subprocess" in credential_source or '\"/usr/bin/security\"' in credential_source:
    raise AssertionError("staged credential vault contains a command-line Keychain path")
if credentials.STORAGE_ACCOUNT_PREFIX != "openclam-v2:":
    raise AssertionError("staged credential vault lacks the isolated v2 account namespace")
credentials._MacKeychain()
model = Path(providers.resolve_mlx_whisper_model())
if model.name != providers.MLX_WHISPER_MODEL_DIR:
    raise AssertionError("offline Whisper resolved outside its pinned bundle")
face = Path(sys.argv[1])
if not face.is_file():
    raise AssertionError("MediaPipe face model is missing")
print("staged Python, model, and native runtime QA passed")
"""

result = subprocess.run(
    [str(PYTHON), "-B", "-c", probe, str(MODELS / "face_landmarker.task")],
    cwd=ROOT,
    env=environment,
    capture_output=True,
    text=True,
    timeout=180,
)
for tree_label, tree in (
    ("staged Python runtime after smoke test", PYTHON_RUNTIME),
    ("staged Python dependencies after smoke test", SITE_PACKAGES),
):
    require_clean_tree(tree_label, tree)
if result.returncode:
    raise SystemExit((result.stderr or result.stdout or "staged runtime probe failed")[-4000:])
print(result.stdout.strip())
