# OpenClam Studio 1.0.25

Ordinary dragging consistently moves the 3D avatar in Chat and Avatar modes.
The latched “Rotate 3D view” mode has been removed from both menus. Two-finger
swipes rotate the avatar; pinch resizes it. Option-drag remains an explicit
rotation shortcut and never changes how the next ordinary drag behaves.

Tia’s local walk and run clips were rebaked from the existing downloaded
motions. The locomotion bake uses the source pelvis-to-chest direction to
preserve posture instead of losing the source lean relative to its bind pose.
An optional two-bone solve gives the boots separate lateral paths while
preserving limb lengths, knee flexion and foot orientation. This is an offline
bake; it adds no per-frame runtime solver or network dependency. The original
model, skin weights, wardrobe, hair and other 60 clips are unchanged.

Validation includes ordinary drag after swipe and Option-drag in chat, desktop
and desktop close-up placement, plus the real Tia rig across three locomotion
loops. The gait checks cover pelvis-relative foot clearance, knee excursion,
upright walking and forward running posture. The full rig regression also
covers all 62 clips, punch endings, camera gaze and stage containment.

The proprietary motion library remains local and is not part of the public
source repository or macOS DMG. Existing local Tia installations need motion
library revision 5 for the gait corrections.
