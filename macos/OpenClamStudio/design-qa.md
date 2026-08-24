# Design QA — macOS Avatar/Chat modes, layers, and motion controls

## References

- User-supplied desktop references showing Chat/Talk recording, layer, and opacity states.
- User-supplied mode/menu reference showing the legacy mixed-mode controls.
- User-supplied motion reference showing the Walk failure state.

## Compared state

The opacity/layer reference and updated development renderer were compared together at the same 1084 × 768 Chat/Talk window size. The motion reference was then compared against the live source renderer with Ara in an authored Horizon Walk frame: the dark error toast was absent, the rail and thread geometry were unchanged, and the avatar was visibly moving. The source Mac locked before that transient comparison frame could be retained as a second local artifact, so the live visual observation is paired with deterministic renderer and shell regressions below.

## Blocking checks

- PASS — 100% avatar opacity is visually solid. The avatar stage now composites above the thread wash only when the avatar layer is selected.
- PASS — Thread-first mode restores the avatar beneath the scrolling conversation surface.
- PASS — A vertical drag over a painted avatar pixel changed the persisted opacity from 100% to 70% in the live Electron window.
- PASS — Recording, transcribing, microphone errors, and transcription errors render within the composer status row; no speech-recognition error uses the global avatar-covering toast.
- PASS — The composer, right rail, status line, and chat header remain above or independently interactive from the selected avatar layer as intended.
- PASS — Avatar mode is structurally pure: status, right rail, thread, composer, toast, and picker surfaces are absent, leaving only the avatar.
- PASS — Chat/Talk exposes one explicit `Switch to Avatar mode` rail action; Avatar mode returns through the focused `Open Chat/Talk` context-menu action.
- PASS — Avatar mode keeps head-hold PTT, chest/lower-body opacity taps, and double-click Live Talk while removing the legacy status/rail and unrelated context-menu commands.
- PASS — The Avatar context menu now contains only Open Chat/Talk, Live Talk, Horizon Walk, Moves, and Character Studio.
- PASS — Horizon Walk uses Ara's authored atlas clip and visibly animates. Edge Idle is labelled `Not built` and disabled because Ara's manifest has no Edge Idle asset; selecting motions no longer produces the avatar-covering dark error toast.
- PASS — The installed DMG copy that visually resembled a second UI was a separate running process, not a second renderer source. It was stopped and its mounted volume ejected; development windows now retain the distinct `OpenClam Studio Dev` title.
- PASS — Avatar/Chat is one persisted `interfaceMode` state machine in the Electron main process, rather than parallel local implementations.
- PASS — Existing Codex visual tokens, control labels, keyboard paths, history, OpenClaw timeline/file UI, PTT routes, and Live Talk paths remain covered by the full test suite.

## Verification

- `OpenClam desktop renderer QA passed`
- `Codex macOS visual token and accessibility QA passed`
- `npm run check:syntax` passed
- `npm test` passed: 508 Python tests plus all Electron/renderer QA scripts

Final result: **PASS**
