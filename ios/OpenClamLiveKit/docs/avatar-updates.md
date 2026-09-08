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
the current variant and two prior variants, independently of installed assets. The native wardrobe catalogue is available before GPU loading begins.

Build 68 prepares the texture cache before navigating to the renderer, so
ImageIO work does not overlap WebKit's geometry and GPU allocations on a cold
launch. The iOS bridge uploads textures from every outfit (including hidden
ones) and releases each shared ImageBitmap only after all its textures have
uploaded. This avoids retaining decoded source images through the first
morph-buffer allocation; authored materials and texture pixels are preserved.
A lost graphics context reloads the page instead of reusing closed bitmaps.

WebKit termination and graphics-context loss recover automatically after
2 and then 5 seconds, with smaller texture limits. Duplicate callbacks from a
dead page do not consume another attempt. Recovery waits for the app to become
active, retains the latest frame even if the timeline is paused, and preserves
clothing, props, playback and follow preferences. Preparation has a 120-second
foreground timeout; rendering has a separate 60-second foreground timeout.
Exhausted recovery presents a retry action in Wardrobe & Poses.

Cold-cache launch and actual WebGL context-loss tests cover the startup path.
Simulator success alone does not establish physical-iPhone memory behavior.

## Dynamic motions (build 69)

The optional private `MotionUpdates.bundle` adds a motion library to the signed
application without rewriting the installed GLB or forcing an AVTR reinstall.
Run `stage-motion-update.py --model /path/to/model.glb --motions /path/to/motions`
before a private build. The source bundle is empty and all staged JSON is ignored
by Git. The index records the exact model SHA-256 and every declared file hash
and size. A mismatched custom model never receives the pack. Only indexed paths
are served by the local WebKit scheme, and clip hashes are checked before loading.

The shared macOS motion player loads clips on demand; iOS retains at most two
decoded clips. Wardrobe & Poses offers a searchable motion browser, random dances,
and Stop. React to conversation defaults on and preserves an explicit opt-out.
The ordinary provider reply may carry an allowlisted private reaction category;
the native streaming/final parser removes it before display, history, or speech.
Remote-provider and Live Talk replies use the same conservative local contextual
fallback as macOS. There are no extra inference calls or Meshy calls at runtime.
Text and composer dictation accept explicit motion names and common requests.
Stop takes priority, pauses reactions and the authored pose playlist; Reduce
Motion stops body animation. Existing touch orbit, pinch, placement, gaze,
wardrobe, hand grips, original geometry, and renderer recovery remain available.

Private release verification must inspect the signed archive, confirm all clips
and the model hash, and exercise an existing installed Tia without reimporting.
The optional legacy wardrobe update remains bundled for earlier installations.
