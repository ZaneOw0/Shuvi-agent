'use strict';
const assert=require('node:assert/strict');
exports.cases=h=>{
  const dm=h.load('domain/DocumentParseModels');
  const original=()=>Object.assign(new dm.DocumentOriginal(),{id:'ordinary-docx',assetId:'original-ordinary',title:'ordinary.docx',hash:'d'.repeat(64),bytes:100,format:dm.DocumentParseFormat.Docx,preflight:dm.DocumentPreflightStatus.Passed});
  const session=async()=>{
    const {DocumentParseService}=h.load('application/DocumentParseService');let saved=new dm.DocumentParseSnapshot(),calls={post:0,put:0,query:0,zip:0};let seq=0;
    saved.originals=[original()];saved.config.enabled=true;saved.config.credentialRevision=3;
    const repo={open:async()=>{},load:async()=>dm.documentCopySnapshot(saved),save:async s=>{saved=dm.documentCopySnapshot(s);},close:async()=>{}};
    const service=new DocumentParseService({status:async()=>dm.DocumentCredentialStatus.Configured,clearTransient(){},save:async()=>dm.DocumentCredentialStatus.Configured,remove:async()=>dm.DocumentCredentialStatus.Missing},repo);
    service.attachLocal({select:async()=>new dm.DocumentFileSelection(),selectDocx:async()=>new dm.DocumentFileSelection()},{verify:async()=>{},cancelLocal(){},remove:async()=>{}},{inspect:async o=>o,cancelLocal(){}});
    service.attachRemote({allocate:async action=>{calls.post++;await action.onAllocation('docx-batch');return {batchId:'docx-batch',leaseId:'lease-docx'};},upload:async action=>{await action.onUploadStarting();calls.put++;action.task.uploadRequestStarted=true;},inspect:async action=>{calls.query++;return Object.assign(new dm.DocumentInspection(),{batchId:action.task.batchId,dataId:action.task.dataId,state:dm.DocumentRemoteState.Done,resultLease:'lease-result'});},receive:async action=>{calls.zip++;return Object.assign(new dm.DocumentParseResultEnvelope(),{assetId:'result-docx',taskId:action.task.id,dataId:action.task.dataId,originalHash:action.original.hash,version:1,bytes:100,hash:'e'.repeat(64),completeTransport:true,signature:true});},removeLeases:async()=>{},reconcileLeases:async()=>{},pause(){}},{id:()=>`docx-${++seq}`,now:()=>1000,sleep:async()=>{}});
    await service.initialize();return {service,calls,repo,snapshot:()=>saved};
  };
  exports.session=session;
  return [
    ['us3-docx-purpose-is-distinct',async()=>{assert.equal(h.load('domain/EmbeddingModels').EmbeddingPurpose.DocxCorpus,'DocxCorpus');assert.notEqual(h.load('domain/EmbeddingModels').EmbeddingPurpose.DocxCorpus,h.load('domain/EmbeddingModels').EmbeddingPurpose.Corpus);}],
    ['us3-direct-real-chinese-ascii-repeat-ranges',async()=>{const models=h.load('domain/KnowledgeSearchModels'),policy=h.load('pipeline/KnowledgeMatchPolicy'),query=h.load('pipeline/QueryPreparation');const hit=Object.assign(new models.KnowledgeHit(),{sourceKind:models.KnowledgeSourceKind.Docx,text:'中文 Alpha ALPHA 中文'});for(const q of ['中文','alpha','中文 Alpha']){const match=policy.knowledgeMatch(hit,query.prepareTextQuery(q),false);assert.equal(match.kind,'Direct');assert(match.ranges.every(r=>r.start<r.end&&r.end<=hit.text.length));}assert.equal(policy.knowledgeMatch(hit,query.prepareTextQuery('absent'),true).kind,'Unclassified');}],
    ['us1-denied-fullfile-free-zero-request',async()=>{const s=await session();await assert.rejects(s.service.confirmDocx('ordinary-docx',false,true));await assert.rejects(s.service.confirmDocx('ordinary-docx',true,false));await s.service.submit('ordinary-docx');assert.deepEqual(s.calls,{post:0,put:0,query:0,zip:0});}],
    ['us1-ordinary-permit-not-nonsensitive-ledger-received',async()=>{const s=await session();await s.service.confirmDocx('ordinary-docx',true,true);const g=s.snapshot().grants.at(-1);assert.equal(g.policy,dm.DocxParsePermit.policy);assert.equal(g.acknowledgement.nonSensitive,false);await s.service.submit('ordinary-docx');assert.deepEqual(s.calls,{post:1,put:1,query:1,zip:1});assert.equal(s.snapshot().tasks[0].stage,dm.DocumentParseStage.Received);assert.equal(s.snapshot().docxPermits[0].usage.download,1);await s.service.submit('ordinary-docx');await s.service.resume(s.snapshot().tasks[0].id,true);assert.deepEqual(s.calls,{post:1,put:1,query:1,zip:1});}],
    ['us1-config-drift-revokes-current-grant',async()=>{const s=await session();await s.service.confirmDocx('ordinary-docx',true,true);s.service.state.snapshot.config.credentialRevision++;await s.service.submit('ordinary-docx');assert.equal(s.calls.post,0);}],
    ['us1-copy-permit-usage-is-independent',async()=>{const s=await session();await s.service.confirmDocx('ordinary-docx',true,true);const copied=dm.documentCopySnapshot(s.snapshot());copied.docxPermits[0].usage.query=80;assert.equal(s.snapshot().docxPermits[0].usage.query,0);}]
  ];
};
