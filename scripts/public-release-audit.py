#!/usr/bin/env python3
"""Fail closed when private, generated, or unreviewed material enters source.

The audit prints rule labels and paths only. It never prints matched content.
Run it from a clean public snapshot before every public commit or release.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


ALLOWED_TOP_LEVEL = {
    ".github",
    ".gitignore",
    "AVATAR_ASSET_LICENSE.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "PRIVACY.md",
    "PUBLIC_RELEASE_CHECKLIST.md",
    "README.md",
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
    "agent",
    "cloudflare-broker",
    "contracts",
    "docs",
    "ios",
    "macos",
    "openclaw-bridge",
    "openclaw-plugin-openclam",
    "scripts",
    "shared",
}

REQUIRED_FILES = {
    Path(".github/workflows/release-feature-guards.yml"),
    Path(".gitignore"),
    Path("AVATAR_ASSET_LICENSE.md"),
    Path("CONTRIBUTING.md"),
    Path("LICENSE"),
    Path("PRIVACY.md"),
    Path("PUBLIC_RELEASE_CHECKLIST.md"),
    Path("README.md"),
    Path("SECURITY.md"),
    Path("THIRD_PARTY_NOTICES.md"),
    Path("agent/pyproject.toml"),
    Path("cloudflare-broker/package-lock.json"),
    Path("cloudflare-broker/package.json"),
    Path("contracts/live-talk-approved-tuples-v1.json"),
    Path("contracts/release-feature-contract-v1.json"),
    Path("docs/OPENCLAW_CONNECTOR_ARCHITECTURE.md"),
    Path("ios/OpenClamLiveKit/OpenClamLiveKit.xcodeproj/project.pbxproj"),
    Path("ios/OpenClamLiveKit/project.yml"),
    Path("macos/OpenClamStudio/package-lock.json"),
    Path("macos/OpenClamStudio/package.json"),
    Path("openclaw-bridge/package-lock.json"),
    Path("openclaw-bridge/package.json"),
    Path("openclaw-plugin-openclam/openclaw.plugin.json"),
    Path("openclaw-plugin-openclam/dist/index.js"),
    Path("openclaw-plugin-openclam/dist/setup-entry.js"),
    Path("openclaw-plugin-openclam/package-lock.json"),
    Path("openclaw-plugin-openclam/package.json"),
    Path("shared/agent-connector-v1/frame.schema.json"),
    Path("shared/agent-connector-v1/pairing.schema.json"),
    Path("shared/avatar-package-v2/fixtures/ios-light-golden.avtr"),
    Path("shared/avatar-package-v2/fixtures/ios-light-motion-v3-golden.avtr"),
}

DENIED_DIR_NAMES = {
    ".git",
    ".electron-ffmpeg",
    ".electron-models",
    ".electron-python-runtime",
    ".mypy_cache",
    ".npm",
    ".pytest_cache",
    ".ruff_cache",
    ".swiftpm",
    ".venv",
    ".wrangler",
    "DerivedData",
    "SourcePackages",
    "__pycache__",
    "acceptance-output",
    "avatars",
    "dist",
    "dist-electron",
    "inbox",
    "models",
    "node_modules",
    "outputs",
    "proof",
    "xcuserdata",
}

DENIED_EXACT_PATHS = {
    Path("agent/livekit.toml"),
    Path("agent/.env.local"),
    Path("cloudflare-broker/.dev.vars"),
    Path("cloudflare-broker/.wrangler/cache/wrangler-account.json"),
    Path("ios/OpenClamLiveKit/Config/LiveTalk.local.xcconfig"),
    Path("macos/OpenClamStudio/config.json"),
}

DENIED_NAMES = {
    ".DS_Store",
    ".env",
    "active.json",
    "backend.log",
    "id_ed25519",
    "id_rsa",
    "wrangler-account.json",
}

DENIED_SUFFIXES = {
    ".avtr",
    ".bak",
    ".cer",
    ".der",
    ".dmg",
    ".gif",
    ".gz",
    ".heic",
    ".icns",
    ".ipa",
    ".jpeg",
    ".jpg",
    ".key",
    ".log",
    ".mobileprovision",
    ".mov",
    ".mp3",
    ".mp4",
    ".p12",
    ".p8",
    ".pem",
    ".pfx",
    ".pkg",
    ".png",
    ".provisionprofile",
    ".pyc",
    ".resultbundle",
    ".task",
    ".tmp",
    ".wav",
    ".webm",
    ".webp",
    ".xcarchive",
    ".xcresult",
    ".xz",
    ".zip",
}

# Every public binary is an explicit path-and-hash decision. Any new image,
# sound, archive, model, or executable must receive a separate rights review.
BRANDING_AND_RUNTIME_BINARY_HASHES = {
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark.png"):
        "5664249068345a2dda0418fbd9e49f9a9f8aa2cad2d58abd19ace390345d0d36",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@2x.png"):
        "fa32905f43136ae871ec7d26402fba5eb030673b11860bce307c9074788dde98",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@2xDark.png"):
        "75c6be2a4468a66798647c6fbde04237f6aa66d9fbfa2d02e79969274a0fe093",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@3x.png"):
        "576766050ea39efa5dec0d6160c66c131b758e9ac3a3b37894e758814b3bb223",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMark@3xDark.png"):
        "f5e46dcdec2da0b490b79ba914f11bb3b7c1c63b61022e6c6ccbc9190123ef89",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/OpenClamMark.imageset/OpenClamMarkDark.png"):
        "a3ac4054d207db07a947c4bd02bdb024823a895531bc6652279d05a1a6feec4b",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/live-talk-connection.wav"):
        "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("macos/OpenClamStudio/assets/icon.icns"):
        "5bec8b8a81778d5713864c32044eb163613d22c91a5eb56f1aa8bb16fecebd3c",
    Path("macos/OpenClamStudio/assets/icon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("macos/OpenClamStudio/assets/live-talk-connection.wav"):
        "471bc3d821be0bffaaddc089347c7006d31215d20ff4d5eb5da2440d67edcea4",
    Path("macos/OpenClamStudio/assets/openclam-app-icon.png"):
        "d1e65d2fa4658d8c13559b78cae3339f3286e4d59433b261148e8f6b1928ec2f",
    Path("macos/OpenClamStudio/electron/tray-icon.png"):
        "b3c4c8feda8e99023280b61e5cf8fbf508c6cf60e51452dc9d5da26332d397c9",
    Path("macos/OpenClamStudio/electron/tray-icon@2x.png"):
        "e1c524968ad7b7252f462143b95f0764668370dcfb04da240b2b2f7aac80f712",
    Path("macos/OpenClamStudio/electron/tray-icon@3x.png"):
        "f7c01e384bb20625640b18fb2ba83ee3f0b8e75e5f31bb65c5933c86e9303e3b",
}

# Public Avatar Store thumbnails are catalog artwork, not bundled runtime
# avatars. Keep each release artifact behind an exact path/hash decision while
# the catalog JSON and package payloads remain independently hash-pinned.
AVATAR_STORE_CATALOG_BINARY_HASHES = {
    Path("shared/avatar-store-v1/catalog/v1/captain-ayer-thumbnail.png"):
        "2103488ebbc4a50b459adeabecbada7650cb6dc2b5db5b3640dc911e09f590d6",
    Path("shared/avatar-store-v1/catalog/v1/ara-thumbnail.png"):
        "7eb7ec65799715cdca9b52bad64d664fe2404b072a6f0a5b6af0368f4393217f",
}

CAPTAIN_AYER_BINARY_HASHES = {
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerBody.imageset/CaptainAyerBody.png"):
        "7e38b08b90f06fdd816d728fa3a093de62408164cc99dcfcfb28e86fd98e1375",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerBrowLeft.imageset/CaptainAyerBrowLeft.png"):
        "807e175875a7a49aeb6ee3b71f13d6d7ac97b07c772f5e74eaeeb86ca3e85900",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerBrowRight.imageset/CaptainAyerBrowRight.png"):
        "e77496e8008a6026591c5da510072d5e1bb85dfffb10e3353fc1c66f584dbb0d",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerEyeLeft.imageset/CaptainAyerEyeLeft.png"):
        "d7194d7e2a3023798f980dc198fce698b8279dc5b39a4a3839fe5a5eb34efcf6",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerEyeRight.imageset/CaptainAyerEyeRight.png"):
        "898d8ae06bf9d79c8c54d4a7dfdd6696863c15e4a49b0a657d6f5f77eba22a1d",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerGazeLeftAtlas.imageset/CaptainAyerGazeLeftAtlas.png"):
        "c7abacbe22c25493fc7f7ac8b1d0d3f2d73073f90947276166c057797f9e5974",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerGazeRightAtlas.imageset/CaptainAyerGazeRightAtlas.png"):
        "898a5b6a85ed7fb66f2691993ca4192a0f6dd7557655a06ee364cf6dbe9f9700",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerHeadMask.imageset/CaptainAyerHeadMask.png"):
        "b3d8b6baf850cb4fdac8d1a2d9a16b9415da08aa81479aa8d1bf04fc7f3e03c8",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerKeyframe.imageset/CaptainAyerKeyframe.png"):
        "a227ea77f89be7f669d7d54a8e828bfc160c1b6951b463f1a09ef83453ada6cd",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeAA.imageset/CaptainAyerVisemeAA.jpg"):
        "ec98cdfaadeb445746a55ff3d3eb2bddaf5c526e37bf445e7986a3f190d221af",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeE.imageset/CaptainAyerVisemeE.jpg"):
        "98a4b58dfefef38fc9274067f7864693598efa41797fdf53ead279134b881dcd",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeFF.imageset/CaptainAyerVisemeFF.jpg"):
        "8e823738fc97a2f78b9e87365071528ee30377bcb698e91c52c9843a49499182",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeIH.imageset/CaptainAyerVisemeIH.jpg"):
        "026f5ff983773ec92d591fcf36e7bd8d7b5f37b8dee0870096cb406b36d75bfd",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeNN.imageset/CaptainAyerVisemeNN.jpg"):
        "06649204b31a6e9c8c0e2a9c2c8be2ce15f70cd8bc68f08d4b8f49ef5a96d69f",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeOU.imageset/CaptainAyerVisemeOU.jpg"):
        "5f9287a7f8faa9b95b22ea63ad4126d32e51ad0de531179ff4c0cfda73149b2c",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeRR.imageset/CaptainAyerVisemeRR.jpg"):
        "8e6cca2c202ff88a39f9816862368ee6200b0e04c5263debd1bbd85937c0cfa3",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeSil.imageset/CaptainAyerVisemeSil.jpg"):
        "bc534373f3a2c82c11548307b69c43faf76c73d662d15104c56743812dc4680d",
    Path("ios/OpenClamLiveKit/App/Assets.xcassets/CaptainAyerVisemeTH.imageset/CaptainAyerVisemeTH.jpg"):
        "4d5f8df80fc45343673d36f03d841f102a328ab2b2ec49af1e1cacaf2efef45a",
}

# v1.0.1 shipped the original Ara asset set. The current tree must never use
# these binaries again, but descendants of the public v1.0.1 commit retain the
# exact blobs in reachable history. History accepts only these explicit
# path/hash pairs; no wildcard or unknown Ara binary is approved.
HISTORICAL_ARA_V1_0_1_BINARY_HASHES = {
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/body.png"):
        "3850b113b8181a3c18c497d33de91dd16a42c47d701e48c6c89a9a29b7921432",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/brow-left.png"):
        "4978b71be5e65582f4b943bcc5a7b3ccf89782f6a0b5ddbf029e736ab81d2566",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/brow-right.png"):
        "7fbd6cbddebc2f2ba20239c5ff4c560417ce1cd8dc0802e19faa74d0f50e01d4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/eye-left.png"):
        "06bfebd924fe5c1c9a4766b9b80efaa7b2810d7b9a1f7e927bdc7d10e3f2c05c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/eye-right.png"):
        "8728eb8f965571ea7eaf066cffd23fd1de69f1260c78bdfe529d10d07dbf30b7",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/gaze-left-atlas.png"):
        "407daf03ed613a6a3e074718e8efd9c7403c626e8a51e5f202c4b66a4b49a9b4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/gaze-right-atlas.png"):
        "be12bf910f6d61b1c1abe24abe2fa83d49ac4ce7fa22d69e0d1a9fc832d5d162",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/head-mask.png"):
        "69f6209d005a1fcd1bc2e1ece340cf75352aee3fae180cd0b80288470a2825ed",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/motion-edge-idle.mov"):
        "242a2873de568ee9e9d579291e0eeb1c39b8d6a862688d59bc9dd6ed1e8b6bc5",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/motion-moves.mov"):
        "575cdbd9d3eb7b9f9dad11ef86be9c903a7fde596ff3bdd63c3d5430b7308dc5",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/thumbnail.jpg"):
        "d208eacbb8e50363fbc4ce4429924e944ec01814d4a5e8dfd528fdc560c3d032",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-E.jpg"):
        "ba610571cbf71479572776451ce346a3fd40e255a6cb6b9049ec198dcbbc5908",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-FF.jpg"):
        "5747c766d9a0d4e44dbb60b233e4f80486f82851b882caec7d8218503ff084b7",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-RR.jpg"):
        "2b3abb89b7d3bd7ef9b8d55500e9d2433a2da178518a16b9e1445d0c6ddea14c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-TH.jpg"):
        "d691caec3cf16aceda3ca23ebdbae38d45c2dc3f207455643f464d1d0ae8fb53",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-aa.jpg"):
        "8891cefc2ab4fa834b0b45a26edb49bfc09279d0d609732215e94113540ed89e",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-ih.jpg"):
        "74250e43223e48197570a90af304fd84c23c9095e379e56e7b893643c47dcf34",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-nn.jpg"):
        "cb12409434a20ae87cd8a90ae0c2eb857409c0d75314cf5ddeb6fc828d8975bf",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-ou.jpg"):
        "271339f71da95141a844f1ffc19fe6ec0735b7c4ffcf8ef355af173c66beef1c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-sil.jpg"):
        "32023cdddc2b1d24e9ed47bdf092b0cb1d8edec0f69fe7b8584c837eb72b02e7",
}

# v1.0.2 ships the current brown-blazer Ara asset set. These are the only Ara
# binaries approved in the current source tree.
ARA_BINARY_HASHES = {
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/body.png"):
        "365d91dab92866c6bf976e90971eb8d4c0af1b0a8e977163e47945e264bf0dc3",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/brow-left.png"):
        "f60e4b2de9197c5790239e3189ed960f1d758a33d4ab4c6dced93bc7bd070bfe",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/brow-right.png"):
        "17def36bef479e6762d57f961671771cdf68ff5080fdf7a672c0e6d0f92cf6bd",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/eye-left.png"):
        "ef14733dfeb9657c0bc7f0b4c39f330a574bfcaf7fc046af19d7c023baa2c671",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/eye-right.png"):
        "620cf2e4db34089a1f006be3e91454877969d6b12557b0ac0b72bf153161d6fe",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/gaze-left-atlas.png"):
        "6f61eae78a287e93d8dd3497ecfb35ec54bd4c106767fd530edcd9ae98c9c3ee",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/gaze-right-atlas.png"):
        "6bc1732094df77eff1a63adda77bb121c6195da6ee752a42d1a61429430360c0",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/head-mask.png"):
        "4f179461401257989735e26692c28dc39d14d3f83caea8a84ea7a34b3c750b88",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/motion-edge-idle.mov"):
        "d94013aa1b3e6aad84fae823f0cd7c8ecd84b5ac6cb994f364afe9dbe6fee971",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/motion-moves.mov"):
        "ad838c39d11d9eaec7410a4cf67e2d53f236a8afb452fd9b6ccbaf1b400f6957",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/thumbnail.jpg"):
        "2a6520f7e94baf93788341d453acc9a432a3ced85b8d654fdffd5e425269cc2a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-E.jpg"):
        "204d6b07757ad6d104f685a2c57c1d9c33d12535d8e57579057e5bb4b4ba65c2",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-FF.jpg"):
        "64d169d22abda344d79043453830e572966993c3632059be9419e785837e75f2",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-RR.jpg"):
        "b5b6fc8c67eb6fa3205399a524480d9a043333edabba49db15aeb30814cc5dea",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-TH.jpg"):
        "89dfa4d8341379ae17917dfd32f1f8dc72782fdb99d711b35ad3be30dc5db68b",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-aa.jpg"):
        "66005d9aa4ec3e93feda02052778abd3132ba12d87eaefcb62184833282ea00a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-ih.jpg"):
        "d15b23029fa98821728ce9d097fa89fbb6fdedbe4aba06584ac0a4d187118779",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-nn.jpg"):
        "a5cfa54c5527abec635a4cc50f56b971df3f50503de0bcf9e240e0b6f5335768",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-ou.jpg"):
        "a208a2d7fdaf23b1cc346cfddafe1fb3bc2440f40a824fb14c6a6d03cc8ba33c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/ara/viseme-sil.jpg"):
        "08df7b7dc0cbd5ceaa5d71d086237ed14120be14ffc3bb132960e72545c13804",
}

DETERMINISTIC_FIXTURE_BINARY_HASHES = {
    Path("shared/avatar-package-v2/fixtures/ios-light-golden.avtr"):
        "20f46ca9f3160a0d5934202ef5908085f6246e492f8298582e0e12f7411d78cb",
    Path("shared/avatar-package-v2/fixtures/ios-light-motion-v3-golden.avtr"):
        "bb62a3561c7078721eea922ed7c2a45c910f8c9f87045b69a2378800ea0f6ed3",
}

# v1.0.0 contained this deterministic, likeness-free test guide. v1.0.1
# removes it from the shipped tree, but the descendant release necessarily
# retains the exact old blobs in reachable history. No current-tree exception
# is granted, so reintroducing any of these paths still fails closed.
HISTORICAL_SYNTHETIC_GUIDE_HASHES = {
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/body.png"):
        "259a8fd460ec81bbd33b92e800277f5a227a3278cca833f8b76b1d2979a60e0a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/brow-left.png"):
        "0725704c4af8b4af0ff4c99f5e616581c92adf380ca9ad32e1bad0525e2127d3",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/brow-right.png"):
        "6a07b668123a2681101877c9ce9cd312ec1bc706fa05fad19395a28c3db26f54",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/eye-left.png"):
        "5acd87fb5af386dcf5f47b1c5cc360d1e6d32335b04e1155fdea4df8ad0f68f8",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/eye-right.png"):
        "3229a97da75a31653bd8c1cb88509d90c5e46783d3ee47ae1e23301f33a8e35e",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/gaze-left-atlas.png"):
        "f5227a7328fc5433f5baeb51f948eb63b5a568171453f42cf8dddb5b373d282c",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/gaze-right-atlas.png"):
        "a4d526adb73f2369ba80595cea0b6eb05c0115c117cdadcf303896294552cf8a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/head-mask.png"):
        "e6b7b21576c23b2a07bbff9fef2fc9114b47bf908519f0eaf7e9a52be7603cdc",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/thumbnail.png"):
        "e1416b287d3b4186445ecc656e907765370570bc2d32424ccd93052f96bc714a",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-E.png"):
        "7eeca4eb672f1d4ce1930e01035c5ed2e22be9549ec82565a2c745aa429e7837",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-FF.png"):
        "e81692c50786fdf1b13ae16c31795fed484afe5130c0154545858695744ba3d2",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-RR.png"):
        "cf66a6a38d389c3fbefc9a68ee7f2f35a0dbc9668a80ab45acebf3cfc0e991c4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-TH.png"):
        "a885faa275e06feff6c9947a9ff5e89faced6dce47d4bedd608e5fa8fbb642d1",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-aa.png"):
        "a6ee86eaa90f9e84cd925b26cd2f3e295ab800ba7441f2f51f8b8f6784c09e84",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-ih.png"):
        "9c0af199b5a1030f138ac1bb26b09ca22c3b966192dc4bf39303bedc6fe6a9b8",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-nn.png"):
        "5f4e08a4c94e4e812df176acad4a643737c4fa00dbd2535b402bdb49dfc02da1",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-ou.png"):
        "8b60a213ed4d82e4738f3db16a168f193a609e2a476208d17af2e51bcba9cac4",
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle/public-guide/viseme-sil.png"):
        "655c32ad576de349568fb3bbcbee71f47d8118bb83e02dc781e92e72e14cd381",
}

REQUIRED_AVATAR_BINARY_HASHES = {
    **CAPTAIN_AYER_BINARY_HASHES,
    **ARA_BINARY_HASHES,
}
AUTHORIZED_AVATAR_LEDGER_SHA256 = (
    "7ed8c407fd07c6899b1e75f25879e9b1390848b260dbcf9eb576ae2e74866a16"
)
ALLOWED_BINARY_HASHES = {
    **BRANDING_AND_RUNTIME_BINARY_HASHES,
    **AVATAR_STORE_CATALOG_BINARY_HASHES,
    **REQUIRED_AVATAR_BINARY_HASHES,
    **DETERMINISTIC_FIXTURE_BINARY_HASHES,
}

CAPTAIN_AYER_CONTENTS_FILES = {
    path.with_name("Contents.json") for path in CAPTAIN_AYER_BINARY_HASHES
}

REQUIRED_STORE_POLICY_SNIPPETS = {
    Path("ios/OpenClamLiveKit/App/AvatarCatalog/OpenClamAvatarStore.swift"): (
        b"static let catalogURL: URL? = productionCatalogURL",
        b"avatar-store-v1.0.0/shared/avatar-store-v1/catalog/v1/catalog.json",
        b"static let release = Self(catalogURL: OpenClamAvatarStoreReleasePolicy.catalogURL)",
        b"guard remoteAccess.isEnabled else",
    ),
    Path("macos/OpenClamStudio/electron/avatar-store.cjs"): (
        b"const AVATAR_STORE_AVAILABLE = false;",
        b"const RELEASE_ENDPOINT_POLICY = null;",
    ),
    Path("macos/OpenClamStudio/electron/main.cjs"): (
        b"if (!AVATAR_STORE_AVAILABLE)",
    ),
}

RELEASE_FEATURE_CONTRACT_PATH = Path("contracts/release-feature-contract-v1.json")
REQUIRED_RELEASE_FEATURE_SNIPPETS = {
    Path("ios/OpenClamLiveKit/App/Services/LocalAssistantServices.swift"): (
        b"request.shouldReportPartialResults = true",
        b"AIProviderRegistry.usesRealtimeSpeechRecognition",
        b"CloudRecordingManualStopTailCapture.waitThenStop",
    ),
    Path("ios/OpenClamLiveKit/App/Services/CloudVoiceServices.swift"): (
        b'static let speechToTextServiceID = "grok-transcribe"',
        b"struct XAIRealtimeSpeechToTextService",
        b'static let model = "grok-transcribe-live"',
        b'"interim_results"',
        b'"audio.done"',
        b"struct SonioxRealtimeSpeechToTextService",
        b'static let model = "stt-rt-v5"',
    ),
    Path("ios/OpenClamLiveKit/App/Models/AIProviderSettings.swift"): (
        b'static let xAIBatchSpeechToTextModel = "grok-transcribe"',
        b'static let xAILiveSpeechToTextModel = "grok-transcribe-live"',
        b"usesRealtimeSpeechRecognition",
    ),
    Path("ios/OpenClamLiveKit/App/Services/AIConfigurationModel.swift"): (
        b"XAIRealtimeSpeechToTextService",
        b"SonioxRealtimeSpeechToTextService",
    ),
}

AVATAR_CATALOG_ASSET_ROOT = Path(
    "ios/OpenClamLiveKit/App/AvatarCatalog/Resources/AvatarCatalogAssets.bundle"
)
ALLOWED_AVATAR_CATALOG_ROOT_FILES = {
    AVATAR_CATALOG_ASSET_ROOT / "Info.plist",
    AVATAR_CATALOG_ASSET_ROOT / "live-talk-connection.wav",
    AVATAR_CATALOG_ASSET_ROOT / "provenance.json",
}
UNAPPROVED_LIKENESS_PATH_MARKERS = {
    "cleo",
    "emma",
    "octavia",
    "samantha",
    "vivieen",
    "vvn",
}

# macOS 26 attaches this system provenance marker to every file materialized
# by the local execution service and immediately recreates it after deletion.
# Git does not serialize it, so it cannot enter an archive or repository blob.
# Every other extended attribute remains a release blocker.
NON_TRANSPORTED_PLATFORM_XATTRS = {"com.apple.provenance"}

PRIVATE_PATH_PATTERNS = {
    "personal home path": re.compile(
        rb"/" + rb"Users/(?!example(?:/|$)|yourname(?:/|$))[^/\s\"']+"
    ),
    "temporary attachment path": re.compile(
        rb"(?:/" + rb"var/folders/|/tmp/codex-remote-" + rb"attachments/|codex-" + rb"clipboard-)"
    ),
    "named private portrait": re.compile(rb"Samantha\.png", re.IGNORECASE),
}

PRIVATE_PATH_PATTERN_DETECTOR_FILES = {
    Path("macos/OpenClamStudio/scripts/opencv-cmake-hooks/STATUS_DUMP_EXTRA.cmake"),
    Path("scripts/public-release-audit.py"),
}

SECRET_PATTERNS = {
    "private key": re.compile(
        rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
    ),
    "GitHub credential": re.compile(
        rb"(?:\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b)"
    ),
    "provider credential": re.compile(
        rb"(?:\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}\b"
        rb"|\bgsk_[A-Za-z0-9_-]{20,}\b"
        rb"|\bxai-[A-Za-z0-9]{24,}\b"
        rb"|\bAIza[A-Za-z0-9_-]{30,}\b)"
    ),
    "AWS access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "Slack credential": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "payment credential": re.compile(rb"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b"),
    "agent workspace id": re.compile(rb"\bagent\|[A-Za-z0-9_-]{8,}\b"),
}

HIGH_ENTROPY_RE = re.compile(
    rb"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{40,}={0,2}(?![A-Za-z0-9_+/-])"
)
HIGH_ENTROPY_SKIP_NAMES = {
    "Package.resolved",
    "package-lock.json",
    "requirements-backend.lock",
    "requirements-electron.lock",
    "uv.lock",
}

ALLOWED_SOURCE_BUILD_FILES = {
    Path("macos/OpenClamStudio/build/entitlements.mac.inherit.plist"),
    Path("macos/OpenClamStudio/build/entitlements.mac.plist"),
}

# OpenClaw package installs require JavaScript entrypoints. These bounded,
# reproducibly generated files are the complete reviewed runtime surface; any
# other generated `dist` path remains fail-closed.
ALLOWED_OPENCLAW_PLUGIN_RUNTIME_PATHS = {
    Path("openclaw-plugin-openclam/dist"),
    Path("openclaw-plugin-openclam/dist/index.js"),
    Path("openclaw-plugin-openclam/dist/setup-entry.js"),
    Path("openclaw-plugin-openclam/dist/src"),
    Path("openclaw-plugin-openclam/dist/src/attachment-upload.js"),
    Path("openclaw-plugin-openclam/dist/src/bridge-client.js"),
    Path("openclaw-plugin-openclam/dist/src/channel-base.js"),
    Path("openclaw-plugin-openclam/dist/src/channel.js"),
    Path("openclaw-plugin-openclam/dist/src/channel.setup.js"),
    Path("openclaw-plugin-openclam/dist/src/cli.js"),
    Path("openclaw-plugin-openclam/dist/src/config.js"),
    Path("openclaw-plugin-openclam/dist/src/credentials.js"),
    Path("openclaw-plugin-openclam/dist/src/gateway.js"),
    Path("openclaw-plugin-openclam/dist/src/inbound.js"),
    Path("openclaw-plugin-openclam/dist/src/media.js"),
    Path("openclaw-plugin-openclam/dist/src/pairing.js"),
    Path("openclaw-plugin-openclam/dist/src/protocol.js"),
    Path("openclaw-plugin-openclam/dist/src/runtime.js"),
    Path("openclaw-plugin-openclam/dist/src/types.js"),
}

MAX_SOURCE_BYTES = 10 * 1024 * 1024


def shannon_entropy(value: bytes) -> float:
    counts: dict[int, int] = defaultdict(int)
    for byte in value:
        counts[byte] += 1
    length = len(value)
    return -sum(
        (count / length) * math.log2(count / length) for count in counts.values()
    )


def git_root(root: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    discovered = Path(os.fsdecode(result.stdout.strip())).resolve()
    return discovered if discovered == root else None


def source_tree_entries(root: Path) -> list[tuple[Path, os.stat_result]]:
    """Enumerate every non-.git entry without following links.

    This intentionally does not consult ignore rules. A private file must not
    disappear from the release audit merely because .gitignore knows about it.
    """
    entries: list[tuple[Path, os.stat_result]] = []
    pending = [root]
    while pending:
        current = pending.pop()
        with os.scandir(current) as scanned:
            for entry in scanned:
                path = Path(entry.path)
                relative = path.relative_to(root)
                if relative == Path(".git"):
                    continue
                metadata = entry.stat(follow_symlinks=False)
                entries.append((relative, metadata))
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(path)
    return sorted(entries, key=lambda item: item[0].as_posix())


def git_reviewable_files(root: Path) -> set[Path] | None:
    if git_root(root) is None:
        return None
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
        capture_output=True,
        check=True,
    )
    return {
        Path(os.fsdecode(value))
        for value in result.stdout.split(b"\0")
        if value
    }


def extended_attributes(path: Path) -> list[str]:
    listxattr = getattr(os, "listxattr", None)
    if listxattr is not None:
        try:
            return listxattr(path, follow_symlinks=False)
        except OSError:
            return ["<unreadable>"]
    try:
        result = subprocess.run(
            ["xattr", "-s", str(path)],
            capture_output=True,
            check=False,
        )
    except OSError:
        return ["<unreadable>"]
    if result.returncode != 0:
        return ["<unreadable>"]
    return [os.fsdecode(name) for name in result.stdout.splitlines() if name]


def manifest_file_record(root: Path, relative: Path) -> dict[str, str]:
    path = root / relative
    metadata = path.lstat()
    return {
        "path": relative.as_posix(),
        "mode": f"{metadata.st_mode:06o}",
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }


def manifest_records(root: Path) -> list[dict[str, str]]:
    return [
        manifest_file_record(root, relative)
        for relative, metadata in source_tree_entries(root)
        if stat.S_ISREG(metadata.st_mode)
    ]


def write_manifest(root: Path, output: Path) -> None:
    resolved_output = output.resolve()
    try:
        resolved_output.relative_to(root)
    except ValueError:
        pass
    else:
        raise ValueError("manifest output must be outside the audited tree")
    document = {
        "format": 1,
        "files": manifest_records(root),
    }
    resolved_output.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def manifest_findings(root: Path, manifest_path: Path) -> list[str]:
    findings: list[str] = []
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return ["release manifest is unreadable or invalid"]
    if not isinstance(document, dict) or document.get("format") != 1:
        return ["release manifest has an unsupported format"]
    raw_files = document.get("files")
    if not isinstance(raw_files, list):
        return ["release manifest has no file list"]

    expected: dict[Path, tuple[str, str]] = {}
    for item in raw_files:
        if not isinstance(item, dict) or set(item) != {"path", "mode", "sha256"}:
            findings.append("release manifest has an invalid file record")
            continue
        raw_path = item.get("path")
        mode = item.get("mode")
        digest = item.get("sha256")
        if not isinstance(raw_path, str) or not raw_path or "\0" in raw_path:
            findings.append("release manifest has an invalid path")
            continue
        relative = Path(raw_path)
        if relative.is_absolute() or ".." in relative.parts:
            findings.append("release manifest has an unsafe path")
            continue
        if relative in expected:
            findings.append(f"release manifest repeats path: {relative}")
            continue
        if not isinstance(mode, str) or not re.fullmatch(r"100(?:644|755)", mode):
            findings.append(f"release manifest has invalid mode: {relative}")
            continue
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            findings.append(f"release manifest has invalid hash: {relative}")
            continue
        expected[relative] = (mode, digest)

    actual = {
        Path(record["path"]): (record["mode"], record["sha256"])
        for record in manifest_records(root)
    }
    for relative in sorted(actual.keys() - expected.keys()):
        findings.append(f"unexpected path not in release manifest: {relative}")
    for relative in sorted(expected.keys() - actual.keys()):
        findings.append(f"release manifest path missing: {relative}")
    for relative in sorted(actual.keys() & expected.keys()):
        if actual[relative][0] != expected[relative][0]:
            findings.append(f"release manifest mode mismatch: {relative}")
        if actual[relative][1] != expected[relative][1]:
            findings.append(f"release manifest hash mismatch: {relative}")
    return findings


def denied_path_reason(relative: Path) -> str | None:
    if not relative.parts:
        return "invalid empty path"
    if relative.parts[0] not in ALLOWED_TOP_LEVEL:
        return "unreviewed top-level path"
    if relative in DENIED_EXACT_PATHS:
        return "runtime/private file"
    if relative in ALLOWED_OPENCLAW_PLUGIN_RUNTIME_PATHS:
        return None
    if any(part in DENIED_DIR_NAMES or part.startswith("dist-") for part in relative.parts):
        return "generated/private directory"
    if "build" in relative.parts and relative not in ALLOWED_SOURCE_BUILD_FILES:
        if relative == Path("macos/OpenClamStudio/build"):
            return None
        return "generated/private directory"
    lower_name = relative.name.lower()
    lowered_parts = tuple(part.lower() for part in relative.parts)
    if relative.name in DENIED_NAMES or (
        lower_name.startswith(".env.")
        and lower_name not in {".env.example", ".dev.vars.example"}
    ):
        return "runtime/private file"
    if lower_name.endswith(".local.xcconfig"):
        return "runtime/private file"
    lowered = relative.as_posix().lower()
    if any(marker in lowered_parts for marker in UNAPPROVED_LIKENESS_PATH_MARKERS):
        return "unapproved likeness path"
    if AVATAR_CATALOG_ASSET_ROOT == relative:
        return None
    try:
        avatar_catalog_relative = relative.relative_to(AVATAR_CATALOG_ASSET_ROOT)
    except ValueError:
        avatar_catalog_relative = None
    if avatar_catalog_relative is not None:
        if relative in ALLOWED_AVATAR_CATALOG_ROOT_FILES:
            return None
        if avatar_catalog_relative == Path("ara"):
            return None
        if relative not in ARA_BINARY_HASHES:
            return "unapproved bundled avatar asset"
    if any(
        part.lower().startswith("captainayer") and part.lower().endswith(".imageset")
        for part in relative.parts
    ) and relative not in CAPTAIN_AYER_BINARY_HASHES \
            and relative not in CAPTAIN_AYER_CONTENTS_FILES:
        return "unapproved Captain Ayer asset path"
    if any(
        marker in lowered
        for marker in (
            "codex-remote-attachments",
            "codex-clipboard-",
            "samantha.png",
        )
    ):
        return "private evidence/user asset"
    suffix = relative.suffix.lower()
    if suffix in DENIED_SUFFIXES and relative not in ALLOWED_BINARY_HASHES:
        return "generated/private or unreviewed binary"
    return None


def denied_directory_reason(relative: Path) -> str | None:
    if not relative.parts:
        return "invalid empty path"
    if relative.parts[0] not in ALLOWED_TOP_LEVEL:
        return "unreviewed top-level path"
    if relative in ALLOWED_OPENCLAW_PLUGIN_RUNTIME_PATHS:
        return None
    if any(part in DENIED_DIR_NAMES or part.startswith("dist-") for part in relative.parts):
        return "generated/private directory"
    if "build" in relative.parts and relative != Path("macos/OpenClamStudio/build"):
        return "generated/private directory"
    lowered_parts = tuple(part.lower() for part in relative.parts)
    if any(marker in lowered_parts for marker in UNAPPROVED_LIKENESS_PATH_MARKERS):
        return "unapproved likeness path"
    try:
        avatar_catalog_relative = relative.relative_to(AVATAR_CATALOG_ASSET_ROOT)
    except ValueError:
        avatar_catalog_relative = None
    if avatar_catalog_relative is not None \
            and avatar_catalog_relative != Path(".") \
            and avatar_catalog_relative.parts[0] != "ara":
        return "unapproved bundled avatar directory"
    return None


def high_entropy_finding(relative: Path, raw: bytes) -> bool:
    if relative.name in HIGH_ENTROPY_SKIP_NAMES:
        return False
    for match in HIGH_ENTROPY_RE.finditer(raw):
        token = match.group(0)
        stripped = token.rstrip(b"=")
        if b"/" in stripped:
            # Source paths and URLs are not secret literals. Provider-specific
            # credential patterns above still scan their full surrounding text.
            continue
        if stripped.count(b"_") >= 2 and not any(
            byte in b"0123456789" for byte in stripped
        ):
            continue
        if set(stripped) == set(
            b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        ):
            continue
        if len(stripped) in {40, 64, 96, 128} and re.fullmatch(
            rb"[0-9a-fA-F]+", stripped
        ):
            continue
        if token.startswith((b"sha256-", b"sha384-", b"sha512-")):
            continue
        if shannon_entropy(token) >= 4.7:
            return True
    return False


def audit_bytes(relative: Path, raw: bytes) -> list[str]:
    findings: list[str] = []
    if len(raw) > MAX_SOURCE_BYTES:
        return [f"oversized source artifact: {relative}"]

    expected_hash = ALLOWED_BINARY_HASHES.get(relative)
    if expected_hash is not None:
        actual = hashlib.sha256(raw).hexdigest()
        if actual != expected_hash:
            findings.append(f"approved binary hash mismatch: {relative}")
        return findings

    if b"\0" in raw:
        return [f"unreviewed binary source artifact: {relative}"]
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        return [f"non-UTF-8 source artifact: {relative}"]

    if relative not in PRIVATE_PATH_PATTERN_DETECTOR_FILES:
        for label, pattern in PRIVATE_PATH_PATTERNS.items():
            if pattern.search(raw):
                findings.append(f"{label}: {relative}")
    for label, pattern in SECRET_PATTERNS.items():
        if pattern.search(raw):
            findings.append(f"{label}: {relative}")
    if high_entropy_finding(relative, raw):
        findings.append(f"unreviewed high-entropy literal: {relative}")
    return findings


def audit_history_bytes(relative: Path, raw: bytes) -> list[str]:
    historical_ara_hash = HISTORICAL_ARA_V1_0_1_BINARY_HASHES.get(relative)
    if historical_ara_hash is not None \
            and hashlib.sha256(raw).hexdigest() == historical_ara_hash:
        return []
    historical_hash = HISTORICAL_SYNTHETIC_GUIDE_HASHES.get(relative)
    if historical_hash is None:
        return audit_bytes(relative, raw)
    if hashlib.sha256(raw).hexdigest() != historical_hash:
        return [f"historical synthetic fixture hash mismatch: {relative}"]
    return []


def avatar_rights_findings(root: Path) -> list[str]:
    findings: list[str] = []
    ledger = b"".join(
        f"{digest}  {relative.as_posix()}\n".encode("utf-8")
        for relative, digest in sorted(
            REQUIRED_AVATAR_BINARY_HASHES.items(),
            key=lambda item: item[0].as_posix(),
        )
    )
    if hashlib.sha256(ledger).hexdigest() != AUTHORIZED_AVATAR_LEDGER_SHA256:
        findings.append("authorized avatar path/hash ledger mismatch")

    provenance_path = AVATAR_CATALOG_ASSET_ROOT / "provenance.json"
    try:
        provenance = json.loads((root / provenance_path).read_text(encoding="utf-8"))
        avatars = provenance["avatars"]
        avatar_ids = [avatar["id"] for avatar in avatars]
        rights = [avatar["rights_basis"] for avatar in avatars]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError):
        findings.append("bundled avatar provenance is unreadable or incomplete")
    else:
        if avatar_ids != ["captain-ayer", "ara"]:
            findings.append("bundled avatar provenance identity set mismatch")
        if rights != [
            "user-confirmed-owned-and-authorized",
            "user-confirmed-owned-and-authorized",
        ]:
            findings.append("bundled avatar provenance rights basis mismatch")
    return findings


def store_release_policy_findings(root: Path) -> list[str]:
    findings: list[str] = []
    for relative, snippets in REQUIRED_STORE_POLICY_SNIPPETS.items():
        try:
            raw = (root / relative).read_bytes()
        except OSError:
            findings.append(f"store release-policy file missing: {relative}")
            continue
        for snippet in snippets:
            if snippet not in raw:
                findings.append(f"store release-policy marker missing: {relative}")
                break
    return findings


def release_feature_contract_findings(root: Path) -> list[str]:
    findings: list[str] = []
    try:
        contract = json.loads(
            (root / RELEASE_FEATURE_CONTRACT_PATH).read_text(encoding="utf-8")
        )
        ios = contract["ios"]
        store = ios["avatar_store"]
        ptt = ios["push_to_talk"]
        controls = contract["change_control"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError):
        return ["release feature contract is unreadable or incomplete"]

    if contract.get("schema_version") != 1:
        findings.append("release feature contract schema mismatch")
    if store != {"enabled": True, "catalog_tag": "avatar-store-v1.0.0"}:
        findings.append("release feature contract changed the approved Avatar Store state")
    if ptt.get("apple") != {"enabled": True, "transcript_delivery": "live"}:
        findings.append("release feature contract changed Apple PTT delivery")
    if ptt.get("soniox") != {
        "enabled": True,
        "default_model": "stt-rt-v5",
        "transcript_delivery": "live",
    }:
        findings.append("release feature contract changed Soniox PTT delivery")
    if ptt.get("xai") != {
        "enabled": True,
        "default_model": "grok-transcribe",
        "modes": {
            "grok-transcribe": "after_stop",
            "grok-transcribe-live": "live",
        },
    }:
        findings.append("release feature contract changed xAI PTT modes")
    if controls != {
        "feature_disable_requires_explicit_product_approval": True,
        "one_user_visible_feature_per_commit": True,
        "signed_smoke_required_for_changed_capture_path": True,
    }:
        findings.append("release feature contract changed required change controls")

    for relative, snippets in REQUIRED_RELEASE_FEATURE_SNIPPETS.items():
        try:
            raw = (root / relative).read_bytes()
        except OSError:
            findings.append(f"release feature implementation file missing: {relative}")
            continue
        for snippet in snippets:
            if snippet not in raw:
                findings.append(f"release feature implementation marker missing: {relative}")
                break
    return findings


def audit_current_tree(root: Path) -> tuple[list[str], int]:
    findings: list[str] = []
    entries = source_tree_entries(root)
    reviewable_files = git_reviewable_files(root)
    for required in sorted(REQUIRED_FILES):
        if not (root / required).is_file():
            findings.append(f"required public file missing: {required}")
    for required in sorted(
        set(REQUIRED_AVATAR_BINARY_HASHES)
        | set(DETERMINISTIC_FIXTURE_BINARY_HASHES)
    ):
        if not (root / required).is_file():
            findings.append(f"required approved binary missing: {required}")

    inspected = 0
    for relative, metadata in entries:
        path = root / relative
        unexpected_xattrs = (
            set(extended_attributes(path)) - NON_TRANSPORTED_PLATFORM_XATTRS
        )
        if unexpected_xattrs:
            findings.append(f"extended attributes not allowed: {relative}")
        if stat.S_ISLNK(metadata.st_mode):
            findings.append(f"symlink not allowed in public source: {relative}")
            continue
        if stat.S_ISDIR(metadata.st_mode):
            reason = denied_directory_reason(relative)
            if reason is not None:
                findings.append(f"{reason}: {relative}")
            continue
        if not stat.S_ISREG(metadata.st_mode):
            findings.append(f"non-regular source entry: {relative}")
            continue
        inspected += 1
        if reviewable_files is not None and relative not in reviewable_files:
            findings.append(f"ignored path present in public tree: {relative}")
        reason = denied_path_reason(relative)
        if reason is not None:
            findings.append(f"{reason}: {relative}")
            continue
        if metadata.st_nlink != 1:
            findings.append(f"hard-linked source file not allowed: {relative}")
        mode = stat.S_IMODE(metadata.st_mode)
        if mode & 0o022:
            findings.append(f"group/world-writable source file: {relative}")
        findings.extend(audit_bytes(relative, path.read_bytes()))
    findings.extend(avatar_rights_findings(root))
    findings.extend(store_release_policy_findings(root))
    findings.extend(release_feature_contract_findings(root))
    return findings, inspected


def reachable_objects(root: Path) -> tuple[dict[str, set[Path]], list[str]]:
    result = subprocess.run(
        ["git", "-C", str(root), "rev-list", "--objects", "--all"],
        capture_output=True,
        check=True,
    )
    paths_by_oid: dict[str, set[Path]] = defaultdict(set)
    object_ids: list[str] = []
    for raw_line in result.stdout.splitlines():
        decoded = os.fsdecode(raw_line)
        oid, separator, object_path = decoded.partition(" ")
        if oid not in paths_by_oid:
            object_ids.append(oid)
        if separator and object_path:
            paths_by_oid[oid].add(Path(object_path))
    return paths_by_oid, object_ids


def history_findings(root: Path, require_fresh: bool) -> list[str]:
    repository = git_root(root)
    if repository is None:
        return ["fresh-history check requested but snapshot has no Git history"] if require_fresh else []

    findings: list[str] = []
    if require_fresh:
        count = int(
            subprocess.check_output(
                ["git", "-C", str(root), "rev-list", "--count", "--all"],
                text=True,
            ).strip()
            or "0"
        )
        roots = subprocess.check_output(
            ["git", "-C", str(root), "rev-list", "--max-parents=0", "--all"],
            text=True,
        ).splitlines()
        if count != 1 or len(roots) != 1:
            findings.append(
                "public snapshot must have exactly one fresh root commit before first push"
            )

    identities = subprocess.check_output(
        ["git", "-C", str(root), "log", "--format=%ae%x00%ce%x00", "--all"]
    )
    for identity in identities.split(b"\0"):
        lowered = identity.strip().lower()
        if lowered.endswith(b".local") or b"@localhost" in lowered:
            findings.append("non-public local commit identity in reachable history")
            break

    # ``rev-list --objects`` reports only one path when multiple files share an
    # object ID (the empty blob is the common case). Enumerate commit diffs as
    # well so a deleted private path cannot hide behind an allowed identical
    # blob.
    history_names = subprocess.check_output(
        ["git", "-C", str(root), "log", "--all", "--format=", "--name-only", "-z"]
    )
    for raw_name in history_names.split(b"\0"):
        if not raw_name:
            continue
        relative = Path(os.fsdecode(raw_name).strip("\n"))
        if relative in HISTORICAL_SYNTHETIC_GUIDE_HASHES:
            continue
        reason = denied_path_reason(relative)
        if reason is not None:
            findings.append(f"reachable history {reason}: {relative}")

    paths_by_oid, object_ids = reachable_objects(root)

    process = subprocess.Popen(
        ["git", "-C", str(root), "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write("".join(f"{oid}\n" for oid in object_ids).encode("ascii"))
    process.stdin.close()
    for oid in object_ids:
        header = process.stdout.readline().rstrip(b"\n")
        fields = header.split()
        if len(fields) != 3 or fields[1] == b"missing":
            findings.append("could not inspect one reachable Git object")
            continue
        object_type = fields[1]
        size = int(fields[2])
        content = process.stdout.read(size)
        process.stdout.read(1)
        if object_type != b"blob":
            continue
        for relative in paths_by_oid.get(oid, set()):
            findings.extend(
                f"reachable history {finding}"
                for finding in audit_history_bytes(relative, content)
            )
    return findings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-fresh-history",
        action="store_true",
        help="require exactly one root commit (for the first public push)",
    )
    manifest = parser.add_mutually_exclusive_group()
    manifest.add_argument(
        "--manifest",
        type=Path,
        help="require an exact file/mode/SHA-256 match to this release manifest",
    )
    manifest.add_argument(
        "--write-manifest",
        type=Path,
        help="write an exact file/mode/SHA-256 manifest outside the audited tree",
    )
    parser.add_argument("root", nargs="?", default=".")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    if not root.is_dir():
        print("Public release audit failed: root is not a directory", file=sys.stderr)
        return 2

    current, inspected = audit_current_tree(root)
    if args.manifest is not None:
        current.extend(manifest_findings(root, args.manifest.resolve()))
    history = history_findings(root, args.require_fresh_history)
    findings = sorted(set(current + history))
    if findings:
        print("Public release audit failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1
    if args.write_manifest is not None:
        try:
            write_manifest(root, args.write_manifest)
        except (OSError, ValueError) as error:
            print(f"Public release manifest failed: {error}", file=sys.stderr)
            return 2
        print(f"Release manifest written: {args.write_manifest.resolve()}")
    history_label = " and reachable history" if git_root(root) is not None else ""
    manifest_label = " with exact manifest" if args.manifest is not None else ""
    print(
        f"Public release audit passed "
        f"({inspected} files{history_label}{manifest_label} inspected)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
