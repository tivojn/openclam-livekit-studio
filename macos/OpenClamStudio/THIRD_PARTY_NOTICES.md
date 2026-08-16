# Third-party notices

OpenClam Studio uses the software and model assets described below. Each
component remains governed by its own license and, where applicable, service
terms. This notice describes the packaged macOS application, not the broader
source-development environment.

## OpenClam and avatar runtime

The application and adapted OpenClam/avatar-runtime sources are MIT licensed.
The retained copyright notices and MIT terms are in `LICENSE`.

## Electron, Chromium, Node.js, and Python 3.12

Electron 43.4.0, its Chromium and Node.js components, and their generated
license inventory ship inside the Electron framework. The embedded Python
3.12 runtime retains its `LICENSE.txt` in the packaged `python` directory.

- Electron: https://github.com/electron/electron
- Python: https://www.python.org/

## LiveKit client 2.21.0

The renderer ships the published `livekit-client` 2.21.0 UMD bundle. LiveKit's
client SDK is Apache-2.0 licensed. The release build reads the publisher's UMD
source map, rejects any unreviewed dependency name or version, checks the
publisher license-file hashes, and generates these packaged files:

- `docs/LICENSES/LIVEKIT_CLIENT_APACHE-2.0.txt`
- `docs/LICENSES/LIVEKIT_UMD_BUNDLED_LICENSES.txt`
- `docs/LICENSES/LIVEKIT_UMD_MANIFEST.json`

The checked bundle covers `@bufbuild/protobuf`, `@livekit/mutex`,
`@livekit/protocol`, `events`, `jose`, `loglevel`, `sdp`, `sdp-transform`,
`tslib`, `typed-emitter`, and `webrtc-adapter`. It includes the Apache-2.0,
BSD, MIT, and 0BSD texts and attributions applicable to those components.
Packages declared by LiveKit but not retained as distinct source-map paths are
included conservatively.

- Project: https://github.com/livekit/client-sdk-js
- Lock: `package-lock.json`

## FFmpeg 7.1.5 (LGPL-2.1-or-later)

The macOS app builds an unmodified FFmpeg 7.1.5 command-line executable from
official, checksum-pinned source. The build disables autodetection, networking,
documentation, debug facilities, and everything not explicitly required. It
does not enable GPL or nonfree mode and links only to Apple system libraries.
The release gate checks the reported license, configuration, component
allowlist, architecture, deployment target, and dynamic dependencies.

- Source: https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz
- SHA-256: `de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`
- License in the app: `backend/bin/LICENSE.LGPLv2.1.txt`
- Corresponding-source offer in the app:
  `docs/LICENSES/FFmpeg-SOURCE-OFFER.md`

Every binary release must attach the exact source archive as
`OpenClam-Studio-FFmpeg-7.1.5-Source.tar.xz` plus its SHA-256 sidecar. The
source tree's `scripts/prepare-ffmpeg-source-release-asset.sh` prepares those
assets without building or modifying FFmpeg. The written offer keeps the exact
corresponding source available for at least three years after each binary
release.

## OpenCV 4.12.0 and bundled image codecs

The packaged `cv2` module is not the prebuilt `opencv-contrib-python` wheel.
That wheel remains in `requirements-electron.lock` only to resolve the Python
dependency graph; staging removes its module and distribution metadata, then
builds OpenCV 4.12.0 from checksum-pinned official source.

- Source: https://github.com/opencv/opencv/archive/refs/tags/4.12.0.tar.gz
- SHA-256: `44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d`
- OpenCV license: Apache License 2.0

The custom Apple-silicon build contains only `core`, `imgproc`, `imgcodecs`,
`video`, `videoio`, `photo`, `calib3d`, `features2d`, and Python bindings.
OpenCV nonfree modules, FFmpeg, GStreamer, IPP, TIFF, WebP, OpenEXR, OpenCL,
and other unused integrations are disabled. AVFoundation is the only enabled
video backend. The build statically includes OpenCV's pinned libjpeg-turbo,
libpng, OpenJPEG, and zlib copies. Their complete terms and required IJG
attribution ship as:

- `docs/LICENSES/OPENCV_BUNDLED_CODEC_LICENSES.txt`

The app also retains the OpenCV Apache license at `python/.../cv2/LICENSE.txt`.

## MediaPipe and Face Landmarker

The app packages MediaPipe 0.10.35 and Google's Face Landmarker float16 model.
The build accepts the model only when its SHA-256 matches the pinned value and
bundles it for offline use; the installed app does not download it on first
portrait use.

- MediaPipe: https://github.com/google-ai-edge/mediapipe
- Model: https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
- Model SHA-256: `64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff`
- MediaPipe license: Apache License 2.0

The package retains MediaPipe's Apache-2.0 text beside the model and in its
Python distribution metadata. Use of the separately published model remains
subject to Google's applicable terms.

## MLX Whisper and the bundled Whisper Small model

The app packages MLX/MLX Metal 0.32.0, `mlx-whisper` 0.4.3, and one
multilingual, quantized Whisper Small model for offline push-to-talk. The build
fetches the model only from the immutable MLX Community revision below,
verifies every accepted file against the checked manifest, and bundles it.
The installed application has no speech-model download fallback.

- Model repository: https://huggingface.co/mlx-community/whisper-small-mlx-4bit
- Immutable revision: `f1da4c67f2ee8b6e763b974e149aa65d5b7658b7`
- `config.json` SHA-256:
  `d414b27f911c1c416a90525a0f856e0dc1c9e38632a833ca8dd05c58b3d8a01a`
- `weights.npz` SHA-256:
  `ca6659298fe7550468ff0fc49dea7442615d9a53d1ce087aaded1b7627451998`
- Whisper license source revision:
  `e58f28804528831904c3b6f2c0e473f346223433`
- Bundled Whisper MIT license SHA-256:
  `b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d`
- Whisper project: https://github.com/openai/whisper
- MLX Whisper project: https://github.com/ml-explore/mlx-examples/tree/main/whisper

The conversion repository identifies the asset as an MLX conversion of
Whisper Small but does not publish separate license metadata in its model card.
The upstream Whisper project is MIT licensed. Redistribution remains subject
to the upstream project and model-repository terms.

## Packaged Python dependencies

The exact packaged dependency resolution is hash-locked in
`requirements-electron.lock`, derived from `requirements-electron.txt`.
Direct runtime components include FastAPI, Uvicorn, python-multipart,
Pydantic, HTTPX, NumPy, SciPy, SoundFile, Pillow, MediaPipe, MLX, MLX Metal,
MLX Whisper, Edge TTS, WebSockets, and the custom OpenCV build described
above. Their transitive dependencies are also fixed by that lock.

Publisher-supplied `.dist-info` metadata, license directories, notices, and
third-party inventories remain in the packaged `site-packages` where supplied.
SciPy 1.18.0's retained inventory covers its bundled `libgfortran`, `libgcc_s`,
and `libquadmath` libraries, including the GPLv3 GCC Runtime Library Exception
and libquadmath LGPL terms. Pillow 12.3.0 retains its license inventory and
CycloneDX software bill of materials for its bundled codec/font libraries.
Edge TTS 7.2.8 is predominantly LGPLv3 (with its SRT composer under MIT); its
Python source and complete combined license text both ship in the app.

`requirements-electron.lock` contains a PyTorch resolution used only while
assembling the upstream MLX Whisper dependency graph. The packaging step
deletes `torch`, `functorch`, `torchgen`, Torch distribution metadata, headers,
and binaries, and the release gate proves they are absent. Kokoro, Misaki,
eSpeak NG, spaCy, and `en_core_web_sm` are likewise not redistributed in the
macOS application. They may appear in separate source-development requirement
files, which do not describe the packaged runtime.

Cloud-backed providers such as Edge TTS and user-selected model or media
services have service terms separate from their client-library software
licenses. Users are responsible for the terms of services they choose and the
content they submit.
