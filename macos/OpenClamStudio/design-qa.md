# Design QA — macOS Chat/Talk workspace, layers, and motion controls

## References

- User-supplied Chat/Talk references showing recording, history, layer, opacity, and motion states.
- User-supplied Codex Work reference showing the requested thread typography, alignment, and progressive step treatment.
- User-supplied mode/menu reference showing the legacy mixed-mode controls.

## Compared state

The opacity/layer, motion, and Codex Work references were compared with the updated development renderer at the same 1084 × 768 Chat/Talk window size. The final surface uses the Codex-like quiet white/gray/black hierarchy, keeps user messages in compact right-aligned bubbles, presents agent work as a left-aligned timeline, and constrains avatar motion to the window floor above the composer.

## Blocking checks

- PASS — 100% avatar opacity is visually solid. The avatar stage now composites above the thread wash only when the avatar layer is selected.
- PASS — Thread-first mode restores the avatar beneath the scrolling conversation surface.
- PASS — Standby, Walk, Moves, and Edge Idle share the same painted-pixel interaction model when the avatar layer is selected: hold-and-drag follows the cursor in both axes and persists the new position, while pinch resizes. Opacity remains an explicit 0–100% rail control so it cannot conflict with dragging.
- PASS — Recording, transcribing, microphone errors, and transcription errors render within the composer status row; no speech-recognition error uses the global avatar-covering toast.
- PASS — The avatar status chip is absent. Runtime notices appear quietly in the chat thread/work steps instead of an avatar-covering dark bar.
- PASS — The composer, right rail, thread, and chat header remain above or independently interactive from the selected avatar layer as intended.
- PASS — New chat is available beside the top-left history control and inside the history sidebar; Settings is available in the sidebar footer.
- PASS — Thread typography, spacing, neutral colors, assistant alignment, user bubbles, and work-step hierarchy follow the supplied Codex Work reference without copying product branding.
- PASS — Avatar mode is structurally pure: status, right rail, thread, composer, toast, and picker surfaces are absent, leaving only the avatar.
- PASS — Chat/Talk exposes one explicit `Switch to Avatar mode` rail action; Avatar mode returns through the focused `Open Chat/Talk` context-menu action.
- PASS — Avatar mode keeps head-hold PTT, chest/lower-body opacity taps, and double-click Live Talk while removing the legacy status/rail and unrelated context-menu commands.
- PASS — The Avatar context menu contains only meaningful companion actions: Chat/Talk, Live Talk, Horizon Walk, Moves, the two requested size presets, Always on Top, and Character Studio. Transparent body gaps are permanently click-through and are no longer exposed as a preference.
- PASS — Horizon Walk uses Ara's authored gait trajectory and phase-locks foot cadence to distance along the lower window edge above the composer. Edge Idle pins its measured silhouette support point to the right window edge, or supplies a safe window-scoped lean there when no authored clip exists; neither path produces an avatar-covering dark error toast.
- PASS — The installed DMG copy that visually resembled a second UI was a separate running process, not a second renderer source. It was stopped and its mounted volume ejected; development windows now retain the distinct `OpenClam Studio Dev` title.
- PASS — Avatar/Chat is one persisted `interfaceMode` state machine in the Electron main process, rather than parallel local implementations.
- PASS — Existing Codex visual tokens, control labels, keyboard paths, history, OpenClaw timeline/file UI, PTT routes, and Live Talk paths remain covered by the full test suite.
- PASS — A status-only step such as “Response ready” no longer expands into an empty gray detail strip. The supplied failing screenshot and a same-state development capture were compared side by side after the fix.
- PASS — The composer `+` menu exposes Files, Photos or Video, and Camera. Selected input files use authenticated private handles; generated and received image, video, audio, PDF, Markdown/text, and generic-file cards expose preview plus Open/Share/Save actions.
- PASS — The real running backend completed an authenticated image upload/download round trip with the same SHA-256 and without retaining the test fixture.

## Verification

- `OpenClam desktop renderer QA passed`
- `Codex macOS visual token and accessibility QA passed`
- `npm run check:syntax` passed
- `npm test` passed: 510 Python tests plus all Electron/renderer QA scripts
- Authenticated local media round trip passed with byte-for-byte SHA-256 equality

Final result: **PASS**
