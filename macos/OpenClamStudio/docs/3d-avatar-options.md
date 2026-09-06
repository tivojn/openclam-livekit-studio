# Wardrobe and authored poses

A 3D avatar can include selectable outfits, props, and saved body/hand poses.
On macOS, open the avatar display menu and expand **Wardrobe & poses**;
in Avatar mode, right-click the character and choose **Wardrobe & poses…**.
On iOS, open **3D view controls → Wardrobe & Poses**.
The menu appears when the installed GLB includes an options library.

Choices are saved per avatar. Body pose choices clear hand overrides. A prop
can select its matching grip/body pose; hands can then be adjusted separately.
**Reset appearance & pose** restores the default outfit, relaxed standing,
and no prop. Rotate, move, pinch, and reset-view controls remain independent.
Poses blend over 650 ms; Reduce Motion applies them immediately. These are
transitions between authored static poses, not newly supplied animation clips.

An older avatar import needs an updated private asset package to expose its
additional clothing and poses. Updating the app does not add missing artwork.
The iPhone export now preserves the Mac GLB exactly, including its textures
and options metadata, for the shared renderer introduced in iOS build 62.

## Optional GLB metadata

`extras.openclamAvatar` carries `version: 1`, a `rest` object keyed by unique
bone source names, and a `poses` array. Each pose has `id`, `label`, `group`
(`body`, `hands`, `leftHand`, or `rightHand`) and `deltas`. A delta is a finite
4 × 4 row-major matrix representing the authored transform in model space
relative to the original bone world matrix. Hand layers replace only the
specified bones' local transforms after the body pose. Keep affine transforms
from rig stretch constraints; do not silently discard shear.

`outfits` and `props` contain `{id, label, nodes}` entries naming glTF nodes.
`defaultOutfit` identifies the initially visible outfit. A prop may add `pose`
with a matching body pose ID. Prop nodes should already be attached to the
correct joint in the glTF hierarchy. Geometry, materials, skin weights, inverse
bind matrices, and non-expression fitting morphs are preserved by the player.

The renderer accepts up to 256 poses and 512 uniquely matched bones. Metadata
is data only; it executes no asset-supplied scripts. UI labels are inserted as
text, and mobile resources stay on the existing local URL allowlist.

## Validation

`qa/avatar3d_options_qa.js` checks affine bone transforms, hand layers,
wardrobe/prop visibility, reduced motion, and repeated resets. The existing
fidelity and interaction checks cover model appearance, projection, gaze,
rotate/move/pinch controls, and resource packaging. iOS includes saved-selection
unit coverage and an optional UI test against an installed private 3D fixture.
