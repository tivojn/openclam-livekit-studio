#!/usr/bin/env python3
"""Run real offline PTT through the exact runtime inside a packaged app."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


if len(sys.argv) != 2:
    raise SystemExit("usage: packaged_runtime_qa.py /path/to/OpenClam Studio.app")

APP = Path(sys.argv[1]).resolve()
RESOURCES = APP / "Contents/Resources"
APP_ASAR = RESOURCES / "app.asar"
PYTHON = RESOURCES / "python/bin/python"
SITE_PACKAGES = RESOURCES / "python/lib/python3.12/site-packages"
BACKEND = RESOURCES / "backend"
FFMPEG_DIR = BACKEND / "bin"
MODELS = BACKEND / "models"
CUTOUT = RESOURCES / "native/person-cutout"
NATIVE_PATH_AUDIT = Path(__file__).resolve().parent.parent / "scripts/audit-native-build-paths.py"

if not APP_ASAR.is_file():
    raise SystemExit(f"packaged Electron archive is missing: {APP_ASAR}")
for required in (PYTHON, FFMPEG_DIR / "ffmpeg", CUTOUT):
    if not required.is_file() or not os.access(required, os.X_OK):
        raise SystemExit(f"packaged executable is missing: {required}")
if not SITE_PACKAGES.is_dir() or not (MODELS / "face_landmarker.task").is_file():
    raise SystemExit("packaged Python dependencies or models are missing")

native_path_audit = subprocess.run(
    [
        sys.executable,
        str(NATIVE_PATH_AUDIT),
        str(FFMPEG_DIR / "ffmpeg"),
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


def require_clean_packaged_asar() -> None:
    """Reject test assets while proving preserved JavaScript runtime imports."""

    project = Path(__file__).resolve().parent.parent
    asar_module = project / "node_modules/@electron/asar"
    node = shutil.which("node")
    if node is None or not asar_module.is_dir():
        raise SystemExit("packaged ASAR QA requires Node.js and @electron/asar")

    probe = r"""
const path = require('node:path');
const { createRequire } = require('node:module');
const asar = require(process.argv[2]);
const archive = process.argv[3];
const extracted = process.argv[4];
const entries = asar.listPackage(archive);
const entrySet = new Set(entries);

function atOrBelow(entry, root) {
  return entry === root || entry.startsWith(`${root}/`);
}

const forbidden = entries.filter((entry) => (
  atOrBelow(entry, '/node_modules/livekit-client/src/test')
  || (
    entry.startsWith('/node_modules/livekit-client/src/')
    && (entry.includes('/__snapshots__/') || entry.endsWith('.test.ts'))
  )
  || entry === '/node_modules/livekit-client/src/room/token-source/test-tokens.ts'
  || atOrBelow(entry, '/node_modules/livekit-client/dist/src/test')
  || atOrBelow(entry, '/node_modules/livekit-client/dist/ts4.2/test')
  || entry === '/node_modules/@livekit/mutex/src/index.test.ts'
  || entry === '/node_modules/@livekit/mutex/dist/index.test.d.ts'
  || entry === '/node_modules/@livekit/mutex/dist/index.test.d.ts.map'
));
if (forbidden.length) {
  throw new Error(`packaged ASAR contains test-only artifacts: ${forbidden.slice(0, 12).join(', ')}`);
}

const required = [
  '/electron/main.cjs',
  '/package.json',
  '/node_modules/livekit-client/package.json',
  '/node_modules/livekit-client/dist/livekit-client.umd.js',
  '/node_modules/@livekit/mutex/package.json',
  '/node_modules/@livekit/mutex/dist/index.js',
  '/node_modules/rxjs/package.json',
  '/node_modules/rxjs/dist/cjs/index.js',
  '/node_modules/rxjs/dist/cjs/testing/index.js',
  '/node_modules/rxjs/testing/package.json',
];
const missing = required.filter((entry) => !entrySet.has(entry));
if (missing.length) {
  throw new Error(`packaged ASAR is missing runtime files: ${missing.join(', ')}`);
}

asar.extractAll(archive, extracted);
const packedRequire = createRequire(path.join(extracted, 'package.json'));
const livekit = packedRequire('livekit-client');
const mutex = packedRequire('@livekit/mutex');
const rxjsTesting = packedRequire('rxjs/testing');
if (typeof livekit.Room !== 'function') {
  throw new Error('packaged livekit-client import lacks Room');
}
if (typeof mutex.Mutex !== 'function') {
  throw new Error('packaged @livekit/mutex import lacks Mutex');
}
if (typeof rxjsTesting.TestScheduler !== 'function') {
  throw new Error('packaged rxjs/testing import lacks TestScheduler');
}
console.log('packaged ASAR dependency QA passed');
"""

    with tempfile.TemporaryDirectory(prefix="openclam-packaged-asar-") as extracted:
        result = subprocess.run(
            [node, "-", str(asar_module), str(APP_ASAR), extracted],
            input=probe,
            capture_output=True,
            text=True,
            timeout=60,
        )
    if result.returncode:
        raise SystemExit(
            (result.stderr or result.stdout or "packaged ASAR dependency QA failed")[-4000:]
        )
    print(result.stdout.strip())


require_clean_packaged_asar()

# Keep package-time diagnostics and dependency test suites out of the signed
# application. The names below are deliberately explicit: broad `*_test.py`
# or `testing/**` rules would remove scipy.stats runtime implementations and
# NumPy's public testing helpers, both of which SciPy imports in production.
FORBIDDEN_PACKAGED_TEST_ARTIFACTS = (
    BACKEND / "studio/blink_qa.py",
    BACKEND / "studio/life_qa.py",
    SITE_PACKAGES / "absl/testing",
    SITE_PACKAGES / "aiohttp/pytest_plugin.py",
    SITE_PACKAGES / "aiohttp/test_utils.py",
    SITE_PACKAGES / "annotated_types/test_cases.py",
    SITE_PACKAGES / "click/testing.py",
    SITE_PACKAGES / "anyio/pytest_plugin.py",
    SITE_PACKAGES / "fsspec/conftest.py",
    SITE_PACKAGES / "matplotlib/testing",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/bundler/llm_bundler_metadata_options_test.py",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/converter/llm_converter_test.py",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/converter/pytorch_converter_test.py",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/converter/quantization_util_test.py",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/converter/safetensors_converter_test.py",
    SITE_PACKAGES / "mediapipe/tasks/python/genai/converter/weight_bins_writer_test.py",
    SITE_PACKAGES / "networkx/conftest.py",
    SITE_PACKAGES / "numba/core/datamodel/testing.py",
    SITE_PACKAGES / "numba/cuda/testing.py",
    SITE_PACKAGES / "numba/runtests.py",
    SITE_PACKAGES / "numba/testing",
    SITE_PACKAGES / "numpy/conftest.py",
    SITE_PACKAGES / "scipy/conftest.py",
    SITE_PACKAGES / "setuptools/command/test.py",
    SITE_PACKAGES / "sympy/conftest.py",
    SITE_PACKAGES / "sympy/testing",
    SITE_PACKAGES / "sympy/utilities/pytest.py",
    SITE_PACKAGES / "sympy/utilities/runtests.py",
    SITE_PACKAGES / "sympy/utilities/tmpfiles.py",
)
present_test_artifacts = [
    path.relative_to(RESOURCES)
    for path in FORBIDDEN_PACKAGED_TEST_ARTIFACTS
    if path.exists()
]
if present_test_artifacts:
    sample = ", ".join(str(path) for path in present_test_artifacts[:8])
    raise SystemExit(f"packaged app contains test-only artifacts: {sample}")

for pattern in ("numpy/_core/*_tests.cpython-*.so", "scipy/**/_test*.cpython-*.so"):
    matches = sorted(path.relative_to(SITE_PACKAGES) for path in SITE_PACKAGES.glob(pattern))
    if matches:
        sample = ", ".join(str(path) for path in matches[:8])
        raise SystemExit(f"packaged app contains native test artifacts: {sample}")

REQUIRED_RUNTIME_TEST_NAMED_MODULES = (
    SITE_PACKAGES / "anyio/_core/_testing.py",
    SITE_PACKAGES / "jinja2/tests.py",
    SITE_PACKAGES / "numpy/testing/__init__.py",
    SITE_PACKAGES / "pyparsing/testing.py",
    SITE_PACKAGES / "scipy/_external/array_api_extra/testing.py",
    SITE_PACKAGES / "scipy/_lib/_testutils.py",
    SITE_PACKAGES / "scipy/stats/_bws_test.py",
    SITE_PACKAGES / "scipy/stats/_page_trend_test.py",
)
missing_runtime_modules = [
    path.relative_to(SITE_PACKAGES)
    for path in REQUIRED_RUNTIME_TEST_NAMED_MODULES
    if not path.is_file()
]
if missing_runtime_modules:
    sample = ", ".join(str(path) for path in missing_runtime_modules)
    raise SystemExit(f"packaged runtime module was over-pruned: {sample}")


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


def require_clean_packaged_python(label: str) -> None:
    bytecode = generated_bytecode(RESOURCES / "python")
    if bytecode:
        sample = ", ".join(str(path) for path in bytecode[:5])
        raise SystemExit(
            f"{label} contains generated Python bytecode "
            f"({len(bytecode)} paths; first: {sample})"
        )
    private_home = str(Path.home()).encode()
    private_matches = [
        path.relative_to(RESOURCES / "python")
        for path in (RESOURCES / "python").rglob("*")
        if path.is_file() and contains_bytes(path, private_home)
    ]
    if private_matches:
        sample = ", ".join(str(path) for path in private_matches[:5])
        raise SystemExit(
            f"{label} embeds the build user's private home path "
            f"({len(private_matches)} files; first: {sample})"
        )


require_clean_packaged_python("packaged Python runtime")

environment = {
    **os.environ,
    "HF_HUB_OFFLINE": "1",
    "OPENCLAM_NO_RVM": "1",
    "OPENCLAM_PACKAGED": "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "PYTHONPATH": os.pathsep.join((str(SITE_PACKAGES), str(BACKEND / "server"))),
    "TOKENIZERS_PARALLELISM": "false",
    "TRANSFORMERS_OFFLINE": "1",
    "PATH": os.pathsep.join((str(FFMPEG_DIR), "/usr/bin", "/bin")),
}

probe = r"""
import asyncio
import encodings
import importlib.util
import json
from pathlib import Path
import re
import site
import ssl
import sys

import cv2
import fastapi
import httpx
import mediapipe
import mlx_whisper
import scipy.stats
import soundfile
import uvicorn
import credentials
import providers

if importlib.util.find_spec("torch") is not None:
    raise AssertionError("packaged runtime unexpectedly contains PyTorch")
if not callable(scipy.stats.bws_test) or not callable(scipy.stats.page_trend_test):
    raise AssertionError("packaged SciPy runtime lost test-named statistical APIs")
credential_source = Path(credentials.__file__).read_text(encoding="utf-8")
if "import subprocess" in credential_source or '\"/usr/bin/security\"' in credential_source:
    raise AssertionError("packaged credential vault contains a command-line Keychain path")
if credentials.STORAGE_ACCOUNT_PREFIX != "openclam-v2:":
    raise AssertionError("packaged credential vault lacks the isolated v2 account namespace")
credentials._MacKeychain()
if providers.spec("tts", "kokoro") is not None:
    raise AssertionError("packaged runtime advertises unbundled Kokoro")
if any(row["id"] == "kokoro" for row in providers.catalog()["tts"]):
    raise AssertionError("packaged TTS catalog exposes unbundled Kokoro")
raw = Path(sys.argv[1]).read_bytes()
config = dict(providers.DEFAULTS["stt"])
text = asyncio.run(providers._hear_direct(raw, "known.aiff", config))
normalized = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
if "open clam" not in normalized or "entirely offline" not in normalized:
    raise AssertionError(f"offline PTT transcript mismatch: {text!r}")
print(text)
"""

with tempfile.TemporaryDirectory(prefix="openclam-packaged-ptt-") as temporary:
    audio = Path(temporary) / "known.aiff"
    spoken = "Open Clam can hear this sentence entirely offline."
    say = subprocess.run(
        ["/usr/bin/say", "-v", "Samantha", "-o", str(audio), spoken],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if say.returncode or not audio.is_file():
        raise SystemExit((say.stderr or "macOS could not create the PTT fixture")[-2000:])
    result = subprocess.run(
        [str(PYTHON), "-B", "-c", probe, str(audio)],
        cwd=BACKEND,
        env=environment,
        capture_output=True,
        text=True,
        timeout=300,
    )

require_clean_packaged_python("packaged Python runtime after offline PTT")
if result.returncode:
    raise SystemExit((result.stderr or result.stdout or "packaged PTT probe failed")[-4000:])
print(f"packaged offline PTT QA passed: {result.stdout.strip()}")
