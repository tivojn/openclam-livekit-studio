# OpenClam Studio 1.0.18 / iOS 1.0.3 (60)

Import rigged GLB avatars on Mac and export an iPhone 3D AVTR for explicit
import on iOS. Both renderers drive speech, blinking and gaze from named
morph targets and bones.

The Blender preparation tool exports the supplied scene's visible outfit
and hair, bakes the connected shader graph, and preserves render subdivision
and facial shape keys. Hidden alternatives are excluded. Materials keep
their authored alpha settings; animation leaves wardrobe morphs intact.

Mac close-up mode (Shift-Command-9) passes the visible portrait crop to the
3D camera, preserving body and face proportions while zooming.

Downloaded avatar models and Blender sources are local user assets and are
not bundled with this release. iOS packages remain limited to 64 MiB; prepare
a mobile-sized model before exporting. Offline Blender lighting, subsurface
scattering and unsupported SceneKit material extensions can differ from the
real-time renderers.

iOS approximates transmissive surfaces using the material’s declared
transmission and index of refraction, so glass eye surfaces reveal the iris
instead of becoming opaque. This fallback does not provide refractive distortion.
