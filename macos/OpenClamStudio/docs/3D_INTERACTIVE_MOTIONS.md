# Interactive 3D companions on macOS

An avatar with a local motion library adds **Dynamic motions** to the
avatar display menu, in both Chat/Talk and desktop Avatar mode. It can walk
toward the cursor, wave, dance, and use the original Heart, Sitting and
Standing poses. Cursor walking is optional; the existing head/eye gaze
preference remains independent. “Stay” stops walking, clip playback and the
automatic body-pose playlist and conversation reactions. Dragging, pinching and orbiting take priority
and pause walking for three seconds. A small conversational nod can be
disabled with **Conversational gestures**.

Typed and spoken requests always go through the selected LLM. It answers from
the full exchange and decides whether a performance is appropriate. Mentioning
“kungfu” can lead to a clarification or discussion; it never triggers a local
canned response. Direct chat carries an optional private category, installed
`clip:ID`, or allowlisted `action:ACTION` in the ordinary model reply. That cue
is stripped before display, history and speech. No second inference is needed.
Live Talk keeps avatar expression in its voice LLM, outside the external-action
bridge. Providers without private cues use conservative matching of an
affirmative performance statement in the assistant reply, never input alone.
Manual menu buttons still control playback immediately.

Following also accepts phrases such as “walk with the mouse”, “keep
following my cursor”, “move wherever my mouse goes” and polite requests.
Repeating a follow command keeps it enabled; the menu button toggles it.
Movement follows both cursor axes, including diagonals, within the chat's
usable area or the desktop display's work area. The avatar turns toward
travel, slows on arrival and stays visible at the edges. Native movement
preserves subpixel steps so low-speed diagonal travel does not stall.

## Dynamic motions

**React to conversation** is enabled by default and can be switched off in
Dynamic motions. A happy reply can produce a smiling dance or cheer,
a greeting chooses a wave, and affection chooses an overhead heart. Choices
are randomized within the matching category without repeating the previous
clip when another is available. The LLM can also select a fighting preset when
a demonstration fits the conversation.

The model's explicit `none` suppresses a reaction. Unsupported motion IDs and
non-animation actions are rejected. Requests without an AI reply never play.
An AI-selected demonstration uses full-body framing and takes over cursor
walking or ambient animation; mood reactions wait for those activities.
Mood reactions have a 20-second cooldown and expire after 12 seconds.
Dragging, rotating, resizing, Reduce Motion, held props and Stop take priority.

The browser under Dynamic motions supports search and categories. A preset
can also be requested by name, for example “play jazz dance”, “try hip hop”,
“do kung fu” or “show an overhead heart”. The desktop right-click menu has
the same catalog grouped by category. Clips load on demand, with at most
four decoded clips retained. Smiles use the existing facial channels and
fade with the clip. Tia's authored hand poses supply fist, point and thumbs-up
articulation where the donor rig has no fingers; selected prop grips win.

## Asset pipeline

Meshy's text-to-motion and preset Animation APIs produce standalone motion clips. Generate the
clips outside the app, then use `scripts/retarget-tia-motion.py` with Blender
to bake an FBX through Tia's original Auto-Rig Pro controls. The script
reads the original Blender scene and matching GLB without changing either.
It calibrates the donor's T-pose to Tia's A-pose, preserves the original
constraint evaluation and affine bone transforms, and exports motion for
the hierarchy actually present in the GLB. Limb clearance and torso range
account for Tia's proportions and fitted clothing.

Use `--preset` for the Meshy preset rig. The bake preserves airborne motion,
resamples long clips to at most 900 frames without changing duration, and
records a camera envelope so jumps and raised hands stay in frame. Render
meshes are discarded only from the temporary bake session to speed up rig
evaluation. The source project is never saved.

Place validated clip JSON files in the avatar's `motions/` directory. A
`motions/library.json` file declares the available clips:

```json
{"version":1,"clips":[{"id":"walk","label":"Walk","file":"walk.json"},{"id":"wave","label":"Wave","file":"wave.json"},{"id":"dance","label":"Dance","file":"dance.json"}]}
```

Set `motion_library: true` in the avatar's source manifest and publish its
runtime. Each clip contains `version`, `id`, `fps`, `loop`, `bones` and
`frames`, plus optional model-space `bounds`. Library entries may include
`category`, `aliases`, `reactions`, `requiresFreeHands`, authored hand-pose
IDs and `expression` values. Every frame contains twelve row-major affine matrix values per
bone, in the named bone order. The loader rejects a mismatched rig, malformed
numbers or nonlocal URLs, and loads clips on demand. A stopped pending load
cannot start playing later. The original GLB, textures, skin weights and
hair remain the avatar's source of appearance.

The app contains no Meshy key and makes no Meshy calls during interaction.
Licensed character files, donor FBX files and private retargeted clips must
stay outside the public repository. A Mac-full avatar export includes the
motion directory; iOS uses the same conversation controller and motion resources through its
existing signed motion-update bundle.

## Verification

Perspective travel uses a normal starting distance. “Come closer” plays the
walking cycle while bringing the face toward the viewer; repeated requests
continue from the current distance. “Step back” can pass the starting distance,
making the figure smaller, and coming back restores its normal size. Camera
field of view, mesh proportions, clothing, and hair are preserved. “Stay”
freezes the current position. Reset 3D view restores ordinary framing.

The studio stage maps its upper edge to the far distance, its vertical middle
to the chosen normal size, and its lower edge to the near distance. A shared
reciprocal-distance projection changes the uniform presentation scale as the
actor moves in depth. It never stretches the model or changes the lens field
of view. “Go to the upper-right corner” chooses that destination directly;
no cursor movement is required. Named corners, edges and center are also in
the Walk to menu on both platforms. Manual gestures cancel a pending route.

“Walk around” and “run around” select successive destinations on both axes of
the available chat window or desktop work area, turn toward travel, and use
the appropriate loop and speed. Same-depth travel and poses retain the chosen
size. The standing bounds define framing; raised arms and kicks no longer
trigger automatic zoom-out. The renderer extends the visible crop instead.
Automatic resting/docking and motion-triggered Standby switching are disabled
for 3D. Manual resizing remains available and manual gestures cancel roaming.

Travel is planned on the studio floor, then heading is calibrated against the
actual projected ground path after scale and framing changes. The camera's
ground foreshortening determines the body angle; the actor turns into alignment
before translating. Cadence follows the rendered ground speed, and its natural
speed limit also limits translation. A continuous animation clock preserves the
foot cycle while slowing or turning. The library's gait
calibration revision 1 measures speed from the donor root trajectory, or from
the supporting foot when the donor already runs in place. Library revision 4
adds that metadata to the revision-3 anatomical corrections.

An explicit “come closer” attends to the camera through the approach and on
arrival. It compensates the walking clip's authored head turn, then converges
both eyes on the lens independently of the pointer. Head and neck limits
remain active while turning. Manual gestures or another motion command
release camera attention; the follow-cursor opt-out remains available.

All conversational requests still go through the selected LLM. Validated
completed-reply cues or affirmative replies select spatial actions. Live Talk
relays the action once to its visible peer, which moves within its own viewport
without acquiring another call. Manual controls do not require an LLM roundtrip.

Run `node qa/avatar3d_locomotion_qa.js` for stable framing, perspective distance,
repeat/back/stop, aspect, bounded routes, running speed, and Live Talk action
handoff. The iOS UI audit `testSpatialMotionsAndCloseApproach` exercises the
installed library and captures standing, running, close approach and step back.

Run `node qa/avatar3d_motion_qa.js`, `node qa/avatar3d_companion_qa.js`,
the existing 3D interaction/fidelity/options/gaze checks,
`python -m unittest discover -s tests -p 'test_avatar_reactions.py'`, and
`python -m unittest discover -s tests -p 'test_avatar3d*.py'`.
Test the actual original model in Electron as well: synthetic rigs cannot
prove character retargeting quality. Verify both windows, commands, stop
during loading, clothing/prop attachment, manual gestures, screen edges and
Reduce Motion. Include vertical and diagonal cursor paths, repeated follow
requests, mirrored chat, small/large avatars and each work-area edge.

## Live Talk between desktop modes

Chat/Talk and Avatar mode share one application-owned LiveKit session. Changing
presentation hides one window and shows the other; the original renderer keeps
its microphone and remote audio, and mirrors mouth/expression/motion frames to
the other view. Both views show the call state and can hang up. Ending a call
retains its lease until pending connection/microphone work has drained. Reloads
and renderer crashes release that document's lease; stale cleanup cannot end a
new call. The user starts Live Talk once and changes modes without calling again.

Validate with `node qa/live_talk_owner_qa.js` and
`node_modules/.bin/electron qa/live_talk_ipc_qa.cjs`. The latter exercises the real
sandboxed preload and Electron IPC with two windows; neither test opens a
microphone or connects to a voice service.

## Motion weight transfer

Retargeting revision 2 transfers all three axes of the source pelvis trajectory,
scaled to Tia's leg length. Revision 1 discarded horizontal translation, which
made planted feet swing under an almost stationary pelvis. Use `--in-place` for
walking driven by the companion's screen movement: it removes net travel while
preserving the within-step hip shift. Other actions retain their source travel.

Existing revision-1 private libraries can be migrated with
`scripts/repair-tia-root-travel.py` in Blender. Supply the original read-only
`--blend`, `--model`, `--clips`, one or more `--fbx` directories, and a separate
`--output` directory. It changes coherent body translation only, preserving all
bone rotations/scales, vertical grounding and airborne motion. Keep a backup,
validate with `qa/tia_grounding_qa.py --model MODEL --before OLD --after NEW`, then
publish the new library. No Meshy request or new credit expenditure is needed.

## Motion anatomy

Retargeting revision 3 also calibrates the ankle and toe coordinate bases.
Preset bind poses can already be mid-stride; transferring their rotation
deltas without this calibration curls a foot upwards. The preset rigs use
toe-tip directions. SMPL-H terminal display bones have arbitrary tails, so
their neutral toe direction comes from the footprint instead.

Head and neck tracks are evaluated relative to the animated torso. Ordinary
looks are preserved. When a donor keeps its head facing forward while the
body turns backwards, the invalid look smoothly fades to the torso direction
before reaching the quaternion's 180-degree boundary. This fixes the Kung Fu
Punch ending and excessive turns in kick clips. Corrections are baked through
Tia's original controls so the face, eyes and hair remain attached together.

Rebake existing clips with `scripts/retarget-tia-motion.py`, preserving each
clip's preset and in-place settings. Publish the new library only after an
audit against the original model. The translation-only revision-2 migration
does not perform these corrections. Geometry and inverse bind data stay
unchanged. The same private clips are staged into the iOS motion bundle.

Run `node qa/tia_motion_rig_qa.js MODEL.glb OLD_MOTIONS NEW_MOTIONS REPORT.json`
to exercise the actual exported skeleton through playback and its return to
standing, including the backward-head and running-foot regressions, authored
heart-pose returns and extreme gaze input. The optional iOS UI audit
`testKungFuEndingAndRunningFeet` captures those motions in the shared renderer.
The rig audit also measures head and optical-axis error during both camera
approach gaits. `qa/avatar3d_locomotion_qa.js` checks travel/heading alignment,
reversals, perspective boundaries and cadence; `qa/avatar3d_fidelity_qa.js`
checks camera attention on flattened and nested neck hierarchies.
