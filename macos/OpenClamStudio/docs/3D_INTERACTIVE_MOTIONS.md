# Interactive 3D companions on macOS

An avatar with a local motion library adds **Interactive motions** to the
avatar display menu, in both Chat/Talk and desktop Avatar mode. It can walk
toward the cursor, wave, dance, and use the original Heart, Sitting and
Standing poses. Cursor walking is optional; the existing head/eye gaze
preference remains independent. “Stay” stops walking, clip playback and the
automatic body-pose playlist. Dragging, pinching and orbiting take priority
and pause walking for three seconds. A small conversational nod can be
disabled with **Conversational gestures**.

Direct typed and transcribed commands include “Tia, wave”, “follow my
cursor”, “come here”, “show me a heart”, “sit down”, “stand up”, “dance” and
“stay”. These commands execute locally. Ordinary conversation still uses
the selected assistant. Live Talk's trusted action bridge returns the same
local result and suppresses duplicate playback from the transcript.
Following also accepts phrases such as “walk with the mouse”, “keep
following my cursor”, “move wherever my mouse goes” and polite requests.
Repeating a follow command keeps it enabled; the menu button toggles it.
Movement follows both cursor axes, including diagonals, within the chat's
usable area or the desktop display's work area. The avatar turns toward
travel, slows on arrival and stays visible at the edges. Native movement
preserves subpixel steps so low-speed diagonal travel does not stall.

## Asset pipeline

Meshy's text-to-motion API produces standalone motion clips. Generate the
clips outside the app, then use `scripts/retarget-tia-motion.py` with Blender
to bake an FBX through Tia's original Auto-Rig Pro controls. The script
reads the original Blender scene and matching GLB without changing either.
It calibrates the donor's T-pose to Tia's A-pose, preserves the original
constraint evaluation and affine bone transforms, and exports motion for
the hierarchy actually present in the GLB. Limb clearance and torso range
account for Tia's proportions and fitted clothing.

Place validated clip JSON files in the avatar's `motions/` directory. A
`motions/library.json` file declares the available clips:

```json
{"version":1,"clips":[{"id":"walk","label":"Walk","file":"walk.json"},{"id":"wave","label":"Wave","file":"wave.json"},{"id":"dance","label":"Dance","file":"dance.json"}]}
```

Set `motion_library: true` in the avatar's source manifest and publish its
runtime. Each clip contains `version`, `id`, `fps`, `loop`, `bones` and
`frames`. Every frame contains twelve row-major affine matrix values per
bone, in the named bone order. The loader rejects a mismatched rig, malformed
numbers or nonlocal URLs, and loads clips on demand. A stopped pending load
cannot start playing later. The original GLB, textures, skin weights and
hair remain the avatar's source of appearance.

The app contains no Meshy key and makes no Meshy calls during interaction.
Licensed character files, donor FBX files and private retargeted clips must
stay outside the public repository. A Mac-full avatar export includes the
motion directory; this iteration does not change the iOS package format or
add the new interactive controller to TestFlight.

## Verification

Run `node qa/avatar3d_motion_qa.js`, `node qa/avatar3d_companion_qa.js`,
the existing 3D interaction/fidelity/options/gaze checks, and
`python -m unittest discover -s tests -p 'test_avatar3d*.py'`.
Test the actual original model in Electron as well: synthetic rigs cannot
prove character retargeting quality. Verify both windows, commands, stop
during loading, clothing/prop attachment, manual gestures, screen edges and
Reduce Motion. Include vertical and diagonal cursor paths, repeated follow
requests, mirrored chat, small/large avatars and each work-area edge.
