// Private-asset regression audit. No model or clip data is committed.
// node qa/tia_greeting_qa.js MODEL.glb MOTIONS REPORT.json
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
(async()=>{
 const studio=path.resolve(__dirname,'..');
 const [modelPath,afterDir,reportPath]=process.argv.slice(2);
 assert(modelPath&&afterDir&&reportPath,'Supply original model, greeting clips and report path');
 let motionDir=afterDir;
 const THREE=await import(path.join(studio,'node_modules/three/build/three.module.js'));
 const file=fs.readFileSync(modelPath);const doc=JSON.parse(file.subarray(20,20+file.readUInt32LE(12)));
 const jointIds=new Set(doc.skins.flatMap(s=>s.joints)),byName=new Map();
 const nodes=doc.nodes.map((n,i)=>{const b=jointIds.has(i)?new THREE.Bone():new THREE.Group();b.name=n.name||'';b.userData.sourceName=b.name;
  if(n.matrix){b.matrix.fromArray(n.matrix);b.matrix.decompose(b.position,b.quaternion,b.scale);b.matrixAutoUpdate=false;}
  else {b.position.fromArray(n.translation||[0,0,0]);b.quaternion.fromArray(n.rotation||[0,0,0,1]);b.scale.fromArray(n.scale||[1,1,1]);b.updateMatrix();}
  byName.set(b.name,b);return b;});
 doc.nodes.forEach((n,i)=>(n.children||[]).forEach(j=>nodes[i].add(nodes[j])));
 const model=new THREE.Group();for(const i of doc.scenes[doc.scene||0].nodes)model.add(nodes[i]);model.updateMatrixWorld(true);
 class Renderer {setPixelRatio(){}setSize(){}setClearColor(){}render(){}}
 let time=0;
 const s={THREE:{...THREE,WebGLRenderer:Renderer},URL,Float32Array,performance:{now:()=>time},location:{href:'http://local/'},document:{createElement:()=>({})},window:{dispatchEvent(){}},Event:class{},console,
 fetch:async url=>({ok:true,json:async()=>JSON.parse(fs.readFileSync(path.join(motionDir,new URL(url).pathname.split('/').pop())))} )};
 const run=(file,exporter)=>vm.runInNewContext('(function(){'+fs.readFileSync(path.join(studio,'web',file),'utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+'\n'+exporter+'})();',s);
 run('avatar3d-options.js','globalThis.Avatar3DOptions=Avatar3DOptions;globalThis.mountAvatar3DOptions=mountAvatar3DOptions');
 run('avatar3d.js','globalThis.Avatar=Avatar3D;Avatar3D.prototype.lights=function(){}');
 run('avatar3d-motion.js','globalThis.Player=Avatar3DMotion');
 const avatar=new s.Avatar();avatar.model=model;avatar.root.add(model);avatar.collectBones();avatar.resolveChannels();
 avatar.options=new s.Avatar3DOptions(avatar,doc.extras.openclamAvatar);avatar.relaxArms();avatar.options.captureIdle();

 let frames=0;avatar.frame=()=>{frames++;};
 avatar.motion=new s.Player(avatar.options);await avatar.motion.load('/library.json');
 const report={modelSHA256:require('node:crypto').createHash('sha256').update(file).digest('hex'),samples:[]};
 const maxDiff=(a,b)=>Math.max(...a.elements.map((v,i)=>Math.abs(v-b.elements[i])));
 const point=name=>byName.get(name).getWorldPosition(new THREE.Vector3());
 for(const id of ['wave','wave-one-hand'])for(const pose of ['', 'Ps004.sit','Ps001.heart']){
  avatar.motion.stop({immediate:true});time=0;
  avatar.options.select({body:pose,playTransitions:'false',followCursor:'false'},0);
  avatar.options.update(1000);time=1000;
  const before=avatar.options.current.slice(),worlds=avatar.options.bones.map(b=>b.node.matrixWorld.clone());
  const calls=frames;await avatar.motion.play(id,{now:time});
  const action=avatar.motion.active,side=action.clip.gesture.side,duration=(action.clip.frames.length-1)/action.clip.fps;
  assert(avatar.motion.isPortraitGesture(id));assert(!action.bounds);
  const closeUp={scale:4,x:-600,y:-300};
  assert.equal(avatar.keepMotionInViewport(closeUp,{x:0,y:0,width:390,height:700}),closeUp,'a greeting never pulls a deliberately cropped portrait into full-body view');
  let peakJump=0,previous=point('hand.'+side),peakWrist=-Infinity,peakElbow=-Infinity,minLength=Infinity,maxLength=0;
  for(let elapsed=0;elapsed<duration;elapsed+=1/60){
   time=1000+elapsed*1000;avatar.motion.update(time);
   avatar.options.bones.forEach((b,i)=>{
    assert(b.node.matrix.elements.every(Number.isFinite));
    if(!action.gesture.mask[i]){
     assert(maxDiff(b.node.matrixWorld,worlds[i])<1e-6,id+' preserves body, head, feet and opposite arm in '+(pose||'standing'));
    }
   });
   const wrist=point('hand.'+side),elbow=point('c_forearm_stretch.'+side),shoulder=point('c_arm_twist.'+side);
   peakJump=Math.max(peakJump,wrist.distanceTo(previous));previous=wrist;
   if(elapsed>1&&elapsed<duration-.9){
    peakWrist=Math.max(peakWrist,wrist.y);peakElbow=Math.max(peakElbow,elbow.y-shoulder.y);
    minLength=Math.min(minLength,wrist.distanceTo(elbow));maxLength=Math.max(maxLength,wrist.distanceTo(elbow));
   }
  }
  avatar.motion.update(1000+duration*1000+1);
  assert(!avatar.motion.active&&!avatar.options.transition);
  before.forEach((v,i)=>assert(maxDiff(v.m,avatar.options.current[i].m)<1e-9,'returns exactly to the interrupted pose'));
  assert.equal(frames,calls,'greetings never reframe the camera');
  assert(peakJump<.045,id+' smooth hand path: '+peakJump);
  assert(peakElbow<-.05,id+' elbow stays below the shoulder');
  assert(maxLength-minLength<.00001,id+' forearm does not stretch during the wave');
  assert(minLength>.22&&maxLength<.26,id+' uses the anatomical elbow, not the distal twist helper');
  report.samples.push({id,pose:pose||'standing',peakHandStep:peakJump,peakWrist,peakElbow,forearmLength:[minLength,maxLength],cameraReframes:frames-calls});
 }
 assert(!avatar.motion.clips.get('big-wave-hello').reactions.includes('greeting'),'overhead theatrical wave is an explicit choice, not a conversational greeting');
 fs.writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
 console.log('Tia greetings: two hands × standing/seated/heart, anatomical elbows, fixed body/camera, smooth paths and exact return passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
