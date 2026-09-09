# OpenClam Studio 1.0.26 / iOS 1.0.5 (75)

Walking Woman is the default travel animation. The revised offline transfer
preserves Meshy's hip sway and forward/back arm articulation, corrects the
left/right ankle trajectories, and maps foot roll relative to each rig's flat
sole. It retains balanced toe turnout and a narrower Walking Woman step path.

Ordinary dragging places the avatar in both screen axes without changing its
camera distance. Pinch resizes; two-finger swipes rotate. Spoken studio travel
continues to use perspective and the selected walking style.

Appearance controls now include studio lighting, expressions, hair and color
choices, and optional appearance-package import/download on Mac and iPhone.
Package installs validate compatibility and hashes and support removal.

Validation includes the 62-motion real-rig audit, source hip and hand motion,
separate heel/forefoot contacts, three-loop gait checks, front/side/rear visual
inspection, and the iPhone simulator walking-style/travel UI test. The new
source regression reproduces the previous gait failures.

Proprietary model and motion assets are excluded from public source and the
public macOS DMG. Existing private Tia installations use motion library
revision 9 (gait revision 5). The private iOS build includes the updated motion
bundle. The original model geometry, skin weights and hair are unchanged.
