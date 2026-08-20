# OpenClam avatar store v1 contract

Avatar Store is release-disabled in OpenClam v1.0.1. Neither shipped app has a
catalog URL, loads a cached store catalog, or requests remote thumbnails or
packages. Direct AVTR import, library use, export, and deletion are separate
local workflows and remain available.

This directory retains the strict catalog contract and a generic offline
staging builder for a future, separately reviewed store. The catalog root is
exactly:

```json
{"schemaVersion": 1, "entries": []}
```

Each entry contains only `id`, `name`, `author`, `version`, `thumbnail`, and
`variants`. Every entry has exactly an `ios-light` package and a `macos-full`
package. Clients select their own profile, stream the download with progress,
verify its declared byte count and SHA-256, then hand the file to the existing
atomic AVTR v2 importer. A package for the other platform is never used as a
fallback.

## Generic staging layout

`build_release.py` has no production URL, identity, publisher, version, or
filename defaults. All release identity and endpoint values must be supplied
explicitly. For an identifier such as the clearly synthetic `fixture-avatar`,
it produces this unpublished staging layout:

```text
release-assets/
  fixture-avatar-ios-light.avtr
  fixture-avatar-ios-light.avtr.sha256
  fixture-avatar-macos-full.avtr
  fixture-avatar-macos-full.avtr.sha256
catalog/v1/
  catalog.json
  catalog.json.sha256
  catalog.schema.json
  fixture-avatar-thumbnail.png
  fixture-avatar-thumbnail.png.sha256
```

The builder performs no network operation and never publishes. Its explicit
URLs only populate the staged catalog; approving media, selecting a repository,
and enabling either client require a separate release review.

Synthetic example (these fixture endpoints are not a shipped store):

```sh
python3 shared/avatar-store-v1/build_release.py \
  --avatar-root "/path/to/avatars/fixture-avatar" \
  --output "/private/output/avatar-store-fixture" \
  --identifier "fixture-avatar" \
  --display-name "Fixture Avatar" \
  --author "Example Publisher" \
  --version 1 \
  --catalog-url "https://raw.githubusercontent.com/openclam-fixtures/avatar-store-fixtures/main/catalog/v1/catalog.json" \
  --release-url "https://github.com/openclam-fixtures/avatar-store-fixtures/releases/download/fixtures-v1" \
  --thumbnail-url "https://raw.githubusercontent.com/openclam-fixtures/avatar-store-fixtures/main/catalog/v1/fixture-avatar-thumbnail.png"
```

The source manifest identity must match the explicit identifier and display
name, must be `ready`, and must provide head, full body, walk, edge idle, and
moves. Existing output is rejected rather than overwritten. ZIP order,
timestamps, permissions, and compression are normalized so identical source
bytes and arguments reproduce identical archives and checksums.
