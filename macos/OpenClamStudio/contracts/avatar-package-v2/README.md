# OpenClam avatar package v2

This directory is the shared contract for portable OpenClam avatars. It is a
file-transfer format only. It does not synchronize avatars or couple the iOS
and macOS applications at runtime.

## iPhone-light profile

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
