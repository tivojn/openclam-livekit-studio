# OpenClam 1.0.16 — avatar controls and cartoon speech parity

## Mac interaction and framing

Selected-reply Copy and Ask AI actions follow the light/dark surface and text
colours. Right-clicking the avatar in Chat/Talk opens the avatar controls;
selected text and editable fields retain their own context menus. The composer
uses native macOS editing actions, including undo, redo, cut, copy, paste, paste
and match style, and select all.

Standby and Close-up remember separate user-adjusted sizes in Chat/Talk and
desktop Avatar mode. Command-Shift-9 reanchors the remembered close-up size at
the bottom-right of the applicable canvas. Command-Shift-0 recalls the saved
standby size; a factory reset remains a separate explicit menu action.

Pinch resizing changes the avatar camera without enlarging a desktop window
beyond its screen. The crown, hair, and headwear stay within the top edge of the
chat canvas or screen, including when the body extends below the close-up view.
Standby no longer stops enlarging at four times its base size or at the native
window boundary. Close-up uses the same complete body: shrinking it progressively
reveals the legs and feet without requiring a switch to Standby. At an
intentionally extreme enlargement the lower face and body may extend below the
canvas; keeping the crown inside the top edge does not silently reduce the
requested size. Reversing a pinch changes the rendered size immediately.

## iPhone mouth composition

The stylized renderer replaces the complete authored mouth interior, including
the neutral mouth corners, instead of exposing the resting smile through a
difference-only mask. Speech and emotional mouth artwork resolve into one
replacement plate before composition. The surrounding canonical face, nose,
jaw, and approved static head/body registration stay unchanged.

Soft-3D mouth plates can use measured lip contours to match surrounding skin
without recolouring lips or teeth. Spatial correction is bounded to 65,536
pixels; larger plates retain the bounded constant-tone fallback. Resolved
plates use a bounded 96-entry, 24 MiB cache.

Photorealistic avatars retain their separate renderer. Legacy cartoon packages
without authored mouth bounds retain their existing speech route rather than
losing lip movement. Drawn cartoons do not use soft-3D skin correction.

## Authoring and package compatibility

Cartoon mouth preparation can use a rigid pixel registration of the unchanged
upper face when human-face landmarks introduce a false tilt. The refinement
requires high correlation, a small rigid motion, and a measured improvement
over the existing alignment. It does not scale or shear the artwork, and it
does not run for photographs or blink plates. Neutral mouth-corner ownership
is opaque, with the skin transition outside the lip artwork rather than
through it. Retained raw plates can be reprocessed without regenerating the
approved head, body, gaze, blink, or motion assets.

Closed-mouth expression cells for explicitly classified cartoons also cover the
canonical outer lip corners. Their alpha mask gains a small opaque margin and
an outer skin feather, without changing any RGB artwork or the other fourteen
speech shapes. This prevents the original smile corners from showing through
a narrower closed expression, as found in Celine's seventeen closed cells.
Photographs and unclassified legacy packages keep their existing masks.

Successful cartoon registration is bound to the exact canonical and processed
files and their decoded pixels. Expression export verifies that proof before
skipping a second global mouth-centering offset. Replaced files, stale metadata,
unknown or duplicate shapes, photographs, and unproven legacy banks do not take
that shortcut.

The Mac exporter can include optional, public-only soft-3D lip-contour geometry
in full-expression iPhone packages. Exporting this geometry does not regenerate
or alter the approved image and animation assets. Complete per-viseme and
per-emotion contours are validated for finite coordinates, canonical bounds,
registration, polygon shape, and bounded serialized size.

The new contour field requires the matching updated iOS decoder. Previously
published Store catalogs and downloads remain immutable so earlier iOS builds
continue to use compatible packages. New Store endpoints are enabled only after
the exact downloadable archives pass native importing and public hash checks.

## Verification scope

Qualification separates native app speech captures, exact-package import tests,
and controlled CoreGraphics pixel comparisons. A clean compositor result does
not certify malformed source artwork: the per-avatar audit also checks the
original processed mouth plates. Host timing measurements are not advertised
as physical-iPhone frame-rate measurements.
