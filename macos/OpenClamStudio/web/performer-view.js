const finite=n=>Number.isFinite(Number(n))?Number(n):0;
const clamp=(n,a,b)=>Math.max(a,Math.min(b,finite(n)));
export function performerBudget(mode='balanced'){
 if(mode==='eco')return {width:960,height:540,fps:24,textures:'eco',texturePixels:960};
 return {width:1280,height:720,fps:30,textures:mode==='quality'?'quality':'balanced',texturePixels:720};
}
export function cameraAngles(yaw=0,pitch=0){
 return {yaw:((finite(yaw)+180)%360+360)%360-180,
  pitch:clamp(pitch,-60,60)};
}
export function dragCamera(start,dx,dy,mirrored=false){
 return cameraAngles(start.yaw-dx*.35*(mirrored?-1:1),start.pitch+dy*.25);
}
export function framePerformerCamera(camera,{top,bottom,aspect=16/9,yaw=0,pitch=0}){
 const angles=cameraAngles(yaw,pitch),radians=Math.PI/180;
 const distance=(top-bottom)/2/Math.tan(camera.fov*radians/2),center=(top+bottom)/2;
 const y=angles.yaw*radians,p=angles.pitch*radians;
 camera.clearViewOffset();camera.aspect=aspect;
 camera.position.set(Math.sin(y)*Math.cos(p)*distance,center+Math.sin(p)*distance,Math.cos(y)*Math.cos(p)*distance);
 camera.lookAt(0,center,0);camera.updateProjectionMatrix();
 return {distance,center,...angles};
}

// Only presentation preferences are persisted. Camera access and live capture
// always start off, and no landmarks, video frames, or device IDs are stored.
export const preferenceKey='openclam-performer-settings';
// Empty detector results are heartbeat packets, not new animated poses.
// A turned-away face can still have a visible body or hands: keep those live.
export function hasPerformerTracking(frame){
 return frame?.face===true||Boolean(frame?.hands?.some(hand=>hand.world?.length>=21))
  ||[11,12,13,14,15,16].some(i=>Number(frame?.pose?.[i]?.visibility)>=.5);
}
export const preferenceChoices={
 quality:['balanced','eco','quality'],framing:['bust','waist','full'],background:['dark','light','green'],
 smoothing:['80','45','140'],gaze:['.65','.35','0'],blinkSensitivity:['1','.8','1.2'],
 expressionStrength:['1','1.4','1.8'],mouthStrength:['1','1.65','2.1'],
};
export function performerPreferences(value){
 const result={};if(!value||typeof value!=='object')return result;
 for(const [key,choices] of Object.entries(preferenceChoices))
  if(choices.includes(String(value[key])))result[key]=String(value[key]);
 for(const key of ['body','hands','mirror'])if(typeof value[key]==='boolean')result[key]=value[key];
 for(const [key,limit] of [['yaw',180],['pitch',60]])
  if(typeof value[key]==='number'&&Number.isFinite(value[key]))result[key]=Math.max(-limit,Math.min(limit,value[key]));
 if(typeof value.outfit==='string'&&value.outfit.length<=128)result.outfit=value.outfit;
 return result;
}
