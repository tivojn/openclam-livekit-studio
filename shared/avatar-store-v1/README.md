# OpenClam avatar store v1

This directory owns the strict catalog contract and the offline release builder
used by both OpenClam apps. The catalog root is exactly:

```json
{"schemaVersion": 1, "entries": []}
```

Each entry contains only `id`, `name`, `author`, `version`, `thumbnail`, and
`variants`. Every entry has exactly an `ios-light` package and a `macos-full`
package. Clients select their own profile, stream the download with progress,
verify its declared byte count and SHA-256, then hand the file to the existing
atomic AVTR v2 importer. A package for the other platform is never used as a
fallback.

## Vivieen v1 release layout

The public catalog is fixed at:

`https://raw.githubusercontent.com/tivojn/openclam-avatar-store/main/catalog/v1/catalog.json`

`build_release.py` produces this unpublished staging layout:

```text
release-assets/
  Vivieen-iPhone.avtr
  Vivieen-iPhone.avtr.sha256
  Vivieen-Mac.avtr
  Vivieen-Mac.avtr.sha256
catalog/v1/
  catalog.json
  catalog.json.sha256
  catalog.schema.json
  vivieen-thumbnail.png
  vivieen-thumbnail.png.sha256
```

The two AVTR files are release assets for tag `avatars-v1.0.0`; the `catalog/`
tree belongs on the repository's `main` branch. The builder performs no network
operation and never publishes.

Run it against the approved Studio avatar directory:

```sh
python3 shared/avatar-store-v1/build_release.py \
  --avatar-root "/path/to/OpenClam Studio/backend-data/avatars/vivieen" \
  --output "/private/output/openclam-avatar-store-v1"
```

The source must be `ready` and must provide head, full body, walk, edge idle,
and moves. Existing output is rejected rather than overwritten. ZIP order,
timestamps, permissions, and compression are normalized so the same source
bytes reproduce the same archives and checksums.
