# Design QA — macOS Chat/Talk Codex-style workspace

## Source and implementation evidence

- Primary structure reference: `Screenshot 2026-08-28 at 9.22.53 AM.png`
- Split-pane/detail reference: `Screenshot 2026-08-28 at 9.23.02 AM.png`
- Latest implementation, details open: `/private/tmp/openclam-ui-qa/implementation-details-open.png`
- Latest implementation, staged attachment: `/private/tmp/openclam-ui-qa/implementation-attachment-chip.png`
- Final Edge Idle/control-safe state: `/private/tmp/openclam-ui-qa/final-edge-idle-details-open.png`
- Final response actions and rail-safe message state: `/private/tmp/openclam-ui-qa/final-response-actions-and-safe-rail.png`
- Normalized side-by-side comparison: `/private/tmp/openclam-ui-qa/reference-vs-implementation.png`

The reference and implementation were normalized to the same 1112 × 768 comparison viewport. The comparison covers the persistent history pane, task header, central conversation, floating composer, right-side task details, and the avatar control rail. Product-specific content remains OpenClam content; the visual hierarchy, sizing, neutral palette, and three-pane behavior follow the supplied Codex reference.

## Iterations and resolved findings

### Iteration 1 — structure and behavior

- P1 resolved — the left history pane and right task-details pane now have independent persistent fold/unfold controls.
- P1 resolved — Settings lives in the left sidebar; the rail chevron occupies the previous gear position and points right when folded/down when open.
- P1 resolved — the composer attachment action now exposes File, Photo Library, and Camera, with removable staged previews.
- P1 resolved — each history row exposes its ellipsis only on hover or keyboard focus and offers Pin/Unpin and Delete.
- P2 resolved — the empty-thread instruction was removed.

### Iteration 2 — collision and safe-area correction

- P1 resolved — right-aligned user messages reserve a real 58 px control gutter, so short text such as `hi` cannot sit beneath the rail.
- P1 resolved — Standby, Moves, Horizon Walk, and Edge Idle derive their fit from the central-pane safe viewport; a 16 px invariant keeps visible pixels before the rail and full-body feet above the composer across repaint and resize.
- P1 resolved — Edge Idle's per-frame support-point anchoring uses that same safe viewport instead of the raw workspace.
- P2 resolved — staged attachment chips now have a stable 38 px target, strong light/dark contrast, a 24 px remove affordance, and no extra scrollbar.
- P2 resolved — rail shadows were reduced to the reference's quieter chrome; attachment removal and Details close controls now have clearer targets and focus treatment.

### Iteration 3 — live visual verification

- PASS — with task details open, the `hi` bubble ends before the phone control and remains readable.
- PASS — right-edge Edge Idle clears every rail control and ends above the floating composer.
- PASS — the Luffy image stages locally as a visible `l2.jpg.webp` chip and can be removed without sending it.
- PASS — the File, Photo Library, and Camera choices are visible; the camera preview opens and was canceled without retaining a photo.
- PASS — the combined source/implementation inspection shows the requested left/center/right hierarchy, thin dividers, compact header, quiet typography, floating composer, and rail placement.

### Iteration 4 — response actions and attachment trust boundary

- P1 resolved — Copy and Read Aloud now sit immediately below every completed assistant response, left-aligned with the response instead of occupying the message's right edge.
- P1 resolved — the composer route is labeled `OpenClam` rather than implying on-device model inference.
- P1 resolved — the attachment menu states that files reach the provider configured in Settings only after Send; unsupported binary files remain metadata-only and say so explicitly.
- P1 resolved — ChatGPT OAuth's text-only chat route disables Photo and Camera, converts an image selected through File to metadata-only, and explains why at the point of choice; verified vision routes retain Photo and Camera.
- P2 resolved — failed or canceled built-in model turns restore the staged attachment chips so the user can retry without choosing the files again.
- PASS — the reloaded development window exposes Copy, Read Aloud, then the runtime route in that visual order, and the short `hi` user bubble remains clear of the rail with task details open.

## Regression evidence

- `OpenClam desktop renderer QA passed`
- `Validated 7 browser script blocks.`
- Full Python regression: 719 passed, 0 failures, 0 errors.
- Node/Electron QA: 11/11 commands passed.
- `npm run check:syntax` and `git diff --check` passed after the final layout corrections.

final result: passed
