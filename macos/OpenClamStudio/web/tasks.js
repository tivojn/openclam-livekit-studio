'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const state = {task:null,tasks:[],models:[],items:new Map(),requests:new Map(),events:null,cwd:'',tab:'files',diff:'',attachments:[],selection:0};
  const el = (tag, text, className) => {const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(className)node.className=className;return node;};
  let settingsSave=Promise.resolve(), settingsBusy=false;
  const permissionHelp={ask:'May edit project files. Asks you before additional access.',autoReview:'May edit project files. Codex reviews requests for additional access and may approve or deny them.',alwaysAllow:'No approval prompts for project work. Writes outside the project and blocked network access stay restricted.',fullAccess:'May modify files across this Mac and access the network without approval prompts.',readOnly:'Starts with read-only access. Asks you before additional access.'};
  const active = () => ['starting','running','waiting'].includes(state.task?.status);
  const label = value => ({inProgress:'Working',running:'Working',starting:'Starting',waiting:'Needs your input',completed:'Completed',interrupted:'Stopped',failed:'Failed',idle:'Ready'}[value] || value || 'Ready');
  function error(value){let message=value?.message||String(value);try{const data=JSON.parse(message);message=data.error?.message||data.message||message;}catch{}$('notice').textContent=message;$('notice').hidden=false;}
  async function api(path,body){
    const response=await fetch('/api/agent'+path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(!response.ok){const data=await response.json().catch(()=>({}));throw new Error(typeof data.detail==='string'?data.detail:'The request could not be completed.');}
    return response.json();
  }
  const taskPath = suffix => '/tasks/'+state.task.id+(suffix||'');
  function efforts(selected=$('effort').value){
    const model=state.models.find(m=>m.model===$('model').value||m.id===$('model').value)||(!$('model').value&&state.models.find(m=>m.isDefault));
    $('model').title=model?.description||'Choose a model from the connected engine catalog.';
    $('effort').replaceChildren(new Option(model?.defaultReasoningEffort?'Default · '+model.defaultReasoningEffort:'Default effort',''));
    for(const item of model?.supportedReasoningEfforts||[])$('effort').add(new Option(item.reasoningEffort,item.reasoningEffort));
    if([...$('effort').options].some(o=>o.value===selected))$('effort').value=selected;
  }
  function selectModel(value){
    if(value&&![...$('model').options].some(o=>o.value===value))$('model').add(new Option(value+' · saved model',value));
    $('model').value=value||'';
  }
  async function connect(){
    $('account').textContent='Connecting to Codex…';
    try{
      const data=await api('/status');state.models=data.models;state.tasks=data.tasks;
      $('account').textContent=data.connected?'Codex connected · '+(data.accountType==='chatgpt'?'ChatGPT account':data.accountType):'Sign in to Codex in OpenClam Settings, then reconnect.';
      const selection=state.task?.model||$('model').value;
      $('model').replaceChildren(new Option('Default model',''));
      const additional=el('optgroup');additional.label='Additional engine models';
      for(const model of data.models){const option=new Option(model.displayName||model.model||model.id,model.model||model.id);option.title=model.description||'';if(model.hidden)additional.append(option);else $('model').add(option);}
      if(additional.children.length)$('model').append(additional);
      $('account').textContent+=' · '+data.models.length+' models';
      const defaultModel=data.models.find(m=>m.isDefault);if(defaultModel)$('model').options[0].textContent='Default · '+defaultModel.displayName;
      selectModel(selection);
      efforts();renderList();
    }catch(e){$('account').textContent='Codex unavailable';error(e);}
  }
  function renderList(){
    $('taskList').replaceChildren();
    for(const task of state.tasks.filter(t=>$('showArchived').checked||!t.archived)){
      const b=el('button',undefined,task.id===state.task?.id?'selected':'');
      b.append(el('strong',task.title),el('small',(task.archived?'Archived · ':'')+label(task.status)));
      b.onclick=()=>openTask(task.id).catch(error);$('taskList').append(b);
    }
  }
  async function refreshList(){const data=await api('/tasks');state.tasks=data.tasks;renderList();}
  function controls(){
    $('title').textContent=state.task?.title||'What would you like to do?';
    $('folder').textContent=state.task?.cwd||state.cwd||'Choose a project, or start with a fresh workspace.';
    $('folder').title=$('folder').textContent;
    $('state').textContent=label(state.task?.status);
    $('stop').hidden=!active();$('send').textContent=active()?'Send follow-up ↑':state.task?'Continue ↑':'Start task ↑';
    $('send').disabled=!!state.task?.archived||settingsBusy;$('chooseFolder').disabled=!!state.task;
    $('access').disabled=active()||settingsBusy;$('model').disabled=active()||settingsBusy;$('effort').disabled=active()||settingsBusy;
    $('archive').hidden=!state.task;$('rename').hidden=!state.task;
    $('archive').textContent=state.task?.archived?'Restore':'Archive';
    $('review').disabled=!state.task||active();
    $('composerHint').textContent=active()?'Follow-ups steer the current task. Closing this window keeps it running.':(permissionHelp[$('access').value]||permissionHelp.ask);
    $('access').title=permissionHelp[$('access').value]||permissionHelp.ask;
  }
  function snapshot(data){
    state.cursor=data.cursor||0;
    state.task=data.task;state.items=new Map(data.items.map(i=>[i.id,i]));state.requests=new Map(data.requests.map(r=>[r.id,r]));
    $('welcome').hidden=true;$('activity').hidden=false;selectModel(data.task.model);$('access').value=data.task.permission||'ask';efforts(data.task.effort||'');
    renderItems();renderRequests();controls();
  }
  async function openTask(id){
    const selection=++state.selection;
    if(state.task?.id!==id){state.attachments=[];$('attachments').replaceChildren();}
    state.events?.close();state.events=null;state.diff='';$('notice').hidden=true;
    const data=await api('/tasks/'+id);if(selection!==state.selection)return;
    snapshot(data);renderList();inspect().catch(error);
    const stream=new EventSource('/api/agent/tasks/'+id+'/events');state.events=stream;
    stream.onmessage=event=>{
      if(state.task?.id!==id)return;
      const data=JSON.parse(event.data);
      if(data.type==='snapshot'){snapshot(data);return;}
      const cursor=Number(event.lastEventId)||0;if(cursor&&cursor<=state.cursor)return;if(cursor)state.cursor=cursor;
      if(data.type==='settings'){state.task=data.task;selectModel(data.task.model);$('access').value=data.task.permission;efforts(data.task.effort||'');controls();return;}
      if(data.type==='history/replaced'){openTask(id).catch(error);return;}
      if(data.type==='item'){state.items.set(data.item.id,data.item);renderItems();}
      if(data.type==='delta'){
        const item=state.items.get(data.id)||{id:data.id,type:data.itemType};
        item[data.field]=((item[data.field]||'')+data.delta).slice(-64000);state.items.set(data.id,item);renderItems();
      }
      if(data.type==='request'){state.requests.set(data.request.id,data.request);state.task.status='waiting';renderRequests();controls();}
      if(data.type==='resolved'){state.requests.delete(data.id);renderRequests();}
      if(data.type==='status'){
        state.task.status=data.status;if(!active()){state.requests.clear();renderRequests();}
        controls();refreshList().catch(error);if(!active())inspect().catch(error);
        if(data.error)error(data.error.message||JSON.stringify(data.error));if(data.message)error(data.message);
      }
      if(data.type==='turn/diff/updated'){state.diff=data.params.diff||'';if(state.tab==='changes')renderChanges();}
      if(data.type==='turn/plan/updated'){
        state.items.set('plan',{id:'plan',type:'plan',plan:data.params.plan});renderItems();
      }
      if(data.type==='error'&&!data.params.willRetry)error(data.params.error?.message||'The agent reported an error.');
    };
    stream.onerror=()=>{$('state').textContent='Reconnecting…';};
  }
  function itemText(item){
    if(item.type==='userMessage')return (item.content||[]).map(c=>c.text||c.path||c.url||'').join('\n');
    if(item.type==='agentMessage')return item.text||'';
    if(item.type==='plan')return (item.plan||[]).map(p=>(p.status==='completed'?'✓ ':p.status==='inProgress'?'◉ ':'○ ')+p.step).join('\n');
    return '';
  }
  function formatted(text){
    const fragment=document.createDocumentFragment();
    const pattern=/```[^\n]*\n([\s\S]*?)```|\[([^\]]+)\]\((<[^>]+>|[^)]+)\)|\*\*([^*]+)\*\*|`([^`]+)`/g;
    let offset=0,match;
    while((match=pattern.exec(text))){
      fragment.append(document.createTextNode(text.slice(offset,match.index)));
      if(match[1]!==undefined)fragment.append(el('pre',match[1]));
      else if(match[2]!==undefined){
        const target=match[3].replace(/^<|>$/g,'');const a=el('a',match[2]);a.href='#';
        a.onclick=e=>{e.preventDefault();if(/^https?:\/\//.test(target))window.openclamTasks?.openLink(target);else if(!/^[a-z]+:/i.test(target))preview(state.task.id,target.replace(/:\d+$/,'')).catch(error);};fragment.append(a);
      }else fragment.append(el(match[4]!==undefined?'strong':'code',match[4]??match[5]));
      offset=pattern.lastIndex;
    }
    fragment.append(document.createTextNode(text.slice(offset)));return fragment;
  }
  function renderItems(){
    const container=$('activity');const stick=container.scrollHeight-container.scrollTop-container.clientHeight<100;
    const existing=new Map([...container.children].map(n=>[n.dataset.id,n]));
    for(const item of state.items.values()){
      let node=existing.get(item.id);if(!node){node=el('article',undefined,'item '+item.type);node.dataset.id=item.id;container.append(node);}
      existing.delete(item.id);
      if(['userMessage','agentMessage','plan'].includes(item.type)){const text=itemText(item);if(node._text!==text){node._text=text;if(item.type==='agentMessage')node.replaceChildren(formatted(text));else node.textContent=text;}continue;}
      let detail=node.querySelector('details');if(!detail){detail=el('details');detail.append(el('summary'),el('pre'));node.append(detail);}
      const titles={commandExecution:'Command',fileChange:'File changes',webSearch:'Web search',mcpToolCall:'Connected tool',imageGeneration:'Image generation',enteredReviewMode:'Review started',exitedReviewMode:'Review finished',contextCompaction:'Conversation compacted',collabAgentToolCall:'Agent collaboration'};
      detail.querySelector('summary').textContent=(titles[item.type]||item.type)+' · '+(item.command||item.tool||item.query||label(item.status)).slice(0,180);
      const output=item.aggregatedOutput||item.result||item.changes||item.action||item;
      detail.querySelector('pre').textContent=typeof output==='string'?output:JSON.stringify(output,null,2);
    }
    for(const node of existing.values())node.remove();
    if(stick)container.scrollTop=container.scrollHeight;
  }
  function renderRequests(){
    $('requests').replaceChildren();
    for(const request of state.requests.values()){
      const box=el('div',undefined,'request');const p=request.params;const isQuestion=request.method==='item/tool/requestUserInput';
      box.append(el('strong',isQuestion?'The agent needs your input':'Approval needed'));
      if(p.reason||p.message)box.append(el('p',p.reason||p.message));
      const inputs={};
      if(isQuestion){
        for(const q of p.questions||[]){
          const l=el('label',q.question);const input=el('input');input.maxLength=12000;inputs[q.id]=input;l.append(input);
          for(const option of q.options||[]){const b=el('button',option.label);b.title=option.description||'';b.onclick=()=>{input.value=option.label;};l.append(b);}
          box.append(l);
        }
      }else{
        box.append(el('pre',p.command||JSON.stringify(p.permissions||p.networkApprovalContext||{directory:p.cwd,root:p.grantRoot},null,2)));
        if(request.method==='item/fileChange/requestApproval'){
          const item=state.items.get(p.itemId);if(item?.changes)box.append(el('pre',JSON.stringify(item.changes,null,2)));
        }
      }
      const submit=async decision=>{
        const id=state.task.id;const answers=isQuestion?Object.fromEntries(Object.entries(inputs).map(([k,v])=>[k,v.value])):null;
        try{const data=await api('/tasks/'+id+'/requests/'+request.id,{decision,answers});if(state.task?.id===id)snapshot(data);}catch(e){error(e);}
      };
      let choices=isQuestion?[['Send answer','']]:request.method==='mcpServer/elicitation/request'?[['Decline','decline']]:[['Allow once','accept'],['Allow for this session','acceptForSession'],['Decline','decline']];
      if(!isQuestion&&Array.isArray(p.availableDecisions)&&request.method!=='item/permissions/requestApproval')choices=choices.filter(([,decision])=>p.availableDecisions.includes(decision));
      for(const [name,decision] of choices){const b=el('button',name);b.onclick=()=>submit(decision);box.append(b);}
      $('requests').append(box);
    }
  }
  async function send(event){
    event?.preventDefault();const prompt=$('prompt').value.trim();if(!prompt)return;
    let identity=state.task?.id;const selection=state.selection;
    const options={cwd:state.cwd,model:$('model').value||null,effort:$('effort').value||null,permission:$('access').value};
    const attachments=state.attachments.map(a=>a.handle);
    $('notice').hidden=true;$('send').disabled=true;
    try{
      await settingsSave;
      if(!identity){const data=await api('/tasks',options);identity=data.task.id;if(selection===state.selection)await openTask(identity);}
      const result=await api('/tasks/'+identity+'/send',{prompt,model:options.model,effort:options.effort,permission:options.permission,attachments});
      if(state.task?.id===identity){snapshot(result);if($('prompt').value.trim()===prompt)$('prompt').value='';state.attachments=[];$('attachments').replaceChildren();}await refreshList();
    }catch(e){error(e);}finally{controls();}
  }
  function newTask(){$('access').value='ask';state.selection++;state.events?.close();state.events=null;state.task=null;state.cwd='';state.items.clear();state.requests.clear();state.diff='';state.attachments=[];$('attachments').replaceChildren();$('prompt').value='';$('activity').replaceChildren();$('activity').hidden=true;$('requests').replaceChildren();$('welcome').hidden=false;$('notice').hidden=true;$('details').replaceChildren(el('p','Choose a task to inspect its files.'));controls();renderList();$('prompt').focus();}
  async function action(action,title=''){if(!state.task)return;const id=state.task.id;const data=await api('/tasks/'+id+'/action',{action,title});if(state.task?.id===id)snapshot(data);await refreshList();}
  async function inspect(path=''){
    for(const tab of ['files','changes','tools'])$(tab+'Tab').classList.toggle('selected',state.tab===tab);
    if(!state.task)return;
    if(state.tab==='changes'){renderChanges();return;}
    const id=state.task.id;const container=$('details');container.replaceChildren(el('p','Loading…'));
    if(state.tab==='files'){
      const data=await api('/tasks/'+id+'/files?path='+encodeURIComponent(path));if(state.task?.id!==id)return;container.replaceChildren();
      if(path){const b=el('button','← Parent folder');b.onclick=()=>inspect(path.split('/').slice(0,-1).join('/')).catch(error);container.append(b);}
      for(const file of data.files){const b=el('button',(file.directory?'▸ ':'')+file.name);b.onclick=()=>file.directory?inspect(file.path).catch(error):preview(id,file.path).catch(error);container.append(b);}
      if(!data.files.length)container.append(el('p','No visible files yet.'));
    }else{
      const data=await api('/tasks/'+id+'/capabilities');if(state.task?.id!==id)return;container.replaceChildren();
      container.append(el('h3','Available skills'),el('p','Mention $skill-name in your message to use a skill.'));
      for(const group of data.skills.data||[])for(const skill of group.skills||[]){const b=el('button',skill.name);b.title=skill.description||'';b.onclick=()=>{$('prompt').value+='$'+skill.name+' ';$('prompt').focus();};container.append(b);}
      if(data.skills.error)container.append(el('p',data.skills.error));
      container.append(el('h3','Connected tools'));
      for(const server of data.connections.data||[])container.append(el('p',(server.name||server.serverName||'MCP server')+' · '+Object.keys(server.tools||{}).length+' tools'));
      if(data.connections.error)container.append(el('p',data.connections.error));
      container.append(el('p','Uses skills and MCP connections configured in Codex. OpenClaw remains available in Chat.'));
    }
  }
  function renderChanges(){
    const container=$('details');container.replaceChildren();
    if(state.diff){container.append(el('pre',state.diff));return;}
    let count=0;for(const item of state.items.values())if(item.type==='fileChange'){count++;for(const change of item.changes||[]){container.append(el('h3',change.path),el('pre',change.diff||JSON.stringify(change.kind)));}}
    if(!count)container.append(el('p','No file changes in this task yet.'));
  }
  async function preview(id,path){
    const response=await fetch('/api/agent/tasks/'+id+'/file?path='+encodeURIComponent(path));
    if(!response.ok)throw new Error((await response.json()).detail||'Unable to open file.');
    const blob=await response.blob();
    $('htmlPreview').hidden=true;$('htmlPreview').srcdoc='';$('previewText').hidden=false;
    if(/\.html?$/i.test(path)){
      $('previewTitle').textContent=path;$('previewText').hidden=true;$('htmlPreview').hidden=false;
      $('htmlPreview').srcdoc='<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; img-src data: blob:; connect-src \'none\'; form-action \'none\';">'+await blob.text();
      $('preview').showModal();return;
    }
    if(/\.(txt|md|csv|json|js|mjs|cjs|ts|tsx|jsx|py|html|css|yml|yaml|toml|swift|rs|go|sh|xml|sql|log)$/i.test(path)){
      $('previewTitle').textContent=path;$('previewText').textContent=await blob.text();$('preview').showModal();
    }else{const url=URL.createObjectURL(blob);const a=el('a');a.href=url;a.download=path.split('/').pop();a.click();setTimeout(()=>URL.revokeObjectURL(url),30000);}
  }
  $('composer').onsubmit=send;$('prompt').onkeydown=e=>{if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();send();}};
  function saveSettings(){
    controls();if(!state.task)return;
    const id=state.task.id;const settings={model:$('model').value,effort:$('effort').value,permission:$('access').value};
    settingsBusy=true;controls();
    settingsSave=api('/tasks/'+id+'/settings',settings).then(data=>{if(state.task?.id===id)state.task=data.task;}).catch(e=>{error(e);if(state.task?.id===id){selectModel(state.task.model);$('access').value=state.task.permission;efforts(state.task.effort||'');}}).finally(()=>{settingsBusy=false;controls();});
  }
  $('newTask').onclick=newTask;$('model').onchange=()=>{efforts('');saveSettings();};$('effort').onchange=saveSettings;$('access').onchange=saveSettings;$('reconnect').onclick=connect;$('showArchived').onchange=renderList;
  $('stop').onclick=()=>action('stop').catch(error);$('archive').onclick=()=>action(state.task.archived?'restore':'archive').catch(error);
  $('rename').onclick=()=>{$('renameValue').value=state.task?.title||'';$('renameDialog').showModal();$('renameValue').focus();};
  $('renameForm').onsubmit=async event=>{event.preventDefault();try{await action('rename',$('renameValue').value);$('renameDialog').close();}catch(e){error(e);}};
  $('cancelRename').onclick=()=>$('renameDialog').close();
  $('review').onclick=()=>action('review').catch(error);
  const branch=el('button','Branch conversation');branch.onclick=async()=>{try{if(!state.task)return;const data=await api(taskPath('/action'),{action:'fork'});await openTask(data.task.id);await refreshList();}catch(e){error(e);}};$('inspector').insertBefore(branch,$('details'));
  const attach=el('button','Attach files');attach.type='button';attach.onclick=()=>$('fileInput').click();document.querySelector('.composer-controls').insertBefore(attach,$('access'));
  $('fileInput').onchange=async()=>{
    try{
      const files=[...$('fileInput').files];
      if(files.length+state.attachments.length>8||files.some(f=>f.size>20*1024*1024))throw new Error('Attach up to eight files, each below 20 MB.');
      if(!state.task){const data=await api('/tasks',{cwd:state.cwd,model:$('model').value||null,effort:$('effort').value||null,permission:$('access').value});await openTask(data.task.id);await refreshList();}
      const id=state.task.id;
      for(const file of files){
        const form=new FormData();form.append('file',file);
        const response=await fetch('/api/agent/tasks/'+id+'/attachments',{method:'POST',body:form});
        if(!response.ok)throw new Error((await response.json()).detail||'Attachment failed.');
        const attachment=await response.json();
        if(state.task?.id===id){state.attachments.push(attachment);const b=el('button',attachment.name+' ×');b.onclick=()=>{state.attachments=state.attachments.filter(a=>a.handle!==attachment.handle);b.remove();};$('attachments').append(b);}
      }
    }catch(e){error(e);}finally{$('fileInput').value='';}
  };
  $('closePreview').onclick=()=>{$('preview').close();$('htmlPreview').srcdoc='';};
  $('backChat').onclick=()=>window.openclamTasks?.showChat();
  $('chooseFolder').onclick=async()=>{try{const cwd=await window.openclamTasks?.chooseFolder();if(cwd){state.cwd=cwd;controls();}else if(!window.openclamTasks)error('Open Tasks from the OpenClam desktop app to choose a folder.');}catch(e){error(e);}};
  for(const tab of ['files','changes','tools'])$(tab+'Tab').onclick=()=>{state.tab=tab;inspect().catch(error);};
  for(const b of document.querySelectorAll('[data-prompt]'))b.onclick=()=>{$('prompt').value=b.dataset.prompt;$('prompt').focus();};
  window.addEventListener('beforeunload',()=>state.events?.close());
  controls();connect();
})();
