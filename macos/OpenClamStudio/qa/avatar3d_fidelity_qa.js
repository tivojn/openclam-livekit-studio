'use strict';

// Exercise the real loader and per-frame update with synthetic glTF objects.
// WebGL is stubbed; geometry, materials, scene graph and morph logic are real.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

(async () => {
  const three = await import('three');
  const scene = new three.Scene();
  const blend = new three.MeshStandardMaterial({ name: 'glass-pattern fabric',
    transparent: true, opacity: .64, side: three.FrontSide });
  const glass = new three.MeshPhysicalMaterial({ name: 'cornea', transmission: 1,
    opacity: 1, roughness: .05 });
  const mask = new three.MeshStandardMaterial({ alphaTest: .08 });
  const mesh = new three.Mesh(new three.BoxGeometry(), blend);
  mesh.morphTargetDictionary = { wardrobeFit: 0, eyeBlinkLeft: 1, 'vrc.v_aa': 2 };
  mesh.morphTargetInfluences = [.72, 0, 0];
  scene.add(mesh, new three.Mesh(new three.BoxGeometry(), glass),
    new three.Mesh(new three.BoxGeometry(), mask));
  const gltf = { scene, parser: { json: { nodes: [] }, associations: new Map() } };
  class Renderer {
    setPixelRatio() {} setSize() {} setClearColor() {} render() {}
  }
  const sandbox = { THREE: { ...three, WebGLRenderer: Renderer },
    GLTFLoader: class { async loadAsync() { return gltf; } },
    window: { dispatchEvent() {} }, Event: class {},
    document: { createElement: () => ({}) }, console };
  const source = fs.readFileSync(path.join(__dirname, '../web/avatar3d.js'), 'utf8')
    .replace(/^import .*;$/gm, '');
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../web/avatar3d-options.js'), 'utf8').replace(/^import .*;$/gm, '').replace(/export /g, ''), sandbox);
  vm.runInNewContext(source + '\nAvatar3D.prototype.lights = function() {};', sandbox);
  const avatar = sandbox.window.OpenClamAvatar3D.create();
  await avatar.load('synthetic.glb', { pose: 'rest' });
  assert.equal(blend.transparent, true, 'BLEND must retain blending');
  assert.equal(blend.opacity, .64, 'material names must not rewrite opacity');
  assert.equal(blend.side, three.FrontSide, 'preserve authored sidedness');
  assert.equal(glass.transmission, 1);
  assert.equal(glass.opacity, 1, 'transmission is not an alpha-opacity workaround');
  assert.equal(mask.alphaTest, .08, 'preserve the authored alpha cutoff');
  assert.equal(mask.alphaToCoverage, true);
  avatar.render(1000, { reduce: true, viseme: 'aa', blink: { l: 1, r: 0 } });
  assert.equal(mesh.morphTargetInfluences[0], .72, 'speech must preserve wardrobe/body fit');
  assert.equal(mesh.morphTargetInfluences[1], 1);
  assert.ok(mesh.morphTargetInfluences[2] > 0, 'speech still drives the mouth');
  avatar.render(1200, { reduce: true, viseme: 'sil' });
  assert.equal(mesh.morphTargetInfluences[0], .72);
  assert.equal(mesh.morphTargetInfluences[1], 0, 'the blink must release');

  avatar.render(1300, {reduce:true, visemeWeights:{aa:.7,PP:.3}});
  assert.ok(mesh.morphTargetInfluences[2] > 0, 'weighted phone speech reaches the shared solver');
  assert.equal(mesh.morphTargetInfluences[0], .72, 'weighted speech keeps the authored body fit');

  // Exercise the production compositor AND real camera projection together.
  // Previously it calculated a crop but called render() without that view,
  // squeezing the full portrait into the cropped destination rectangle.
  const page = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
  const drawSource = page.match(/const drawAvatar3D = \(now, presentation = ''\) => \{[\s\S]*?\n    \};/)[0];
  let fit, drawn;
  const drawSandbox = {
    document: {hidden:false},
    avatar3d: avatar, clearStage() {}, reducedMotion: { matches: true },
    desiredViseme: () => 'sil', currentViseme: 'sil', previousViseme: 'sil', visemeChangedAt: 0,
    blinkAmounts: () => ({ l: 0, r: 0 }), live: null, peerLiveFrame: null, agentSpeaking: false, speechSource: null,
    cursorGazeTarget: () => ({ x: 0, y: 0 }), pointer: {}, avatarFaceAnchor: () => ({}),
    smoothCursorGaze: () => ({ x: 0, y: 0 }), avatar3dGazeState: {},
    bodyMotionAt: () => ({ breathe: 1 }), bodyMotionState: {},
    cameraFor: () => fit, chatWindowMotionFit: () => fit,
    shellState: { chatCloseUp: false },
    chatAvatarSafeViewport: () => ({ x: 200, y: 80, width: 900, height: 680 }),
    numericAvatarZoom: value => Number(value) || 1,
    avatarCanvasPoint: point => point,
    avatarMirrored: false, root: { classList: { contains: () => true } },
    innerWidth: 1100, innerHeight: 760, pixelRatio: 2,
    audioSignal: null, microBrow: () => 0, avatar3dExpression: () => ({}),
    speechExpressionPlan: null, lastBodyGeometry: null,
    context: { save() {}, restore() {}, setTransform() {}, drawImage(...args) { drawn = args; } },
  };
  vm.runInNewContext(page.match(/const clampChatCameraFit = \(fit, viewport\) => \{[\s\S]*?\n    \};/)[0]
    + '\nglobalThis.clampChatCameraFit = clampChatCameraFit;', drawSandbox);
  vm.runInNewContext(drawSource + '\nglobalThis.draw = drawAvatar3D;', drawSandbox);
  for (const mirrored of [false, true]) {
    drawSandbox.avatarMirrored = mirrored;
    for (const scale of [.35, 1, 2.5, 5]) {
      fit = { x: -160, y: -85, scale, crop: { x: 0, y: 0, w: 1024, h: 1536 } };
      drawn = null;
      drawSandbox.draw(1400);
      assert.ok(drawn, 'an on-screen crop must be composited');
      assert.ok(drawSandbox.lastBodyGeometry.fit.y >= 80, '3D crown stays below the chat header');
      const [, , , , , x, y, w, h] = drawn;
      assert.equal(avatar.currentView.x, x, 'render and composite must use the same crop origin');
      assert.equal(avatar.currentView.y, y);
      assert.equal(avatar.currentView.w, w, 'do not squeeze a full frame into a partial crop');
      assert.equal(avatar.currentView.h, h);
      const center = new three.Vector3(0, .5, 0).project(avatar.camera);
      const horizontal = new three.Vector3(.1, .5, 0).project(avatar.camera);
      const vertical = new three.Vector3(0, .6, 0).project(avatar.camera);
      const unitWidth = Math.abs(horizontal.x - center.x) * w;
      const unitHeight = Math.abs(vertical.y - center.y) * h;
      assert.ok(Math.abs(unitWidth / unitHeight - 1) < 1e-8,
        `3D proportions must survive zoom ${scale} and mirror ${mirrored}`);
    }
  }
  // The phone bridge must preserve the same projection even when WebKit's
  // CSS surface is smaller than SwiftUI's camera crop. This reproduces the
  // measured 728pt → 654pt safe-area compression and keyboard resizing.
  const phoneBridge = path.join(__dirname, '../../../ios/OpenClamLiveKit/App/Avatar3D/avatar-ios.js');
  if (fs.existsSync(phoneBridge)) {
    const phone = { window: { addEventListener() {}, webkit: { messageHandlers: { avatarStatus: { postMessage() {} } } } },
      document: { addEventListener() {} }, location: { search: '?generation=1' }, URLSearchParams, console: { ...console } };
    vm.runInNewContext(fs.readFileSync(phoneBridge, 'utf8')
      .replace(/^import .*;$/gm, '').replace(/export /g, '')
      + '\nglobalThis.fit = fitAvatarViewport;globalThis.upload = uploadAvatarTextures;', phone);
    phone.setTimeout = setTimeout;
    const uploaded = [], closed = [];
    const bitmap = { close() { closed.push('shared'); assert.equal(uploaded.length, 2); } };
    const a = { isTexture: true, image: bitmap }, b = { isTexture: true, image: bitmap };
    const hidden = { visible: false, material: [{ map: a, normalMap: b }, { map: a }] };
    const prepared = { model: { traverse(fn) { fn(hidden); } },
      renderer: { initTexture(texture) { assert.equal(closed.length, 0); uploaded.push(texture); } } };
    assert.equal(await phone.upload(prepared), 1);
    assert.deepEqual(uploaded, [a, b], 'hidden outfits and shared images must upload before bitmap release');
    assert.equal(closed.length, 1, 'each shared bitmap closes exactly once');
    assert.equal(await phone.upload(prepared, () => true), undefined);
    assert.equal(uploaded.length, 2, 'context loss cancels further uploads');
    for (const [width, height] of [[402, 654], [402, 728], [402, 440], [440, 810], [852, 330]]) {
      for (const zoom of [.5, 1, 2.5]) {
        const crop = { x: 98.51428571428573, y: 0, w: 826.9714285714285 / zoom, h: 1497.6 / zoom };
        const view = phone.fit(crop, width, height, 3);
        avatar.render(1500, { reduce: true }, view);
        const center = new three.Vector3(0, .5, 0).project(avatar.camera);
        const horizontal = new three.Vector3(.1, .5, 0).project(avatar.camera);
        const vertical = new three.Vector3(0, .6, 0).project(avatar.camera);
        const ratio = Math.abs(horizontal.x-center.x) * width / (Math.abs(vertical.y-center.y) * height);
        assert.ok(Math.abs(ratio-1) < 1e-8, `phone canvas ${width}×${height}, zoom ${zoom} must be isotropic`);
        assert.ok(Math.abs(view.x+view.w/2-(crop.x+crop.w/2)) < 1e-8, 'preserve the crop center');
        assert.ok(Math.abs(view.y+view.h/2-(crop.y+crop.h/2)) < 1e-8, 'preserve the crop center');
      }
    }
  }

  // Orbit the real camera through a full turn and both elevation limits.
  // All model bounds stay inside the logical portrait; reset is exact.
  const front = avatar.camera.position.clone();
  const frontLayout = JSON.stringify(avatar.layout());
  for (const pitch of [-Math.PI, -.7, 0, .7, Math.PI]) {
    for (let yaw = -Math.PI * 2; yaw <= Math.PI * 2; yaw += Math.PI / 4) {
      avatar.setOrbit({ yaw, pitch });
      assert.ok(Math.abs(avatar.orbit.pitch) < Math.PI / 2, 'camera never flips');
      for (const x of [avatar.bounds.min.x, avatar.bounds.max.x]) {
        for (const y of [avatar.bounds.min.y, avatar.bounds.max.y]) {
          for (const z of [avatar.bounds.min.z, avatar.bounds.max.z]) {
            const point = avatar.project(new three.Vector3(x, y, z));
            assert.ok(point.x >= 0 && point.x <= avatar.width && point.y >= 0 && point.y <= avatar.height,
              'all orbit angles keep the model inside the portrait');
          }
        }
      }
    }
  }
  avatar.setOrbit({});
  assert.ok(avatar.camera.position.distanceTo(front) < 1e-8);
  assert.equal(JSON.stringify(avatar.layout()), frontLayout);
  // Nested and flattened exports must achieve the same visible head turn.
  // In Tia's export, head.x and neck.x are siblings: a 60% head share used
  // to silently lose the neck's other 40%. Check real world orientations,
  // eye compensation and a rigid hair attachment across repeated changes.
  for (const nested of [false, true]) {
    const fixture = new three.Scene();
    const neck = new three.Bone(); neck.name = 'neck.x'; neck.position.y = 1;
    const head = new three.Bone(); head.name = 'head.x';
    fixture.add(neck);
    (nested ? neck : fixture).add(head);
    head.position.y = nested ? .3 : 1.3;
    const eye = new three.Bone(); eye.name = 'c_eye.l'; head.add(eye);
    eye.position.set(-.035, .08, .05);
    const rightEye = new three.Bone(); rightEye.name = 'c_eye.r'; rightEye.position.set(.035, .08, .05); head.add(rightEye);
    const hair = new three.Object3D(); hair.position.set(.1, .2, 0); head.add(hair);
    const body = new three.Mesh(new three.BoxGeometry(.7, 2, .4), new three.MeshStandardMaterial());
    body.position.y = 1; fixture.add(body);
    gltf.scene = fixture;
    const moving = sandbox.window.OpenClamAvatar3D.create();
    await moving.load('gaze-fixture.glb', { pose: 'rest' });
    moving.render(1000, { reduce: true, gaze: { x: 0, y: 0 } });
    const heading = bone => {
      const forward = new three.Vector3(0, 0, 1).applyQuaternion(bone.getWorldQuaternion(new three.Quaternion()));
      return Math.atan2(forward.x, forward.z);
    };
    moving.render(1016, { gaze: { x: 1, y: 0 } });
    assert.ok(heading(head) > 0 && heading(head) < .1, 'head begins smoothly');
    assert.ok(heading(eye) - heading(head) > .12, 'eyes acquire the cursor while the head catches up');
    for (let now = 1032; now <= 2400; now += 16) moving.render(now, { gaze: { x: 1, y: 0 } });
    assert.ok(heading(head) > .43 && heading(head) < .5, `full head turn for ${nested ? 'nested' : 'flattened'} neck`);
    assert.ok(heading(eye) - heading(head) > .05 && heading(eye) - heading(head) < .09,
      'eyes settle toward center as the head turns');
    let gazeTime = 3000;
    for (const x of [-1, 1, -1, 0]) {
      moving.render(gazeTime += 1000, { reduce: true, gaze: { x, y: .6 * x } });
      const hairWorld = hair.getWorldPosition(new three.Vector3());
      const expected = new three.Vector3(.1, .2, 0).applyMatrix4(head.matrixWorld);
      assert.ok(hairWorld.distanceTo(expected) < 1e-8, 'hair remains fixed to the moving head');
    }
    assert.ok(Math.abs(heading(head)) < 1e-8, 'head returns to neutral without drift');
    assert.ok(Math.abs(heading(eye)) < 1e-8, 'eyes return to neutral without drift');
    // Unproject through the uncropped camera, then verify each optical axis
    // independently. This catches sign, eye convergence and orbit/crop errors.
    for (const orbit of [{yaw:0,pitch:0}, {yaw:.2,pitch:.15}, {yaw:-.2,pitch:-.15}]) {
      moving.setOrbit(orbit);
      moving.applyView({x:150,y:50,w:500,h:700,pixelWidth:1000,pixelHeight:1400});
      const face = moving.project(moving.headCenter);
      for (const [dx,dy] of [[0,0],[-45,0],[45,0],[0,-45],[0,45]]) {
        const cursor = {x:face.x+dx,y:face.y+dy};
        const target = moving.gazePoint(cursor), projected = moving.project(target);
        assert.ok(Math.hypot(projected.x-cursor.x,projected.y-cursor.y)<1e-7,
          'cursor depth must reproject to the exact portrait pixel');
        moving.render(gazeTime += 1000, {reduce:true, lookTarget:target});
        for (const eyeBone of [eye,rightEye]) {
          const actual = moving.eyeForward.get(eyeBone).clone()
            .applyQuaternion(eyeBone.getWorldQuaternion(new three.Quaternion())).normalize();
          const expected = target.clone().sub(eyeBone.getWorldPosition(new three.Vector3())).normalize();
          assert.ok(actual.angleTo(expected)<1e-6, 'both eyes converge on the actual target');
        }
      }
    }

    // A walk can contain an authored sideways head pose. Camera attention
    // compensates that track and ignores a pointer parked off to the side.
    for(const authoredYaw of [-.3,.3]){
      moving.baseQuaternions.set(head,new three.Quaternion().setFromAxisAngle(new three.Vector3(0,1,0),authoredYaw));
      moving.setOrbit({yaw:0,pitch:0});
      for(let i=0;i<100;i++)moving.render(gazeTime+=16,{cameraFocus:true,gaze:{x:1,y:1},lookTarget:new three.Vector3(50,50,-50)});
      const forward=moving.headForward.clone().applyQuaternion(head.getWorldQuaternion(new three.Quaternion()));
      const expected=moving.camera.position.clone().sub(moving.headCenter).normalize();
      assert(forward.angleTo(expected)<.035,'head maintains camera contact despite the authored look and pointer');
      for(const eyeBone of [eye,rightEye]){
        const optical=moving.eyeForward.get(eyeBone).clone().applyQuaternion(eyeBone.getWorldQuaternion(new three.Quaternion()));
        const target=moving.camera.position.clone().sub(eyeBone.getWorldPosition(new three.Vector3())).normalize();
        assert(optical.angleTo(target)<1e-6,'each eye looks at the camera');
      }
      const position=hair.getWorldPosition(new three.Vector3());
      assert(position.distanceTo(new three.Vector3(.1,.2,0).applyMatrix4(head.matrixWorld))<1e-8,'camera attention preserves rigid hair attachment');
    }
    moving.baseQuaternions.set(head,new three.Quaternion());
    moving.options = {update() {},enabled:()=>false};
    moving.render(gazeTime += 1000, {reduce:true,gaze:{x:1,y:1},cameraFocus:true,lookTarget:new three.Vector3(3,4,2)});
    assert.ok(Math.abs(heading(head)) < 1e-8, 'cursor opt-out returns the head to its neutral pose');
    assert.ok(Math.abs(heading(eye)) < 1e-8, 'cursor opt-out returns both eyes to neutral');
  }
  console.log('3D appearance: authored materials and non-speech morph weights preserved.');
  console.log('3D compositor: close-up, zoom and mirror preserve camera aspect ratio.');
  console.log('3D attention: head and eyes coordinate on nested and flattened neck rigs.');
})().catch(error => { console.error(error); process.exitCode = 1; });
