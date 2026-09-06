# Offline avatar updates

An iOS update can carry a replacement for an exact earlier imported 3D model.
At launch, the app matches the installed avatar ID and model SHA-256 against
the signed resource index, verifies the replacement archive SHA-256, and uses
the existing validated, atomic AVTR installer. It preserves the avatar ID,
conversation, framing, and appearance preferences. Already updated or custom
models are skipped, and deleted avatars are never restored.

The public source contains an empty `AvatarUpdates.bundle/updates.json`.
For a private TestFlight delivery, stage the user's authorized package before
building:

```sh
python3 stage-avatar-update.py --package /path/to/wardrobe.avtr \
  --previous /path/to/earlier.avtr
xcodegen generate
```

Repeat `--previous` for each supported earlier archive or installed package
directory. The staging tool verifies each actual model hash. This writes a
git-ignored archive and `updates.local.json` inside the resource bundle.
Keep these private files out of GitHub and public installer artifacts.
Use a clean checkout with only the empty index for a public build.

Before uploading, inspect the actual signed archive for the resource bundle,
verify its package hash and target model against the source package, then
test upgrading an existing installation with an earlier package. Installing
the wardrobe manually in the simulator does not validate automatic delivery.

If an upgrade fails, the existing model remains usable. The Wardrobe & Poses
sheet displays the error and a retry action. Files import remains available
for custom packages; it explains when Live Talk temporarily blocks imports.


## iOS rendering memory

Packed GLBs are served to WebKit as a read-only glTF document, individual
original buffer views, and PNG textures decoded by ImageIO at a bounded size.
The installed GLB, all geometry/sparse accessors, skin matrices, materials,
pose data, and UVs remain unchanged. Texture scaling preserves aspect ratio
and alpha, uses at most a 2048-pixel longest edge, and selects a smaller common
limit when all decoded textures would exceed 256 MiB. Small custom assets with
inline data URIs retain the original loader path.

The resource worker serializes decoding off the main thread and cancels stale
requests. Decoded PNGs are cached on disk by the actual model SHA-256, texture
limit, and decoder version; damaged entries are regenerated. The cache keeps
the current variant and two prior variants, independently of installed assets. The native wardrobe catalogue is available before GPU loading ends.
A first WebKit process interruption retries once with a smaller texture limit;
a second interruption or a 60-second load timeout presents a retry action in
Wardrobe & Poses. Saved clothing, props, playback, and follow preferences survive
recovery. Build 67 adds this path after build 66 exposed large texture memory
use on a physical iPhone; simulator success alone does not establish hardware
memory behavior.
