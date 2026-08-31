# OpenClam avatar package v2

This directory is the shared contract for portable OpenClam avatars. It is a
file-transfer format only. It does not synchronize avatars or couple the iOS
and macOS applications at runtime.

## Legacy iPhone profile (v2/v3)

An iPhone package has the `.avtr` extension and is a ZIP archive containing
exactly 19 regular files, with no directory entries:

- `manifest.json`
- `assets/thumbnail.(png|jpg|jpeg)`
- `assets/body.png`
- `assets/head-mask.png`
- `assets/eye-left.png` and `assets/eye-right.png`
- `assets/brow-left.png` and `assets/brow-right.png`
- `assets/gaze-left-atlas.png` and `assets/gaze-right-atlas.png`
- Nine `assets/viseme-*.(png|jpg|jpeg)` images for `sil`, `FF`, `TH`, `nn`,
  `RR`, `aa`, `E`, `ih`, and `ou`

The manifest must use version `2`, variant `ios-light`, and the sole accepted
format value `openclam-avatar`. Legacy and third-party format aliases are
rejected. Importing a conforming file is an explicit local file operation; it
does not enable runtime synchronization or couple the iOS and macOS apps.

Every image is named by a semantic role and records its SHA-256, encoded byte
count, MIME type, and pixel dimensions. The iOS importer verifies all of those
values, the face rig, ZIP entry type, path, duplicate status, and compressed and
expanded limits before atomically installing the package under Application
Support.

Unknown files and manifest fields are rejected. In particular, the iPhone
profile must never contain source portraits, prompts, histories, credentials,
provider receipts, generation metadata, raw body turns, raw motion frames, or
macOS authoring libraries.

All iPhone versions may optionally carry the authoritative `sourceMedium`
classification (`photograph`, `game art`, `anime`, `illustration`, or
`3d render`). Packages made before this field remain valid and are treated as
photographic; missing metadata never opts a package into stylized rendering.

## Limits

- Archive: 32 MiB maximum
- Expanded encoded files: 64 MiB maximum
- Each image: 16 MiB maximum
- Decoded image: 8,192 pixels maximum per side and 16 megapixels maximum
- Manifest: 128 KiB maximum
- Files: exactly 19
- Identifier: lowercase ASCII letters, digits, and hyphens; 1–64 characters
- Display name: 1–64 characters after trimming

Run `python3 create_golden_fixture.py` from this directory to reproduce the
deterministic `fixtures/ios-light-golden.avtr` package used by the iOS tests.

## iPhone-light v3 optional motion extension

Version `3` is a backward-compatible extension of the iPhone-light profile.
The 18 image assets and rig are unchanged. A v3 manifest may additionally have
a non-empty `motions` object whose keys are a subset of exactly `walk`,
`edgeIdle`, and `moves`. A v2 manifest must omit `motions`; the iOS importer
continues to accept those 19-file packages unchanged.

Each motion record contains exactly `path`, `sha256`, `byteCount`, `mediaType`,
`width`, `height`, and `durationMilliseconds`. Paths and runtime behavior are
fixed by role, not controlled by package metadata:

- `walk` → `assets/motion-walk.mov`, loops
- `edgeIdle` → `assets/motion-edge-idle.mov`, loops
- `moves` → `assets/motion-moves.mov`, plays once

Every clip is a QuickTime movie (`video/quicktime`) with exactly one HEVC video
track carrying an alpha channel and no audio track. Display dimensions are
64–4,096 pixels per side and at most 16 megapixels; duration is 250–12,000 ms
and must match the manifest within 50 ms. Each clip shares the existing 16 MiB
per-file limit. A v3 archive contains exactly `19 + motions.count` regular
files, up to 22, while retaining the 32 MiB archive and 64 MiB expanded limits.
Unknown keys, files, codecs, audio, missing alpha, reflected display transforms,
hash mismatches, and dimension/duration mismatches are rejected before install.

The normative manifest shape is `ios-light-v3.schema.json`. The synthetic,
non-person `fixtures/ios-light-motion-v3-golden.avtr` fixture contains only
procedural artwork and motion and is used to exercise the importer/runtime
without copying a private avatar.

## iOS full-expression v4

Newly rebuilt runtime-v22 avatars export as version `4` while retaining the
internal `ios-light` variant identifier for Store and importer compatibility.
The user-facing package is no longer expression-light: it carries all 15
production visemes (`sil`, `PP`, `FF`, `TH`, `DD`, `kk`, `CH`, `SS`, `nn`,
`RR`, `aa`, `E`, `ih`, `oh`, `ou`), the viseme-indexed smile/laughter and
sorrow/horror/anger mouth atlases, paired forehead, cheek, and under-eye
strips, and the existing brow, 8-state eyelid, and 275-position gaze banks.
The exporter repacks the tall smile and emotion-mouth source strips into
row-major grid atlases before publishing, preserving every logical frame while
keeping every v4 texture dimension at or below 8,192 pixels for iPhone GPUs.

The `expression` object records each atlas box, dimensions/layout, calibrated
state values, canonical viseme order, emotion order, and bounded brow,
forehead, and under-eye gains derived from the avatar's authored rig profile.
Those gains keep future manually tuned or automatically corrected avatars
visually consistent between macOS and iOS. Import is fail-closed:
v4 is accepted only when every role, state bank, dimension, hash, MIME type,
and path is complete. Version 2 and 3 packages continue to import unchanged.

A rebuilt non-photographic v4 package may additionally carry `speechPatch`:
one nose-safe canonical lip rectangle and a bounded horizontal registration
offset for every one of the 15 visemes (with silence fixed at zero). The iOS
renderer uses this only with an explicit stylized `sourceMedium`; photo
packages retain their legacy lower-face geometry and crossfade. Versions 2 and
3 reject `speechPatch`.

Explicit `3d render` packages may opt in to `speechPatch.skinMatch` without
changing the v4 package version. This public-only v1 geometry contains
`space: "canonical-pixels"`, all 15 `contours`, and complete
`emotion_contours` banks (five smile states, four states each for sorrow,
horror, and anger). Each polygon has 8–64 unique, finite, convex vertices in
the canonical 1024-square face before the viseme's x offset; the offset is
applied exactly once. Registered points must remain within 15% of the speech
rectangle and registration within 35% of its width. Skin geometry is bounded
to 112 KiB and the complete manifest remains bounded to 128 KiB. Import rejects
malformed or incomplete geometry; it never treats missing lip contours as
skin. Existing packages without this optional field use the legacy bounded
tone-matching fallback. Photographic, 2D, and unknown-medium exports do not opt
in. No authoring key hashes, diagnostic data, or changed artwork is exported.

V4 permits 64 MiB archives, 96 MiB of expanded encoded assets, and a maximum
single image dimension of 8,192 pixels while retaining the 16 MiB per-image
and 16-megapixel decoded-pixel limits. A package
contains exactly 33 regular files plus up to three validated motion clips. The
normative shape is `ios-full-expression-v4.schema.json`.

## Mac-full authoring profile

A Mac authoring package also uses the `.avtr` extension and ZIP container, but
it is intentionally a different profile from the iPhone package. Its manifest
uses format `openclam-avatar`, version `2`, and variant `macos-full`.

The archive contains `manifest.json` plus a hash-ledgered `authoring/` tree.
That tree preserves the editable avatar project: the source portrait, head and
viseme work, full-body source plates, wardrobe and calibration metadata, walk,
edge-idle, move sources, and their authoring manifests. Runtime bundles,
diagnostics, temporary stages, logs, caches, credentials, provider keys,
conversation history, and application settings are forbidden.

Every authoring entry is a regular file listed exactly once in the manifest by
path, SHA-256, encoded byte count, and media type. The importer rejects missing,
extra, duplicate, traversal, absolute, directory, device, FIFO, socket, hard
link, and symbolic-link entries before extracting into a private stage. It
verifies every byte and atomically installs only after the complete ledger has
passed. The full package is editable only by OpenClam Studio on macOS; the iOS
app rejects it by variant.

The `capabilities` object records whether the exported project currently has a
head rig, full body, walk, edge idle, and one or more moves. These values are
descriptive and must be recomputed from verified authoring files on import;
they do not grant executable behavior.

Mac-full limits are 4 GiB for the compressed archive, 8 GiB expanded, 2 GiB
per file, 40,000 authoring files, 128 KiB for the manifest, and 1,024 UTF-8
bytes per archive path. The schema is `macos-full.schema.json`.
