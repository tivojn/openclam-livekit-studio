# 3D avatars

OpenClam Studio can drive a rigged 3D character with the same timed viseme
track that animates its 2D sprite avatars. A 3D avatar is one self-contained
glTF binary (`.glb`) whose facial shape keys the renderer maps onto the
Oculus/Meta XR 15-viseme set (`sil PP FF TH DD kk CH SS nn RR aa E ih oh ou`).
Nothing is generated: the model already carries its mouth shapes, so an
imported model is ready to activate immediately.

The 2D pipeline is untouched. Portrait avatars keep every Studio step
(visemes, body, walk, edge idle, moves, AVTR export). A 3D avatar simply takes
a different branch when the desktop page reads `assets/manifest.json` and finds
`"renderer": "3d"`.

## What a model needs

| Feature | Accepted shape-key names (case-insensitive) | Without it |
| --- | --- | --- |
| Lip sync | `vrc.v_aa`, `v_aa`, `viseme_aa` … for all 15 visemes; VRM `A I U E O` / `Fcl_MTH_*` vowels | Approximated from ARKit shapes (`jawOpen`, `mouthFunnel`, `mouthPucker`, `mouthClose`, `mouthStretch*`, `mouthRollLower`, `tongueOut`) |
| Blink | `eyeBlinkLeft/Right`, `vrc.blink_left/right`, `blink`, `Fcl_EYE_Close*` | Eyes stay open |
| Gaze | ARKit `eyeLook{Up,Down,In,Out}{Left,Right}` or eye bones | Head turn only |
| Mood | ARKit brow / smile / frown / cheek shapes, VRM `Fcl_ALL_*` | Neutral face |
| Head follow, breathing | Bones named like `head`, `neck`, `spine_02` / `chest`, `hips` (UE, Mixamo, VRM and Auto-Rig Pro spellings) | Static pose |

Requirements enforced at import:

- glTF 2.0 binary (`.glb`) with embedded buffers and textures, at most 256 MB.
- No `KHR_draco_mesh_compression`, `EXT_meshopt_compression`, or
  `KHR_texture_basisu`; the app ships no decoders for them.
- At least one morph target or one skeleton joint.

The renderer resolves names itself, so a VRoid, Ready Player Me, Character
Creator, MakeHuman or Auto-Rig Pro export usually works unmodified. Rest poses
in A- or T-pose are relaxed automatically: each arm is turned so the forearm
hangs beside the body when it starts more than about 20° from vertical.

## Preparing a heavy studio export

Character packs can contain hidden alternate outfits, render subdivision,
body-fit shape keys, and material graphs that glTF cannot represent directly.
The preparation script preserves the saved visible character by default:

```bash
blender --factory-startup -b --disable-autoexec --python-exit-code 1 \
  --python scripts/prepare-3d-avatar.py -- \
  --input Character.blend --output character-openclam.glb
```

The exporter selects visible, renderable meshes from the saved view layer and
retains their skeleton dependencies. Hidden alternatives stay hidden. Active
non-facial shape keys are baked into the basis and retained facial targets.
Render subdivision is evaluated on every facial target, retaining UVs and skin
weights. Material color/scalar arithmetic is baked to textures; the exporter no
longer chooses an arbitrary input image from a mix graph. Glass is exported as
transmission, using the shader connected to the source render output.

Rigid `Child Of` bone attachments are preserved as glTF hierarchy links,
including hairstyles with their own skeletons. The entire accessory rig follows
the head, while its bind pose, skin weights and internal joints stay intact.
Controllers omitted by deform-only export resolve only to a unique coincident
deform child. Partial or ambiguous constraints stop preparation for explicit
conversion instead of silently leaving an accessory behind.

For the supplied **Tia-001.1 Blender scene**, use:

```bash
blender --factory-startup -b --disable-autoexec --python-exit-code 1 \
  --python scripts/prepare-3d-avatar.py -- \
  --input Blender/Tia-001.1.blend --output tia-original-scene.glb \
  --texture-size 4096 --secondary-size 1024 --image-quality 90
```

This retains the saved blonde ponytail, tan jacket, scarf, skirt, and boots.
The previous example assembled hidden long-hair and white-top alternatives and
replaced the painted skin material. It did **not** reproduce the saved scene.
The original `.blend` and ZIP archives are never modified.

Optional overrides are deliberate appearance changes:

- `--drop REGEX` removes named objects; `--include REGEX` enables hidden pieces.
- `--base-color MATERIAL=IMAGE`, `--assign-material REGEX=MATERIAL[@IMAGE]`,
  and `--parent-to-bone REGEX=ARMATURE:BONE` customize selected pieces.
- `--bake MATERIAL[=SIZE]` forces a base-color bake at a chosen resolution.
- `--control-cage` omits surface modifiers; `--legacy-simplify` uses the old
  lossy material conversion. Neither is appropriate for source fidelity.
- `--no-simplify` leaves shader graphs for glTF's native material exporter.

The real-time renderer preserves glTF alpha modes, cutoffs, sidedness and
transmission. Animation changes only recognized facial channels; body and
wardrobe morph values remain intact. Blender-specific subsurface scattering,
area lighting, and Filmic color management are not reproduced exactly by the
real-time renderer, so an offline render is a reference rather than a promise
of identical pixels. Source subdivision also increases model size and GPU cost.

Preparation regression checks (requires Blender with NumPy and Cycles):

```bash
blender --factory-startup -b --disable-autoexec --python-exit-code 1 \
  --python qa/prepare_3d_fidelity_qa.py
node qa/avatar3d_fidelity_qa.js
```

## Importing

- **Settings → Avatars → Import 3D model (.glb)…**, or drop a `.glb` on the
  portrait well. The card reports how many visemes come straight from the
  model and warns about anything approximated or missing.
- Headless: `.venv/bin/python scripts/import-3d-avatar.py model.glb --name Tia`.

Activate it like any avatar. The first time it renders, the page posts one
face snapshot back to the backend so the deck and carousel show the real
character instead of the placeholder card.

## How lip sync reaches the model

1. `/say` and Live Talk keep producing `[time, viseme]` tracks exactly as
   before (`server/visemes.py`, `server/align.py`).
2. The page's `desiredViseme(now)` picks the viseme for the current audio
   sample, including the reactive mic path used by Live Talk.
3. `web/avatar3d.js` keeps a smoothed weight per viseme (≈38 ms attack, ≈64 ms
   release), so fast consonant–vowel runs pass through real in-between shapes
   instead of snapping. Audio level scales articulation between 58% and 100%.
4. Blink, cursor gaze, micro brow moves, speech-mood shapes, head follow, idle
   sway and breathing reuse the same helpers as the 2D face and are applied as
   morph weights and small world-space bone rotations.
5. The page asks the renderer for exactly the on-screen part of the logical
   1024×1536 portrait at its on-screen pixel size (a camera view offset), then
   draws it through `cameraFor` / the chat edge-idle fit. Close-ups are as
   sharp as the full figure, zoom-outs stay cheap, and mirroring, opacity and
   pixel hit-testing behave as they do for a cutout portrait.

## Runtime bundle

```
avatars/<slug>/
  manifest.json          renderer: "3d", status: ready, viseme_coverage, warnings
  model.glb              the imported model (0600)
  keyframe.png           card face (placeholder, then the renderer snapshot)
  runtime/
    manifest.json        v, renderer, w, h, model: "assets/model.glb", visemes
    model.glb            hard link to the source model
```

`ensure_runtime` republishes this bundle when `RUNTIME_VERSION` moves, the
same trigger the 2D exporter uses. Portrait-only routes (build, calibrate,
body, pipeline, AVTR export) reject 3D slugs with a clear message; persona,
companion, rename, thumbnail and delete work unchanged.

## iPhone

A 3D avatar exports as an `ios-3d` AVTR (**Export iPhone 3D AVTR** on its
card, or `GET /api/avatar/export?slug=…&variant=ios-3d`). The package is three
files: `manifest.json` (version 5, variant `ios-3d`, the projected figure and
face rectangles, and viseme coverage), `assets/thumbnail.png` (512 px) and
`assets/model.glb`. WebP textures are transcoded to PNG/JPEG on export because
Apple's glTF loaders do not read `EXT_texture_webp`; the model must stay under
64 MB after transcoding (80 MB archive). Import it on the iPhone like any
AVTR; the iOS app renders it with SceneKit through GLTFKit2 and drives the
same viseme, blink, gaze and mood channels. Normative shape:
`shared/avatar-package-v2/ios-3d-v5.schema.json`.

## Not yet

- Mac-project (`macos-full`) export/import of 3D avatars (share the `.glb`).
- Walk, edge idle and authored moves: a 3D avatar stands, breathes and looks
  around; clip-based motion stays a 2D feature until skeletal clips land.
- The Avatar Store catalog lists only sprite packages.
