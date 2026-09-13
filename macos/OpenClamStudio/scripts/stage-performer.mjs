import {copyFileSync, mkdirSync, readFileSync, writeFileSync, existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {dirname, join} from 'node:path';
const root=join(dirname(fileURLToPath(import.meta.url)),'..');
const dest=join(root,'web/vendor/performer');
mkdirSync(dest,{recursive:true});
const pkg=join(root,'node_modules/@mediapipe/tasks-vision');
const version=JSON.parse(readFileSync(join(pkg,'package.json'))).version;
if(version!=='0.10.22-rc.20250304')throw Error('Unreviewed MediaPipe runtime');
// Classic worker uses the published CommonJS bundle through an exports shim.
// No CDN, dynamic code evaluation, or Node integration in the renderer.
copyFileSync(join(pkg,'vision_bundle.cjs'),join(dest,'vision.js'));
for(const name of ['vision_wasm_internal.js','vision_wasm_internal.wasm',
  'vision_wasm_nosimd_internal.js','vision_wasm_nosimd_internal.wasm'])
  copyFileSync(join(pkg,'wasm',name),join(dest,name));
const models=[
 ['face_landmarker.task','face_landmarker/face_landmarker','64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff'],
 ['pose_landmarker_lite.task','pose_landmarker/pose_landmarker_lite','59929e1d1ee95287735ddd833b19cf4ac46d29bc7afddbbf6753c459690d574a'],
 ['hand_landmarker.task','hand_landmarker/hand_landmarker','fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1'],
];
const hash=data=>createHash('sha256').update(data).digest('hex');
for(const [name,remote,digest] of models){
 const target=join(dest,name),existing=name==='face_landmarker.task'?join(root,'.electron-models',name):target;
 let data=existsSync(existing)?readFileSync(existing):null;
 if(!data||hash(data)!==digest){
  const response=await fetch(`https://storage.googleapis.com/mediapipe-models/${remote}/float16/1/${name}`);
  if(!response.ok)throw Error(`Could not download ${name}`);
  data=Buffer.from(await response.arrayBuffer());
 }
 if(hash(data)!==digest)throw Error(`Invalid checksum: ${name}`);
 writeFileSync(target,data);
}
copyFileSync(join(root,'.electron-models/LICENSE.Apache-2.0.txt'),join(dest,'LICENSE.txt'));
writeFileSync(join(dest,'manifest.json'),JSON.stringify({version,models:models.map(([file,,sha256])=>({file,sha256}))},null,2)+'\n');
console.log('Offline Performer tracking runtime and three verified models staged.');
