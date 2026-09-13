# OpenClam Studio 1.0.33

OpenClam gains a persistent **Tasks** workspace for multi-step agent work:
project files, commands, edits, tests, research, progress, follow-ups, approvals,
review and conversation branches. Open Tasks from the Chat sidebar or Tia's
right-click menu.

The model picker uses the complete catalog returned by the connected Codex
engine, including GPT-6-Astra and each model's supported reasoning settings.
OpenClam selects the newest installed official Codex runtime rather than an
older command-line copy. Additional engine models appear in their own group;
an explicit model selection is never silently replaced after a failure.

Permissions are saved per task: **Ask for approval**, **Approve for me**,
**Always allow · project**, **Full access**, and **Read only**. They can change
between turns and remain effective after resuming or branching. Approve for me
uses Codex's risk-based review. Always allow retains the project sandbox;
Full access removes that sandbox and approval prompts. Approval cards also
support session-scoped permission grants.

This release also includes the Tia improvements developed since 1.0.27:

- Performer settings in Tia's right-click menu, with camera-driven face,
  upper-body and hand tracking, calibration and a separate OBS output.
- Improvements to shoulder and wrist rotation, finger attachment, face-contact
  placement, blink calibration, expression strength, and camera angle control.
- Reduced duplicate rendering and more efficient avatar resource loading.
- Avatar status/follow-up bubbles that stay hidden when idle, body hold-to-talk
  and head double-click Live Talk gestures, and shared-call routing fixes.
- Better portrait framing for greeting gestures.

Tasks requires a current Codex/ChatGPT app or Codex CLI and its existing login.
The model/permission integration was verified with Codex 0.153.4. OpenClaw
remains the conversation route in Chat and Live Talk. Tasks is a macOS feature;
this release does not upload a new iPhone build.

The macOS release process runs regression, dependency, license, privacy,
native-runtime and packaged-runtime checks, then signs and notarizes the app
and DMG. Existing installed avatar packages and preferences remain in the
application data folder when the app is replaced.
