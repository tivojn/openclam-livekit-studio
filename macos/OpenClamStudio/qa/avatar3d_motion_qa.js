'use strict';
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
(async()=>{
const THREE=await import('three');
let time=0,release;
const scene=new THREE.Group(),head=new THREE.Bone(),hair=new THREE.Group();head.name='head';hair.position.y=1;head.add(hair);scene.add(head);scene.updateMatrixWorld(true);
const make=m=>{const p=new THREE.Vector3(),q=new THREE.Quaternion(),s=new THREE.Vector3();m.decompose(p,q,s);return{m,p,q,s,residual:new THREE.Matrix4().compose(p,q,s).invert().multiply(m)};};
const idle=make(new THREE.Matrix4());
const rows=m=>[0,1,2].flatMap(r=>[0,1,2,3].map(c=>m.elements[c*4+r]));
const rotated=new THREE.Matrix4().makeRotationZ(.4);rotated.elements[4]+=.12;
const document={version:1,id:'wave',bones:['head'],fps:10,frames:[rows(new THREE.Matrix4()),rows(rotated),rows(rotated)],loop:false};
let poseRestored=0;
const options={bones:[{name:'head'}],selection:{},current:[idle],avatar:{bones:{}},
 write(pose){head.matrix.copy(pose[0].m);head.matrixAutoUpdate=false;scene.updateMatrixWorld(true);},
 applyPose(){poseRestored++;},};
const s={THREE,URL,Float32Array,performance:{now:()=>time},location:{href:'http://local/',origin:'http://local'},
 fetch:async url=>({ok:true,json:async()=>String(url).endsWith('library.json')?{version:1,clips:[{id:'wave',file:'wave.json'}]}:document})};
vm.runInNewContext(fs.readFileSync('web/avatar3d-motion.js','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\nglobalThis.Player=Avatar3DMotion;',s);
const player=new s.Player(options);options.avatar.motion=player;
await player.load('/library.json');await player.play('wave',{now:-500});player.update(0);
assert(!player.active&&poseRestored===1,'one-shot motion returns to selected pose');
await player.play('wave',{now:0,loop:true});player.update(450);
const relative=head.matrixWorld.clone().invert().multiply(hair.matrixWorld);
assert(Math.abs(relative.elements[13]-1)<1e-9,'hair remains rigidly attached during animation');
assert(Math.abs(head.matrix.elements[4]-head.matrix.elements[1]*-1)>.001,'affine shear survives interpolation');
player.update(500,true);assert(!player.active,'Reduce Motion interrupts an active clip');
player.clips.get('wave').ready=null;
s.fetch=async()=>({ok:true,json:()=>new Promise(r=>release=r)});
const pending=player.play('wave');await new Promise(r=>setImmediate(r));player.stop();release(document);await pending;
assert(!player.active,'stop cancels a clip that is still loading');
player.clips.get('wave').ready=null;
s.fetch=async()=>({ok:true,json:async()=>({...document,bones:['different-rig']})});
await assert.rejects(player.prepare('wave'),/match/);
await assert.rejects(player.load('https://external.example/library.json'),/local/);
console.log('3D motion: clip lifecycle, cancellation, original attachment, affine transforms, rig validation and local-only loading passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
