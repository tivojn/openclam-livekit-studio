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

  // Exercise the production compositor AND real camera projection together.
  // Previously it calculated a crop but called render() without that view,
  // squeezing the full portrait into the cropped destination rectangle.
  const page = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
  const drawSource = page.match(/const drawAvatar3D = \(now, presentation = ''\) => \{[\s\S]*?\n    \};/)[0];
  let fit, drawn;
  const drawSandbox = {
    avatar3d: avatar, clearStage() {}, reducedMotion: { matches: true },
    desiredViseme: () => 'sil', currentViseme: 'sil', previousViseme: 'sil', visemeChangedAt: 0,
    blinkAmounts: () => ({ l: 0, r: 0 }), live: null, agentSpeaking: false, speechSource: null,
    cursorGazeTarget: () => ({ x: 0, y: 0 }), pointer: {}, avatarFaceAnchor: () => ({}),
    smoothCursorGaze: () => ({ x: 0, y: 0 }), avatar3dGazeState: {},
    bodyMotionAt: () => ({ breathe: 1 }), bodyMotionState: {},
    cameraFor: () => fit, chatWindowMotionFit: () => fit,
    avatarMirrored: false, root: { classList: { contains: () => true } },
    innerWidth: 1100, innerHeight: 760, pixelRatio: 2,
    audioSignal: null, microBrow: () => 0, avatar3dExpression: () => ({}),
    speechExpressionPlan: null, lastBodyGeometry: null,
    context: { save() {}, restore() {}, setTransform() {}, drawImage(...args) { drawn = args; } },
  };
  vm.runInNewContext(drawSource + '\nglobalThis.draw = drawAvatar3D;', drawSandbox);
  for (const mirrored of [false, true]) {
    drawSandbox.avatarMirrored = mirrored;
    for (const scale of [.35, 1, 2.5, 5]) {
      fit = { x: -160, y: -85, scale };
      drawn = null;
      drawSandbox.draw(1400);
      assert.ok(drawn, 'an on-screen crop must be composited');
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
  console.log('3D appearance: authored materials and non-speech morph weights preserved.');
  console.log('3D compositor: close-up, zoom and mirror preserve camera aspect ratio.');
})().catch(error => { console.error(error); process.exitCode = 1; });
