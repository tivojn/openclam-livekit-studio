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

Repeat `--previous` for each supported earlier package. This writes a
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
