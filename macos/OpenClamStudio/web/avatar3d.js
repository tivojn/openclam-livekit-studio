// OpenClam Studio · 3D avatar renderer.
//
// A rigged glTF binary (GLB) becomes a desk avatar driven by the same timed
// Oculus/Meta XR viseme track that animates the 2D sprite banks. The scene is
// rendered to an offscreen WebGL canvas; the page compositor draws that canvas
// through its existing camera, zoom, mirror, hit-test and opacity paths, so the
// 2D pipeline is untouched and both kinds of avatar share one renderer loop.
//
// Loaded as an ES module from this same loopback origin (CSP `script-src
// 'self'`). It publishes `window.OpenClamAvatar3D` and fires the
// `openclam-avatar3d-ready` event once; the inline application script awaits
// that when a runtime manifest declares `renderer: "3d"`.
import * as THREE from '/vendor/three/three.module.js';
import { GLTFLoader } from '/vendor/three/GLTFLoader.js';
import { RoomEnvironment } from '/vendor/three/RoomEnvironment.js';
import { Avatar3DOptions, Avatar3DAppearance, mountAvatar3DOptions } from '/avatar3d-options.js';

const VISEMES = ['sil', 'PP', 'FF', 'TH', 'DD', 'kk', 'CH', 'SS',
  'nn', 'RR', 'aa', 'E', 'ih', 'oh', 'ou'];

// Morph-target spellings accepted for each viseme, compared case-insensitively.
// Covers Oculus/VRChat (`vrc.v_*`, `v_*`), Ready Player Me (`viseme_*`),
// bare names, and VRM/VRoid vowel keys.
const VISEME_ALIASES = {
  sil: ['vrc.v_sil', 'v_sil', 'viseme_sil', 'sil'],
  PP: ['vrc.v_pp', 'v_pp', 'viseme_pp', 'pp'],
  FF: ['vrc.v_ff', 'v_ff', 'viseme_ff', 'ff'],
  TH: ['vrc.v_th', 'v_th', 'viseme_th', 'th'],
  DD: ['vrc.v_dd', 'v_dd', 'viseme_dd', 'dd'],
  kk: ['vrc.v_kk', 'v_kk', 'viseme_kk', 'kk'],
  CH: ['vrc.v_ch', 'v_ch', 'viseme_ch', 'ch'],
  SS: ['vrc.v_ss', 'v_ss', 'viseme_ss', 'ss'],
  nn: ['vrc.v_nn', 'v_nn', 'viseme_nn', 'nn'],
  RR: ['vrc.v_rr', 'v_rr', 'viseme_rr', 'rr'],
  aa: ['vrc.v_aa', 'v_aa', 'viseme_aa', 'aa', 'a', 'fcl_mth_a'],
  E: ['vrc.v_ee', 'vrc.v_e', 'v_ee', 'v_e', 'viseme_e', 'viseme_ee', 'ee', 'e', 'fcl_mth_e'],
  ih: ['vrc.v_ih', 'v_ih', 'viseme_ih', 'viseme_i', 'ih', 'i', 'fcl_mth_i'],
  oh: ['vrc.v_oh', 'v_oh', 'viseme_oh', 'viseme_o', 'oh', 'o', 'fcl_mth_o'],
  ou: ['vrc.v_ou', 'v_ou', 'viseme_ou', 'viseme_u', 'ou', 'u', 'fcl_mth_u'],
};

// When a viseme has no dedicated target, approximate it from ARKit shapes.
const VISEME_RECIPES = {
  sil: {},
  PP: { mouthClose: .55, mouthPressLeft: .5, mouthPressRight: .5, jawOpen: .04 },
  FF: { mouthRollLower: .65, mouthFunnel: .1, jawOpen: .08 },
  TH: { jawOpen: .16, tongueOut: .45, mouthStretchLeft: .1, mouthStretchRight: .1 },
  DD: { jawOpen: .2, mouthStretchLeft: .15, mouthStretchRight: .15 },
  kk: { jawOpen: .26 },
  CH: { jawOpen: .14, mouthFunnel: .35, mouthPucker: .2 },
  SS: { jawOpen: .1, mouthStretchLeft: .35, mouthStretchRight: .35, mouthSmileLeft: .1, mouthSmileRight: .1 },
  nn: { jawOpen: .15, mouthStretchLeft: .1, mouthStretchRight: .1 },
  RR: { jawOpen: .2, mouthFunnel: .35, mouthPucker: .15 },
  aa: { jawOpen: .72, mouthStretchLeft: .08, mouthStretchRight: .08 },
  E: { jawOpen: .36, mouthStretchLeft: .4, mouthStretchRight: .4, mouthSmileLeft: .15, mouthSmileRight: .15 },
  ih: { jawOpen: .2, mouthSmileLeft: .3, mouthSmileRight: .3, mouthStretchLeft: .2, mouthStretchRight: .2 },
  oh: { jawOpen: .5, mouthFunnel: .6, mouthPucker: .2 },
  ou: { jawOpen: .24, mouthPucker: .8, mouthFunnel: .5 },
};

// Idle mouth corners: 0 is the rig's authored neutral, 1 a full smile.
const RESTING_SMILE = .35;

// Expression, blink and gaze channels with their accepted spellings.
const CHANNEL_ALIASES = {
  eyeBlinkLeft: ['eyeblinkleft', 'vrc.blink_left', 'blink_l', 'blink_left', 'blinkleft', 'fcl_eye_close_l', 'eye_close_l', 'eyeclose_l'],
  eyeBlinkRight: ['eyeblinkright', 'vrc.blink_right', 'blink_r', 'blink_right', 'blinkright', 'fcl_eye_close_r', 'eye_close_r', 'eyeclose_r'],
  blink: ['blink', 'fcl_eye_close', 'eyesclosed', 'eyes_closed'],
  eyeLookUpLeft: ['eyelookupleft'], eyeLookDownLeft: ['eyelookdownleft'],
  eyeLookInLeft: ['eyelookinleft'], eyeLookOutLeft: ['eyelookoutleft'],
  eyeLookUpRight: ['eyelookupright'], eyeLookDownRight: ['eyelookdownright'],
  eyeLookInRight: ['eyelookinright'], eyeLookOutRight: ['eyelookoutright'],
  eyeWideLeft: ['eyewideleft'], eyeWideRight: ['eyewideright'],
  eyeSquintLeft: ['eyesquintleft'], eyeSquintRight: ['eyesquintright'],
  browInnerUp: ['browinnerup', 'fcl_brw_surprised'],
  browOuterUpLeft: ['browouterupleft'], browOuterUpRight: ['browouterupright'],
  browDownLeft: ['browdownleft'], browDownRight: ['browdownright'],
  mouthSmileLeft: ['mouthsmileleft'], mouthSmileRight: ['mouthsmileright'],
  mouthFrownLeft: ['mouthfrownleft'], mouthFrownRight: ['mouthfrownright'],
  cheekSquintLeft: ['cheeksquintleft'], cheekSquintRight: ['cheeksquintright'],
  noseSneerLeft: ['nosesneerleft'], noseSneerRight: ['nosesneerright'],
  jawOpen: ['jawopen'], mouthClose: ['mouthclose'], mouthFunnel: ['mouthfunnel'],
  mouthPucker: ['mouthpucker'], mouthRollLower: ['mouthrolllower'],
  mouthPressLeft: ['mouthpressleft'], mouthPressRight: ['mouthpressright'],
  mouthStretchLeft: ['mouthstretchleft'], mouthStretchRight: ['mouthstretchright'],
  tongueOut: ['tongueout'],
  smile: ['fcl_mth_fun', 'fcl_all_fun', 'joy', 'fun', 'happy'],
  sorrow: ['fcl_mth_sorrow', 'fcl_all_sorrow', 'sorrow', 'sad'],
  angry: ['fcl_all_angry', 'angry'],
};

const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
const approach = (current, target, elapsedMs, tauMs) => {
  if (!(tauMs > 0)) return target;
  return current + (target - current) * (1 - Math.exp(-elapsedMs / tauMs));
};
const lower = value => String(value || '').toLowerCase();

const sideOf = name => {
  const n = lower(name);
  if (/(^|[^a-z])(left|l)([^a-z]|$)|_l$|\.l$|^l_|left/.test(n)) return 'l';
  if (/(^|[^a-z])(right|r)([^a-z]|$)|_r$|\.r$|^r_|right/.test(n)) return 'r';
  return null;
};

const BONE_PATTERNS = {
  head: /(^|[^a-z])head($|[^a-z]|\.x$)|j_bip_c_head|mixamorighead|^c_head/,
  neck: /(^|[^a-z])neck(_?0?1)?($|[^a-z]|\.x$)|j_bip_c_neck|mixamorigneck/,
  chest: /(^|[^a-z])(spine_?0?[23]|chest|spine2|upperchest)($|[^a-z])|j_bip_c_chest|mixamorigspine1/,
  hips: /(^|[^a-z])(hips|pelvis|root\.x)($|[^a-z])|j_bip_c_hips|mixamorighips/,
  upperArm: /(upperarm|upper_arm|uparm|^(c_)?arm(_stretch)?[._]|leftarm$|rightarm$|j_bip_[lr]_upperarm|mixamorig(left|right)arm$)/,
  lowerArm: /(lowerarm|lower_arm|^(c_)?forearm(_stretch)?[._]|forearm|j_bip_[lr]_lowerarm|mixamorig(left|right)forearm$)/,
  hand: /((^|[^a-z])hand($|[^a-z])|j_bip_[lr]_hand|mixamorig(left|right)hand$)/,
  eye: /((^|[^a-z])eye($|[^a-z])|c_eye[._]|j_bip_[lr]_faceeye|mixamorig(left|right)eye$)/,
  finger: /(index|middle|ring|pinky|thumb|finger|j_bip_[lr]_(index|middle|ring|little|thumb))/,
};

class Avatar3D {
  constructor({ width = 1024, height = 1536 } = {}) {
    this.width = Math.max(64, Math.round(width));
    this.height = Math.max(64, Math.round(height));
    this.canvas = document.createElement('canvas');
    this.canvas.width = this.width;
    this.canvas.height = this.height;
    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas, alpha: true, antialias: true, premultipliedAlpha: true,
      powerPreference: 'low-power', preserveDrawingBuffer: false,
    });
    this.renderer.setPixelRatio(1);
    this.renderer.setSize(this.width, this.height, false);
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.NeutralToneMapping;
    this.renderer.toneMappingExposure = 1.08;
    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(22, this.width / this.height, .05, 100);
    this.root = new THREE.Group();
    this.scene.add(this.root);
    this.model = null;
    this.morphMeshes = [];
    this.drivenMorphs = new Map();
    this.bones = {};
    this.channels = new Map();
    this.visemeWeights = Object.fromEntries(VISEMES.map(name => [name, 0]));
    this.visemeTargets = {};
    this.coverage = { direct: {}, recipe: [], missing: [] };
    this.baseQuaternions = new Map();
    this.headOffset = new THREE.Quaternion();
    this.eyeForward = new Map();
    this.lastFrameAt = 0;
    this.bounds = new THREE.Box3();
    this.headCenter = null;
    this.headRadius = 0;
    this.layoutCache = null;
    this.orbit = { yaw: 0, pitch: 0 };
    this.smooth = { gazeYaw: 0, gazePitch: 0, headYaw: 0, headPitch: 0, headRoll: 0, intensity: 0 };
    this.cameraApproach = null;
    this.disposed = false;
    this.lights();
  }

  lights() {
    // A soft three-point studio: warm key from the front-left, cool fill from
    // the right, a rim from behind, on top of an image-based room environment.
    const hemisphere = new THREE.HemisphereLight(0xfff7ee, 0x8a8f9a, .45);
    hemisphere.position.set(0, 1, 0);
    const key = new THREE.DirectionalLight(0xfff1e2, 1.5);
    key.position.set(-1.6, 2.6, 3.0);
    const fill = new THREE.DirectionalLight(0xe4ecff, .3);
    fill.position.set(2.4, 1.4, 2.2);
    const rim = new THREE.DirectionalLight(0xffffff, 1.1);
    rim.position.set(.6, 2.4, -2.8);
    this.studioLights = new THREE.Group();
    this.studioLights.add(hemisphere, key, fill, rim);
    this.scene.add(this.studioLights);
    try {
      const pmrem = new THREE.PMREMGenerator(this.renderer);
      const room=new RoomEnvironment();
      this.roomEnvironmentTarget=pmrem.fromScene(room,.04);
      this.scene.environment=this.roomEnvironmentTarget.texture;room.dispose();
      this.scene.environmentIntensity = .5;
      pmrem.dispose();
    } catch (_) {
      // A missing float-texture path only costs image-based reflections.
    }
  }

  async load(url, options = {}) {
    const loader = new GLTFLoader();
    const gltf = await loader.loadAsync(url);
    if (this.disposed) return this;
    this.model = gltf.scene;
    // three.js strips dots and slashes from node names ("head.x" becomes
    // "headx"), which breaks side and suffix detection for Auto-Rig Pro and
    // Blender rigs. Recover the authored names from the glTF document.
    const sourceNodes = (gltf.parser && gltf.parser.json && gltf.parser.json.nodes) || [];
    this.model.traverse(node => {
      const association = gltf.parser && gltf.parser.associations
        ? gltf.parser.associations.get(node) : null;
      const index = association && Number.isInteger(association.nodes) ? association.nodes : -1;
      const meshNode = index<0 && Number.isInteger(association?.meshes)
        ? sourceNodes.find(node=>node.mesh===association.meshes) : null;
      node.userData.sourceName = index >= 0 && sourceNodes[index] && sourceNodes[index].name
        ? String(sourceNodes[index].name) : meshNode?.name || node.name;
      node.userData.sourcePrimitive = association?.primitives || 0;
    });
    this.model.traverse(node => {
      if (!node.isMesh) return;
      node.frustumCulled = false;
      const materials = Array.isArray(node.material) ? node.material : [node.material];
      for (const material of materials) {
        if (!material) continue;
        // GLTFLoader already applies the authored alpha mode, cutoff, sides
        // and transmission. Names like "glass" are not rendering metadata.
        if (material.alphaTest > 0 && !material.transparent) {
          material.alphaToCoverage = true;
          material.needsUpdate = true;
        }
      }
      if (node.morphTargetDictionary && node.morphTargetInfluences) {
        this.morphMeshes.push(node);
      }
    });
    this.root.add(this.model);
    if (Number.isFinite(Number(options.yaw)) && Number(options.yaw)) {
      this.model.rotation.y = THREE.MathUtils.degToRad(Number(options.yaw));
    }
    this.collectBones();
    this.resolveChannels();
    this.appearance = new Avatar3DAppearance(this);
    for (const targets of this.channels.values()) {
      for (const { mesh, index } of targets) {
        if (!this.drivenMorphs.has(mesh)) this.drivenMorphs.set(mesh, new Set());
        this.drivenMorphs.get(mesh).add(index);
      }
    }
    this.model.updateMatrixWorld(true);
    const library = gltf.parser?.json?.extras?.openclamAvatar;
    if (library) {
      try { this.options = new Avatar3DOptions(this, library); }
      catch (error) { console.warn('3D options:', error.message); }
    }
    if(options.appearanceLibrary) {
      try {await this.appearance.loadPacks(options.appearanceLibrary);}
      catch(error){this.appearance.status=error.message;}
    }
    if (options.pose !== 'rest') this.relaxArms();
    this.options?.captureIdle();
    if (this.options && options.motionLibrary) {
      try {
        const { Avatar3DMotion } = await import('/avatar3d-motion.js');
        this.motion = await new Avatar3DMotion(this.options).load(options.motionLibrary);
      } catch (error) { console.warn('3D motions:', error.message); }
    }
    this.normalise();
    this.restHeadCenter = this.headCenter?.clone();
    const eyes=['l','r'].map(side=>this.bones.eye?.[side]).filter(Boolean);
    this.restFaceCenter=eyes.length?eyes.reduce((sum,eye)=>sum.add(eye.getWorldPosition(new THREE.Vector3())),new THREE.Vector3()).multiplyScalar(1/eyes.length)
      .add(new THREE.Vector3(0,-this.headRadius*.25,0)):this.restHeadCenter?.clone();
    this.restBounds = this.bounds.clone();
    this.frame();
    if (this.options) this.options.restBounds = this.bounds.clone();
    this.model.updateMatrixWorld(true);
    if (this.bones.head && this.headCenter) {
      this.headReferencePoint = this.headCenter.clone()
        .applyMatrix4(this.bones.head.matrixWorld.clone().invert());
    }
    this.captureCrown();
    const front = new THREE.Vector3(0, 0, 1)
      .applyQuaternion(this.model.getWorldQuaternion(new THREE.Quaternion()));
    if(this.bones.head)this.headForward=front.clone()
      .applyQuaternion(this.bones.head.getWorldQuaternion(new THREE.Quaternion()).invert());
    for (const side of ['l', 'r']) {
      const eye = this.bones.eye[side];
      if (eye) this.eyeForward.set(eye, front.clone()
        .applyQuaternion(eye.getWorldQuaternion(new THREE.Quaternion()).invert()));
    }
    return this;
  }

  collectBones() {
    // Helper bones (IK targets, offsets, twist/stretch chains, Auto-Rig Pro
    // `c_` controllers) share names with the deforming chain. Score every
    // candidate and keep the plainest name, which is the deform bone.
    const boneName = node => node.userData && node.userData.sourceName
      ? node.userData.sourceName : node.name;
    const penalty = name => {
      const n = lower(name);
      let score = 0;
      for (const token of ['ik_', '_ik', 'offset', 'twist', 'stretch', 'pole', '_fk', 'nostr',
        'ref', 'track', 'target', 'ctrl', 'control', 'helper', 'master', 'scale_fix']) {
        if (n.includes(token)) score += 10;
      }
      if (/^c_/.test(n)) score += 5;
      return score + n.length * .01;
    };
    const candidates = {};
    for (const key of Object.keys(BONE_PATTERNS)) candidates[key] = [];
    this.model.traverse(node => {
      if (!node.isBone && !(node.parent && node.parent.isBone)) return;
      const name = lower(boneName(node));
      for (const key of Object.keys(BONE_PATTERNS)) {
        if (BONE_PATTERNS[key].test(name)) candidates[key].push(node);
      }
    });
    const best = list => list.slice()
      .sort((a, b) => penalty(boneName(a)) - penalty(boneName(b)))[0] || null;
    this.boneGroups = {};
    for (const key of ['upperArm', 'lowerArm', 'hand', 'finger']) {
      this.boneGroups[key] = {};
      for (const side of ['l', 'r']) {
        this.boneGroups[key][side] = candidates[key].filter(node => sideOf(boneName(node)) === side);
      }
    }
    for (const key of ['head', 'neck', 'chest', 'hips']) this.bones[key] = best(candidates[key]);
    for (const key of ['upperArm', 'lowerArm', 'hand', 'eye']) {
      this.bones[key] = {};
      for (const side of ['l', 'r']) {
        this.bones[key][side] = best(candidates[key].filter(node => sideOf(boneName(node)) === side));
      }
    }
    for (const key of ['head', 'neck', 'chest']) {
      const bone = this.bones[key];
      if (bone) this.baseQuaternions.set(bone, bone.quaternion.clone());
    }
    for (const side of ['l', 'r']) {
      const eye = this.bones.eye[side];
      if (eye) this.baseQuaternions.set(eye, eye.quaternion.clone());
    }
  }

  resolveChannels() {
    const lookup = new Map();
    for (const mesh of this.morphMeshes) {
      for (const [name, index] of Object.entries(mesh.morphTargetDictionary)) {
        const key = lower(name);
        if (!lookup.has(key)) lookup.set(key, []);
        lookup.get(key).push({ mesh, index });
      }
    }
    const bind = (channel, aliases) => {
      for (const alias of aliases) {
        const targets = lookup.get(lower(alias));
        if (targets && targets.length) {
          this.channels.set(channel, targets);
          return true;
        }
      }
      return false;
    };
    for (const [channel, aliases] of Object.entries(CHANNEL_ALIASES)) bind(channel, aliases);
    for (const viseme of VISEMES) {
      const found = bind(`viseme:${viseme}`, VISEME_ALIASES[viseme]);
      if (found) {
        this.coverage.direct[viseme] = true;
        continue;
      }
      const recipe = VISEME_RECIPES[viseme];
      const usable = Object.keys(recipe).some(name => this.channels.has(name));
      if (viseme === 'sil' || usable) this.coverage.recipe.push(viseme);
      else this.coverage.missing.push(viseme);
    }
    this.coverage.direct = Object.keys(this.coverage.direct);
    this.coverage.blink = this.channels.has('eyeBlinkLeft') || this.channels.has('blink');
    this.coverage.gaze = this.channels.has('eyeLookOutLeft') || Boolean(this.bones.eye.l);
    this.coverage.head = Boolean(this.bones.head);
  }

  // Rest poses arrive as A- or T-poses. Turn each arm so the forearm hangs
  // beside the body, only when the arm is clearly raised; a rig already posed
  // for idle is left alone. Every deform bone of the segment is moved as one
  // rigid group about the joint, which also covers exporters that flatten
  // twist/stretch helpers into siblings (Auto-Rig Pro, some FBX converters).
  relaxArms() {
    const down = new THREE.Vector3(0, -1, 0);
    for (const side of ['l', 'r']) {
      const upper = this.bones.upperArm[side];
      const forearm = this.bones.lowerArm[side];
      const hand = this.bones.hand[side];
      if (!upper || !forearm) continue;
      const outward = side === 'l' ? 1 : -1;
      const segment = key => this.boneGroups[key][side] || [];
      const upperGroup = [...segment('upperArm'), ...segment('lowerArm'), ...segment('hand'), ...segment('finger')];
      const upperTarget = new THREE.Vector3(.16 * outward, -1, .04).normalize();
      if (!this.rotateGroupAbout(upperGroup, upper, forearm, upperTarget, down, 22)) continue;
      if (hand) {
        const forearmGroup = [...segment('lowerArm'), ...segment('hand'), ...segment('finger')];
        const forearmTarget = new THREE.Vector3(.05 * outward, -1, .12).normalize();
        this.rotateGroupAbout(forearmGroup, forearm, hand, forearmTarget, down, 12);
      }
    }
  }

  rotateGroupAbout(group, pivotBone, endBone, target, down, minimumDegrees) {
    this.model.updateMatrixWorld(true);
    const pivot = pivotBone.getWorldPosition(new THREE.Vector3());
    const current = endBone.getWorldPosition(new THREE.Vector3()).sub(pivot);
    if (current.lengthSq() < 1e-10) return false;
    current.normalize();
    if (THREE.MathUtils.radToDeg(current.angleTo(down)) < minimumDegrees) return false;
    const rotation = new THREE.Matrix4().makeRotationFromQuaternion(
      new THREE.Quaternion().setFromUnitVectors(current, target));
    const about = new THREE.Matrix4().makeTranslation(pivot.x, pivot.y, pivot.z)
      .multiply(rotation)
      .multiply(new THREE.Matrix4().makeTranslation(-pivot.x, -pivot.y, -pivot.z));
    // Only the topmost bones of the group move; their descendants follow.
    const members = new Set(group);
    const roots = group.filter(bone => {
      let ancestor = bone.parent;
      while (ancestor) {
        if (members.has(ancestor)) return false;
        ancestor = ancestor.parent;
      }
      return true;
    });
    for (const bone of roots) {
      const world = about.clone().multiply(bone.matrixWorld);
      const parentInverse = bone.parent
        ? bone.parent.matrixWorld.clone().invert() : new THREE.Matrix4();
      parentInverse.multiply(world).decompose(bone.position, bone.quaternion, bone.scale);
      if (this.baseQuaternions.has(bone)) this.baseQuaternions.set(bone, bone.quaternion.clone());
    }
    this.model.updateMatrixWorld(true);
    return roots.length > 0;
  }

  // Sit the model on y=0, centred on x/z, and measure its extents.
  modelBounds() {
    if (!this.options) return new THREE.Box3().setFromObject(this.model, true);
    const box = new THREE.Box3();
    this.model.traverseVisible(node => {
      if (node.isMesh) box.union(new THREE.Box3().setFromObject(node, true));
    });
    return box;
  }

  normalise() {
    this.model.updateMatrixWorld(true);
    const box = this.modelBounds();
    if (box.isEmpty()) return;
    const size = box.getSize(new THREE.Vector3());
    const center = box.getCenter(new THREE.Vector3());
    this.root.position.set(-center.x, -box.min.y, -center.z);
    this.root.updateMatrixWorld(true);
    this.bounds = this.modelBounds();
    const height = Math.max(1e-4, size.y);
    const head = this.bones.head;
    if (head) {
      const headPosition = head.getWorldPosition(new THREE.Vector3());
      // Head bone origin sits at the base of the skull; the visible head is
      // above it. Estimate a radius from the whole figure's height.
      this.headRadius = height * .075;
      this.headCenter = headPosition.clone().add(new THREE.Vector3(0, this.headRadius * .9, 0));
    } else {
      this.headRadius = height * .075;
      this.headCenter = new THREE.Vector3(0, this.bounds.max.y - this.headRadius * 1.1, 0);
    }
  }

  frame() {
    const bounds = this.restBounds || this.options?.restBounds || this.bounds;
    const size = bounds.getSize(new THREE.Vector3());
    const center = bounds.getCenter(new THREE.Vector3());
    const height = Math.max(1e-4, size.y);
    const width = Math.max(1e-4, size.x);
    const vertical = THREE.MathUtils.degToRad(this.camera.fov) / 2;
    const horizontal = Math.atan(Math.tan(vertical) * this.camera.aspect);
    let distance = Math.max(
      (height * .5 * 1.06) / Math.tan(vertical),
      (width * .5 * 1.12) / Math.tan(horizontal),
    );
    const { yaw, pitch } = this.orbit;
    const outward = new THREE.Vector3(Math.sin(yaw) * Math.cos(pitch),
      Math.sin(pitch), Math.cos(yaw) * Math.cos(pitch));
    const right = new THREE.Vector3(Math.cos(yaw), 0, -Math.sin(yaw));
    const up = new THREE.Vector3().crossVectors(outward, right);
    // Fit every corner from the chosen direction, including its depth. A
    // front-only bounding rectangle clips the crown in elevated/side views.
    for (const x of [bounds.min.x, bounds.max.x]) {
      for (const y of [bounds.min.y, bounds.max.y]) {
        for (const z of [bounds.min.z, bounds.max.z]) {
          const point = new THREE.Vector3(x, y, z).sub(center);
          distance = Math.max(distance, point.dot(outward)
            + Math.max(Math.abs(point.dot(up)) * 1.08 / Math.tan(vertical),
              Math.abs(point.dot(right)) * 1.12 / Math.tan(horizontal)));
        }
      }
    }
    distance = Math.max(distance, bounds.max.z - center.z
      + Math.max(height * .5 * 1.06 / Math.tan(vertical), width * .5 * 1.12 / Math.tan(horizontal)));
    if(this.studioDistance>0)distance=this.studioDistance;
    this.camera.position.copy(center).addScaledVector(outward, distance);
    this.camera.lookAt(center.x, center.y, center.z);
    this.camera.updateMatrixWorld(true);
    this.camera.near = Math.max(.01, distance * .1);
    this.camera.far = distance * 6 + height * 4;
    this.camera.updateProjectionMatrix();
    this.layoutCamera = null;
    this.layoutCache = null;
  }

  lockStudioLens() {
    const center=(this.restBounds||this.bounds).getCenter(new THREE.Vector3());
    this.studioDistance=this.camera.position.distanceTo(center);
  }

  studioProjection() {
    const bounds=this.restBounds||this.bounds,center=bounds.getCenter(new THREE.Vector3());
    const distance=this.studioDistance||this.camera.position.distanceTo(center);
    const focal=this.height/(2*Math.tan(THREE.MathUtils.degToRad(this.camera.fov)/2));
    const groundDepth=(center.y-bounds.min.y)/distance;
    // Walking uses a level camera. The ground's projection is invariant to
    // yaw; forward strides foreshorten vertically by groundDepth.
    return {ground:{x:this.width/2,y:this.height/2+focal*groundDepth},
      pixelsPerUnit:focal/distance,groundDepth};
  }

  setOrbit({ yaw = 0, pitch = 0 } = {}) {
    const finite = value => Number.isFinite(Number(value)) ? Number(value) : 0;
    const next = { yaw: Math.atan2(Math.sin(finite(yaw)), Math.cos(finite(yaw))),
      pitch: clamp(finite(pitch), -Math.PI * .44, Math.PI * .44) };
    if (Math.abs(next.yaw - this.orbit.yaw) < 1e-6
        && Math.abs(next.pitch - this.orbit.pitch) < 1e-6) return;
    this.orbit = next;
    this.frame();
  }

  // Locomotion toward the viewer uses perspective distance, never changes
  // the GLB, bone scale, or the relative shape of the face and hair. The
  // camera tracks up to eye level as the figure enters a close conversation.
  approachCamera(action, now, view) {
    if (!this.headCenter || !view || !(view.w > 0 && view.h > 0)) return false;
    const previous = this.cameraApproach;
    const current = previous ? this.approachFrame(now) : null;
    const initialCamera = this.camera.clone();
    initialCamera.clearViewOffset(); initialCamera.updateProjectionMatrix();
    const origin = previous?.origin || { camera: initialCamera.clone(), view: {...view} };
    const fromCamera = current?.camera.clone() || initialCamera;
    const fromView = {...view};
    const level = action === 'back' ? Math.max(-3, (previous?.level || 0) - 1)
      : Math.min(4, (previous?.level || 0) + 1);
    if (level === (previous?.level || 0) && !previous?.moving) return false;
    const focus = previous?.focus.clone() || (this.restFaceCenter || this.restHeadCenter || this.headCenter).clone();
    const aspect = view.w / view.h;
    const targetView = level>0 ? {x:0, y:0, w:this.width, h:this.width/aspect} : {...origin.view};
    targetView.x = level>0 ? (this.width-targetView.w)/2 : targetView.x;
    targetView.y = level>0 ? (this.height-targetView.h)/2 : targetView.y;
    const targetCamera = origin.camera.clone();
    if (level>0) {
      const fill = [.0,.82,.96,1.08,1.18][level];
      const vertical = Math.tan(THREE.MathUtils.degToRad(targetCamera.fov)/2);
      const horizontal = vertical * this.width/this.height;
      const distance = Math.max(this.headRadius*2.5,
        this.headRadius*this.width/(horizontal*targetView.w*fill),
        this.headRadius*this.height/(vertical*targetView.h*fill));
      targetCamera.position.copy(focus).add(new THREE.Vector3(0,0,distance));
      targetCamera.quaternion.identity();
      targetCamera.near = Math.max(.005, this.headRadius*.08);
      targetCamera.far = Math.max(origin.camera.far, distance+10);
      targetCamera.updateMatrixWorld(true);
    } else if(level<0) {
      const outward=origin.camera.getWorldDirection(new THREE.Vector3()).negate();
      const distance=origin.camera.position.distanceTo(focus);
      targetCamera.position.addScaledVector(outward,distance*(Math.pow(1.45,-level)-1));
      targetCamera.far=Math.max(origin.camera.far,targetCamera.position.distanceTo(focus)*3);
      targetCamera.updateMatrixWorld(true);
    }
    const travel = fromCamera.position.distanceTo(targetCamera.position);
    const height = Math.max(this.headRadius*12, .01);
    this.cameraApproach = {origin, focus, level, fromCamera, targetCamera, fromView,
      targetView, started:now, duration:Math.max(1400,Math.min(6500,travel/height*1500)),
      moving:true, direction:action==='back'?-1:1, baseOrbit:{...this.orbit},
      camera:fromCamera.clone(), view:{...fromView}};
    return true;
  }

  approachFrame(now, {aspect, zoom=1, panX=0, panY=0, reduce=false} = {}) {
    const move = this.cameraApproach;
    if (!move) return null;
    if (reduce) this.stopCameraApproach(now);
    const t = move.moving ? clamp((now-move.started)/move.duration,0,1) : 1;
    const u = t*t*(3-2*t);
    const camera = move.fromCamera.clone();
    camera.position.lerp(move.targetCamera.position,u);
    camera.quaternion.slerp(move.targetCamera.quaternion,u);
    camera.near = Math.min(move.fromCamera.near,move.targetCamera.near);
    camera.far = Math.max(move.fromCamera.far,move.targetCamera.far);
    camera.updateMatrixWorld(true);
    const view = Object.fromEntries(['x','y','w','h'].map(k=>[k,move.fromView[k]+(move.targetView[k]-move.fromView[k])*u]));
    // Resizing a window or showing a keyboard changes the crop uniformly.
    if (aspect > 0 && Number.isFinite(aspect)) {
      const w = Math.max(view.w,view.h*aspect), h = w/aspect;
      view.x -= (w-view.w)/2; view.y -= (h-view.h)/2; view.w=w; view.h=h;
    }
    const z = clamp(Number.isFinite(zoom)?zoom:1,.2,5);
    view.x += view.w*(1-1/z)/2; view.y += view.h*(1-1/z)/2;
    view.w /= z; view.h /= z;
    view.x += Number.isFinite(panX)?panX:0; view.y += Number.isFinite(panY)?panY:0;
    const yaw = this.orbit.yaw-move.baseOrbit.yaw, pitch = this.orbit.pitch-move.baseOrbit.pitch;
    if (Math.abs(yaw)+Math.abs(pitch)>1e-6) {
      const rotation = new THREE.Quaternion().setFromEuler(new THREE.Euler(pitch,yaw,0,'YXZ'));
      camera.position.sub(move.focus).applyQuaternion(rotation).add(move.focus);
      camera.quaternion.premultiply(rotation); camera.updateMatrixWorld(true);
    }
    camera.clearViewOffset(); camera.updateProjectionMatrix();
    move.camera=camera; move.view=view;
    if (t===1) move.moving=false;
    this.camera.copy(camera); this.layoutCamera=null;
    return {camera,view,moving:move.moving,level:move.level};
  }

  stopCameraApproach(now) {
    const move = this.cameraApproach;
    if (!move?.moving) return;
    const frame = this.approachFrame(now);
    move.fromCamera=frame.camera.clone(); move.targetCamera=frame.camera.clone();
    move.fromView={...frame.view}; move.targetView={...frame.view};
    move.baseOrbit={...this.orbit}; move.moving=false;
  }

  resetCameraApproach() {
    this.cameraApproach=null;
    this.frame();
  }

  approachLayout() {
    const camera=this.cameraApproach?.camera;
    if (!camera) return this.layout();
    const project = p => {const n=p.clone().project(camera);return [(n.x+1)*this.width/2,(1-n.y)*this.height/2];};
    const rect = points => {const xs=points.map(p=>p[0]),ys=points.map(p=>p[1]);return [Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys)];};
    const body=[],face=[];
    const bounds=this.restBounds||this.bounds;
    for(const x of [bounds.min.x,bounds.max.x])for(const y of [bounds.min.y,bounds.max.y])for(const z of [bounds.min.z,bounds.max.z])body.push(project(new THREE.Vector3(x,y,z)));
    const center=this.cameraApproach.focus, r=this.headRadius;
    for(const x of [-r,r])for(const y of [-r,r])face.push(project(center.clone().add(new THREE.Vector3(x,y,0))));
    return {bounds:rect(body),faceBounds:rect(face)};
  }

  resize(width, height) {
    const w = Math.max(64, Math.round(width)), h = Math.max(64, Math.round(height));
    if (w === this.width && h === this.height) return;
    this.width = w;
    this.height = h;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.frame();
  }

  project(point) {
    if (!this.layoutCamera) {
      this.layoutCamera = this.camera.clone();
      this.layoutCamera.clearViewOffset();
      this.layoutCamera.updateProjectionMatrix();
    }
    const ndc = point.clone().project(this.layoutCamera);
    return { x: (ndc.x + 1) * .5 * this.width, y: (1 - ndc.y) * .5 * this.height };
  }

  gazePoint(point) {
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return null;
    // Unproject the actual cursor through the full portrait camera. Choosing
    // a plane in front of the face gives the 2D cursor a stable 3D depth.
    // Its projection is exact at any crop, zoom, placement or orbit angle.
    this.project(this.headCenter);
    if (this.cameraApproach) {
      this.layoutCamera=this.cameraApproach.camera.clone();
      this.layoutCamera.clearViewOffset(); this.layoutCamera.updateProjectionMatrix();
    }
    const ray = new THREE.Raycaster();
    ray.setFromCamera(new THREE.Vector2(point.x / this.width * 2 - 1,
      1 - point.y / this.height * 2), this.layoutCamera);
    const normal = this.camera.position.clone().sub(this.headCenter).normalize();
    const depth = Math.min(this.bounds.getSize(new THREE.Vector3()).y * .18,
      this.camera.position.distanceTo(this.headCenter) * .65);
    const plane = new THREE.Plane().setFromNormalAndCoplanarPoint(normal,
      this.headCenter.clone().addScaledVector(normal, depth));
    return ray.ray.intersectPlane(plane, new THREE.Vector3());
  }

  aimEyes(target) {
    for (const side of ['l', 'r']) {
      const eye = this.bones.eye[side];
      const base = eye && this.baseQuaternions.get(eye);
      if (!base) continue;
      const parent = eye.parent
        ? eye.parent.getWorldQuaternion(new THREE.Quaternion()) : new THREE.Quaternion();
      const neutral = parent.clone().multiply(base);
      const forward = this.eyeForward.get(eye);
      if (!forward) continue;
      const from = forward.clone().applyQuaternion(neutral).normalize();
      const to = new THREE.Vector3(target.x, target.y, target.z)
        .sub(eye.getWorldPosition(new THREE.Vector3())).normalize();
      const delta = new THREE.Quaternion().setFromUnitVectors(from, to);
      // Beyond a comfortable eye range, keep looking as close as anatomy
      // allows. Never flip the eyes toward a cursor behind the character.
      const angle = from.angleTo(to);
      if (angle > .65) delta.slerp(new THREE.Quaternion(), 1 - .65 / angle);
      const local = parent.clone().invert().multiply(delta).multiply(parent);
      eye.quaternion.copy(base).premultiply(local);
    }
    this.root.updateMatrixWorld(true);
  }

  // Render only `view` (a rectangle in the logical width x height image) into
  // `pixelWidth` x `pixelHeight` device pixels. The compositor asks for the
  // part that is on screen at its on-screen size, so a close-up is as sharp
  // as the full figure without ever rendering an oversized frame.
  applyView(view) {
    const full = { x: 0, y: 0, w: this.width, h: this.height,
      pixelWidth: this.width, pixelHeight: this.height };
    const wanted = view && view.w > 0 && view.h > 0 ? view : full;
    const pw = Math.max(8, Math.round(wanted.pixelWidth || wanted.w));
    const ph = Math.max(8, Math.round(wanted.pixelHeight || wanted.h));
    if (pw !== this.canvas.width || ph !== this.canvas.height) {
      this.renderer.setSize(pw, ph, false);
    }
    this.camera.setViewOffset(this.width, this.height, wanted.x, wanted.y, wanted.w, wanted.h);
    this.camera.updateProjectionMatrix();
    this.currentView = { x: wanted.x, y: wanted.y, w: wanted.w, h: wanted.h, pixelWidth: pw, pixelHeight: ph };
    return this.currentView;
  }

  // Pixel boxes the compositor uses for framing, close-up and gaze anchoring.
  layout() {
    if (this.layoutCache) return this.layoutCache;
    // Motion extents remain available for hit testing, but a raised arm,
    // kick, or seated pose must not shrink the entire character to fit.
    const bounds = this.restBounds || this.options?.restBounds || this.bounds;
    const corners = [];
    for (const x of [bounds.min.x, bounds.max.x]) {
      for (const y of [bounds.min.y, bounds.max.y]) {
        for (const z of [bounds.min.z, bounds.max.z]) {
          corners.push(this.project(new THREE.Vector3(x, y, z)));
        }
      }
    }
    const box = points => {
      const xs = points.map(p => p.x), ys = points.map(p => p.y);
      const x0 = clamp(Math.min(...xs), 0, this.width), x1 = clamp(Math.max(...xs), 0, this.width);
      const y0 = clamp(Math.min(...ys), 0, this.height), y1 = clamp(Math.max(...ys), 0, this.height);
      return [x0, y0, Math.max(1, x1 - x0), Math.max(1, y1 - y0)];
    };
    const face = [];
    if (this.headCenter) {
      const r = this.headRadius;
      for (const dx of [-r, r]) {
        for (const dy of [-r, r]) {
          face.push(this.project((this.restHeadCenter || this.headCenter).clone().add(new THREE.Vector3(dx, dy, 0))));
        }
      }
    }
    this.layoutCache = {
      bounds: box(corners),
      faceBounds: face.length ? box(face) : null,
    };
    return this.layoutCache;
  }

  setChannel(weights, channel, value) {
    if (!(value > 0)) return;
    weights.set(channel, Math.min(1, (weights.get(channel) || 0) + value));
  }

  captureCrown() {
    if (!this.bones.head || !this.headCenter) return;
    // Measure the visible geometry once at load. A projected 3D box includes
    // empty corners above the hair; magnifying that gap made close-ups sink.
    // Keep only the crown landmark, attached to the same head as the hair.
    const point=new THREE.Vector3();let top=Infinity,crown=null;
    this.model.traverseVisible(node=>{
      if(!node.isMesh||!node.geometry?.attributes.position)return;
      for(let i=0;i<node.geometry.attributes.position.count;i++){
        node.getVertexPosition(i,point).applyMatrix4(node.matrixWorld);
        if(point.y<this.headCenter.y)continue;
        const y=this.project(point).y;
        if(y<top){top=y;crown=point.clone();}
      }
    });
    if(crown)this.crownReferencePoint=crown.applyMatrix4(this.bones.head.matrixWorld.clone().invert());
  }

  crownProjection() {
    if(!this.crownReferencePoint||!this.bones.head)return null;
    return this.project(this.crownReferencePoint.clone().applyMatrix4(this.bones.head.matrixWorld));
  }

  prepareMotionFrame(now, reduce = false) {
    this.options?.update(now, reduce);
    this.preparedMotionFrame={now,reduce};
  }

  keepMotionInViewport(fit, surface) {
    if (!this.options || !(this.motion?.active || this.options.transition)) return fit;
    // Joint bounds are cheap and include the animated root translation. Keep
    // hands, head and feet inside the host surface without changing actor size.
    // Exact deformed-vertex bounds would stall the mobile render thread.
    const points=this.options.bones.map(({node})=>this.project(node.getWorldPosition(new THREE.Vector3())));
    if(!points.length||!points.every(p=>Number.isFinite(p.x)&&Number.isFinite(p.y)))return fit;
    const pad=Math.max(8,this.height*fit.scale*.025);
    const crown=this.crownProjection();if(crown)points.push(crown);
    const xs=points.map(p=>p.x*fit.scale),ys=points.map(p=>p.y*fit.scale);
    const torso=[this.bones.head,this.bones.chest,this.bones.hips].filter(Boolean)
      .map(node=>this.project(node.getWorldPosition(new THREE.Vector3())));
    const focusX=(torso.length?torso:points).map(p=>p.x*fit.scale);
    const head=crown||(torso.length?torso[0]:points[0]);
    const place=(origin,min,max,start,length,focusMin,focusMax=focusMin)=>max-min+pad*2<=length
      ? clamp(origin,start+pad-min,start+length-pad-max)
      : clamp(origin,start+pad-focusMin,start+length-pad-focusMax);
    // A deliberately enlarged figure can exceed a phone's width. Keep its
    // torso/head on screen without a surprise zoom or letting the root lunge
    // carry the entire performer outside the view.
    return {...fit,x:place(fit.x,Math.min(...xs),Math.max(...xs),surface.x,surface.width,Math.min(...focusX),Math.max(...focusX)),
      y:place(fit.y,Math.min(...ys),Math.max(...ys),surface.y,surface.height,head.y*fit.scale)};
  }

  render(now, state = {}, view = null) {
    if (this.disposed || !this.model) return this.canvas;
    if(this.preparedMotionFrame?.now!==now||this.preparedMotionFrame.reduce!==Boolean(state.reduce))
      this.options?.update(now, Boolean(state.reduce));
    this.preparedMotionFrame=null;
    if (this.options && !this.options.enabled('followCursor')) {
      state = {...state,gaze:{x:0,y:0},lookTarget:null,cameraFocus:false};
    }
    if (this.cameraApproach) this.camera.copy(this.cameraApproach.camera);
    this.applyView(view);
    // An explicit approach attends to the viewer, independently of the last
    // pointer position. Manual controls/new actions release this attention.
    if(state.cameraFocus)state={...state,gaze:{x:0,y:0},lookTarget:this.camera.position.clone()};
    const elapsed = this.lastFrameAt > 0 ? clamp(now - this.lastFrameAt, 1, 120) : 16;
    this.lastFrameAt = now;
    const reduce = Boolean(state.reduce);
    const weights = new Map();

    // Lips. Every viseme keeps its own smoothed weight so a fast DD→aa→nn run
    // blends through real in-between shapes instead of snapping.
    const wanted = VISEMES.includes(state.viseme) ? state.viseme : 'sil';
    const intensity = clamp(Number(state.intensity) || 0, 0, 1);
    this.smooth.intensity = approach(this.smooth.intensity, intensity, elapsed, 60);
    const articulation = .58 + .42 * this.smooth.intensity;
    for (const viseme of VISEMES) {
      const target = state.visemeWeights && typeof state.visemeWeights === 'object'
        ? clamp(Number(state.visemeWeights[viseme]) || 0, 0, 1)
        : viseme === wanted && wanted !== 'sil' ? 1 : 0;
      const tau = target > this.visemeWeights[viseme] ? 38 : 64;
      this.visemeWeights[viseme] = approach(this.visemeWeights[viseme], target, elapsed, tau);
      const weight = this.visemeWeights[viseme];
      if (weight < .002 || viseme === 'sil') continue;
      const scaled = weight * articulation;
      if (this.channels.has(`viseme:${viseme}`)) {
        this.setChannel(weights, `viseme:${viseme}`, scaled);
      } else {
        for (const [channel, amount] of Object.entries(VISEME_RECIPES[viseme])) {
          this.setChannel(weights, channel, amount * scaled);
        }
      }
    }

    // Eyes.
    const blink = state.blink || { l: 0, r: 0 };
    if (this.channels.has('eyeBlinkLeft') || this.channels.has('eyeBlinkRight')) {
      this.setChannel(weights, 'eyeBlinkLeft', blink.l);
      this.setChannel(weights, 'eyeBlinkRight', blink.r);
    } else {
      this.setChannel(weights, 'blink', Math.max(blink.l || 0, blink.r || 0));
    }
    const gaze = state.gaze || { x: 0, y: 0 };
    const attentionX = clamp(Number(gaze.x) || 0, -1, 1);
    const attentionY = clamp(Number(gaze.y) || 0, -1, 1);
    const { x: gx, y: gy } = this.pose(now, elapsed, {
      gx: attentionX, gy: attentionY, reduce, speaking: Boolean(state.speaking),
      breathe: Number(state.breathe) || 1, head: state.head || {}, target: state.lookTarget,cameraFocus:state.cameraFocus,
    });
    // +x is the viewer's right, which is the character's own left.
    if (!(state.lookTarget && this.bones.eye.l && this.bones.eye.r)) {
      if (gx > 0) { this.setChannel(weights, 'eyeLookOutLeft', gx); this.setChannel(weights, 'eyeLookInRight', gx); }
      if (gx < 0) { this.setChannel(weights, 'eyeLookInLeft', -gx); this.setChannel(weights, 'eyeLookOutRight', -gx); }
      if (gy > 0) { this.setChannel(weights, 'eyeLookDownLeft', gy); this.setChannel(weights, 'eyeLookDownRight', gy); }
      if (gy < 0) { this.setChannel(weights, 'eyeLookUpLeft', -gy); this.setChannel(weights, 'eyeLookUpRight', -gy); }
    }

    // Brows and mood.
    const brow = clamp(Number(state.brow) || 0, -1, 1);
    if (brow > 0) {
      this.setChannel(weights, 'browInnerUp', brow * .45);
      this.setChannel(weights, 'browOuterUpLeft', brow * .35);
      this.setChannel(weights, 'browOuterUpRight', brow * .35);
    } else if (brow < 0) {
      this.setChannel(weights, 'browDownLeft', -brow * .4);
      this.setChannel(weights, 'browDownRight', -brow * .4);
    }
    const mood = state.expression || {};
    // A resting hint of a smile keeps a neutral rig from reading as blank or
    // stern; spoken moods and sadness still take over above it.
    const restingSmile = Math.max(0, RESTING_SMILE - clamp(Number(mood.sad) || 0, 0, 1)
      - clamp(Number(mood.anger) || 0, 0, 1));
    const smile = Math.max(restingSmile, clamp(Number(mood.smile) || 0, 0, 1));
    const sad = clamp(Number(mood.sad) || 0, 0, 1);
    const surprise = clamp(Number(mood.surprise) || 0, 0, 1);
    const anger = clamp(Number(mood.anger) || 0, 0, 1);
    if (smile) {
      this.setChannel(weights, 'mouthSmileLeft', smile * .5);
      this.setChannel(weights, 'mouthSmileRight', smile * .5);
      this.setChannel(weights, 'cheekSquintLeft', smile * .3);
      this.setChannel(weights, 'cheekSquintRight', smile * .3);
      this.setChannel(weights, 'smile', smile * .5);
    }
    if (sad) {
      this.setChannel(weights, 'mouthFrownLeft', sad * .35);
      this.setChannel(weights, 'mouthFrownRight', sad * .35);
      this.setChannel(weights, 'browInnerUp', sad * .4);
      this.setChannel(weights, 'sorrow', sad * .4);
    }
    if (surprise) {
      this.setChannel(weights, 'eyeWideLeft', surprise * .4);
      this.setChannel(weights, 'eyeWideRight', surprise * .4);
      this.setChannel(weights, 'browInnerUp', surprise * .3);
      this.setChannel(weights, 'browOuterUpLeft', surprise * .3);
      this.setChannel(weights, 'browOuterUpRight', surprise * .3);
    }
    if (anger) {
      this.setChannel(weights, 'browDownLeft', anger * .5);
      this.setChannel(weights, 'browDownRight', anger * .5);
      this.setChannel(weights, 'noseSneerLeft', anger * .2);
      this.setChannel(weights, 'noseSneerRight', anger * .2);
      this.setChannel(weights, 'angry', anger * .4);
    }

    this.appearance?.expression(weights,this.options?.selection||{},Boolean(state.speaking));
    // Write morph influences: zero everything the renderer owns, then apply.
    for (const [mesh, indices] of this.drivenMorphs) {
      for (const index of indices) mesh.morphTargetInfluences[index] = 0;
    }
    for (const [channel, value] of weights) {
      const targets = this.channels.get(channel);
      if (!targets) continue;
      for (const { mesh, index } of targets) {
        mesh.morphTargetInfluences[index] = Math.max(mesh.morphTargetInfluences[index], value);
      }
    }

    this.renderer.render(this.scene, this.camera);
    return this.canvas;
  }

  applyWorldRotation(bone, euler) {
    const base = this.baseQuaternions.get(bone);
    if (!base) return;
    const parentWorld = bone.parent
      ? bone.parent.getWorldQuaternion(new THREE.Quaternion()) : new THREE.Quaternion();
    const worldDelta = new THREE.Quaternion().setFromEuler(euler);
    const localDelta = parentWorld.clone().invert().multiply(worldDelta).multiply(parentWorld);
    bone.quaternion.copy(base).premultiply(localDelta);
  }

  pose(now, elapsed, { gx, gy, reduce, speaking, breathe, head, target, cameraFocus=false }) {
    const t = now / 1000;
    const idle = reduce ? 0 : 1;
    // The eyes acquire the cursor first; the head catches up over ~180 ms.
    // As it turns, the eyes settle back toward the middle of their sockets.
    let wantedYaw = gx * .46, wantedPitch = gy * .28;
    if(cameraFocus){
      // Measure the authored gait, never last frame's added gaze. Otherwise
      // compensating a sideways head track creates a feedback oscillation.
      for(const [bone,base] of this.baseQuaternions)bone.quaternion.copy(base);
      this.root.updateMatrixWorld(true);
      if(this.headReferencePoint&&this.bones.head)this.headCenter.copy(this.headReferencePoint).applyMatrix4(this.bones.head.matrixWorld);
    }
    if (target) {
      const direction = new THREE.Vector3(target.x, target.y, target.z).sub(this.headCenter);
      const front = cameraFocus&&this.headForward&&this.bones.head
        ? this.headForward.clone().applyQuaternion(this.bones.head.getWorldQuaternion(new THREE.Quaternion()))
        : new THREE.Vector3(0, 0, 1).applyQuaternion(this.model.getWorldQuaternion(new THREE.Quaternion()));
      const relativeYaw = Math.atan2(direction.x, direction.z) - Math.atan2(front.x, front.z);
      const gain=cameraFocus?1:.65;
      wantedYaw = clamp(Math.atan2(Math.sin(relativeYaw), Math.cos(relativeYaw)) * gain, -.55, .55);
      const frontPitch=cameraFocus?Math.atan2(-front.y,Math.hypot(front.x,front.z)):0;
      wantedPitch = clamp((Math.atan2(-direction.y, Math.hypot(direction.x, direction.z))-frontPitch) * gain, -.35, .35);
    }
    this.smooth.gazeYaw = approach(this.smooth.gazeYaw, wantedYaw, elapsed, reduce ? 1 : 180);
    this.smooth.gazePitch = approach(this.smooth.gazePitch, wantedPitch, elapsed, reduce ? 1 : 210);
    const yawTarget = this.smooth.gazeYaw + idle * (Math.sin(t * .37) * .012 + Math.sin(t * .11) * .01)
      + (Number(head.yaw) || 0);
    const pitchTarget = this.smooth.gazePitch + idle * Math.sin(t * .29 + 1.3) * .008
      + (speaking ? Math.sin(t * 2.1) * .006 : 0) + (Number(head.pitch) || 0);
    const rollTarget = idle * Math.sin(t * .19 + .7) * .006 + (Number(head.roll) || 0);
    this.smooth.headYaw = yawTarget;
    this.smooth.headPitch = pitchTarget;
    this.smooth.headRoll = approach(this.smooth.headRoll, rollTarget, elapsed, reduce ? 1 : 140);
    // Precise targets use world-space pitch: positive X looks down for a
    // figure facing +Z. Keep the legacy normalized-gaze fallback separate.
    const pitchSign = target ? 1 : -1;
    if (this.bones.neck) {
      this.applyWorldRotation(this.bones.neck, new THREE.Euler(
        pitchSign * this.smooth.headPitch * .4, this.smooth.headYaw * .4, this.smooth.headRoll * .4, 'YXZ'));
    }
    if (this.bones.head) {
      // Some exports flatten neck and head into siblings. In that case the
      // head inherits none of the neck's turn and must receive the full angle.
      let inheritsNeck = false;
      for (let parent = this.bones.head.parent; parent; parent = parent.parent) {
        if (parent === this.bones.neck) { inheritsNeck = true; break; }
      }
      const share = inheritsNeck ? .6 : 1;
      this.applyWorldRotation(this.bones.head, new THREE.Euler(
        pitchSign * this.smooth.headPitch * share, this.smooth.headYaw * share, this.smooth.headRoll * share, 'YXZ'));
    }
    if (this.bones.chest) {
      const breath = (breathe - 1) / .0025;
      this.applyWorldRotation(this.bones.chest, new THREE.Euler(
        -clamp(breath, -2, 2) * .006 * idle, idle * Math.sin(t * .23) * .006, 0, 'YXZ'));
    }
    const eyeGaze = this.bones.head
      ? { x: clamp(gx - .6 * this.smooth.gazeYaw / .46, -1, 1),
        y: clamp(gy - .6 * this.smooth.gazePitch / .28, -1, 1) }
      : { x: gx, y: gy };
    if (!this.channels.has('eyeLookOutLeft')) {
      for (const side of ['l', 'r']) {
        const eye = this.bones.eye[side];
        if (eye) this.applyWorldRotation(eye, new THREE.Euler(-eyeGaze.y * .12, eyeGaze.x * .18, 0, 'YXZ'));
      }
    }
    this.root.updateMatrixWorld(true);
    if (target) this.aimEyes(target);
    return eyeGaze;
  }

  // A card-sized face crop for the avatar carousel and settings deck.
  snapshot(size = 512, state = null) {
    // The card keyframe: a neutral, eyes-open face crop rendered straight
    // into a square buffer of the requested size. Rendering the crop itself
    // (instead of copying a corner of whatever the stage last drew) keeps the
    // result independent of the stage's current view, pixel density and
    // blink phase. The drawing buffer is not preserved between frames, so the
    // copy happens immediately after the draw.
    const layout = this.layout();
    const face = layout.faceBounds || layout.bounds;
    const side = Math.max(face[2], face[3]) * 2.2;
    const crop = Math.max(1, Math.min(side, this.width, this.height));
    const cx = face[0] + face[2] * .5, cy = face[1] + face[3] * .55;
    const x = clamp(cx - crop * .5, 0, Math.max(0, this.width - crop));
    const y = clamp(cy - crop * .5, 0, Math.max(0, this.height - crop));
    const previous = this.currentView;
    const neutral = Object.assign({
      viseme: 'sil', intensity: 0, blink: { l: 0, r: 0 }, gaze: { x: 0, y: 0 },
      brow: 0, expression: {}, breathe: 0, speaking: false, reduce: true,
    }, state || {});
    const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
    this.render(now, neutral, { x, y, w: crop, h: crop, pixelWidth: size, pixelHeight: size });
    const target = document.createElement('canvas');
    target.width = size;
    target.height = size;
    const context = target.getContext('2d');
    context.fillStyle = '#1b1d24';
    context.fillRect(0, 0, size, size);
    context.drawImage(this.canvas, 0, 0, this.canvas.width, this.canvas.height, 0, 0, size, size);
    if (previous) this.applyView(previous);
    // A GPU process that is still coming up can hand back a partly unwritten
    // buffer. The crop ends in shoulders and hair over a #1b1d24 fill, never
    // in a solid band of pure black, so such a frame is reported as missing
    // and the caller tries again later.
    const band = Math.floor(size * .4);
    const probe = context.getImageData(0, size - band, size, band).data;
    let black = 0;
    for (let i = 0; i < probe.length; i += 4) {
      if (probe[i] === 0 && probe[i + 1] === 0 && probe[i + 2] === 0) black += 1;
    }
    if (black > (probe.length / 4) * .95) return null;
    return target.toDataURL('image/png');
  }

  dispose() {
    this.disposed = true;
    this.motion?.dispose();
    this.appearance?.dispose();
    if (this.model) {
      this.model.traverse(node => {
        if (node.geometry) node.geometry.dispose();
        const materials = Array.isArray(node.material) ? node.material : [node.material];
        for (const material of materials) {
          if (!material) continue;
          for (const value of Object.values(material)) {
            if (value && value.isTexture) value.dispose();
          }
          material.dispose();
        }
      });
    }
    if(this.roomEnvironmentTarget)this.roomEnvironmentTarget.dispose();
    else if(this.scene.environment)this.scene.environment.dispose();
    this.renderer.dispose();
    this.model = null;
    this.morphMeshes = [];
    this.drivenMorphs.clear();
  }
}

const supported = () => {
  try {
    const probe = document.createElement('canvas');
    return Boolean(probe.getContext('webgl2') || probe.getContext('webgl'));
  } catch (_) {
    return false;
  }
};

window.OpenClamAvatar3D = Object.freeze({
  mountOptions: mountAvatar3DOptions,
  VISEMES: VISEMES.slice(),
  supported,
  create: options => new Avatar3D(options),
});
window.dispatchEvent(new Event('openclam-avatar3d-ready'));
