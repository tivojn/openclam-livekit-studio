# OpenClam avatar store v1 contract

Avatar Store publication is deliberately split from client enablement. The
catalog and hash-pinned release assets must be publicly reachable and verified
before an app release is allowed to set its production catalog URL. Direct
AVTR import, library use, export, and deletion remain separate local workflows.

This directory retains the strict catalog contract and a generic offline
staging builder for a future, separately reviewed store. The catalog root is
exactly:

```json
{"schemaVersion": 1, "entries": []}
```

Each entry contains only `id`, `name`, `author`, `version`, `thumbnail`, and
`variants`. Every entry has an `ios-light` package; a `macos-full` package is
optional and may be listed only when reviewed Mac authoring media exists.
Clients select their own profile, stream the download with progress, verify its
declared byte count and SHA-256, then hand the file to the existing atomic AVTR
importer. A package for the other platform is never used as a fallback.

`build_bundled_ios_catalog.py` stages the two user-authorized identities already
shipped with iOS: Captain Ayer and Ara. Their Store packages use the same IDs as
the protected bundled fallbacks. Only the Store's pinned verification path may
install these updates; Files import remains collision-blocked, and the bundled
fallback remains undeletable.

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
