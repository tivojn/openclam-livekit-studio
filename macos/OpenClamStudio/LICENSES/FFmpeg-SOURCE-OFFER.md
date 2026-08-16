# FFmpeg corresponding source

OpenClam Studio ships an unmodified, minimal FFmpeg 7.1.5 executable under
the GNU Lesser General Public License, version 2.1 or later. The release build
uses the official archive below and accepts it only when its SHA-256 matches.

- Source archive: `ffmpeg-7.1.5.tar.xz`
- Official source: https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz
- SHA-256: `de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`
- Build recipe: `scripts/stage-electron-ffmpeg.sh` in the corresponding
  OpenClam Studio source release
- License text in the installed app:
  `backend/bin/LICENSE.LGPLv2.1.txt`

Every OpenClam Studio binary release must attach
`OpenClam-Studio-FFmpeg-7.1.5-Source.tar.xz` and its SHA-256 sidecar as release
assets. `scripts/prepare-ffmpeg-source-release-asset.sh` prepares those files
without building or modifying FFmpeg.

The project will keep this exact corresponding source available at no charge
for at least three years after each binary release. If a release asset becomes
unavailable, request it by opening an issue at
https://github.com/tivojn/openclam-livekit-studio/issues and identify the
OpenClam Studio version and FFmpeg 7.1.5. The source will be provided at no
more than the reasonable cost of physically performing source distribution.
