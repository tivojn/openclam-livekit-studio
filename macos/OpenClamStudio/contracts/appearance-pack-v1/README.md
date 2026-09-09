# Optional appearance packs (.oclook)

An appearance pack is a ZIP of runtime data for an **exact installed model**, identified by the SHA-256 of its original GLB. It adds clothing/hair visibility combinations, color textures, original facial deformations, and an optional studio environment. New mesh geometry or another model belongs in a complete `.avtr` avatar package.

Both Mac and iOS provide Files import, direct HTTPS download with progress/cancellation, and pack removal. There is no public asset catalogue or hardcoded private asset URL. Hosts and users must have rights to their packs. Neither the Blender project nor executable scripts belong in a runtime pack.

`appearance.json` contains `format: "openclam-appearance"`, `version: 1`, `id`, `label`, `modelSHA256`, `files`, and `items`. Each file entry declares its exact byte size and SHA-256. Items have an ID, label, and kind:

- `clothes` / `hair`: `nodes` and optional `hideNodes` name original glTF source nodes.
- `texture`: `file`, `material`, optional `nodes`, and a `slot` to replace one selected color independently.
- `expression`: `file`, optional `region` (`mouth`, `eyes`, `brows`). The JSON has version 1 and mesh entries with source `node`, `primitive`, base vertex `count`, ascending unique little-endian base64 UInt32 `indices`, and base64 Float32 XYZ `deltas`. Positions are relative to the unchanged GLB mesh basis. Selected mouth controls attenuate during speech; selected eye controls yield during a blink.

An optional `environment` declares a half-float RGBA `.bin`, width, height, and Y-axis rotation in radians. This is decoded into a filtered environment map by the renderer; it is not a background image.

Limits: 384 MiB compressed/expanded per pack, 32 MiB per asset, 256 assets/items, 16 installed packs, 512 KiB manifest, 2 MiB combined catalogue. Paths are flat safe filenames; image textures are PNG/JPEG up to 2048 pixels per dimension. Environment maps are at most 1024×1024. Files, sizes and checksums are verified before the installed index is switched atomically. Failed installation preserves the prior index and avatar model.

Only selected textures and one selected original expression are decoded by the renderer. Replaced textures/bitmaps and environment targets are disposed. Removing a pack restores original textures, hair visibility, and environment. The base GLB stays unchanged.

Studio portrait is the default for Tia. Soft studio and Classic are reversible alternatives. The skin effect is bounded wrapped diffuse scattering; the eye surface has adjusted roughness and IOR. This is a real-time approximation, not the original offline Cycles shader or a promise of pixel-identical gallery renders.

To build a pack from prepared runtime assets: `.venv/bin/python scripts/package-appearance.py /path/to/prepared-pack --model /path/to/model.glb --output /path/to/new.oclook`. The builder runs the same installer checks before producing the output and refuses to overwrite an existing pack.
