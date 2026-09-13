/* Webcam frames are transferred here once, processed locally, then closed. */
self.exports={};
importScripts('/performer/vision.js');
const {FilesetResolver,FaceLandmarker,PoseLandmarker,HandLandmarker}=self.exports;
let face,pose,hands;
self.onmessage=async({data})=>{
 try{
  if(data.type==='init'){
   const files=await FilesetResolver.forVisionTasks('/performer');
   const base=name=>({baseOptions:{modelAssetPath:'/performer/'+name,delegate:'CPU'},runningMode:'VIDEO'});
   face=await FaceLandmarker.createFromOptions(files,{...base('face_landmarker.task'),numFaces:1,
    outputFaceBlendshapes:true,outputFacialTransformationMatrixes:true});
   if(data.body)pose=await PoseLandmarker.createFromOptions(files,{...base('pose_landmarker_lite.task'),numPoses:1});
   if(data.hands)hands=await HandLandmarker.createFromOptions(files,{...base('hand_landmarker.task'),numHands:2});
   self.postMessage({type:'ready'});return;
  }
  if(data.type!=='frame'||!face){data.image?.close();return;}
  const start=performance.now(),result=face.detectForVideo(data.image,data.at);
  const body=pose?.detectForVideo(data.image,data.at);
  const hand=hands?.detectForVideo(data.image,data.at);
  self.postMessage({type:'frame',face:!!result.faceLandmarks.length,
   facePoints:result.faceLandmarks.length?{mouth:result.faceLandmarks[0][13],left:result.faceLandmarks[0][33],right:result.faceLandmarks[0][263]}:null,
   blendshapes:Object.fromEntries((result.faceBlendshapes[0]?.categories||[]).map(c=>[c.categoryName,c.score])),
   matrix:result.facialTransformationMatrixes[0]?.data||null,
   pose:body?.worldLandmarks[0]||null,poseImage:body?.landmarks[0]||null,
   hands:hand?hand.worldLandmarks.map((world,i)=>({world,image:hand.landmarks[i]})):[],
   cost:performance.now()-start});
 }catch(error){self.postMessage({type:'error',message:String(error.message||error).slice(0,220)});}
 finally{data.image?.close();}
};
