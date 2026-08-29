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

The `avatar-store-v1.0.3` catalog adds full-expression iOS packages for
`luffy-2d` / Luffy · 2D and `luffy-3d` / Luffy · 3D alongside Ara and Cleo.
Each package is produced by the reviewed Mac AVTR exporter from an approved
avatar project; only its public thumbnail is retained in source. The catalog
pins every release package's exact size and SHA-256 digest.

The immutable `avatar-store-v1.0.4` catalog replaces only `luffy-3d` with the
repaired full-expression package, advances that entry to version 2, and gives
the iOS client a new cache identity. The v1.0.3 catalog and release remain
unchanged for older clients.

The immutable `avatar-store-v1.0.5` catalog advances `luffy-3d` to version 3
with the approved upright, centred head registration and a seamless stylized
jaw-to-neck handoff. It preserves the straw hat, full-expression face assets,
and all three reviewed motion roles. Earlier catalog tags remain unchanged.

## Generic staging layout

`build_release.py` has no production URL, identity, publisher, version, or
filename defaults. All release identity and endpoint values must be supplied
explicitly. For an identifier such as the clearly synthetic `fixture-avatar`,
it produces this unpublished staging layout:

```text
release-assets/
  fixture-avatar-ios-light.avtr
  fixture-avatar-ios-light.avtr.sha256
catalog/v1/
  catalog.json
  catalog.json.sha256
  catalog.schema.json
  fixture-avatar-thumbnail.png
  fixture-avatar-thumbnail.png.sha256
```

iOS-only is the safe default. `--include-macos-full` explicitly adds the Mac
archive and its checksum only when a separately reviewed Mac authoring package
is intended for publication; that archive's own ID and display name must match
the public Store entry.

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

The validator remains compatible with iOS AVTR v2 and motion-capable v3. A
protected Ara or Cleo Store update is stricter: its public package and catalog
identity must be exactly `ara` / `Ara` or `cleo` / `Cleo`, while
`--source-identifier` and `--source-display-name` may name the reviewed local
authoring project. It also requires all of the following:

- `--base-catalog` pointing to the reviewed catalog that already contains
  Captain Ayer, Ara, and Cleo. The builder replaces only the selected avatar
  and verifies that both other rows remain equivalent as JSON data.
- A monotonically higher entry version.
- `--release-tag avatar-store-vX.Y.Z`, with the same immutable tag present in
  the catalog, thumbnail, and GitHub release URLs.
- A full-expression iOS AVTR v4 containing exactly `walk`, `edgeIdle`, and
  `moves` motion roles.
- Two independent normalized exports with byte-for-byte identical results.

These checks only produce a local staging directory. They do not create a Git
tag, upload a release asset, change the checked-in production catalog, or
enable a client URL.
