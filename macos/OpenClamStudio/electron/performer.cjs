'use strict';
// Only the two owned documents can exchange bounded tracking coefficients.
// Camera frames stay in the controller's local worker, never cross IPC.
class PerformerWindows {
 constructor({BrowserWindow,ipcMain,path,baseUrl,enter,leave}){
  Object.assign(this,{BrowserWindow,path,baseUrl,enter,leave});
  this.controls=null;this.output=null;this.closing=false;this.settings=null;
  ipcMain.on('openclam:performer-data',(event,data)=>{
   const source=event.sender;
   if(!this.owns(source)||!data||typeof data!=='object')return;
   let length;try{length=JSON.stringify(data).length;}catch{return;}
   if(length>32000)return;
   if(source===this.controls?.webContents){
    if(!['frame','settings','reset','stop'].includes(data.type))return;
    if(data.type==='settings')this.settings=data;
    this.post(this.output,data);
   }else if(data.type==='view'){
    if(!Number.isFinite(data.yaw)||!Number.isFinite(data.pitch))return;
    const view={yaw:Math.max(-180,Math.min(180,data.yaw)),pitch:Math.max(-60,Math.min(60,data.pitch))};
    this.settings={...this.settings,type:'settings',...view};
    this.post(this.controls,{type:'view',...view});
   }else if(['ready','status'].includes(data.type)){
    if(data.type==='ready'&&this.settings)this.post(this.output,this.settings);
    this.post(this.controls,data);
   }
  });
  ipcMain.on('openclam:performer-command',(event,value)=>{
   if(!this.owns(event.sender))return;
   if(value==='exit')this.close();
   if(value==='output'){this.output?.show();this.output?.focus();}
   if(value==='controls'){this.controls?.show();this.controls?.focus();}
  });
 }
 get active(){return !!this.controls&&!this.controls.isDestroyed();}
 owns(sender){return [this.controls,this.output].some(w=>w&&!w.isDestroyed()&&w.webContents===sender);}
 post(w,data){if(w&&!w.isDestroyed())w.webContents.send('openclam:performer-data',data);}
 open(){
  if(this.active){this.controls.show();this.controls.focus();return;}
  this.enter();this.settings=null;
  const create=(role,options)=>{
   const w=new this.BrowserWindow({...options,show:false,backgroundColor:'#18202a',
    title:role==='output'?'Tia · OBS Output':'Tia · Performer',
    webPreferences:{preload:this.path.join(__dirname,'performer-preload.cjs'),contextIsolation:true,
     nodeIntegration:false,sandbox:true,webSecurity:true,backgroundThrottling:false}});
   w.webContents.setWindowOpenHandler(()=>({action:'deny'}));
   w.webContents.on('will-navigate',event=>event.preventDefault());
   w.on('page-title-updated',event=>event.preventDefault());
   w.on('close',event=>{if(!this.closing){event.preventDefault();this.close();}});
   w.webContents.on('render-process-gone',()=>this.close());
   w.once('ready-to-show',()=>{if(!w.isDestroyed())w.show();});
   w.loadURL(`${this.baseUrl()}/performer?role=${role}`);
   return w;
  };
  this.output=create('output',{width:960,height:580,minWidth:640,minHeight:390,useContentSize:true});
  this.controls=create('controls',{width:430,height:780,minWidth:400,minHeight:620});
 }
 close(restore=true){
  if(this.closing||!this.controls&&!this.output)return;
  this.closing=true;
  // Destroying the capture renderer also closes camera tracks and its worker,
  // including a pending permission prompt or an unresponsive script.
  for(const w of [this.controls,this.output])if(w&&!w.isDestroyed())w.destroy();
  this.controls=this.output=null;this.settings=null;this.closing=false;
  if(restore)this.leave();
 }
}
module.exports={PerformerWindows};
