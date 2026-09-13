// Bake compact companion greetings on the original exported Tia rig.
// No meshes, skin weights, bind matrices or materials are modified.
// node scripts/build-tia-greetings.mjs MODEL.glb OUTPUT_DIRECTORY [LIBRARY.json]
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import * as THREE from 'three';
const [modelPath,outDir,libraryPath]=process.argv.slice(2);
if(!modelPath||!outDir)throw Error('Supply the original model and output directory');
const file=fs.readFileSync(modelPath),doc=JSON.parse(file.subarray(20,20+file.readUInt32LE(12)));
const jointIds=new Set(doc.skins.flatMap(s=>s.joints));
const nodes=doc.nodes.map((n,i)=>{
 const b=jointIds.has(i)?new THREE.Bone():new THREE.Group();
 b.name=n.name||'';b.userData.sourceName=b.name;
 if(n.matrix)b.matrix.fromArray(n.matrix);
 else b.matrix.compose(new THREE.Vector3(...(n.translation||[0,0,0])),new THREE.Quaternion(...(n.rotation||[0,0,0,1])),new THREE.Vector3(...(n.scale||[1,1,1])));
 b.matrix.decompose(b.position,b.quaternion,b.scale);b.matrixAutoUpdate=false;return b;
});
doc.nodes.forEach((n,i)=>(n.children||[]).forEach(j=>nodes[i].add(nodes[j])));
const model=new THREE.Group();for(const i of doc.scenes[doc.scene||0].nodes)model.add(nodes[i]);model.updateMatrixWorld(true);
class Renderer{setPixelRatio(){}setSize(){}setClearColor(){}}
const scope={THREE:{...THREE,WebGLRenderer:Renderer},document:{createElement:()=>({})},window:{dispatchEvent(){}},Event:class{},console,mountAvatar3DOptions:()=>{}};
const studio=path.resolve(path.dirname(new URL(import.meta.url).pathname),'..');
vm.runInNewContext(fs.readFileSync(path.join(studio,'web/avatar3d.js'),'utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\nglobalThis.Avatar=Avatar3D;Avatar3D.prototype.lights=function(){};',scope);
const avatar=new scope.Avatar();avatar.model=model;avatar.root.add(model);avatar.collectBones();
const bones=nodes.filter(n=>n.isBone&&Object.hasOwn(doc.extras.openclamAvatar.rest,n.name));
// Auto-Rig Pro's similarly named twist/stretch bones are subdivisions, not
// interchangeable joints. The forearm twist starts near the wrist, whereas
// c_forearm_stretch is the anatomical elbow.
const joints=Object.fromEntries(['l','r'].map(side=>[side,{
 upper:bones.find(b=>b.name==='c_arm_twist.'+side),
 lower:bones.find(b=>b.name==='c_forearm_stretch.'+side),
 hand:bones.find(b=>b.name==='hand.'+side)
}]));
if(Object.values(joints).some(j=>Object.values(j).some(b=>!b)))throw Error('The original Tia arm joints are required');
const position=b=>b.getWorldPosition(new THREE.Vector3());
const group=(keys,side)=>keys.flatMap(k=>avatar.boneGroups[k][side]||[]);
function turn(members,pivot,rotation){
 const p=position(pivot),about=new THREE.Matrix4().makeTranslation(...p.toArray()).multiply(new THREE.Matrix4().makeRotationFromQuaternion(rotation)).multiply(new THREE.Matrix4().makeTranslation(-p.x,-p.y,-p.z));
 const set=new Set(members),roots=members.filter(b=>{for(let p=b.parent;p;p=p.parent)if(set.has(p))return false;return true;});
 const worlds=roots.map(b=>about.clone().multiply(b.matrixWorld));
 roots.forEach((b,i)=>{b.matrix.copy(b.parent.matrixWorld).invert().multiply(worlds[i]);b.matrix.decompose(b.position,b.quaternion,b.scale);});model.updateMatrixWorld(true);
}
function aim(members,start,end,direction){turn(members,start,new THREE.Quaternion().setFromUnitVectors(position(end).sub(position(start)).normalize(),direction.clone().normalize()));}
for(const side of ['l','r']){
 const sign=side==='l'?1:-1;
 const {upper,lower,hand}=joints[side];
 aim(group(['upperArm','lowerArm','hand','finger'],side),upper,lower,new THREE.Vector3(.16*sign,-1,.04));
 aim(group(['lowerArm','hand','finger'],side),lower,hand,new THREE.Vector3(.05*sign,-1,.12));
}
const idle=bones.map(b=>b.matrix.clone());
const smooth=t=>{t=Math.max(0,Math.min(1,t));return t*t*t*(t*(t*6-15)+10);};
const vectorBlend=(a,b,t)=>a.clone().applyQuaternion(new THREE.Quaternion().slerp(new THREE.Quaternion().setFromUnitVectors(a,b),t));
fs.mkdirSync(outDir,{recursive:true});
for(const [id,side,duration,cycles] of [['wave','r',3.8,2],['wave-one-hand','l',3.5,2]]){
 const sign=side==='l'?1:-1,frames=[],fps=30,report=[];
 for(let frame=0;frame<=Math.round(duration*fps);frame++){
  bones.forEach((b,i)=>b.matrix.copy(idle[i]));model.updateMatrixWorld(true);
  const t=frame/fps,weight=smooth(t/.85)*smooth((duration-t)/.9);
  const phase=Math.max(0,Math.min(1,(t-.85)/(duration-1.75)));
  const wave=Math.sin(phase*Math.PI*2*cycles)*Math.sin(phase*Math.PI);
  const {upper,lower,hand}=joints[side];
  const startUpper=position(lower).sub(position(upper)).normalize(),startLower=position(hand).sub(position(lower)).normalize();
  const desiredUpper=new THREE.Vector3(sign*.72,-.5,.24).normalize();
  const desiredLower=new THREE.Vector3(sign*(.12+.055*wave),.96,.23).normalize();
  aim(group(['upperArm','lowerArm','hand','finger'],side),upper,lower,vectorBlend(startUpper,desiredUpper,weight));
  aim(group(['lowerArm','hand','finger'],side),lower,hand,vectorBlend(startLower,desiredLower,weight));
  // Small wrist articulation follows the forearm; no overhead arm swing.
  turn(group(['hand','finger'],side),hand,new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0,0,1),sign*wave*.15*weight));
  frames.push(bones.flatMap(b=>[0,1,2].flatMap(r=>[0,1,2,3].map(c=>Number(b.matrix.elements[c*4+r].toFixed(7))))));
  report.push({time:t,hand:position(hand).toArray(),elbow:position(lower).toArray()});
 }
 const data={version:1,id,label:id==='wave'?'Gentle Wave':'Friendly Wave',source:'OpenClam companion greeting authored on the original Tia rig',fps,bones:bones.map(b=>b.name),frames,loop:false,
  gesture:{version:1,side,anchor:'shoulder.'+side,blendIn:.65,blendOut:.8},retargeting:{version:10,greetingFit:'relaxed-elbow-small-wrist-wave',rootMotion:false}};
 fs.writeFileSync(path.join(outDir,id+'.json'),JSON.stringify(data));
 fs.writeFileSync(path.join(outDir,id+'-measurements.json'),JSON.stringify(report));
 console.log(id,frames.length,'frames',side+' arm');
}
if(libraryPath){
 const library=JSON.parse(fs.readFileSync(libraryPath,'utf8'));
 if(library.version!==1||!Array.isArray(library.clips))throw Error('Invalid source library');
 for(const entry of library.clips){
  if(['wave','wave-one-hand'].includes(entry.id)){
   const clip=JSON.parse(fs.readFileSync(path.join(outDir,entry.id+'.json'),'utf8'));
   Object.assign(entry,{label:clip.label,source:clip.source,duration:(clip.frames.length-1)/clip.fps,
    portraitGesture:true,requiresFreeHands:true,reactions:['greeting'],expression:{smile:.4}});
   delete entry.action_id;
  }
  if(entry.id==='big-wave-hello')entry.reactions=(entry.reactions||[]).filter(r=>r!=='greeting');
 }
 library.greetingRevision=1;
 fs.writeFileSync(path.join(outDir,'library.json'),JSON.stringify(library,null,2)+'\n');
}
