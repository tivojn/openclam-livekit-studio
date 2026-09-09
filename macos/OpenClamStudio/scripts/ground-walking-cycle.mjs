/** Ground a baked walking cycle against the original, skinned shoe soles.
 * Usage: node scripts/ground-walking-cycle.mjs MODEL.glb CLIP.json [OUTPUT.json]
 * The model is read-only. Running without OUTPUT is a contact audit.
 */
import fs from 'node:fs';
import * as T from 'three';
const [modelPath, clipPath, outputPath] = process.argv.slice(2);
if (!modelPath || !clipPath) throw Error('Expected MODEL.glb CLIP.json [OUTPUT.json]');
const bytes=fs.readFileSync(modelPath), size=bytes.readUInt32LE(12);
const doc=JSON.parse(bytes.subarray(20,20+size)), bin=bytes.subarray(28+size);
const clip=JSON.parse(fs.readFileSync(clipPath));
if (outputPath && !clip.retargeting?.walkingCycle) throw Error('Only a complete walking cycle can be grounded');
const parents=new Map(), ids=new Map(doc.nodes.map((n,i)=>[n.name,i]));
doc.nodes.forEach((n,i)=>(n.children||[]).forEach(c=>parents.set(c,i)));
const locals=doc.nodes.map(n=>n.matrix ? new T.Matrix4().fromArray(n.matrix) : new T.Matrix4().compose(
  new T.Vector3().fromArray(n.translation||[0,0,0]),new T.Quaternion().fromArray(n.rotation||[0,0,0,1]),new T.Vector3().fromArray(n.scale||[1,1,1])));
function worlds(local) {
  const out=[];const at=i=>out[i]||(out[i]=(parents.has(i)?at(parents.get(i)).clone():new T.Matrix4()).multiply(local[i]));
  local.forEach((_,i)=>at(i));return out;
}
const rest=worlds(locals), slots=new Map(clip.bones.map((n,k)=>[ids.get(n),k]));
if(slots.has(undefined))throw Error('Clip does not match model');
function accessor(id) {
  const a=doc.accessors[id],v=doc.bufferViews[a.bufferView], n={SCALAR:1,VEC2:2,VEC3:3,VEC4:4,MAT4:16}[a.type];
  const formats={5126:[4,'readFloatLE'],5123:[2,'readUInt16LE'],5121:[1,'readUInt8']},[width,read]=formats[a.componentType]||[];
  if(!width||a.sparse||a.normalized)throw Error('Unsupported accessor');
  return Array.from({length:a.count},(_,i)=>Array.from({length:n},(_,j)=>bin[read]((v.byteOffset||0)+(a.byteOffset||0)+i*(v.byteStride||width*n)+j*width)));
}
const shoes=doc.nodes.filter(n=>['BootHeel','Fem-A_Fot_Ac_HlStrp_01','Fem-A_Fot_Ac_Tenni_01'].includes(n.name)).map(n=>{
  const skin=doc.skins[n.skin], inverse=accessor(skin.inverseBindMatrices).map(a=>new T.Matrix4().fromArray(a));
  const vertices=doc.meshes[n.mesh].primitives.flatMap(p=>{
    const positions=accessor(p.attributes.POSITION),joints=accessor(p.attributes.JOINTS_0),weights=accessor(p.attributes.WEIGHTS_0);
    return positions.map((p,i)=>({p:new T.Vector3().fromArray(p),j:joints[i],w:weights[i]}));
  });return {name:n.name,skin,inverse,vertices};
});
if(!shoes.some(s=>s.name==='BootHeel'))throw Error('Original shoe geometry is required');
function contact(shoe,pose) {
  const mats=shoe.skin.joints.map((id,i)=>pose[id].clone().multiply(shoe.inverse[i]));
  let min=Infinity;const p=new T.Vector3(),sum=new T.Vector3();
  for(const v of shoe.vertices){sum.set(0,0,0);for(let j=0;j<4;j++)if(v.w[j])sum.addScaledVector(p.copy(v.p).applyMatrix4(mats[v.j[j]]),v.w[j]);min=Math.min(min,sum.y);}
  return min;
}
const baseline=Object.fromEntries(shoes.map(s=>[s.name,contact(s,rest)])), reports=[];
const roots=[...slots].filter(([id])=>!slots.has(parents.get(id))).map(([id,k])=>({k,inverse:parents.has(id)?rest[parents.get(id)].clone().invert():new T.Matrix4()}));
const low=new T.Vector3(Infinity,Infinity,Infinity),high=new T.Vector3(-Infinity,-Infinity,-Infinity);
for(const values of clip.frames) {
  const local=locals.map(m=>m.clone());for(const [id,k] of slots){const a=values.slice(k*12,k*12+12);local[id].set(...a,0,0,0,1);}
  const pose=worlds(local), before=Object.fromEntries(shoes.map(s=>[s.name,contact(s,pose)-baseline[s.name]]));
  const correction=-before.BootHeel;
  if(Math.abs(correction)>.3)throw Error('Unexpected sole offset; check the rig before grounding');
  reports.push(before);
  if(outputPath)for(const {k,inverse} of roots){
    const offset=new T.Vector3(0,correction,0).applyMatrix4(inverse).sub(new T.Vector3().applyMatrix4(inverse));
    for(let axis=0;axis<3;axis++)values[k*12+axis*4+3]=Number((values[k*12+axis*4+3]+offset.getComponent(axis)).toFixed(7));
  }
  for(const [id] of slots){const p=new T.Vector3().setFromMatrixPosition(pose[id]);if(outputPath)p.y+=correction;low.min(p);high.max(p);}
}
const summary=Object.fromEntries(shoes.map(s=>[s.name,{min:Math.min(...reports.map(r=>r[s.name])),max:Math.max(...reports.map(r=>r[s.name]))}]));
if(outputPath){clip.bounds=[low.addScalar(-.12).toArray(),high.addScalar(.12).toArray()];clip.retargeting.groundContact='original-skinned-shoe-sole';fs.writeFileSync(outputPath,JSON.stringify(clip));}
console.log(JSON.stringify({id:clip.id,frames:clip.frames.length,soleOffsetMetres:summary,corrected:Boolean(outputPath)},null,2));
