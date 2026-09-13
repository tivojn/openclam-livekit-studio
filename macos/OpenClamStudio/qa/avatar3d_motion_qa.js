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
await player.play('wave',{now:0,loop:true});
player.setPlaybackRate(0,100);
assert.equal(player.elapsed(1000),.1,'turning holds gait phase instead of marching/sliding');
player.setPlaybackRate(.5,1000);
assert.equal(player.elapsed(1500),.35,'acceleration integrates the new cadence without a phase jump');
player.setPlaybackRate(1,1500);
assert.equal(player.elapsed(1600),.44999999999999996);
await player.play('wave',{now:0,loop:true});assert.equal(player.active.rate,1,'ordinary motions retain their authored timing');
player.update(500,true);assert(!player.active,'Reduce Motion interrupts an active clip');
player.clips.get('wave').ready=null;
s.fetch=async()=>({ok:true,json:()=>new Promise(r=>release=r)});
const pending=player.play('wave');await new Promise(r=>setImmediate(r));assert(player.pending);player.stop();release(document);await pending;
assert(!player.active&&!player.pending,'stop cancels a clip that is still loading');
player.clips.get('wave').ready=null;
s.fetch=async()=>({ok:true,json:async()=>({...document,bones:['different-rig']})});
await assert.rejects(player.prepare('wave'),/match/);
await assert.rejects(player.load('https://external.example/library.json'),/local/);
// A catalog can be broad without retaining every decoded clip in memory.
const wide=new s.Player(options);
s.fetch=async url=>({ok:true,json:async()=>String(url).endsWith('library.json')
  ? {version:1,clips:Array.from({length:63},(_,i)=>({id:'motion-'+i,file:'motion-'+i+'.json'}))}
  : {...document,id:new URL(url).pathname.split('/').pop().replace('.json','')}});
await wide.load('/library.json');assert.equal(wide.clips.size,63);
await wide.play('motion-0',{now:0});
for(let i=1;i<8;i++)await wide.prepare('motion-'+i);
assert.equal([...wide.clips.values()].filter(c=>c.ready).length,4);
assert(wide.clips.get('motion-0').ready,'LRU retains active clip');
assert.equal(wide.clips.get('motion-1').ready,null,'old unused clip is released');
// Authored finger layers affect fingers only, and explicit props keep their grip.
const finger=make(new THREE.Matrix4().makeRotationZ(.8));
const grip=make(new THREE.Matrix4().makeRotationZ(.2));
const boneOptions={...options,bones:[{name:'index_01.r'},{name:'head'}],current:[idle,idle],
  poses:new Map([['point',{id:'point',group:'rightHand',deltas:{'index_01.r':[]}}]]),
  targetFor:()=>[finger,finger],write(){},selection:{},avatar:{bones:{}}};
const handPlayer=new s.Player(boneOptions);
handPlayer.clips.set('wave',{id:'wave',rightHand:'point',expression:{smile:.8}});
handPlayer.prepare=async()=>({frames:[null,null],fps:1,loop:false});
handPlayer.frame=()=>[idle,idle];
await handPlayer.play('wave',{now:0});
assert.equal(handPlayer.expression(0).smile,0,'smile fades into a happy motion');
assert.equal(handPlayer.expression(400).smile,.8);
assert.equal(Object.keys(handPlayer.expression(400,true)).length,0,'Reduce Motion suppresses the motion expression');
handPlayer.update(400);
assert(Math.abs(boneOptions.current[0].q.z-finger.q.z)<1e-6);
assert.equal(boneOptions.current[1].q.z,0,'hand layer does not rotate the head');
boneOptions.current=[grip,idle];boneOptions.selection={prop:'pistol'};
await handPlayer.play('wave',{now:1000});handPlayer.update(1400);
assert(Math.abs(boneOptions.current[0].q.z-grip.q.z)<1e-6,'held prop keeps user-selected finger transform');
// A closed walking cycle must keep its full last support step, rather than
// spending its final 200 ms crossfading prematurely to the first frame.
const cyclePlayer=new s.Player(options);
const cycle={...document,fps:10,frames:Array.from({length:11},()=>rows(new THREE.Matrix4())),retargeting:{loopBlendSeconds:0}};
s.fetch=async url=>({ok:true,json:async()=>String(url).endsWith('library.json')?{version:1,clips:[{id:'wave',file:'wave.json'}]}:cycle});
await cyclePlayer.load('/library.json');
await cyclePlayer.play('wave',{now:0,loop:true});
let samples=[];cyclePlayer.frame=(_clip,seconds)=>{samples.push(seconds);return [idle];};
cyclePlayer.update(950);assert.deepEqual(samples,[9,10]);
cyclePlayer.active.clip.loopBlendSeconds=.1;samples=[];cyclePlayer.update(950);
assert.deepEqual(samples,[9,10,0],'cropped cycles retain their explicit seam blend');
// A portrait greeting overlays the original pose in shoulder space. Exercise
// flattened limb roots and a parented finger, with the body translated/turned
// as if seated, so an absolute-world overlay cannot accidentally pass.
const rig=new THREE.Group(),shoulder=new THREE.Bone(),arm=new THREE.Bone(),wrist=new THREE.Bone(),fingerNode=new THREE.Bone(),still=new THREE.Bone();
[shoulder,arm,wrist,still].forEach(b=>rig.add(b));wrist.add(fingerNode);
const gestureNodes=[shoulder,arm,wrist,fingerNode,still];
['shoulder.r','arm.r','hand.r','index.r','head'].forEach((name,i)=>gestureNodes[i].name=name);
const reference=[0,1,2,0,4].map(x=>make(new THREE.Matrix4().makeTranslation(x,0,0)));
const anchorNow=new THREE.Matrix4().makeRotationZ(.2).setPosition(0,-2,0);
const base=reference.map((p,i)=>make(i===3?p.m.clone():anchorNow.clone().multiply(p.m)));
let framed=0;
const gestureOptions={bones:gestureNodes.map(node=>({node,name:node.name})),current:base,selection:{},
 avatar:{bones:{},boneGroups:{upperArm:{r:[arm]},lowerArm:{r:[]},hand:{r:[wrist]},finger:{r:[fingerNode]}},bounds:new THREE.Box3(),frame(){framed++;}},
 write(pose){gestureNodes.forEach((node,i)=>{node.matrix.copy(pose[i].m);node.matrixAutoUpdate=false;});rig.updateMatrixWorld(true);},applyPose(){throw Error('Greeting must restore the interrupted pose');}};
const gesturePlayer=new s.Player(gestureOptions);
const gestureDoc={version:1,id:'hello',fps:1,bones:gestureNodes.map(b=>b.name),frames:Array.from({length:4},(_,frame)=>reference.flatMap((p,i)=>rows(i===1||i===2?new THREE.Matrix4().makeTranslation(0,frame===1||frame===2?.3:0,0).multiply(p.m):p.m))),
 gesture:{version:1,side:'r',anchor:'shoulder.r',blendIn:.5,blendOut:.5},bounds:[[-10,-10,-10],[10,10,10]]};
s.fetch=async url=>({ok:true,json:async()=>String(url).endsWith('library.json')?{version:1,clips:[{id:'hello',file:'hello.json',portraitGesture:true}]}:gestureDoc});
await gesturePlayer.load('/library.json');await gesturePlayer.play('hello',{now:0});gesturePlayer.update(1500);
assert.equal(gestureOptions.current[0],base[0]);assert.equal(gestureOptions.current[4],base[4],'head never adopts the clip body pose');
const expected=anchorNow.clone().multiply(new THREE.Matrix4().makeTranslation(2,.3,0));
assert(Math.max(...expected.elements.map((v,i)=>Math.abs(v-wrist.matrix.elements[i])))<1e-6,'flattened hand follows the current shoulder frame');
assert.equal(gesturePlayer.active.bounds,null,'ignores full-body bounds for a portrait gesture');
assert.equal(framed,0);
gesturePlayer.update(3001);assert(!gesturePlayer.active);assert.equal(gestureOptions.current[2],base[2]);
console.log('3D motion: clip lifecycle, cancellation, original attachment, affine transforms, rig validation and local-only loading passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
