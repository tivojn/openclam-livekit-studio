# OpenClam 1.0.15 / Avatar Store 1.0.7

## Avatar corrections

- Explicit Photo, 2D Cartoon, and 3D Cartoon source classification keeps the
  corresponding build, expression, and cutout paths separate.
- Rigid iris translation preserves pupil shape instead of deforming it with
  the surrounding eye. Photo, drawn cartoon, soft 3D, and button-eye 3D artwork
  retain their own masks, texture handling, and blink ownership.
- Soft 3D blink ownership preserves canonical fringe and cheek markings outside
  the eye instead of replacing them with the closing-eyelid plate.
- Mouth-skin ownership, jaw-band removal, and registered head/body composition
  address rectangular mouth patches and doubled jaw/neck outlines without
  regenerating approved faces.
- Cursor gaze follows motion without requiring a click. Head-visibility bounds
  constrain chat-window avatar zoom and placement.
- Face and motion publication are transactional; a failed or interrupted
  rebuild must not replace the last working avatar.

## Chat and delivery corrections

- The iPhone thread uses the rail-safe width, with horizontally scrollable
  starter prompts and the normal attachment composer.
- Save to Photos uses an explicit contrasting symbol in both appearances.
- Paired-agent cancellation is pending until the agent reports a terminal
  result. A delivered cancellation request is not confused with cancellation
  of the underlying job.
- Durable text/file receipts, bounded final-delivery waiting, and replayable
  progress preserve recovery after delayed acknowledgements or reconnects.

## Store publication

Store 1.0.7 updates Ara, Luffy · 2D, and Luffy · 3D; adds Sarah and Celine;
and retains the existing Captain Ayer and Cleo entries. The five new packages
include full-expression iPhone assets and Walk, Edge Idle, and Moves, plus
separate full Mac authoring backups. The legacy `ios-light` profile name remains
part of the public contract and does not indicate a reduced expression rig.

Luffy geometry migration is explicit and pinned to a previously published
package. Decoded body/head/mask pixels and the complete static face-to-body
affine must match. iOS preserves that approved static registration while
disabling dynamic head tilt. New builds still pass the ordinary upright gate.

Catalog and release URLs are immutable, with exact lengths and SHA-256 hashes.
Client endpoint enablement follows public download verification; previous
Store tags and packages remain available for rollback.

The 1.0.6 source tag was an unpublished release candidate. Final visual checks
caught Luffy · 3D blink ownership affecting his fringe and cheek scar; no 1.0.6
release assets were published or enabled in the iOS client. The corrected
candidate uses a new 1.0.7 tag rather than changing the existing source tag.

## Verification scope

Regression suites cover native iOS importing and registration, UI layout,
agent delivery/cancellation, avatar packaging and compositing, and release
source/security contracts. Gaze assets are checked at every authored position;
controlled driver tests exercise the production no-click handlers and renderer.
An automated virtual cursor does not substitute for a physical mouse-follow
check when the operating system supplies a different cursor position.
