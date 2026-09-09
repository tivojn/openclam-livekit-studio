/** Regression against the original Meshy Walking Woman joint trajectories.
 * Usage: node qa/tia_walking_source_qa.mjs MODEL CLIP SOURCE_JOINTS.json [REPORT]
 * Source joints come from the unmodified private FBX, exported Y-up in metres.
 * Uses the original skinned sneaker vertices to distinguish heel landing,
 * flat support, and toe-off. Private model and motion data are not committed.
 */
import fs from 'node:fs';
import * as T from 'three';
import assert from 'node:assert/strict';
const [modelPath, clipPath, sourcePath, reportPath] = process.argv.slice(2);
if (!modelPath || !clipPath || !sourcePath) throw Error('Expected MODEL.glb CLIP.json SOURCE_JOINTS.json [REPORT.json]');
const bytes=fs.readFileSync(modelPath), size=bytes.readUInt32LE(12);
const doc=JSON.parse(bytes.subarray(20,20+size)), bin=bytes.subarray(28+size);
const clip=JSON.parse(fs.readFileSync(clipPath));
assert(clip.retargeting?.walkingCycle, 'Expected a complete walking cycle');
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
const donors=JSON.parse(fs.readFileSync(sourcePath)).find(x=>x.id==='walking-woman').rows;
const point=(pose,n)=>new T.Vector3().setFromMatrixPosition(pose[ids.get(n)]);
const shoe=shoes.find(s=>s.name==='Fem-A_Fot_Ac_Tenni_01');
function landmarks(pose){const mats=shoe.skin.joints.map((id,i)=>pose[id].clone().multiply(shoe.inverse[i]));const out={l:{heel:Infinity,toe:Infinity},r:{heel:Infinity,toe:Infinity}};
 for(const v of shoe.vertices){const q=new T.Vector3();for(let i=0;i<4;i++)if(v.w[i])q.addScaledVector(v.p.clone().applyMatrix4(mats[v.j[i]]),v.w[i]);const p=new T.Vector3();for(let i=0;i<4;i++)if(v.w[i])p.addScaledVector(v.p.clone().applyMatrix4(rest[shoe.skin.joints[v.j[i]]].clone().multiply(shoe.inverse[v.j[i]])),v.w[i]);
 const side=p.x>0?'l':'r';const ankle=point(rest,'foot.'+side);if(p.z<ankle.z)out[side].heel=Math.min(out[side].heel,q.y);if(p.z>ankle.z+.095)out[side].toe=Math.min(out[side].toe,q.y);
 }return out;}
const report=[];for(let frame=0;frame<clip.frames.length;frame++){const local=locals.map(m=>m.clone());for(const [id,k]of slots)local[id].set(...clip.frames[frame].slice(k*12,k*12+12),0,0,0,1);const pose=worlds(local),d=donors.find(r=>r.frame===frame+clip.retargeting.sourceFrameRange[0]).joints;
 const pts={};for(const [side,prefix]of[['l','Left'],['r','Right']]){const s=point(pose,'c_arm_twist.'+side),el=point(pose,'c_forearm_stretch.'+side),hand=point(pose,'hand.'+side);pts[side]={hand:hand.z-s.z,upper:el.z-s.z,sourceHand:d[prefix+'Hand'][2]-d[prefix+'Arm'][2],sourceUpper:d[prefix+'ForeArm'][2]-d[prefix+'Arm'][2]};}
 const hip=point(pose,'c_thigh_twist.l').sub(point(pose,'c_thigh_twist.r')),sh=new T.Vector3().fromArray(d.LeftUpLeg).sub(new T.Vector3().fromArray(d.RightUpLeg));
 report.push({frame,roll:Math.atan2(hip.y,hip.x)*180/Math.PI,yaw:Math.atan2(hip.z,hip.x)*180/Math.PI,sourceRoll:Math.atan2(sh.y,sh.x)*180/Math.PI,sourceYaw:Math.atan2(sh.z,sh.x)*180/Math.PI,feet:landmarks(pose),...pts});}

const range=values=>[Math.min(...values),Math.max(...values)];
const errors={roll:Math.max(...report.map(r=>Math.abs(r.roll-r.sourceRoll))),yaw:Math.max(...report.map(r=>Math.abs(r.yaw-r.sourceYaw)))};
const checks={hipErrorDegrees:errors,hands:{},contact:{}};
assert(errors.roll<.3&&errors.yaw<.3,'hip roll and yaw must track the source, without a first-frame bias');
for(const side of ['l','r']){
 const hands=range(report.map(r=>r[side].hand));checks.hands[side]=hands;
 assert(hands[0]<-.1&&hands[1]>.1,'each hand must swing both in front and behind the anatomical shoulder');
 const feet=report.map(r=>r.feet[side]);
 const heel=feet.filter(f=>f.heel<.003&&f.toe>f.heel+.012).length;
 const flat=feet.filter(f=>Math.abs(f.heel)<.009&&Math.abs(f.toe)<.003).length;
 const push=feet.filter(f=>f.heel>.025&&Math.abs(f.toe)<.005).length;
 checks.contact[side]={heelLandingFrames:heel,flatSupportFrames:flat,toeOffFrames:push};
 assert(heel>=1,'each foot must have a heel landing');
 assert(flat>=4,'each shoe needs sustained flat support, not continuous tiptoeing');
 assert(push>=1,'each shoe needs a toe-off phase after flat support');
 // Follow the next half cycle after heel landing: support must occur
 // before push-off, rather than counting unrelated airborne poses.
 const strike=feet.findIndex(f=>f.heel<.003&&f.toe>f.heel+.012);
 const next=Array.from({length:Math.ceil(feet.length*.6)},(_,i)=>feet[(strike+i)%feet.length]);
 const support=next.findIndex(f=>Math.abs(f.heel)<.009&&Math.abs(f.toe)<.003);
 const off=next.findIndex(f=>f.heel>.025&&Math.abs(f.toe)<.005);
 assert(support>=0&&off>support,'heel landing must lead to flat support and then toe-off');
}
if(reportPath)fs.writeFileSync(reportPath,JSON.stringify({checks,frames:report},null,2)+'\n');
console.log('PASS source gait and separate heel/forefoot contacts',JSON.stringify(checks));
