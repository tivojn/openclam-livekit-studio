'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
(async()=>{
 const THREE=await import('three'),s={THREE};vm.createContext(s);
 vm.runInContext(fs.readFileSync('web/performer-rig.js','utf8').replace(/^import .*;$/gm,'').replace(/export /g,'')+';globalThis.split=splitStaticMorphGeometry;',s);
 const source=new THREE.BufferGeometry(),count=15000;
 const positions=new Float32Array(count*3),normal=new Float32Array(count*3),uv=new Uint16Array(count*2),weights=new Float32Array(count*4),bones=new Uint16Array(count*4);
 const delta=new Float32Array(count*3),normalDelta=new Float32Array(count*3);
 for(let i=0;i<count;i++){
  positions.set([i*.001,i%3,.2],i*3);normal[i*3+1]=1;uv.set([i%65535,i%1000],i*2);weights[i*4]=1;bones[i*4]=i%4;
  if(i<600)delta[i*3+2]=.03;if(i>=900&&i<930)normalDelta[i*3]=.1;
 }
 for(const [name,array,size,normalized] of [['position',positions,3,false],['normal',normal,3,false],['uv',uv,2,true],['skinWeight',weights,4,false],['skinIndex',bones,4,false]])
  source.setAttribute(name,new THREE.BufferAttribute(array,size,normalized));
 source.setIndex(Array.from({length:count},(_,i)=>i));source.addGroup(0,7500,0);source.addGroup(7500,7500,1);
 source.morphTargetsRelative=true;source.morphAttributes={position:[new THREE.BufferAttribute(delta,3)],normal:[new THREE.BufferAttribute(normalDelta,3)]};
 const split=s.split(source);assert(split);assert.ok(split.face.vertices.length<1000);
 let total=0;const triangles=[];
 for(const [name,part] of Object.entries(split)){
  const g=part.geometry;total+=g.index.count;
  for(const [key,attribute] of Object.entries(source.attributes)){
   const copied=g.attributes[key];assert.equal(copied.normalized,attribute.normalized);assert.equal(copied.array.constructor,attribute.array.constructor);
   part.vertices.forEach((v,i)=>{for(let k=0;k<attribute.itemSize;k++)assert.equal(copied.array[i*attribute.itemSize+k],attribute.array[v*attribute.itemSize+k]);});
  }
  for(const group of g.groups)for(let i=group.start;i<group.start+group.count;i+=3){
   const ids=[0,1,2].map(k=>part.vertices[g.index.getX(i+k)]);triangles.push(ids.join(',')+':'+group.materialIndex);
  }
  for(const [key,attrs] of Object.entries(source.morphAttributes))for(let t=0;t<attrs.length;t++)part.vertices.forEach((v,i)=>{
   for(let k=0;k<3;k++)assert.equal(name==='face'?g.morphAttributes[key][t].array[i*3+k]:0,attrs[t].array[v*3+k],'every morph delta, including normal-only movement, is preserved');
  });
 }
 assert.equal(total,source.index.count);assert.equal(new Set(triangles).size,count/3);
 for(let i=0;i<count;i+=3)assert.ok(triangles.includes(`${i},${i+1},${i+2}:${i<7500?0:1}`),'triangle winding and material assignment stay identical');
 source.morphTargetsRelative=false;assert.equal(s.split(source),null,'unsupported absolute targets stay unchanged');
 vm.runInContext('(function(){'+fs.readFileSync('web/performer-view.js','utf8').replace(/export /g,'')+';globalThis.budget=performerBudget;})();',s);
 assert.equal(s.budget().width,1280);assert.equal(s.budget().fps,30);assert.equal(s.budget().texturePixels,720);
 assert.equal(s.budget('eco').width,960);assert.equal(s.budget('eco').fps,24);assert.equal(s.budget('quality').textures,'quality');
 assert.equal(s.budget('unknown').textures,'balanced');
 vm.runInContext('(function(){'+fs.readFileSync('web/performer-view.js','utf8').replace(/export /g,'')+';globalThis.preferences=performerPreferences;})();',s);
 const prefs=s.preferences({quality:'eco',framing:'full',hands:true,body:false,mirror:true,outfit:'dress',yaw:500,pitch:-90,expressionStrength:1.8,mouthStrength:2.1,
  cameraActive:true,device:'private-id',landmarks:[1,2],frames:'video'});
 assert.equal(prefs.quality,'eco');assert.equal(prefs.hands,true);assert.equal(prefs.outfit,'dress');assert.equal(prefs.expressionStrength,'1.8');
 assert.equal(prefs.yaw,180);assert.equal(prefs.pitch,-60);
 for(const key of ['cameraActive','device','landmarks','frames'])assert.equal(key in prefs,false,'only presentation preferences can persist');
 assert.equal(Object.keys(s.preferences({quality:'invalid',hands:'yes',yaw:NaN,pitch:Infinity,expressionStrength:9,outfit:'x'.repeat(129)})).length,0,'invalid saved values cannot corrupt output or enable camera capture');
 vm.runInContext('(function(){'+fs.readFileSync('web/performer-view.js','utf8').replace(/export /g,'')+';globalThis.tracked=hasPerformerTracking;})();',s);
 assert.equal(s.tracked({face:false,pose:null,hands:[]}),false,'empty detector heartbeats can rest the renderer');
 assert.equal(s.tracked({face:true}),true,'face return wakes rendering immediately');
 const body=Array.from({length:33},()=>({visibility:.1}));body[13].visibility=.9;
 assert.equal(s.tracked({face:false,pose:body,hands:[]}),true,'an arm remains animated when the face is turned away');
 body[13].visibility=.2;
 assert.equal(s.tracked({face:false,pose:body,hands:[]}),false,'low-confidence body guesses cannot keep an absent performer rendering');
 assert.equal(s.tracked({face:false,hands:[{world:Array(21).fill({x:0,y:0,z:0})}]}),true,'visible hands keep rendering even with an occluded face');
 console.log('Performer rendering QA passed: exact geometry/morph/skin/UV preservation, material groups, normal-only deformation, safe fallback and output budgets.');
})().catch(e=>{console.error(e);process.exitCode=1;});
