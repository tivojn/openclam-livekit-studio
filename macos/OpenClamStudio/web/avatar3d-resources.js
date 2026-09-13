import * as THREE from '/vendor/three/three.module.js';
import { KTX2Loader } from '/vendor/three/KTX2Loader.js';

// Derived textures/optional meshes are replaceable; rig transforms, materials,
// alpha modes, UVs and the authored source asset remain unchanged.
export class AvatarResources {
  constructor(renderer) {
    this.renderer=renderer;this.records=new Map();this.meshes=new Map();
    this.ready=true;this.disposed=false;this.generation=0;this.error='';
    this.ktx=new KTX2Loader().setTranscoderPath('/vendor/three/').setWorkerLimit(1).detectSupport(renderer);
  }
  plugin(parser) {
    if(parser.json.extras?.openclamResources?.version!==1)return {name:'OPENCLAM_RESOURCES'};
    this.parser=parser;
    const original=parser.loadGeometries.bind(parser);
    this.loadGeometry=original;
    const deferred=new WeakMap();
    parser.json.meshes.forEach((mesh,index)=>{
      if(mesh.extras?.openclamDeferred)deferred.set(mesh.primitives,index);
    });
    parser.loadGeometries=primitives=>{
      if(!deferred.has(primitives))return original(primitives);
      const index=deferred.get(primitives);
      return Promise.resolve(primitives.map((p,i)=>{
        const geometry=this.emptyGeometry();
        geometry.userData.deferredMesh=index;geometry.userData.deferredPrimitive=i;
        return geometry;
      }));
    };
    return {name:'OPENCLAM_RESOURCES',loadTexture:index=>{
      const def=parser.json.textures[index];
      const image=parser.json.images[def.source];
      if(!image?.extras?.openclamVariants)return null;
      const texture=new THREE.Texture();
      texture.flipY=false;texture.name=image.name||'';
      texture.userData.residentTexture=index;
      const sampler=parser.json.samplers?.[def.sampler]||{};
      const filters={9728:THREE.NearestFilter,9729:THREE.LinearFilter,9984:THREE.NearestMipmapNearestFilter,
        9985:THREE.LinearMipmapNearestFilter,9986:THREE.NearestMipmapLinearFilter,9987:THREE.LinearMipmapLinearFilter};
      const wraps={33071:THREE.ClampToEdgeWrapping,33648:THREE.MirroredRepeatWrapping,10497:THREE.RepeatWrapping};
      texture.magFilter=filters[sampler.magFilter]||THREE.LinearFilter;
      texture.minFilter=filters[sampler.minFilter]||THREE.LinearMipmapLinearFilter;
      texture.wrapS=wraps[sampler.wrapS]||THREE.RepeatWrapping;
      texture.wrapT=wraps[sampler.wrapT]||THREE.RepeatWrapping;
      this.records.set(index,{index,variants:image.extras.openclamVariants,targets:new Set([texture]),loaded:null});
      return Promise.resolve(texture);
    }};
  }
  emptyGeometry(){
    const g=new THREE.BufferGeometry();
    g.setAttribute('position',new THREE.Float32BufferAttribute([],3));
    g.setAttribute('skinIndex',new THREE.Uint16BufferAttribute([],4));
    g.setAttribute('skinWeight',new THREE.Float32BufferAttribute([],4));
    return g;
  }
  bind(model) {
    this.model=model;
    model.traverse(node=>{
      const mi=node.geometry?.userData?.deferredMesh;
      if(mi!==undefined){
        if(!this.meshes.has(mi))this.meshes.set(mi,{index:mi,nodes:[],loaded:false});
        this.meshes.get(mi).nodes.push(node);
      }
      for(const material of Array.isArray(node.material)?node.material:[node.material]){
        for(const texture of Object.values(material||{})){
          const record=this.records.get(texture?.userData?.residentTexture);
          if(record)record.targets.add(texture);
        }
      }
    });
  }
  level(profile,pixels){
    if(profile==='quality')return Infinity;
    if(profile==='eco')return pixels>800?1024:512;
    return pixels>1000?4096:pixels>360?2048:1024;
  }
  requirements(profile,pixels){
    const textures=new Set(),meshes=new Set();
    this.model.traverseVisible(node=>{
      const mi=node.userData.residentMesh??node.geometry?.userData?.deferredMesh;
      if(mi!==undefined){node.userData.residentMesh=mi;meshes.add(mi);}
      for(const material of Array.isArray(node.material)?node.material:[node.material]){
        for(const texture of Object.values(material||{})){
          const record=this.records.get(texture?.userData?.residentTexture);
          if(record){record.targets.add(texture);textures.add(record.index);}
        }
      }
    });
    const level=this.level(profile,pixels);
    const variants=new Map([...textures].map(index=>{
      const r=this.records.get(index);
      return [index,r.variants.find(v=>v.size>=level)||r.variants.at(-1)];
    }));
    return {textures,meshes,variants,key:JSON.stringify([[...meshes], [...variants].map(([i,v])=>[i,v.size]),profile])};
  }
  update(profile='balanced',pixels=1200,force=false){
    if(!this.parser||this.disposed||performance.now()<(this.retryAt||0))return Promise.resolve();
    const wanted=this.requirements(profile,pixels);
    if(wanted.key===this.key)return this.pending||Promise.resolve();
    // Avoid reallocating on every pinch/orbit frame. Wardrobe changes and
    // quality switches are immediate; display-size changes settle briefly.
    const content=JSON.stringify([[...wanted.meshes],[...wanted.textures],profile]);
    if(!force&&content===this.content&&performance.now()-(this.changedAt||0)<1500)return this.pending||Promise.resolve();
    this.content=content;this.changedAt=performance.now();this.key=wanted.key;
    const generation=++this.generation;
    this.ready=false;this.error='';
    // Serialize scene residency changes so a fast wardrobe change cannot
    // evict geometry which an older asynchronous request is still installing.
    this.pending=Promise.resolve(this.pending).catch(()=>{}).then(async()=>{
      if(this.disposed||generation!==this.generation)return;
      for(const r of this.records.values())if(!wanted.textures.has(r.index))this.releaseTexture(r);
      for(const r of this.meshes.values())if(!wanted.meshes.has(r.index))this.releaseMesh(r);
      for(const index of wanted.meshes){
        if(this.disposed||generation!==this.generation)return;
        await this.ensureMesh(this.meshes.get(index));
      }
      for(const [index,variant] of wanted.variants){
        if(this.disposed||generation!==this.generation)return;
        await this.ensureTexture(this.records.get(index),variant,profile);
      }
      if(generation===this.generation&&!this.disposed)this.ready=true;
    }).catch(error=>{
      if(!this.disposed&&generation===this.generation){this.error=error.message;this.key=null;this.retryAt=performance.now()+10000;}
      throw error;
    });
    return this.pending;
  }
  async ensureMesh(record){
    if(!record||record.loaded)return;
    const def=this.parser.json.meshes[record.index];
    const geometries=await this.loadGeometry(def.primitives);
    if(this.disposed){for(const g of geometries)g.dispose();return;}
    for(let i=0;i<record.nodes.length;i++){
      const node=record.nodes[i],pi=node.geometry.userData.deferredPrimitive??node.userData.residentPrimitive??i;
      node.userData.residentPrimitive=pi;node.userData.residentMesh=record.index;
      node.geometry.dispose();node.geometry=geometries[pi];
      if(node.isSkinnedMesh)node.normalizeSkinWeights();
      node.boundingBox=null;node.boundingSphere=null;
      node.updateMorphTargets();
      if(def.extras?.targetNames&&node.morphTargetInfluences)
        node.morphTargetDictionary=Object.fromEntries(def.extras.targetNames.map((name,i)=>[name,i]));
      if(def.weights&&node.morphTargetInfluences)node.morphTargetInfluences.splice(0,def.weights.length,...def.weights);
    }
    record.loaded=true;
  }
  releaseMesh(record){
    if(!record.loaded)return;
    for(const node of record.nodes){
      node.geometry.dispose();node.geometry=this.emptyGeometry();
      node.morphTargetInfluences=[];node.morphTargetDictionary={};
      node.boundingBox=null;node.boundingSphere=null;
    }
    const def=this.parser.json.meshes[record.index],accessors=new Set();
    for(const p of def.primitives){
      for(const i of Object.values(p.attributes||{}))accessors.add(i);
      if(p.indices!==undefined)accessors.add(p.indices);
      for(const t of p.targets||[])for(const i of Object.values(t))accessors.add(i);
    }
    for(const i of accessors){
      const vi=this.parser.json.accessors[i].bufferView;
      this.parser.cache.remove('accessor:'+i);
      if(vi!==undefined){this.parser.cache.remove('bufferView:'+vi);this.parser.cache.remove('buffer:'+this.parser.json.bufferViews[vi].buffer);}
    }
    for(const [key,value] of Object.entries(this.parser.primitiveCache))
      if(def.primitives.includes(value.primitive))delete this.parser.primitiveCache[key];
    record.loaded=false;
  }
  url(path){return new URL(path,new URL(this.parser.options.path,location.href)).href;}
  async ensureTexture(record,variant,profile){
    // Quality is the lossless reference; Balanced/Eco use high-quality UASTC
    // when present. Decode failure falls back to the same-size lossless PNG.
    const compressed=profile!=='quality'&&!this.compressionFailed&&variant.compressed;
    const key=variant.uri+':'+Boolean(compressed);
    if(record.loaded?.key===key)return;
    let resource;
    if(compressed){
      try{
        // A broken/unsupported worker must not leave an invisible model forever.
        let timeout;
        const task=this.ktx.loadAsync(this.url(compressed));
        try{resource=await Promise.race([task,new Promise((_,reject)=>{timeout=setTimeout(()=>reject(Error('Texture decode timed out')),12000);})]);}
        catch(error){task.then(texture=>texture.dispose(),()=>{});throw error;}
        finally{clearTimeout(timeout);}
      }catch{this.compressionFailed=true;this.ktx?.dispose();this.ktx=null;}
    }
    if(!resource){
      const response=await fetch(this.url(variant.uri));
      if(!response.ok)throw Error('Wardrobe texture could not be loaded.');
      const bitmap=await createImageBitmap(await response.blob(),{premultiplyAlpha:'none',colorSpaceConversion:'none',imageOrientation:'none'});
      resource=new THREE.Texture(bitmap);resource.flipY=false;
    }
    if(this.disposed){resource.image?.close?.();resource.dispose();return;}
    this.releaseTexture(record);
    for(const target of record.targets){
      target.source=resource.source;target.mipmaps=resource.mipmaps;
      target.format=resource.format;target.type=resource.type;
      target.internalFormat=resource.internalFormat;
      target.generateMipmaps=resource.isCompressedTexture?false:true;
      target.isCompressedTexture=Boolean(resource.isCompressedTexture);
      target.needsUpdate=true;
    }
    record.loaded={key,resource};
  }
  releaseTexture(record){
    if(!record.loaded)return;
    for(const texture of record.targets){
      texture.dispose();texture.source=new THREE.Source(null);texture.mipmaps=[];
    }
    record.loaded.resource.image?.close?.();record.loaded.resource.dispose();record.loaded=null;
  }
  stats(){return {textures:[...this.records.values()].filter(r=>r.loaded).length,
    optionalMeshes:[...this.meshes.values()].filter(r=>r.loaded).length,ready:this.ready};}
  dispose(){
    this.disposed=true;++this.generation;
    for(const r of this.records.values())this.releaseTexture(r);
    this.ktx?.dispose();this.records.clear();this.meshes.clear();this.model=null;this.parser=null;
  }
}
