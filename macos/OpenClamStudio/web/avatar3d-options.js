import * as THREE from '/vendor/three/three.module.js';

const identity = () => new THREE.Matrix4();
const matrix = rows => new THREE.Matrix4().set(...rows.flat());
const validMatrix = rows => Array.isArray(rows) && rows.length === 4
  && rows.every(row => Array.isArray(row) && row.length === 4 && row.every(Number.isFinite));
const nameOf = node => node.userData.sourceName || node.name;
const parts = m => {
  const p = new THREE.Vector3(), q = new THREE.Quaternion(), s = new THREE.Vector3();
  m.decompose(p, q, s);
  const residual = new THREE.Matrix4().compose(p, q, s).invert().multiply(m);
  return {m:m.clone(), p, q, s, residual};
};
const copy = value => parts(value.m);

/// Optional, data-driven wardrobe and authored static poses embedded in glTF
/// extras. The loader never changes geometry, materials or inverse bind data.
export class Avatar3DOptions {
  constructor(avatar, data) {
    this.avatar = avatar;
    this.data = data;
    this.cache = new Map();
    this.selection = {};
    this.transition = null;
    this.nextPlaybackAt = null;
    this.playbackIndex = -1;
    this.nodes = new Map();
    this.bones = [];
    if (data?.version !== 1 || !data.rest || !Array.isArray(data.poses)) throw Error('Unsupported 3D options library');
    if (data.poses.length > 256 || Object.keys(data.rest).length > 512) throw Error('3D options library is too large');
    avatar.model.updateMatrixWorld(true);
    const inverse = avatar.model.matrixWorld.clone().invert();
    avatar.model.traverse(node => {
      const name = nameOf(node);
      if (!this.nodes.has(name)) this.nodes.set(name, []);
      this.nodes.get(name).push(node);
      if (node.isBone && Object.hasOwn(data.rest, name)) {
        this.bones.push({node,name,world:inverse.clone().multiply(node.matrixWorld),rest:parts(node.matrix)});
      }
    });
    if (this.bones.length !== Object.keys(data.rest).length
      || new Set(this.bones.map(b=>b.name)).size !== this.bones.length) throw Error('3D pose library does not match the rig');
    this.poses = new Map(data.poses.map(pose => {
      if (!pose.id || !['body','hands','leftHand','rightHand'].includes(pose.group)
        || !pose.deltas || !Object.values(pose.deltas).every(validMatrix)) throw Error('Invalid authored pose');
      return [pose.id, pose];
    }));
    // An authored playlist can opt into other poses. Without one, cycle
    // upright social poses; seated poses and weapon grips remain explicit.
    this.playback = [...this.poses.values()].filter(pose => pose.group === 'body'
      && (Array.isArray(data.playback) ? data.playback.includes(pose.id)
        : /standing|heart/i.test(pose.label || pose.id)));
    this.outfits = data.outfits || [];
    this.props = data.props || [];
    this.applyVisibility({});
  }

  enabled(key) { return this.selection[key] !== 'false'; }

  catalogue() {
    const choices = list => list.map(({id,label,group,pose})=>({id,label:String(label||id).slice(0,80),...(group?{group}:{}),...(pose?{pose}:{})}));
    return {poses:choices([...this.poses.values()]),outfits:choices(this.outfits),props:choices(this.props)};
  }

  captureIdle() {
    this.avatar.model.updateMatrixWorld(true);
    this.idle = this.bones.map(({node})=>parts(node.matrix));
    this.current = this.idle.map(copy);
  }

  applyVisibility(selection) {
    const apply = (choices, id) => {
      for (const name of new Set(choices.flatMap(choice=>choice.nodes||[]))) {
        for (const node of this.nodes.get(name)||[]) node.visible = false;
      }
      for (const name of choices.find(choice=>choice.id===id)?.nodes||[]) {
        for (const node of this.nodes.get(name)||[]) node.visible = true;
      }
    };
    apply(this.outfits, selection.outfit || this.data.defaultOutfit);
    apply(this.props, selection.prop || '');
  }

  write(transforms) {
    this.bones.forEach(({node}, i) => {
      const transform = transforms[i];
      node.position.copy(transform.p); node.quaternion.copy(transform.q); node.scale.copy(transform.s);
      // Keep the affine transforms authored by Blender's stretch constraints.
      // Procedural head/eye channels use their own quaternion overlay below.
      node.matrixAutoUpdate = this.avatar.baseQuaternions.has(node);
      if (node.matrixAutoUpdate) {
        node.updateMatrix();
        this.avatar.baseQuaternions.set(node, node.quaternion.clone());
      } else node.matrix.copy(transform.m);
      node.matrixWorldNeedsUpdate = true;
    });
    this.avatar.root.updateMatrixWorld(true);
  }

  targetFor(pose) {
    if (this.cache.has(pose.id)) return this.cache.get(pose.id);
    this.write(this.bones.map(b=>b.rest));
    const world = this.avatar.model.matrixWorld;
    const targets = this.bones.map(b=>world.clone()
      .multiply(pose.deltas[b.name]?matrix(pose.deltas[b.name]):identity()).multiply(b.world));
    const result = [];
    this.bones.forEach(({node}, i) => {
      node.parent.updateWorldMatrix(true,false);
      const local = node.parent.matrixWorld.clone().invert().multiply(targets[i]);
      const transform = parts(local);
      node.position.copy(transform.p);node.quaternion.copy(transform.q);node.scale.copy(transform.s);
      node.matrix.copy(local);node.matrixAutoUpdate=false;node.matrixWorldNeedsUpdate=true;node.updateWorldMatrix(false,false);
      result.push(transform);
    });
    this.cache.set(pose.id,result);
    return result;
  }

  select(value={}, now=performance.now()) {
    const next = {};
    for (const group of ['body','hands','leftHand','rightHand']) {
      const pose = this.poses.get(value[group]);
      if (pose?.group === group) next[group]=pose.id;
    }
    for (const [key,choices] of [['outfit',this.outfits],['prop',this.props]]) {
      if (choices.some(choice=>choice.id===value[key])) next[key]=value[key];
    }
    for (const key of ['playTransitions','followCursor']) {
      if (value[key] === false || value[key] === 'false') next[key] = 'false';
    }
    if (JSON.stringify(next) === JSON.stringify(this.selection)) return this.selection;
    const previous = this.selection;
    this.selection = next;
    if (this.avatar.motion?.active && ['body','hands','leftHand','rightHand'].every(key=>previous[key]===next[key])) {
      this.applyVisibility(next);
      return this.selection;
    }
    // Changing gaze alone must not restart a pose or the playback interval.
    const withoutGaze = value => JSON.stringify({...value,followCursor:undefined});
    if (withoutGaze(previous) !== withoutGaze(next)) {
      this.nextPlaybackAt = now + 4000;
      this.applyPose(next, now);
    }
    return this.selection;
  }

  applyPose(next, now) {
    this.avatar.motion?.stop({immediate:true});
    this.applyVisibility(next);
    let target=this.idle.map(copy);
    if(next.body) target=this.targetFor(this.poses.get(next.body)).map(copy);
    for(const group of ['hands','leftHand','rightHand']) {
      if(!next[group])continue;
      const pose=this.poses.get(next[group]), layer=this.targetFor(pose);
      this.bones.forEach((bone,i)=>{if(Object.hasOwn(pose.deltas,bone.name))target[i]=copy(layer[i]);});
    }
    let targetBounds = null;
    if (this.restBounds && this.avatar.modelBounds) {
      this.write(target);
      targetBounds = this.restBounds.clone().union(this.avatar.modelBounds());
    }
    this.transition={from:this.current.map(copy),target,start:now,
      fromBounds:this.avatar.bounds?.clone(),targetBounds};
    this.write(this.current);
  }

  update(now, reduce=false) {
    if (this.avatar.motion?.update(now, reduce)) return;
    if (reduce || !this.enabled('playTransitions')) {
      this.nextPlaybackAt = now + 4000;
    } else if (this.nextPlaybackAt === null) {
      this.nextPlaybackAt = now + 4000;
    } else if (now >= this.nextPlaybackAt && this.playback.length) {
      this.playbackIndex = (this.playbackIndex + 1) % this.playback.length;
      this.applyPose({...this.selection, body:this.playback[this.playbackIndex].id,
        hands:undefined,leftHand:undefined,rightHand:undefined}, now);
      this.nextPlaybackAt = now + 4000;
    }
    if (!this.transition) return;
    const {from,target,start,fromBounds,targetBounds}=this.transition;
    const t=reduce?1:Math.max(0,Math.min(1,(now-start)/650));
    const u=t*t*(3-2*t);
    this.current=t===1?target:target.map((v,i)=>{
      const p=from[i].p.clone().lerp(v.p,u), q=from[i].q.clone().slerp(v.q,u), s=from[i].s.clone().lerp(v.s,u);
      const shear=identity();shear.elements=shear.elements.map((_,j)=>from[i].residual.elements[j]*(1-u)+v.residual.elements[j]*u);
      return parts(new THREE.Matrix4().compose(p,q,s).multiply(shear));
    });
    this.write(this.current);
    if (targetBounds && fromBounds) {
      this.avatar.bounds.min.copy(fromBounds.min).lerp(targetBounds.min,u);
      this.avatar.bounds.max.copy(fromBounds.max).lerp(targetBounds.max,u);
      this.avatar.frame();
    }
    if(t===1)this.transition=null;
    const head = this.avatar.bones.head;
    if (head && this.avatar.headReferencePoint) {
      this.avatar.headCenter.copy(this.avatar.headReferencePoint).applyMatrix4(head.matrixWorld);
    }
    this.avatar.layoutCache=null;
  }
}

// Native mobile menus use catalogue()/select(); desktop uses the same data
// with accessible HTML controls and per-avatar preferences shared by windows.
export function mountAvatar3DOptions(container, library, key, onBodyPose = () => {}, onImport = null) {
  container.replaceChildren();
  const details = document.createElement('details'), summary = document.createElement('summary');
  summary.textContent = 'Wardrobe & poses'; details.append(summary);
  if (!library) {
    const message = document.createElement('p');
    message.textContent = 'This avatar package has no wardrobe or poses. Import an updated avatar package to add them.';
    details.append(message);
    if (onImport) {
      const button = document.createElement('button');button.type = 'button';button.textContent = 'Import avatar package…';
      button.addEventListener('click', onImport);details.append(button);
    }
    container.append(details);
    return () => {};
  }
  const catalogue = library.catalogue(), selects = new Map(), toggles = new Map();
  const groups = [
    ['outfit','Outfit',catalogue.outfits,'Original appearance'],
    ['body','Body pose',catalogue.poses.filter(p=>p.group==='body'),'Relaxed standing'],
    ['hands','Both hands',catalogue.poses.filter(p=>p.group==='hands'),'From body pose'],
    ['leftHand','Left hand',catalogue.poses.filter(p=>p.group==='leftHand'),'From body pose'],
    ['rightHand','Right hand',catalogue.poses.filter(p=>p.group==='rightHand'),'From body pose'],
    ['prop','Prop',catalogue.props,'None'],
  ];
  const refresh = () => {
    for(const [group, select] of selects) select.value=library.selection[group]||'';
    for(const [key, input] of toggles) input.checked=library.enabled(key);
  };
  const apply = (value, persist=false) => {
    library.select(value);
    if(persist)localStorage.setItem(key,JSON.stringify(library.selection));
    refresh();
  };
  for(const [group,label,choices,fallback] of groups) {
    if(!choices.length)continue;
    const row=document.createElement('label'), text=document.createElement('span'), select=document.createElement('select');
    text.textContent=label; select.setAttribute('aria-label',label);selects.set(group,select);
    for(const item of [{id:'',label:fallback},...choices]){const option=document.createElement('option');option.value=item.id;option.textContent=item.label;select.append(option);}
    select.addEventListener('change',()=>{
      const next={...library.selection,[group]:select.value};
      if(['body','hands','leftHand','rightHand'].includes(group))next.playTransitions='false';
      if(group==='body'){delete next.hands;delete next.leftHand;delete next.rightHand;}
      if(group==='prop'&&select.value){next.body=choices.find(p=>p.id===select.value).pose;delete next.hands;delete next.leftHand;delete next.rightHand;}
      apply(next,true);if(group==='body'||group==='prop')onBodyPose();
    });
    row.append(text,select);details.append(row);
  }
  for(const [key,label] of [['playTransitions','Play transitions'],['followCursor','Follow cursor']]) {
    const row=document.createElement('label'), text=document.createElement('span'), input=document.createElement('input');
    text.textContent=label;input.type='checkbox';input.setAttribute('aria-label',label);toggles.set(key,input);
    input.addEventListener('change',()=>{
      const next={...library.selection,[key]:String(input.checked)};
      if(key==='playTransitions'&&input.checked)onBodyPose();
      apply(next,true);
    });
    row.append(text,input);details.append(row);
  }
  const reset=document.createElement('button');reset.type='button';reset.textContent='Reset appearance & pose';
  reset.addEventListener('click',()=>apply({playTransitions:'false',followCursor:library.selection.followCursor},true));details.append(reset);
  container.append(details);
  const restore=()=>{try{apply(JSON.parse(localStorage.getItem(key)||'{}'));}catch{apply({});}};
  const storage=event=>{if(event.key===key)restore();};
  restore();window.addEventListener('storage',storage);
  window.addEventListener('openclam-avatar-controls-refresh',refresh);
  return ()=>{window.removeEventListener('storage',storage);window.removeEventListener('openclam-avatar-controls-refresh',refresh);};
}
