# OpenClam Studio 1.0.23 / iOS 1.0.5 (72)

3D companions can walk or run across the available chat window or desktop.
Moving toward the top of the scene increases distance and reduces apparent
size; moving toward the bottom brings the avatar closer. “Come closer” walks
toward a face-filling camera view while maintaining eye contact.

- Body heading and gait follow the final projected travel path. The avatar
  turns before translating, and stride cadence controls travel speed.
- Standing, resting and performing a motion retain the same scale at the
  same distance. Manual gestures take priority over automatic movement.
- Conversation remains owned by the selected LLM. Affirmative replies choose
  motions; an isolated input keyword never substitutes a canned answer.
- Live Talk transfers between chat and avatar mode with a single call owner.
  Partial captions stream immediately, and finalized caption handling avoids
  dropping or duplicating transcript segments.
- Tia motion retargeting corrects ankle/toe orientation and rejects invalid
  head/neck rotations relative to the torso. Gait speed metadata supports
  calibrated playback of the matching private motion package.

The software source contains no private Tia model or motion media. Compatible
avatar packages are installed separately; the iOS TestFlight build carries
the matching private motion update for the already installed Tia model.

Validation covers desktop renderer/companion/Live Talk regressions, the actual
Tia rig and all 62 clips, projected direction and cadence, iOS unit tests, and
simulator movement/close-approach UI tests. Physical-iPhone verification was
unavailable. The macOS release pipeline additionally checks dependencies,
privacy, licenses, native/runtime packaging, signing, notarization, and the
mounted DMG.
