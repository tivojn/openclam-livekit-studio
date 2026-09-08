import * as THREE from '/vendor/three/three.module.js';

const parts = m => {
  const p = new THREE.Vector3(), q = new THREE.Quaternion(), s = new THREE.Vector3();
  m.decompose(p, q, s);
  return {m, p, q, s, residual: new THREE.Matrix4().compose(p,q,s).invert().multiply(m)};
};
const blend = (a,b,t) => b.map((v,i) => {
  const p=a[i].p.clone().lerp(v.p,t), q=a[i].q.clone().slerp(v.q,t), s=a[i].s.clone().lerp(v.s,t);
  const residual=new THREE.Matrix4();
  residual.elements=residual.elements.map((_,j)=>a[i].residual.elements[j]*(1-t)+v.residual.elements[j]*t);
  return parts(new THREE.Matrix4().compose(p,q,s).multiply(residual));
});
const smooth = t => {t=Math.max(0,Math.min(1,t));return t*t*(3-2*t);};

// Optional local motion clips. The API credential and donor character never
// enter the runtime. Clips address the original exported rig by bone name.
export class Avatar3DMotion {
  constructor(options) { this.options=options;this.clips=new Map();this.active=null;this.generation=0; }
  async load(url) {
    const origin=new URL(url,location.href);
    if(origin.origin!==location.origin)throw Error('Motion library must be local');
    const response=await fetch(origin,{cache:'no-cache'});
    if(!response.ok)throw Error('Motion library unavailable');
    const data=await response.json();
    if(data.version!==1||!Array.isArray(data.clips)||data.clips.length>24)throw Error('Invalid motion library');
    for(const entry of data.clips) {
      if(!/^[a-z0-9_-]{1,40}$/.test(entry.id))throw Error('Invalid motion name');
      const source=new URL(entry.file,origin);
      if(source.origin!==origin.origin)throw Error('Motion clip must be local');
      this.clips.set(entry.id,{...entry,url:source.href,ready:null});
    }
    return this;
  }
  async prepare(id) {
    const clip=this.clips.get(id);
    if(!clip)throw Error('This motion is not installed');
    if(clip.ready)return clip.ready;
    if(clip.loading)return clip.loading;
    clip.loading=(async()=>{
      const response=await fetch(clip.url,{cache:'no-cache'});
      if(!response.ok)throw Error('Could not load motion');
      const data=await response.json(), bones=this.options.bones;
      if(data.version!==1||data.id!==id||!Array.isArray(data.bones)
        ||data.bones.length!==bones.length||new Set(data.bones).size!==bones.length
        ||!Array.isArray(data.frames)||data.frames.length<2||data.frames.length>900
        ||!(data.fps>=1&&data.fps<=120))throw Error('Invalid motion clip');
      const indices=bones.map(b=>data.bones.indexOf(b.name));
      if(indices.includes(-1))throw Error('Motion does not match this avatar');
      const frames=data.frames.map(frame=>{
        if(!Array.isArray(frame)||frame.length!==bones.length*12
          ||!frame.every(v=>Number.isFinite(v)&&Math.abs(v)<10000))throw Error('Invalid motion transform');
        return new Float32Array(frame);
      });
      clip.ready={frames,indices,fps:data.fps,loop:Boolean(data.loop),cache:new Map()};
      return clip.ready;
    })();
    try{return await clip.loading;}finally{clip.loading=null;}
  }
  frame(clip,index) {
    if(clip.cache.has(index))return clip.cache.get(index);
    const values=clip.frames[index];
    const transforms=clip.indices.map(i=>parts(new THREE.Matrix4().set(...values.subarray(i*12,i*12+12),0,0,0,1)));
    clip.cache.set(index,transforms);
    if(clip.cache.size>6)clip.cache.delete(clip.cache.keys().next().value);
    return transforms;
  }
  async play(id,{loop,now}={}) {
    const generation=++this.generation;
    const clip=await this.prepare(id);
    if(generation!==this.generation)return false;
    this.options.transition=null;
    const selection=this.options.selection;
    const hands=this.options.bones.map(({name},i)=>
      /index|middle|ring|pinky|thumb/.test(name) && (selection.prop||selection.hands
        ||(name.endsWith('.l')&&selection.leftHand)||(name.endsWith('.r')&&selection.rightHand))
        ? this.options.current[i] : null);
    this.active={id,clip,loop:loop??clip.loop,start:now??performance.now(),from:this.options.current.slice(),hands};
    return true;
  }
  stop({immediate=false}={}) {
    ++this.generation;
    if(!this.active)return;
    this.active=null;
    if(!immediate)this.options.applyPose(this.options.selection,performance.now());
  }
  update(now,reduce=false) {
    const action=this.active;
    if(!action)return false;
    if(reduce){this.stop();return false;}
    const {clip}=action, duration=(clip.frames.length-1)/clip.fps;
    let seconds=Math.max(0,(now-action.start)/1000);
    if(!action.loop&&seconds>=duration){this.stop();return false;}
    if(action.loop)seconds%=duration;
    const f=seconds*clip.fps, i=Math.min(clip.frames.length-1,Math.floor(f));
    let pose=blend(this.frame(clip,i),this.frame(clip,Math.min(i+1,clip.frames.length-1)),f-i);
    // Join a generated loop over its final 200ms, then blend into an action.
    if(action.loop&&seconds>duration-.2)pose=blend(pose,this.frame(clip,0),smooth((seconds-duration+.2)/.2));
    pose=blend(action.from,pose,smooth((now-action.start)/350));
    pose=pose.map((transform,i)=>action.hands[i]||transform);
    this.options.current=pose;
    this.options.write(pose);
    this.options.nextPlaybackAt=now+4000;
    const avatar=this.options.avatar;
    if(avatar.headReferencePoint&&avatar.bones.head)
      avatar.headCenter.copy(avatar.headReferencePoint).applyMatrix4(avatar.bones.head.matrixWorld);
    return true;
  }
  dispose(){this.stop({immediate:true});this.clips.clear();}
}
