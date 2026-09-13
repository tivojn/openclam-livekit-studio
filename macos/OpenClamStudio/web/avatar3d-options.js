import * as THREE from '/vendor/three/three.module.js';

// These controls use targets already present in the model. Authored asset
// packs can add their own facial targets; they are identified separately.
export const expressionChoices = [
  {id:'neutral',label:'Neutral',weights:{}},
  {id:'smile',label:'Gentle smile',weights:{mouthSmileLeft:.55,mouthSmileRight:.55,cheekSquintLeft:.15,cheekSquintRight:.15}},
  {id:'happy',label:'Happy',weights:{mouthSmileLeft:.8,mouthSmileRight:.8,cheekSquintLeft:.3,cheekSquintRight:.3,eyeSquintLeft:.15,eyeSquintRight:.15}},
  {id:'surprised',label:'Surprised',weights:{eyeWideLeft:.55,eyeWideRight:.55,browInnerUp:.6,jawOpen:.25}},
  {id:'thoughtful',label:'Thoughtful',weights:{browInnerUp:.25,mouthPucker:.2,browDownRight:.2}},
  {id:'sad',label:'Sad',weights:{browInnerUp:.6,mouthFrownLeft:.55,mouthFrownRight:.55}},
  {id:'angry',label:'Angry',weights:{browDownLeft:.65,browDownRight:.65,noseSneerLeft:.25,noseSneerRight:.25}},
  {id:'wink-left',label:'Wink · left',weights:{eyeBlinkLeft:1,mouthSmileLeft:.4,mouthSmileRight:.4}},
  {id:'wink-right',label:'Wink · right',weights:{eyeBlinkRight:1,mouthSmileLeft:.4,mouthSmileRight:.4}},
];

export class Avatar3DAppearance {
  constructor(avatar) {
    this.avatar=avatar;this.materials=new Map();this.generation=0;this.resources=[];
    this.packs=[];this.items=[];this.textureSelections=new Map();this.faceMeshes=new Map();
    this.originalEnvironment=avatar.scene.environment;this.originalVisibility=new Map();
    avatar.model.traverse(node=>{
      this.originalVisibility.set(node,node.visible);
      for(const material of (Array.isArray(node.material)?node.material:[node.material])) {
        if(!material||this.materials.has(material))continue;
        this.materials.set(material,{roughness:material.roughness,ior:material.ior,
          envMapIntensity:material.envMapIntensity,onBeforeCompile:material.onBeforeCompile,
          customProgramCacheKey:material.customProgramCacheKey});
      }
    });
    this.isTia=[...this.materials.keys()].some(m=>m.name==='Top_Tia01A_M');
    this.defaultLighting=this.isTia?'studio':'classic';
    this.select({});
  }

  select(value) {
    this.updateAssets(value);
    const style=['studio','soft','classic'].includes(value.lighting)?value.lighting:this.defaultLighting;
    if(style===this.style)return;
    this.style=style;
    const avatar=this.avatar, enhanced=style!=='classic';
    if(avatar.studioLights)avatar.studioLights.visible=!enhanced;
    if(!this.lights) {
      this.lights=new THREE.Group();
      // Source scene directions converted from Blender Z-up to glTF Y-up.
      // Directional lights avoid distance-dependent exposure during travel.
      const add=(color,intensity,x,y,z)=>{const light=new THREE.DirectionalLight(color,intensity);light.position.set(x,y,z);this.lights.add(light);};
      add(0xfffaf5,2.15,-2.15,3.42,3.43);
      add(0xffe0e0,.7,2.41,2.92,1.91);
      add(0x91b6ff,.85,1.52,3.10,-1.66);
      add(0xfff4e8,.7,-2.22,3.22,-2.73);
      this.lights.add(new THREE.HemisphereLight(0xfff8f0,0x6d6978,.28));
      avatar.scene.add(this.lights);
    }
    this.lights.visible=enhanced;
    avatar.renderer.toneMapping=enhanced?THREE.ACESFilmicToneMapping:THREE.NeutralToneMapping;
    avatar.renderer.toneMappingExposure=enhanced?(style==='soft'?1.03:.93):1.08;
    avatar.scene.environmentIntensity=enhanced?(style==='soft'?.75:.55):.5;
    avatar.scene.environment=enhanced&&this.environmentTarget?this.environmentTarget.texture:this.originalEnvironment;
    avatar.scene.environmentRotation.y=enhanced&&this.environmentTarget?this.environmentRotation:0;
    for(const [material,base] of this.materials) {
      if(material.name==='Top_Tia01A_M') {
        material.onBeforeCompile=base.onBeforeCompile;
        material.customProgramCacheKey=base.customProgramCacheKey;
        if(enhanced) {
          // A bounded wrapped-diffuse approximation to skin scattering. No
          // extra render pass, shadow map or texture allocation on iPhone.
          material.onBeforeCompile=shader=>{
            base.onBeforeCompile.call(material,shader,avatar.renderer);
            const original=THREE.ShaderChunk.lights_physical_pars_fragment;
            const marker='reflectedLight.directDiffuse += irradiance * BRDF_Lambert( material.diffuseContribution );';
            const replacement=`${marker}
              float skinWrap = max(0.0, (dot(geometryNormal, directLight.direction) + 0.4) / 1.4);
              float skinEdge = max(0.0, skinWrap - saturate(dot(geometryNormal, directLight.direction)));
              reflectedLight.directDiffuse += 0.22 * skinEdge * directLight.color
                * vec3(1.0, 0.42, 0.28) * BRDF_Lambert(material.diffuseContribution);`;
            if(!original.includes(marker))throw Error('Skin shader does not match the installed renderer');
            shader.fragmentShader=shader.fragmentShader.replace('#include <lights_physical_pars_fragment>',original.replace(marker,replacement));
          };
          material.customProgramCacheKey=()=> 'openclam-skin-wrap-v1';
        }
      }
      if(material.name==='Hed_clr_M') {
        material.roughness=enhanced?.035:base.roughness;
        material.ior=enhanced?1.376:base.ior;
        material.envMapIntensity=enhanced?1.05:base.envMapIntensity;
      }
      material.needsUpdate=true;
    }
  }

  choices() {
    return [...expressionChoices.filter(choice=>choice.id==='neutral'||Object.keys(choice.weights).some(k=>this.avatar.channels.has(k))),
      ...this.items.filter(x=>x.kind==='expression')];
  }

  catalogue() {
    return {packs:this.packs.map(p=>({id:p.id,label:p.label,bytes:Object.values(p.files).reduce((sum,f)=>sum+f.bytes,0)})),
      assets:this.items.filter(x=>x.kind!=='expression').map(({id,label,kind,slot})=>({id,label,kind,slot}))};
  }

  async loadPacks(url) {
    this.indexURL=url;
    const response=await fetch(url,{cache:'no-store'});
    if(response.status===404)return;
    if(!response.ok)throw Error('Appearance library could not be read.');
    const value=await response.json();
    if(value.version!==1||!Array.isArray(value.packs)||value.packs.length>16)throw Error('Invalid appearance library.');
    const base=new URL(value.baseURL||'./',new URL(url,location.href));
    if(base.origin!==new URL(url,location.href).origin)throw Error('Appearance assets must come from the installed library.');
    this.avatar.options?.applyVisibility({...this.avatar.options.selection,hair:'',clothes:''});
    this.packs=value.packs;
    this.items=[];
    for(const pack of value.packs) {
      if(!/^[a-z0-9][a-z0-9.-]{0,99}$/.test(pack.directory)||!Array.isArray(pack.items)||pack.items.length>256)throw Error('Invalid appearance pack.');
      pack.base=new URL(pack.directory+'/',base);
      for(const item of pack.items) {
        if(!/^[a-z0-9][a-z0-9-]{0,47}$/.test(item.id))throw Error('Invalid appearance choice.');
        this.items.push({...item,id:pack.id+'/'+item.id,pack});
      }
    }
    const environment=this.packs.find(p=>p.environment);
    if(environment)await this.loadEnvironment(environment);
    else {this.environmentTarget?.dispose();this.environmentTarget=null;this.environmentRotation=0;}
    this.style=null;
    this.assetSelectionKey=null;
    this.select(this.avatar.options?.selection||{});
  }

  async bytes(pack,file) {
    const spec=pack.files[file];
    if(!/^[a-z0-9][a-z0-9._-]{0,79}$/.test(file)||!spec||spec.bytes>32*1024*1024)throw Error('Invalid appearance resource.');
    const response=await fetch(new URL(file,pack.base),{cache:'no-store'});
    if(!response.ok)throw Error('Appearance resource could not be loaded.');
    const bytes=await response.arrayBuffer();
    if(bytes.byteLength!==spec.bytes)throw Error('Appearance resource is incomplete.');
    return bytes;
  }

  async loadEnvironment(pack) {
    const env=pack.environment;
    if(!Number.isInteger(env.width)||!Number.isInteger(env.height)||env.width<1||env.height<1||env.width>1024||env.height>1024)throw Error('Invalid studio environment.');
    const data=await this.bytes(pack,env.file);
    if(data.byteLength!==env.width*env.height*8)throw Error('Invalid environment pixels.');
    const map=new THREE.DataTexture(new Uint16Array(data),env.width,env.height,THREE.RGBAFormat,THREE.HalfFloatType);
    map.mapping=THREE.EquirectangularReflectionMapping;map.colorSpace=THREE.LinearSRGBColorSpace;map.needsUpdate=true;
    const generator=new THREE.PMREMGenerator(this.avatar.renderer);
    try {
      const target=generator.fromEquirectangular(map);
      this.environmentTarget?.dispose();this.environmentTarget=target;
      this.environmentRotation=Number.isFinite(env.rotation)?env.rotation:0;
    } finally {map.dispose();generator.dispose();}
  }

  updateAssets(selection) {
    const relevant=Object.fromEntries(Object.entries(selection).filter(([k])=>['hair','clothes','expression'].includes(k)||k.startsWith('texture:')));
    const key=JSON.stringify(relevant);
    if(key===this.assetSelectionKey)return;
    this.assetSelectionKey=key;
    const generation=++this.generation;
    this.applyWardrobe(selection);
    const face=this.items.find(x=>x.id===selection.expression&&x.kind==='expression');
    this.faceRegion=face?.region;
    this.activeFace=[];this.faceWeight=-1;
    if(face) {
      this.status='Loading original expression…';
      this.bytes(face.pack,face.file).then(bytes=>this.decodeFace(bytes)).then(meshes=>{
        if(generation!==this.generation||this.avatar.disposed)return;
        this.activeFace=meshes;this.faceWeight=-1;this.status='';
      }).catch(error=>{if(generation===this.generation)this.status=error.message;});
    }
    const chosen=this.items.filter(x=>x.kind==='texture'&&selection['texture:'+(x.slot||'color')]===x.id);
    void this.loadTextures(chosen,generation);
  }

  applyWardrobe(selection) {
    const nodes=this.avatar.options?.nodes;if(!nodes)return;
    // Restore baseline hair before applying a pack's optional visibility recipe.
    for(const item of this.items.filter(x=>x.kind==='hair'))for(const name of [...(item.nodes||[]),...(item.hideNodes||[])])
      for(const node of nodes.get(name)||[])node.visible=this.originalVisibility.get(node)??true;
    for(const kind of ['clothes','hair']) {
      const item=this.items.find(x=>x.kind===kind&&x.id===selection[kind]);if(!item)continue;
      for(const [names,visible] of [[item.hideNodes||[],false],[item.nodes||[],true]])
        for(const name of names)for(const node of nodes.get(name)||[])node.visible=visible;
    }
  }

  async loadTextures(items,generation) {
    const pending=[];
    try {
      for(const item of items) {
        const prior=this.textureSelections.get(item.id);
        if(prior){pending.push(prior);continue;}
        const bytes=await this.bytes(item.pack,item.file);
        const bitmap=await createImageBitmap(new Blob([bytes]),{imageOrientation:'none',premultiplyAlpha:'none',colorSpaceConversion:'none'});
        if(bitmap.width>2048||bitmap.height>2048){bitmap.close();throw Error('Texture exceeds the 2048 pixel pack limit.');}
        const texture=new THREE.Texture(bitmap);texture.flipY=false;texture.colorSpace=THREE.SRGBColorSpace;texture.needsUpdate=true;
        pending.push({id:item.id,item,texture,bitmap});
      }
      if(generation!==this.generation||this.avatar.disposed)throw Error('cancelled');
      if(!this.baseMaps)this.baseMaps=new Map();
      for(const [material,map] of this.baseMaps){material.map=map;material.needsUpdate=true;}
      for(const resource of pending) {
        const item=resource.item;
        this.avatar.model.traverse(node=>{
          if(item.nodes?.length&&!item.nodes.includes(node.userData.sourceName||node.name))return;
          for(const material of (Array.isArray(node.material)?node.material:[node.material])) {
            if(material?.name!==item.material)continue;
            if(!this.baseMaps.has(material))this.baseMaps.set(material,material.map);
            material.map=resource.texture;material.needsUpdate=true;
          }
        });
      }
      const next=new Map(pending.map(r=>[r.id,r]));
      for(const [id,r] of this.textureSelections)if(!next.has(id)){r.texture.dispose();r.bitmap.close();}
      this.textureSelections=next;
    } catch(error) {
      for(const r of pending)if(!this.textureSelections.has(r.id)){r.texture.dispose();r.bitmap.close();}
      if(error.message!=='cancelled'&&generation===this.generation)this.status=error.message;
    }
  }

  decodeFace(bytes) {
    const data=JSON.parse(new TextDecoder().decode(bytes));
    if(data.version!==1||!Array.isArray(data.meshes)||data.meshes.length>32)throw Error('Invalid expression data.');
    const decode=(s,Type)=>{
      if(typeof s!=='string'||s.length>16*1024*1024)throw Error('Invalid facial data.');
      const raw=atob(s),a=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)a[i]=raw.charCodeAt(i);
      return new Type(a.buffer);
    };
    const result=[];
    for(const entry of data.meshes) {
      let mesh;
      this.avatar.model.traverse(n=>{if(n.isMesh&&n.userData.sourceName===entry.node&&(n.userData.sourcePrimitive||0)===entry.primitive)mesh=n;});
      if(!mesh||mesh.geometry.attributes.position.count!==entry.count)throw Error('Expression does not match this model.');
      const indices=decode(entry.indices,Uint32Array),deltas=decode(entry.deltas,Float32Array);
      if(deltas.length!==indices.length*3||indices.length>entry.count||indices.some((v,i)=>v>=entry.count||(i>0&&v<=indices[i-1]))||deltas.some(v=>!Number.isFinite(v)||Math.abs(v)>.25))throw Error('Invalid facial deformation.');
      result.push({mesh,indices,deltas});
    }
    for(const {mesh} of result)if(!this.faceMeshes.has(mesh)) {
      const position=mesh.geometry.attributes.position;
      this.faceMeshes.set(mesh,new Float32Array(position.array));
    }
    return result;
  }

  applyFace(selection,speaking,blink=0) {
    const strength=Math.max(0,Math.min(1,Number(selection.expressionStrength??.7)));
    const weight=this.activeFace?.length?strength*(speaking&&this.faceRegion==='mouth'?.2:1)*(this.faceRegion==='eyes'?1-Math.max(0,Math.min(1,blink)):1):0;
    if(weight===this.faceWeight)return;
    this.faceWeight=weight;
    for(const [mesh,basis] of this.faceMeshes)mesh.geometry.attributes.position.array.set(basis);
    for(const {mesh,indices,deltas} of this.activeFace||[]) {
      const a=mesh.geometry.attributes.position.array;
      for(let i=0;i<indices.length;i++)for(let axis=0;axis<3;axis++)a[indices[i]*3+axis]+=deltas[i*3+axis]*weight;
    }
    for(const mesh of this.faceMeshes.keys())mesh.geometry.attributes.position.needsUpdate=true;
  }

  expression(weights,selection,speaking) {
    this.applyFace(selection,speaking,Math.max(weights.get('eyeBlinkLeft')||0,weights.get('eyeBlinkRight')||0,weights.get('blink')||0));
    const preset=expressionChoices.find(x=>x.id===selection.expression);
    if(!preset&&!this.activeFace?.length)return;
    const strength=Math.max(0,Math.min(1,Number(selection.expressionStrength??.7)));
    // Manual expressions own mood channels. Blinks and gaze retain their
    // independent channels; speech attenuates manual mouth deformation.
    for(const key of ['mouthSmileLeft','mouthSmileRight','mouthFrownLeft','mouthFrownRight','cheekSquintLeft','cheekSquintRight','browInnerUp','browOuterUpLeft','browOuterUpRight','browDownLeft','browDownRight','noseSneerLeft','noseSneerRight','smile','sorrow','angry','eyeWideLeft','eyeWideRight'])weights.delete(key);
    for(const [key,amount] of Object.entries(preset?.weights||{})) {
      const value=amount*strength*(speaking&&/^(mouth|jaw)/.test(key)?.25:1);
      weights.set(key,Math.max(weights.get(key)||0,value));
    }
  }

  dispose() {
    ++this.generation;
    for(const resource of this.resources)resource.dispose?.();
    this.resources=[];
    for(const r of this.textureSelections.values()){r.texture.dispose();r.bitmap.close();}
    this.textureSelections.clear();this.activeFace=[];this.faceMeshes.clear();
    for(const [material,map] of this.baseMaps||[])material.map=map;
    this.baseMaps?.clear();this.originalVisibility.clear();
    if(this.environmentTarget)this.environmentTarget.dispose();
  }
}

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
  defaultWalkingClip() { return this.avatar.motion?.clips.has('walking-woman')?'walking-woman':'walk'; }
  walkingClip() { return this.avatar.motion?.clips.has(this.selection.walkStyle)?this.selection.walkStyle:this.defaultWalkingClip(); }
  isTravelClip(id) { return ['walking-woman','walk','casual-walk','stage-walk','hello-run'].includes(id); }

  catalogue() {
    const choices = list => list.map(({id,label,group,pose})=>({id,label:String(label||id).slice(0,80),...(group?{group}:{}),...(pose?{pose}:{})}));
    return {poses:choices([...this.poses.values()]),outfits:choices(this.outfits),props:choices(this.props),
      walkingStyles:[{id:'walking-woman',label:'Walking Woman'},{id:'walk',label:'Natural walk'},{id:'casual-walk',label:'Casual stroll'},{id:'stage-walk',label:'Runway walk'}].filter(x=>this.avatar.motion?.clips.has(x.id)),
      expressions:choices(this.avatar.appearance?.choices()||[]),
      lighting:[{id:'studio',label:'Studio portrait'},{id:'soft',label:'Soft studio'},{id:'classic',label:'Classic'}],
      ...(this.avatar.appearance?.catalogue()||{})};
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
    this.avatar.appearance?.applyWardrobe(selection);
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
    if(['walking-woman','walk','casual-walk','stage-walk'].includes(value.walkStyle)&&this.avatar.motion?.clips.has(value.walkStyle))next.walkStyle=value.walkStyle;
    if(['balanced','eco','quality'].includes(value.performance))next.performance=value.performance;
    if(['studio','soft','classic'].includes(value.lighting))next.lighting=value.lighting;
    if(this.avatar.appearance?.choices().some(x=>x.id===value.expression))next.expression=value.expression;
    if(value.expressionStrength!==undefined&&Number.isFinite(Number(value.expressionStrength)))
      next.expressionStrength=String(Math.max(0,Math.min(1,Number(value.expressionStrength))));
    for(const item of this.avatar.appearance?.items||[]) {
      const key=item.kind==='texture'?'texture:'+(item.slot||'color'):item.kind;
      if(value[key]===item.id)next[key]=item.id;
    }
    if (JSON.stringify(next) === JSON.stringify(this.selection)) return this.selection;
    const previous = this.selection;
    this.selection = next;
    this.avatar.appearance?.select(next);
    if (this.avatar.motion?.active && ['body','hands','leftHand','rightHand'].every(key=>previous[key]===next[key])) {
      this.applyVisibility(next);
      return this.selection;
    }
    // Changing gaze alone must not restart a pose or the playback interval.
    const withoutGaze = value => JSON.stringify(Object.fromEntries(Object.entries(value).filter(([key])=>
      !['performance','followCursor','lighting','expression','expressionStrength','hair','clothes','walkStyle'].includes(key)&&!key.startsWith('texture:'))));
    if (withoutGaze(previous) !== withoutGaze(next)) {
      this.nextPlaybackAt = now + 4000;
      this.applyPose(next, now);
    } else this.applyVisibility(next);
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
    // Framing already uses the standing bounds. Re-skinning every vertex and
    // evaluating every morph to measure a pose stalls the render thread (Tia
    // has 760k vertices). Bone animation does not need that unused measurement.
    const targetBounds = this.restBounds?.clone() || null;
    this.transition={from:this.current.map(copy),target,start:now,
      fromBounds:this.avatar.bounds?.clone(),targetBounds};
    this.write(this.current);
  }

  update(now, reduce=false) {
    if (this.avatar.motion?.update(now, reduce)) return;
    if (reduce || !this.enabled('playTransitions') || this.avatar.motion?.pending) {
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
      if (!this.avatar.restBounds) this.avatar.frame();
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
  summary.textContent = 'Appearance, wardrobe & poses'; details.append(summary);
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
  let strengthInput;
  const groups = [
    ['walkStyle','Walking style',catalogue.walkingStyles,(catalogue.walkingStyles.find(x=>x.id===library.defaultWalkingClip())?.label||'Walk')+' (default)'],
    ['performance','Resource use',[{id:'eco',label:'Eco · lowest resource use'},{id:'quality',label:'Quality · original textures'}],'Balanced (default)'],
    ['lighting','Lighting',catalogue.lighting,'Avatar default'],
    ['expression','Expression',catalogue.expressions,'Automatic · conversation'],
    ['hair','Hair',catalogue.assets?.filter(x=>x.kind==='hair'),'Original hair'],
    ['clothes','Clothing combination',catalogue.assets?.filter(x=>x.kind==='clothes'),'From outfit'],
    ['outfit','Outfit',catalogue.outfits,'Original appearance'],
    ['body','Body pose',catalogue.poses.filter(p=>p.group==='body'),'Relaxed standing'],
    ['hands','Both hands',catalogue.poses.filter(p=>p.group==='hands'),'From body pose'],
    ['leftHand','Left hand',catalogue.poses.filter(p=>p.group==='leftHand'),'From body pose'],
    ['rightHand','Right hand',catalogue.poses.filter(p=>p.group==='rightHand'),'From body pose'],
    ['prop','Prop',catalogue.props,'None'],
  ];
  for(const slot of new Set((catalogue.assets||[]).filter(x=>x.kind==='texture').map(x=>x.slot||'color')))
    groups.push(['texture:'+slot,slot+' color',catalogue.assets.filter(x=>x.kind==='texture'&&(x.slot||'color')===slot),'Original texture']);
  const refresh = () => {
    for(const [group, select] of selects) select.value=library.selection[group]||'';
    for(const [key, input] of toggles) input.checked=library.enabled(key);
    if(strengthInput)strengthInput.value=library.selection.expressionStrength??'.7';
  };
  const apply = (value, persist=false) => {
    library.select(value);
    if(persist)localStorage.setItem(key,JSON.stringify(library.selection));
    refresh();
  };
  for(const [group,label,choices,fallback] of groups) {
    if(!choices?.length)continue;
    const row=document.createElement('label'), text=document.createElement('span'), select=document.createElement('select');
    text.textContent=label; select.setAttribute('aria-label',label);selects.set(group,select);
    for(const item of [{id:'',label:fallback},...choices]){const option=document.createElement('option');option.value=item.id;option.textContent=item.label;select.append(option);}
    select.addEventListener('change',()=>{
      const next={...library.selection,[group]:select.value};
      if(group==='outfit')delete next.clothes;
      if(['body','hands','leftHand','rightHand'].includes(group))next.playTransitions='false';
      if(group==='body'){delete next.hands;delete next.leftHand;delete next.rightHand;}
      if(group==='prop'&&select.value){next.body=choices.find(p=>p.id===select.value).pose;delete next.hands;delete next.leftHand;delete next.rightHand;}
      apply(next,true);if(group==='body'||group==='prop')onBodyPose();
    });
    row.append(text,select);details.append(row);
  }
  if(catalogue.expressions?.length) {
    const row=document.createElement('label'),text=document.createElement('span'),input=document.createElement('input');
    strengthInput=input;
    text.textContent='Expression intensity';input.type='range';input.min='0';input.max='1';input.step='.05';
    input.setAttribute('aria-label','Expression intensity');input.value=library.selection.expressionStrength??'.7';
    input.addEventListener('input',()=>apply({...library.selection,expressionStrength:input.value},true));
    row.append(text,input);details.append(row);
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
  let transfer=null;
  if(library.avatar.appearance?.indexURL==='/api/avatar/appearance') {
    const assets=document.createElement('details'),title=document.createElement('summary');
    title.textContent='Import or download appearance assets';assets.append(title);
    const help=document.createElement('p');help.textContent='Add clothes, hair, colors and original expressions with an appearance pack. Only selected assets are loaded.';assets.append(help);
    const file=document.createElement('input');file.type='file';file.accept='.oclook,.zip';file.hidden=true;
    const pick=document.createElement('button');pick.type='button';pick.textContent='Import from Files…';pick.addEventListener('click',()=>file.click());
    const url=document.createElement('input');url.type='url';url.placeholder='Direct HTTPS download link';url.setAttribute('aria-label','Appearance pack download link');
    const download=document.createElement('button');download.type='button';download.textContent='Download appearance pack';
    const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Cancel download';cancel.hidden=true;
    const status=document.createElement('p');status.setAttribute('role','status');
    const progress=document.createElement('progress');progress.max=1;progress.hidden=true;
    const busy=value=>{pick.disabled=value;download.disabled=value;url.disabled=value;progress.hidden=!value;};
    const refreshAssets=async()=>{
      await library.avatar.appearance.loadPacks('/api/avatar/appearance');
      library.select(library.selection);localStorage.setItem(key,JSON.stringify(library.selection));
      localStorage.setItem(key+'.assets-revision',String(Date.now()));
      window.dispatchEvent(new Event('openclam-appearance-changed'));
    };
    file.addEventListener('change',async()=>{
      if(!file.files[0])return;busy(true);status.textContent='Importing and verifying…';
      const data=new FormData();data.append('archive',file.files[0]);
      try {
        const response=await fetch('/api/avatar/appearance/import',{method:'POST',body:data});const result=await response.json();
        if(!response.ok)throw Error(result.detail||'Import failed.');
        status.textContent='Installed '+result.installed;await refreshAssets();
      } catch(error){status.textContent=error.message;}finally{busy(false);file.value='';}
    });
    download.addEventListener('click',async()=>{
      let target;try{target=new URL(url.value.trim());}catch{status.textContent='Enter a direct HTTPS link.';return;}
      if(target.protocol!=='https:'||target.username||target.password||target.hash){status.textContent='Enter a direct HTTPS link.';return;}
      busy(true);cancel.hidden=false;progress.removeAttribute('value');status.textContent='Downloading…';
      const controller=new AbortController();transfer=controller;
      try {
        const response=await fetch('/api/avatar/appearance/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url:target.href}),signal:controller.signal});
        if(!response.ok)throw Error('The download could not start.');
        const reader=response.body.getReader(),decoder=new TextDecoder();let pending='',installed=false;
        for(;;){const {done,value}=await reader.read();if(done)break;pending+=decoder.decode(value,{stream:true});
          let end;while((end=pending.indexOf('\n'))>=0){const result=JSON.parse(pending.slice(0,end));pending=pending.slice(end+1);
            if(result.error)throw Error(result.error);
            if(result.received){status.textContent='Downloaded '+(result.received/1e6).toFixed(1)+' MB';if(result.total)progress.value=Math.min(.99,result.received/result.total);}
            if(result.status){status.textContent=result.status;cancel.hidden=true;}
            if(result.installed){installed=true;status.textContent='Installed '+result.installed;}
          }
        }
        if(!installed)throw Error('The download ended before installation. Try again.');
        await refreshAssets();
      }catch(error){status.textContent=error.name==='AbortError'?'Download cancelled.':error.message;}
      finally{transfer=null;cancel.hidden=true;busy(false);}
    });
    cancel.addEventListener('click',()=>transfer?.abort());
    assets.append(file,pick,url,download,cancel,progress,status);
    for(const pack of catalogue.packs||[]) {
      const row=document.createElement('div'),label=document.createElement('span'),remove=document.createElement('button');
      label.textContent=pack.label+' · '+(pack.bytes/1e6).toFixed(1)+' MB';remove.type='button';remove.textContent='Remove pack';
      remove.addEventListener('click',async()=>{try{const response=await fetch('/api/avatar/appearance/'+encodeURIComponent(pack.id),{method:'DELETE'});if(!response.ok)throw Error('Could not remove pack.');await refreshAssets();}catch(error){status.textContent=error.message;}});
      row.append(label,remove);assets.append(row);
    }
    details.append(assets);
  }
  container.append(details);
  const restore=()=>{try{apply(JSON.parse(localStorage.getItem(key)||'{}'));}catch{apply({});}};
  const storage=event=>{
    if(event.key===key)restore();
    else if(event.key===key+'.assets-revision'&&library.avatar.appearance?.indexURL) {
      library.avatar.appearance.loadPacks(library.avatar.appearance.indexURL).then(()=>{
        if(library.avatar.disposed)return;restore();window.dispatchEvent(new Event('openclam-appearance-changed'));
      }).catch(error=>{library.avatar.appearance.status=error.message;});
    }
  };
  restore();window.addEventListener('storage',storage);
  window.addEventListener('openclam-avatar-controls-refresh',refresh);
  return ()=>{transfer?.abort();window.removeEventListener('storage',storage);window.removeEventListener('openclam-avatar-controls-refresh',refresh);};
}
