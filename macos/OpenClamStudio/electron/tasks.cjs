'use strict';
class TaskWindow {
  constructor({BrowserWindow,ipcMain,dialog,shell,path,baseUrl,showChat}){
    Object.assign(this,{BrowserWindow,path,baseUrl});this.window=null;
    ipcMain.handle('openclam:tasks-folder',async event=>{
      if(!this.owns(event.sender,event.senderFrame))return null;
      const result=await dialog.showOpenDialog(this.window,{title:'Choose a project for OpenClam',properties:['openDirectory','createDirectory']});
      return result.canceled?null:result.filePaths[0]||null;
    });
    ipcMain.handle('openclam:tasks-chat',event=>{
      if(this.owns(event.sender,event.senderFrame))showChat();
    });
    ipcMain.handle('openclam:tasks-link',(event,value)=>{
      if(!this.owns(event.sender,event.senderFrame)||typeof value!=='string'||value.length>4096)return;
      try{
        const url=new URL(value);if(url.username||url.password)return;
        if(url.protocol==='https:')return shell.openExternal(url.href);
        if(url.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(url.hostname)){
          // Generated local apps get a separate, temporary browser session:
          // no Studio auth header, preload, node access, or shared cookies.
          const preview=new this.BrowserWindow({width:1100,height:760,title:'OpenClam · Preview',
            webPreferences:{partition:'openclam-preview-'+Date.now(),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true}});
          preview.webContents.setWindowOpenHandler(()=>({action:'deny'}));
          preview.webContents.on('will-navigate',(event,target)=>{try{if(new URL(target).origin!==url.origin)event.preventDefault();}catch{event.preventDefault();}});
          preview.loadURL(url.href);
        }
      }catch{}
    });
  }
  owns(sender,frame){
    if(!this.window||this.window.isDestroyed()||this.window.webContents!==sender||frame!==sender.mainFrame)return false;
    try{const url=new URL(frame.url);return url.origin===this.baseUrl()&&url.pathname==='/tasks';}catch{return false;}
  }
  open(){
    if(this.window&&!this.window.isDestroyed()){this.window.show();this.window.focus();return;}
    const w=new this.BrowserWindow({width:1320,height:850,minWidth:750,minHeight:560,show:false,title:'OpenClam · Tasks',
      webPreferences:{preload:this.path.join(__dirname,'tasks-preload.cjs'),contextIsolation:true,nodeIntegration:false,sandbox:true,webSecurity:true}});
    this.window=w;w.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    w.webContents.on('will-navigate',event=>event.preventDefault());
    w.on('page-title-updated',event=>event.preventDefault());
    w.on('closed',()=>{this.window=null;});
    w.once('ready-to-show',()=>w.show());w.loadURL(this.baseUrl()+'/tasks');
  }
}
module.exports={TaskWindow};
