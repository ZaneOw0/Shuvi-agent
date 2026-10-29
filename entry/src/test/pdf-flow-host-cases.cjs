'use strict';
const assert=require('node:assert/strict');
exports.cases=h=>{
 const D=h.load('domain/DocumentParseModels'),P=h.load('domain/ParsedDocumentModels');
 const {DocumentParseService}=h.load('application/DocumentParseService');let seq=0;
 async function session(){
  let saved=new D.DocumentParseSnapshot();saved.originals.push(Object.assign(new D.DocumentOriginal(),{id:'pdf-local',assetId:'original-pdf-local',hash:'a'.repeat(64),bytes:100,title:'synthetic.pdf',pages:0,preflightReason:'历史PDFKit加载失败'}));
  const calls={verify:0,network:0};let badHash=false;
  const service=new DocumentParseService({status:async()=>D.DocumentCredentialStatus.Configured,clearTransient(){}},{open:async()=>{},close:async()=>{},load:async()=>D.documentCopySnapshot(saved),save:async s=>{saved=D.documentCopySnapshot(s);}});
  service.attachSourceProtection({withSource:async(_id,fn)=>fn(),assertCleanup:async()=>{},assertDeletable:async()=>{}});
  service.attachLocal({select:async()=>new D.DocumentFileSelection()},{verify:async()=>{calls.verify++;if(badHash)throw new D.DocumentParseFailure('原件摘要或长度不符','上传前');},cancelLocal(){}});
  service.attachRemote({allocate:async a=>{calls.network++;await a.onAllocation('batch-pdf');return {batchId:'batch-pdf',leaseId:'lease-upload'};},upload:async a=>{calls.network++;await a.onUploadStarting();a.task.uploadRequestStarted=true;a.task.uploadBytes=100;},inspect:async a=>{calls.network++;return Object.assign(new D.DocumentInspection(),{batchId:a.task.batchId,dataId:a.task.dataId,state:D.DocumentRemoteState.Done,resultLease:'lease-result'});},receive:async a=>{calls.network++;return Object.assign(new D.DocumentParseResultEnvelope(),{assetId:'result-pdf',taskId:a.task.id,dataId:a.task.dataId,originalHash:a.original.hash,version:a.original.version,bytes:100,hash:'b'.repeat(64),completeTransport:true,signature:true});},removeLeases:async()=>{},pause(){}},{id:()=>`pdf-flow-${++seq}`,now:()=>1000,sleep:async()=>{}});
  await service.initialize();return {service,calls,saved:()=>saved,badHash:()=>{badHash=true;}};
 }
 async function grant(s){await s.service.confirm('pdf-local',Object.assign(new D.DocumentTestAcknowledgement(),{fullFile:true,embeddedImages:true,nonSensitive:true,privacyUnknown:true,freeEligible:true}));await s.service.setEnabled(true);}
 return [
  ['pdf_removed_preflight_old_blocked_zero_pages_reaches_controlled_pipeline',async()=>{const s=await session();await grant(s);await s.service.submit('pdf-local');assert.equal(s.calls.network,4,s.service.state.message);assert.equal(s.calls.verify,1);assert.equal(s.saved().tasks[0].stage,D.DocumentParseStage.Received);assert.equal(s.saved().originals[0].pages,0);assert.equal(s.saved().originals[0].preflight,D.DocumentPreflightStatus.Blocked);}],
  ['pdf_removed_preflight_still_requires_consent_credential_and_size_budget',async()=>{for(const mode of ['consent','credential','size']){const s=await session();if(mode!=='consent')await grant(s);if(mode==='credential')s.service.state.credential=D.DocumentCredentialStatus.Missing;if(mode==='size')s.service.state.snapshot.originals[0].bytes=20971521;await assert.rejects(s.service.submit('pdf-local'));assert.equal(s.calls.network,0);assert.equal(s.saved().tasks.length,0);}}],
  ['pdf_removed_preflight_still_verifies_original_hash_before_request',async()=>{const s=await session();await grant(s);s.badHash();await s.service.submit('pdf-local');assert.equal(s.calls.network,0);assert.equal(s.calls.verify,1);assert(s.service.state.message.includes('摘要'));}],
  ['pdf_detail_submits_without_rechecking_and_preserves_rejection_message',async()=>{
   const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),view=new ParsedDocumentView(),o=Object.assign(new D.DocumentOriginal(),{id:'pdf-message',hash:'a'.repeat(64),preflightReason:'历史PDFKit失败'}),state=new D.DocumentParseViewState();state.snapshot.originals=[o];let confirmations=0;
   view.alive=true;view.service={state:new P.ParsedImportState()};view.parse={viewState:()=>state,confirm:async()=>{confirmations++;},setEnabled:async()=>{},submit:async()=>{state.message='凭据不可用，未发送请求';}};view.originals=[o];view.selectedOriginal=o.id;view.parseConsent=o.id;view.fullFile=true;view.freeEligible=true;await view.requestParse();assert.equal(confirmations,1);assert.equal(view.message,state.message);assert.equal(view.selectedStatus(),'文件已保存在本机，可开始解析');assert.equal(view.localBusy,false);
  }],
  ['pdf_detail_retains_cloud_failure_and_no_result',async()=>{const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),view=new ParsedDocumentView();view.originals=[Object.assign(new D.DocumentOriginal(),{id:'pdf-failed'})];view.selectedOriginal='pdf-failed';view.tasks=[Object.assign(new D.DocumentParseTask(),{originalId:'pdf-failed',stage:D.DocumentParseStage.RemoteFailed,failure:'InvalidPdf'})];assert(view.selectedStatus().includes('没有完成'));assert.equal(view.selectedResult(),undefined);}]
 ];
};
