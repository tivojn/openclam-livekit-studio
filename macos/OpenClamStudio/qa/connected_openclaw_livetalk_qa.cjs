'use strict';
const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const page=fs.readFileSync('web/index.html','utf8');
const start=page.indexOf('    const handleAgentTurnRPC =');
const end=page.indexOf('    const setLiveButton =', start);
assert.ok(start>0&&end>start);
const calls=[];
const expected=[];
const sandbox={
  performance:{now:()=>1000}, LIVE_TALK_AGENT_RPC_DEADLINE_MARGIN_MS:1000,
  trustedAgentTurnInvocation:()=>true, parseAgentTurnRequest:JSON.parse,
  waitForMatchingFinalUserTurn:async()=>true, turnController:null,
  document:{querySelector:()=>null}, selectedOpenClawAgent:()=> 'different-agent',
  claimLiveTalkRPCRequest:(ids,id)=>{ids.add(id);return true;},
  submitOpenClawTurn:async(text,agent,options)=>{calls.push({text,agent,options});return{ok:true,text:'I will wave hello.'};},
  boundedAgentTurnReply:x=>x, rememberExpectedDelegatedAssistantReply:(_s,text)=>expected.push(text),
  agentTurnRPCAnswer:(status,spoken_reply='')=>({status,spoken_reply}),
  setStatus:()=>{}, LIVE_TALK_OPENCLAW_REQUIRED_MESSAGE:'Choose OpenClaw.',
};
vm.createContext(sandbox);
vm.runInContext(page.slice(start,end)+'\nglobalThis.handle=handleAgentTurnRPC;',sandbox);
(async()=>{
  const session={connectedAgentID:'pinned-agent',replayedAgentTurnRequests:new Set()};
  const invocation={responseTimeout:300000,payload:JSON.stringify({request_id:'turn-one',spoken_request:'Hello there'})};
  const result=await sandbox.handle(session,invocation);
  assert.equal(result.status,'completed');
  assert.equal(calls[0].agent,'pinned-agent');
  assert.equal(calls[0].text,'Hello there');
  assert.equal(calls[0].options.liveAgentBridge,true);
  assert.equal(calls[0].options.userAlreadyRendered,true);
  assert.deepEqual(expected,['I will wave hello.']);
  assert.equal((await sandbox.handle(session,invocation)).status,'rejected');
  assert.equal(calls.length,1);
  sandbox.selectedOpenClawAgent=()=>'';
  assert.equal((await sandbox.handle({replayedAgentTurnRequests:new Set()},invocation)).spoken_reply,'Choose OpenClaw.');
  assert.equal(calls.length,1);
  console.log('Connected OpenClaw Live Talk: pinned route, exact transcript, single voice and replay protection passed.');
})().catch(e=>{console.error(e);process.exitCode=1;});
