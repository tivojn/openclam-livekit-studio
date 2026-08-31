"""Execute the real macOS camera helpers without opening or mutating the app."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node is required for the renderer geometry checks")
class ChatAvatarHeadVisibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "web" / "index.html").read_text()
        names = (
            "chatWorkspaceViewport", "chatAvatarSafeViewport",
            "boundedChatAvatarOffset", "viewCrop", "numericAvatarZoom", "chatCloseUpGeometry", "closeUpZoomOutGeometry",
            "chatCameraAlphaBounds", "chatCameraHeadSpan", "clampChatCameraFit", "cameraFor",
            "pinchZoomValue", "holdAvatarZoom",
        )
        helpers = ["const chatCameraAlphaBoundsCache = new WeakMap();"]
        for name in names:
            match = re.search(
                rf"    (const {name} =[\s\S]*?\n    \}};)", cls.source)
            if match is None:
                raise AssertionError(f"Missing independently testable helper: {name}")
            helpers.append(match[1])
        cls.helpers = "\n".join(helpers)

    def run_js(self, assertions):
        bootstrap = r"""
            const assert = require('node:assert/strict');
            let inChat = true, avatarMirrored = false;
            let isCompanion = false, idleDocked = false;
            const root = {classList: {contains: name =>
              inChat && (name === 'chat-mode' || name === 'chat-open'
                || (name === 'avatar-mirrored' && avatarMirrored))}};
            let innerWidth = 1440, innerHeight = 900;
            const rect = (x, y, width, height) => ({
              left: x, top: y, width, height, right: x + width, bottom: y + height});
            let workspaceRect = rect(240, 0, 920, 900);
            let headerRect = rect(240, 0, 920, 54);
            let railRect = rect(1092, 66, 40, 420);
            let composerRect = rect(280, 760, 800, 100);
            const chatWorkspace = {getBoundingClientRect: () => workspaceRect};
            const chatHeader = {getBoundingClientRect: () => headerRect};
            const rail = {getBoundingClientRect: () => railRect};
            const composerShell = {getBoundingClientRect: () => composerRect};
            const chatDock = composerShell;
            let shellState = {chatCloseUp: false, chatCloseUpBaseZoom: .6,
              desktopCloseUp: false, pet: {view: 'full', zoom: .6, roam: false,
                canvasBaseSize: {width: 560, height: 760}}};
            let chatAvatarOffset = {x: 0, y: 0};
            let desktopCloseUpOffset = {x: 0, y: 0};
            let lastFrame = 123;
            const metadata = {
              bounds: [230, 20, 620, 1400],
              alignment: {face_bounds: [430, 70, 170, 215]},
            };
            let manifest = {body: metadata};
            let bodyImage = null, headMask = null, headReplacementActive = false,
              headReplacementCanvas = null, cutoutImage = null;
            let alphaReads = 0, alphaCanvases = 0, largestAlphaRead = 0;
            const alphaImage = (width, height, boxes) => ({
              width, height, naturalWidth: width, naturalHeight: height, complete: true, boxes,
            });
            // A bounded synthetic alpha raster allows the actual cache and
            // camera math to run, without starting Electron or loading assets.
            const document = {createElement: kind => {
              assert.equal(kind, 'canvas');
              alphaCanvases += 1;
              let image;
              const canvas = {width: 0, height: 0};
              canvas.getContext = () => ({
                drawImage: source => { image = source; },
                getImageData: () => {
                  alphaReads += 1;
                  if (image.rejectRead) throw new Error('SecurityError: tainted image');
                  largestAlphaRead = Math.max(largestAlphaRead, canvas.width, canvas.height);
                  const data = new Uint8ClampedArray(canvas.width * canvas.height * 4);
                  const scaleX = image.width / canvas.width, scaleY = image.height / canvas.height;
                  for (const [left, top, right, bottom] of image.boxes || []) {
                    for (let y = Math.max(0, Math.floor(top / scaleY)); y < Math.min(canvas.height, Math.ceil(bottom / scaleY)); y += 1)
                      for (let x = Math.max(0, Math.floor(left / scaleX)); x < Math.min(canvas.width, Math.ceil(right / scaleX)); x += 1)
                        data[(y * canvas.width + x) * 4 + 3] = 255;
                  }
                  return {data};
                },
              });
              return canvas;
            }};
            const visible = (fit, viewport, span = fit.headSpan) => {
              for (const key of ['x', 'y', 'scale']) assert.ok(Number.isFinite(fit[key]), key);
              assert.ok(fit.scale > 0, 'positive rendered scale');
              assert.ok(fit.y + span.top * fit.scale >= viewport.y - 1e-7,
                `crown above chat top: ${JSON.stringify({fit, viewport, span})}`);
              const tolerance = Math.max(1e-7, Math.abs(span.top * fit.scale) * Number.EPSILON * 4);
              // The user's invariant is crown visibility, not a head-size
              // ceiling. An intentional huge close-up may clip the chin.
              if ((span.bottom - span.top) * fit.scale <= viewport.bottom - viewport.y)
                assert.ok(fit.y + span.bottom * fit.scale <= viewport.bottom + tolerance,
                  `fitting chin below canvas: ${JSON.stringify({fit, viewport, span})}`);
              else assert.ok(Math.abs(fit.y + span.top * fit.scale - viewport.y) <= tolerance,
                'oversized head pins its crown without shrinking the requested scale');
              if (Number.isFinite(span.left) && Number.isFinite(span.right)) {
                const mirror = avatarMirrored ? 2 * (workspaceRect.left + workspaceRect.width * .5) : null;
                const displayLeft = mirror === null ? fit.x + span.left * fit.scale
                  : mirror - (fit.x + span.right * fit.scale);
                const displayRight = mirror === null ? fit.x + span.right * fit.scale
                  : mirror - (fit.x + span.left * fit.scale);
                if ((span.right - span.left) * fit.scale <= viewport.right - viewport.x) {
                  assert.ok(displayLeft >= viewport.x - tolerance,
                    `fitting head beyond left: ${JSON.stringify({fit, viewport, span})}`);
                  assert.ok(displayRight <= viewport.right + tolerance,
                    `fitting head beyond right: ${JSON.stringify({fit, viewport, span})}`);
                } else {
                  assert.ok(displayLeft <= viewport.x + tolerance && displayRight >= viewport.right - tolerance,
                    'oversized head remains across the canvas without a hidden horizontal zoom ceiling');
                }
              }
            };
        """
        result = subprocess.run(
            [NODE, "-"], input=bootstrap + self.helpers + "\n" + assertions,
            text=True, capture_output=True, cwd=ROOT, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_oversized_body_never_undoes_crown_clamp_to_fit_feet(self):
        self.run_js(r"""
            const viewport = {x: 20, y: 70, right: 900, bottom: 670};
            const fit = {x: 100, y: -600, scale: 2,
              crop: {x: 0, y: 20, w: 300, h: 1000}, headSpan: {top: 20, bottom: 180}};
            const actual = clampChatCameraFit(fit, viewport);
            visible(actual, viewport);
            assert.equal(actual.scale, 2, 'do not zoom out merely to fit the body');
            assert.ok(actual.y + 1020 * actual.scale > viewport.bottom,
              'intentional large-avatar legs may extend below the viewport');
        """)

    def test_desktop_close_up_uses_saved_zoom_and_head_guard_without_resizing_canvas(self):
        self.run_js(r"""
            inChat = false;
            shellState.desktopCloseUp = true;
            innerWidth = 1440; innerHeight = 850;
            const viewport = {x:0,y:0,right:innerWidth,bottom:innerHeight};
            shellState.pet.zoom = .6;
            const small = cameraFor(metadata,1086,1448);
            shellState.pet.zoom = 1.2;
            const larger = cameraFor(metadata,1086,1448);
            assert.ok(larger.scale > small.scale);
            for (const zoom of [.08,.25,.6,1.2,4,12,64]) for (const delta of [-1e6,0,1e6]) {
              shellState.pet.zoom = zoom;
              desktopCloseUpOffset = {x:delta,y:delta};
              visible(cameraFor(metadata,1086,1448),viewport);
              assert.equal(shellState.pet.zoom,zoom);
              assert.deepEqual(desktopCloseUpOffset,{x:delta,y:delta});
              assert.equal(innerWidth,1440); assert.equal(innerHeight,850);
            }
        """)

    def test_desktop_standby_retains_excess_zoom_in_bounded_native_canvas(self):
        self.run_js(r"""
            inChat = false;
            innerWidth = 626; innerHeight = 850;
            shellState.pet.zoom = 1.12;
            const small = cameraFor(metadata,1086,1448);
            let previous = small;
            for (const zoom of [4,8,16,64,256]) {
              shellState.pet.zoom = zoom;
              const large = cameraFor(metadata,1086,1448);
              assert.ok(large.scale > previous.scale,'native canvas bound must not swallow user zoom');
              assert.ok(Math.abs(large.scale / small.scale - zoom / 1.12) < 1e-10,
                'rendered zoom continues linearly beyond the former4x cap');
              visible(large,{x:0,y:0,right:innerWidth,bottom:innerHeight});
              assert.equal(shellState.pet.zoom,zoom);
              assert.ok((metadata.bounds[1]+metadata.bounds[3])*large.scale+large.y > innerHeight,
                'zoomed lower body remains drawable beyond canvas');
              previous = large;
            }
        """)

    def test_shrinking_closeup_reveals_real_fullbody_without_switching_to_standby(self):
        self.run_js(r"""
            for (const chat of [false,true]) {
              inChat=chat; shellState.chatCloseUp=chat; shellState.desktopCloseUp=!chat;
              chatAvatarOffset={x:0,y:0}; desktopCloseUpOffset={x:0,y:0};
              shellState.pet.view='full';
              for (const [width,height] of [[380,680],[700,820],[1440,900]]) {
                innerWidth=chat?width+240:width; innerHeight=height;
                workspaceRect=rect(240,0,width,height);
                headerRect=rect(240,0,width,54);
                railRect=rect(240+width-54,66,40,420);
                composerRect=rect(260,height-120,width-40,100);
                shellState.pet.zoom=.6;
                const close=cameraFor(metadata,1086,1448);
                const feet=metadata.bounds[1]+metadata.bounds[3];
                assert.ok(close.y+feet*close.scale>height,
                  'normal preset remains the approved close-up, not an accidental whole-body default');
                let previous=close;
                for (const zoom of [.59,.5,.4,.3,.250001,.25,.249999,.2,.1,.025]) {
                  shellState.pet.zoom=zoom;
                  const fit=cameraFor(metadata,1086,1448);
                  assert.ok(fit.scale<previous.scale,'every zoom-out changes rendered size continuously');
                  const viewport=chat?chatAvatarSafeViewport({reserveComposer:false,reserveRail:true})
                    :{x:0,y:0,right:width,bottom:height};
                  visible(fit,viewport);
                  if(zoom<=.25) {
                    const bodyViewport=chat?chatAvatarSafeViewport({reserveComposer:true,reserveRail:true}):viewport;
                    assert.ok(fit.y+metadata.bounds[1]*fit.scale>=bodyViewport.y-1e-7);
                    assert.ok(fit.y+feet*fit.scale<=bodyViewport.bottom+1e-7,
                      'actual feet pixels must enter canvas, above composer in chat, while still Close-up');
                    assert.ok(fit.x+metadata.bounds[0]*fit.scale>=bodyViewport.x-1e-7);
                    assert.ok(fit.x+(metadata.bounds[0]+metadata.bounds[2])*fit.scale<=bodyViewport.right+1e-7);
                  }
                  assert.equal(shellState.chatCloseUp,chat);
                  assert.equal(shellState.desktopCloseUp,!chat);
                  assert.equal(shellState.pet.view,'full');
                  previous=fit;
                }
                shellState.pet.zoom=.6;
                assert.deepEqual(cameraFor(metadata,1086,1448),close,
                  'zooming back restores the same approved close-up framing');
              }
            }
        """)

    def test_closeup_frame_transition_is_continuous_at_both_transition_sizes(self):
        self.run_js(r"""
            for(const chat of [false,true]) {
              inChat=chat; shellState.chatCloseUp=chat; shellState.desktopCloseUp=!chat;
              for(const boundary of [.25,.6]) {
                shellState.pet.zoom=boundary-1e-8;const before=cameraFor(metadata,1086,1448);
                shellState.pet.zoom=boundary+1e-8;const after=cameraFor(metadata,1086,1448);
                assert.ok(after.scale>before.scale);
                for(const key of ['x','y','scale']) assert.ok(Math.abs(after[key]-before[key])<1e-3,
                  `camera jump at${boundary}: ${key}`);
              }
            }
        """)

    def test_desktop_companion_and_motion_keep_their_existing_native_fit(self):
        self.run_js(r"""
            inChat = false;
            innerWidth = 336; innerHeight = 456;
            for (const branch of ['companion','roam','idle']) {
              isCompanion = branch==='companion'; idleDocked = branch==='idle';
              shellState.pet.roam = branch==='roam'; shellState.pet.zoom = 4;
              const fit = cameraFor(metadata,1086,1448);
              const expected = Math.min(innerWidth/metadata.bounds[2],innerHeight/metadata.bounds[3])
                * (branch==='roam'?.995:.94);
              assert.equal(fit.scale,expected);
              assert.equal(fit.headSpan,null);
            }
        """)

    def test_close_up_clamps_crown_even_with_vertical_body_fitting_disabled(self):
        self.run_js(r"""
            const viewport = {x: 20, y: 70, right: 900, bottom: 670};
            for (const y of [-1e6, -400, 0, 160, 700, 1e6]) {
              const fit = {x: 100, y, scale: 1.8,
                crop: {x: 40, y: 65, w: 500, h: 500}, headSpan: {top: 0, bottom: 230}};
              const actual = clampChatCameraFit(fit, viewport, {vertical: false});
              visible(actual, viewport);
              assert.equal(actual.scale, fit.scale);
            }
        """)

    def test_fit_preserves_an_already_visible_saved_pose(self):
        self.run_js(r"""
            const viewport = {x: 20, y: 70, right: 900, bottom: 670};
            const fit = {x: 380, y: 150, scale: 1,
              crop: {x: 0, y: 0, w: 160, h: 400}, headSpan: {top: 0, bottom: 100}};
            assert.deepEqual(clampChatCameraFit(fit, viewport), fit);
            assert.deepEqual(clampChatCameraFit(fit, viewport, {vertical: false}), fit);
        """)

    def test_oversized_head_translates_crown_without_a_hidden_rendered_scale_cap(self):
        self.run_js(r"""
            const viewport = {x: 20, y: 70, right: 900, bottom: 670};
            const fit = {x: -1e6, y: -1e6, scale: 80,
              crop: {x: 0, y: 20, w: 300, h: 1000}, headSpan: {top: 20, bottom: 180}};
            const saved = structuredClone(fit);
            const actual = clampChatCameraFit(fit, viewport);
            visible(actual, viewport);
            assert.equal(actual.scale, 80);
            assert.equal(actual.y + 20 * actual.scale, viewport.y);
            assert.ok(actual.y + 180 * actual.scale > viewport.bottom,
              'chin may leave the lower edge when user deliberately enlarges it');
            assert.ok(actual.crop.h * actual.scale > 600 * 6);
            assert.deepEqual(fit, saved, 'never overwrite the saved zoom/drag');
        """)

    def test_hat_and_transformed_replacement_head_can_extend_above_bust_and_body(self):
        self.run_js(r"""
            const body = {bounds: [347, 24, 388, 1410],
              alignment: {face_bounds: [477, 81, 125, 155]},
              face_transform: [[.2659521, 0, 400.8325402], [0, .2659521, -3.8371088]]};
            const runtime = {body, cutout: {bounds: [90, 55, 840, 969]}};
            const span = chatCameraHeadSpan(body, 1086, 1448, runtime);
            assert.ok(Math.abs(span.top - 10.7902567) < 1e-7);
            assert.equal(span.bottom, 237);
            const withoutReplacement = chatCameraHeadSpan(body, 1086, 1448);
            assert.equal(withoutReplacement.top, 24);
            const cartoonHat = {bounds: [80, 12, 580, 1000],
              alignment: {face_bounds: [240, 180, 180, 150]}};
            assert.ok(viewCrop(cartoonHat, 720, 1088, 'bust').y > 12);
            assert.equal(chatCameraHeadSpan(cartoonHat, 720, 1088).top, 12,
              'the facial bust crop must never redefine a hat as disposable');
        """)

    def test_rotated_or_mirrored_head_transform_uses_all_crown_corners(self):
        self.run_js(r"""
            const body = {bounds: [200, 40, 400, 1100],
              alignment: {face_bounds: [340, 80, 140, 180]},
              face_transform: [[.3, 0, 200], [-.03, .3, -12]]};
            const runtime = {body, cutout: {bounds: [50, 20, 900, 960]}};
            const span = chatCameraHeadSpan(body, 1086, 1448, runtime);
            assert.equal(span.top, -34.5);
            body.face_transform[0] = [-.3, 0, 800];
            const mirrored = chatCameraHeadSpan(body, 1086, 1448, runtime);
            assert.equal(mirrored.top, span.top);
            assert.equal(mirrored.bottom, span.bottom,
              'horizontal mirroring must not reverse the vertical head guard');
        """)

    def test_bad_numbers_and_missing_head_metadata_fail_to_finite_visible_fit(self):
        self.run_js(r"""
            const viewport = {x: 20, y: 70, width: 600, height: 400,
              right: Infinity, bottom: NaN};
            for (const bad of [NaN, Infinity, -Infinity, undefined, null]) {
              const fit = {x: bad, y: bad, scale: bad,
                crop: {x: bad, y: bad, w: bad, h: bad}, headSpan: null};
              const actual = clampChatCameraFit(fit, viewport);
              for (const value of [actual.x, actual.y, actual.scale, ...Object.values(actual.crop)])
                assert.ok(Number.isFinite(value));
              assert.ok(actual.y >= 70);
              assert.ok(actual.y + actual.crop.h * actual.scale <= 470);
            }
            assert.deepEqual(chatCameraHeadSpan({bounds: [0, NaN, 10, Infinity]}, Infinity, NaN),
              {top: 0, bottom: 1});
            const noFace = chatCameraHeadSpan({bounds: [10, 20, 100, 900]}, 200, 1000);
            assert.deepEqual(noFace, {top: 20, bottom: 920},
              'legacy assets without face geometry use conservative full bounds');
        """)

    def test_both_presets_stay_head_visible_through_zoom_drag_and_sidebar_sizes(self):
        self.run_js(r"""
            let cases = 0;
            for (const closeUp of [false, true])
              for (const width of [1, 160, 380, 700, 1180, 2600])
                for (const height of [1, 90, 240, 580, 1000])
                  for (const zoom of [.25, .6, 1.4, 4, 1e7])
                    for (const offset of [-1e6, 0, 1e6]) {
                      shellState.chatCloseUp = closeUp;
                      shellState.pet.zoom = zoom;
                      innerWidth = width + 560;
                      innerHeight = height;
                      workspaceRect = rect(240, 0, width, height);
                      headerRect = rect(240, 0, width, 54);
                      railRect = rect(240 + width - 54, 66, 40, 420);
                      composerRect = rect(260, Math.max(64, height - 140), width - 40, 100);
                      chatAvatarOffset = {x: offset, y: offset};
                      const fit = cameraFor(metadata, 1086, 1448);
                      const viewport = chatAvatarSafeViewport({reserveComposer: !closeUp, reserveRail: true});
                      visible(fit, viewport);
                      assert.equal(shellState.pet.zoom, zoom);
                      assert.deepEqual(chatAvatarOffset, {x: offset, y: offset});
                      cases += 1;
                    }
            assert.equal(cases, 900);
        """)

    def test_slider_and_live_pinch_share_the_same_head_clamped_camera(self):
        self.run_js(r"""
            const range = {};
            shellState.chatCloseUp = true;
            for (const value of [.08,.25,1,4,12,64]) {
              shellState.pet.zoom = value; // persisted native slider update
              visible(cameraFor(metadata, 1086, 1448),
                chatAvatarSafeViewport({reserveComposer: false, reserveRail: true}));
            }
            for (let tick = 0; tick < 30; tick += 1) {
              const next = pinchZoomValue(shellState.pet.zoom,
                {ctrlKey: true, deltaY: tick < 15 ? -30 : 30, deltaMode: 0}, range, innerHeight);
              lastFrame = 123;
              holdAvatarZoom(next);
              assert.equal(lastFrame, 0, 'live pinch should repaint immediately');
              visible(cameraFor(metadata, 1086, 1448),
                chatAvatarSafeViewport({reserveComposer: false, reserveRail: true}));
            }
            for (const bad of [NaN, Infinity, -Infinity, undefined])
              assert.equal(pinchZoomValue(1, {ctrlKey: true, deltaY: bad}, range, 800), 1);
            assert.equal(pinchZoomValue(1, {ctrlKey: false, deltaY: -30}, range, 800), 1);
            assert.ok(Number.isFinite(pinchZoomValue(1,
              {ctrlKey: true, deltaY: -30, deltaMode: 2}, range, Infinity)));
            for (const current of [.08,.25,4,12,64]) {
              shellState.pet.zoom = current;
              const before = cameraFor(metadata,1086,1448);
              const enlarged = pinchZoomValue(current,{ctrlKey:true,deltaY:-20},range,innerHeight);
              holdAvatarZoom(enlarged);
              const after = cameraFor(metadata,1086,1448);
              assert.ok(enlarged > current && after.scale > before.scale,
                'accepted pinch must change actual rendered size, not only saved intent');
              const shrunk = pinchZoomValue(enlarged,{ctrlKey:true,deltaY:20},range,innerHeight);
              holdAvatarZoom(shrunk);
              const reversed = cameraFor(metadata,1086,1448);
              assert.ok(reversed.scale < after.scale,'reverse gesture has no overshoot dead zone');
              assert.ok(Math.abs(reversed.scale-before.scale) < 1e-9);
            }
        """)

    def test_zoom_arithmetic_rejects_unrepresentable_values_without_hidden_overshoot(self):
        self.run_js(r"""
            const {clampPetZoom}=require('./electron/pet-window-bounds.cjs');
            for(const value of [.0001,.08,4,16,256,1e7]) {
              assert.equal(numericAvatarZoom(value),value);
              assert.equal(clampPetZoom(value,{}),value);
            }
            for(const bad of [NaN,Infinity,-Infinity,0,-2,Number.MAX_VALUE,Number.MIN_VALUE]) {
              assert.equal(numericAvatarZoom(bad,12),12);
              assert.equal(clampPetZoom(bad,{},12),12);
            }
            const last=Number.MAX_VALUE/Number.MAX_SAFE_INTEGER*.9;
            assert.equal(pinchZoomValue(last,{ctrlKey:true,deltaY:-90},{},850),last,
              'unrepresentable forward pinch is rejected, not saved as an invisible excess');
            const reversed=pinchZoomValue(last,{ctrlKey:true,deltaY:20},{},850);
            assert.ok(reversed<last && Number.isFinite(reversed));
            const small=Number.MIN_VALUE*Number.MAX_SAFE_INTEGER*.6;
            assert.equal(pinchZoomValue(small,{ctrlKey:true,deltaY:90},{},850),small);
            assert.ok(pinchZoomValue(small,{ctrlKey:true,deltaY:-20},{},850)>small);
        """)

    def test_narrow_sidebar_head_guard_never_reintroduces_a_zoom_ceiling(self):
        self.run_js(r"""
            // Exact r2 metadata plus measured native-alpha head bounds. The
            // actual 921px CSS layout leaves a 431px chat column; its safe
            // interval is232..585 after the left sidebar and avatar rail.
            const fixtures = [
              {name: 'Sarah', bounds: [357,47,362,1384], face: [468,125,140,152],
                matrix: [[.2994306,0,382.4415418],[0,.2994306,17.109295]],
                cutout: [96,57,831,967], bodyHead: [410,47,663,278],
                head: [132,57,892,883]},
              {name: 'Celine', bounds: [361,30,350,1397], face: [442,118,172,189],
                matrix: [[.3774004,0,334.5210159],[0,.3774004,9.33885]],
                cutout: [93,34,833,917], bodyHead: [372,30,681,308],
                head: [93,34,881,806]},
            ];
            for (const fixture of fixtures) {
              const body = {bounds: fixture.bounds, alignment: {face_bounds: fixture.face},
                face_transform: fixture.matrix};
              manifest = {body, cutout: {bounds: fixture.cutout}};
              bodyImage = alphaImage(1086,1448, [fixture.bodyHead,
                [fixture.bounds[0],fixture.bodyHead[3] + 20,
                  fixture.bounds[0] + fixture.bounds[2],1430]]);
              headMask = alphaImage(1024,1024,[fixture.head]);
              headReplacementActive = true;
              headReplacementCanvas = alphaImage(1024,1024,[fixture.head]);
              shellState.chatCloseUp = true;
              const projectedHeadX = [fixture.bodyHead[0], fixture.bodyHead[2]];
              for (const x of [fixture.head[0],fixture.head[2]])
                for (const y of [fixture.head[1],fixture.head[3]])
                  projectedHeadX.push(fixture.matrix[0][0]*x + fixture.matrix[0][1]*y + fixture.matrix[0][2]);
              const pivot = fixture.bounds[0] + fixture.bounds[2] * .5;
              for (const windowWidth of [921,960,976,1100]) {
                innerWidth = windowWidth;
                workspaceRect = rect(224,0,windowWidth-224-266,900);
                headerRect = rect(224,0,workspaceRect.width,54);
                railRect = rect(workspaceRect.right-54,66,40,420);
                for (const zoom of [.6,4,12]) for (const offset of [-1e6,0,1e6]) {
                  shellState.pet.zoom = zoom;
                  chatAvatarOffset = {x: offset,y: 0};
                  const fit = cameraFor(body,1086,1448);
                  const viewport = chatAvatarSafeViewport({reserveComposer: false,reserveRail: true});
                  visible(fit,viewport);
                  const expected=chatCloseUpGeometry(viewCrop(body,1086,1448,'bust'),
                    viewport.width,viewport.height,zoom/.6);
                  assert.equal(fit.scale,expected.scale,'narrow canvas cannot swallow user zoom');
                  if ((fit.headSpan.right-fit.headSpan.left)*fit.scale <= viewport.width)
                    for (const breathe of [.9975,1,1.0025])
                      for (const sourceX of projectedHeadX) {
                        const x = fit.x + (pivot + (sourceX-pivot)*breathe) * fit.scale;
                        assert.ok(x >= viewport.x - 1e-7 && x <= viewport.right + 1e-7,
                          `${fixture.name} fitting head/hair clipped: ${JSON.stringify({x,viewport,fit})}`);
                      }
                  assert.equal(shellState.pet.zoom,zoom);
                  assert.deepEqual(chatAvatarOffset,{x: offset,y: 0});
                  if (windowWidth === 921) {
                    assert.equal(viewport.x,232);
                    assert.equal(viewport.right,585);
                    if (zoom >= 4) assert.ok((fit.headSpan.right-fit.headSpan.left)*fit.scale > viewport.width,
                      'deliberate enlarged head may crop laterally, not be silently shrunk');
                  }
                }
              }
            }
            assert.equal(alphaReads,4,'two loaded images per avatar, never one read per frame');
        """)

    def test_alpha_head_band_excludes_wide_torso_and_keeps_wide_hat(self):
        self.run_js(r"""
            const body = {bounds: [0,10,900,990], alignment: {face_bounds: [350,80,200,160]},
              face_transform: [[.5,0,200],[0,.5,0]]};
            const runtime = {body, cutout: {bounds: [0,20,1000,1000]}};
            const bodyPixels = alphaImage(900,1000,[[280,10,620,239],[0,260,900,1000]]);
            const head = alphaImage(1000,1000,[[180,20,860,460]]);
            const span = chatCameraHeadSpan(body,900,1000,runtime,{body: bodyPixels,head});
            assert.ok(span.left > 270 && span.left < 280);
            assert.ok(span.right > 630 && span.right < 640,
              'retain canonical hat width beyond face/head on body');
            assert.ok(span.right - span.left < 370,
              'neither900pxbody torso nor1000pxportrait shoulders become head width');
            const viewport = {x: 20,y: 70,right: 620,bottom: 900};
            const fit = clampChatCameraFit({x: -300,y: 90,scale: 1.5,
              crop: {x: 0,y: 10,w: 900,h: 990},headSpan: span},viewport,{vertical: false});
            assert.equal(fit.scale,1.5,'do not shrink an already fitting head tofitwide torso');
            visible(fit,viewport);
        """)

    def test_mirrored_head_uses_inverse_rail_guard_not_refitted_pose(self):
        self.run_js(r"""
            const body = {bounds:[357,47,362,1384], alignment:{face_bounds:[468,125,140,152]},
              face_transform:[[.2994306,0,382.4415418],[0,.2994306,17.109295]]};
            manifest = {body,cutout:{bounds:[96,57,831,967]}};
            bodyImage = alphaImage(1086,1448,[[410,47,663,278],[357,310,719,1431]]);
            headMask = alphaImage(1024,1024,[[132,57,892,883]]);
            for (const width of [921,960,1200]) {
              innerWidth = width;
              workspaceRect = rect(224,0,width-224-266,900);
              headerRect = rect(224,0,workspaceRect.width,54);
              railRect = rect(workspaceRect.right-54,66,40,420);
              composerRect = rect(244,760,workspaceRect.width-40,100);
              for (const closeUp of [false,true])
                for (const zoom of [.6,4])
                  for (const offset of [-1e6,0,1e6]) {
                    shellState.chatCloseUp = closeUp;
                    shellState.pet.zoom = zoom;
                    chatAvatarOffset = {x:offset,y:0};
                    avatarMirrored = false;
                    const original = cameraFor(body,1086,1448);
                    avatarMirrored = true;
                    const reflected = cameraFor(body,1086,1448);
                    const viewport = chatAvatarSafeViewport({reserveComposer:!closeUp,reserveRail:true});
                    visible(reflected,viewport);
                    assert.equal(reflected.y,original.y);
                    assert.equal(reflected.scale,original.scale);
                    assert.deepEqual(chatAvatarOffset,{x:offset,y:0});
                    assert.equal(shellState.pet.zoom,zoom);
                  }
            }
            assert.equal(alphaReads,2);
        """)

    def test_alpha_cache_reads_once_keeps_only_bounded_geometry(self):
        self.run_js(r"""
            const image = alphaImage(4000,8000,[[1500,200,2500,1600],[0,4000,4000,8000]]);
            const first = chatCameraAlphaBounds(image,1800);
            for (let frame = 0; frame < 200; frame += 1)
              assert.deepEqual(chatCameraAlphaBounds(image,1800),first);
            const full = chatCameraAlphaBounds(image);
            assert.ok(full[2] > first[2] * 2);
            assert.equal(alphaReads,1,'different head-band limits reuse prefix geometry');
            assert.equal(alphaCanvases,1);
            assert.ok(largestAlphaRead <= 1024);
            const cached = chatCameraAlphaBoundsCache.get(image);
            assert.deepEqual(Object.keys(cached).sort(),
              ['height','prefix','sampleHeight','sampleWidth','width']);
            assert.ok(cached.prefix.length <= 1024 * 4,'do not retain image pixel buffers');
        """)

    def test_alpha_cache_retries_incomplete_but_not_tainted_images(self):
        self.run_js(r"""
            const pending = alphaImage(100,100,[[20,10,80,70]]);
            pending.complete = false;
            assert.equal(chatCameraAlphaBounds(pending),null);
            assert.equal(chatCameraAlphaBoundsCache.has(pending),false);
            assert.equal(alphaReads,0);
            pending.complete = true;
            pending.naturalWidth = 0;
            assert.equal(chatCameraAlphaBounds(pending),null);
            assert.equal(chatCameraAlphaBoundsCache.has(pending),false);
            pending.naturalWidth = 100;
            assert.deepEqual(chatCameraAlphaBounds(pending),[19,9,62,62]);
            assert.equal(alphaReads,1);
            const tainted = alphaImage(100,100,[[20,10,80,70]]);
            tainted.rejectRead = true;
            for (let frame = 0; frame < 200; frame += 1)
              assert.equal(chatCameraAlphaBounds(tainted),null);
            assert.equal(alphaReads,2,'tainted image is attempted once, then metadata fallback');
            assert.equal(chatCameraAlphaBoundsCache.get(tainted),null);
            const body = {bounds: [0,0,900,1000],alignment: {face_bounds: [300,50,160,200]}};
            const span = chatCameraHeadSpan(body,900,1000,{body},{body: tainted});
            assert.ok(span.left > 290 && span.right < 470,
              'unreadable image falls back to face, not900px torso');
            visible(clampChatCameraFit({x:-2000,y:-2000,scale: 4,
              crop:{x:0,y:0,w:900,h:1000},headSpan: span},
              {x:20,y:70,right:300,bottom:500}),{x:20,y:70,right:300,bottom:500});
        """)

    def test_reused_replacement_canvas_uses_new_loaded_mask_identity(self):
        self.run_js(r"""
            const canvas = alphaImage(100,100,[[20,10,60,70]]);
            const firstMask = alphaImage(100,100,[]);
            const first = chatCameraAlphaBounds(canvas,null,firstMask);
            canvas.boxes = [[5,15,95,80]];
            assert.deepEqual(chatCameraAlphaBounds(canvas,null,firstMask),first);
            const secondMask = alphaImage(100,100,[]);
            const second = chatCameraAlphaBounds(canvas,null,secondMask);
            assert.ok(second[0] < first[0] && second[2] > first[2]);
            assert.equal(alphaReads,2,'exactlyone read per loadedmask acrossavatar reloads');
            assert.equal(chatCameraAlphaBoundsCache.has(canvas),false);
        """)

    def test_desktop_caches_head_bounds_once_while_motion_remains_readback_free(self):
        self.run_js(r"""
            bodyImage = alphaImage(900,1000,[[100,10,700,900]]);
            headMask = alphaImage(1024,1024,[[50,10,960,800]]);
            inChat = false;
            cameraFor(metadata,1086,1448);
            shellState.desktopCloseUp = true;
            cameraFor(metadata,1086,1448);
            const desktopReads = alphaReads;
            assert.equal(desktopReads,2,'desktop now shares the head-safe camera');
            for (let frame=0;frame<200;frame++) cameraFor(metadata,1086,1448);
            assert.equal(alphaReads,desktopReads,'never scan image pixels on each paint');
            shellState.desktopCloseUp = false;
            for (const kind of ['roam','idle','companion']) {
              shellState.pet.roam = kind === 'roam'; idleDocked = kind === 'idle';
              isCompanion = kind === 'companion';
              cameraFor(metadata,1086,1448);
            }
            inChat = true;
            const motionMeta = {bounds:[10,20,700,1000]};
            const motionFit = cameraFor(motionMeta,720,1088,'full');
            assert.deepEqual(motionFit.headSpan,{top:20,bottom:1020});
            assert.equal(alphaReads,desktopReads);
            assert.equal(alphaCanvases,desktopReads);
        """)

    def test_window_resize_reclamps_without_erasing_saved_camera(self):
        self.run_js(r"""
            shellState.chatCloseUp = true;
            shellState.pet.zoom = 3;
            chatAvatarOffset = {x: -80, y: -140};
            const stateBefore = structuredClone(shellState);
            const offsetBefore = {...chatAvatarOffset};
            const original = cameraFor(metadata, 1086, 1448);
            workspaceRect = rect(286, 0, 240, 210);
            headerRect = rect(286, 0, 240, 54);
            railRect = rect(470, 66, 40, 100);
            const small = cameraFor(metadata, 1086, 1448);
            visible(small, chatAvatarSafeViewport({reserveComposer: false, reserveRail: true}));
            workspaceRect = rect(240, 0, 920, 900);
            headerRect = rect(240, 0, 920, 54);
            railRect = rect(1092, 66, 40, 420);
            assert.deepEqual(cameraFor(metadata, 1086, 1448), original);
            assert.deepEqual(shellState, stateBefore);
            assert.deepEqual(chatAvatarOffset, offsetBefore);
            assert.deepEqual(boundedChatAvatarOffset({x: Infinity, y: -Infinity}), {x: 0, y: 0});
        """)

    def test_desktop_close_up_default_scale_preserved_but_head_extent_is_guarded(self):
        self.run_js(r"""
            inChat = false;
            shellState.desktopCloseUp = true;
            const expected = chatCloseUpGeometry(
              viewCrop(metadata, 1086, 1448, 'bust'), innerWidth, innerHeight, 1);
            const actual = cameraFor(metadata, 1086, 1448);
            assert.equal(actual.scale,expected.scale);
            assert.equal(actual.y,expected.y);
            assert.deepEqual(actual.crop,expected.crop);
            visible(actual,{x:0,y:0,right:innerWidth,bottom:innerHeight});
            assert.ok(actual.x <= expected.x,'head silhouette can pull the portrait off the right edge');
        """)

    def test_input_and_layout_paths_request_an_immediate_new_frame(self):
        for pattern in (
            r"if \(avatarZoomChanged\) lastFrame = 0;",
            r"const setHistoryOpen =[\s\S]*?lastFrame = 0;[\s\S]*?\n    \};",
            r"const applyWorkspaceInfoCollapsed =[\s\S]*?lastFrame = 0;[\s\S]*?\n    \};",
            r"chatAvatarOffset = boundedChatAvatarOffset\(\{[\s\S]*?\}\);\s*lastFrame = 0;",
            r"addEventListener\('resize', \(\) => \{[\s\S]*?lastFrame = 0;",
        ):
            with self.subTest(pattern=pattern):
                self.assertRegex(self.source, pattern)
        self.assertIn("context.drawImage(image, 0, 0, width, height);", self.source,
                      "Close-up must still draw the full body, not create a bust-only bitmap")


if __name__ == "__main__":
    unittest.main()
