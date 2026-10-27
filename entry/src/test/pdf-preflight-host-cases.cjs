'use strict';
const assert=require('node:assert/strict');
exports.cases=h=>{
  const D=h.load('domain/DocumentParseModels');
  const {DocumentParseService}=h.load('application/DocumentParseService');
  let sequence=0;
  async function session(mode='') {
    let saved=new D.DocumentParseSnapshot();const original=new D.DocumentOriginal();Object.assign(original,{id:'pdf-local',assetId:'original-pdf-local',title:'synthetic.pdf',hash:'a'.repeat(64),bytes:100,preflightReason:'PDFKit不可用或加载失败；原件保留，外发阻止'});saved.originals.push(original);
    const calls={verify:0,preflight:0,network:0};let fail=mode;
    const repo={open:async()=>{},close:async()=>{},load:async()=>D.documentCopySnapshot(saved),save:async s=>{if(fail==='save')throw Error('SyntheticDiskFailure');saved=D.documentCopySnapshot(s);}};
    const service=new DocumentParseService({status:async()=>D.DocumentCredentialStatus.Configured,clearTransient(){}},repo);
    service.attachSourceProtection({withSource:async(_id,action)=>action(),assertCleanup:async()=>{},assertDeletable:async()=>{}});
    service.attachLocal({select:async()=>new D.DocumentFileSelection()},{verify:async()=>{calls.verify++;if(fail==='hash')throw new D.DocumentParseFailure('原件摘要或长度不符','上传前复核');},cancelLocal(){}},{inspect:async o=>{calls.preflight++;o.pages=3;o.preflight=D.DocumentPreflightStatus.Passed;o.preflightReason='';if(fail==='native'){o.pages=0;o.preflight=D.DocumentPreflightStatus.Blocked;o.preflightReason='PDFKit文档加载失败 [parse=2]';}return o;},cancelLocal(){}});
    service.attachRemote({allocate:async a=>{calls.network++;await a.onAllocation('batch-pdf');return {batchId:'batch-pdf',leaseId:'lease-upload'};},upload:async a=>{calls.network++;await a.onUploadStarting();a.task.uploadRequestStarted=true;a.task.uploadBytes=100;},inspect:async a=>{calls.network++;return Object.assign(new D.DocumentInspection(),{batchId:a.task.batchId,dataId:a.task.dataId,state:D.DocumentRemoteState.Done,resultLease:'lease-result'});},receive:async a=>{calls.network++;return Object.assign(new D.DocumentParseResultEnvelope(),{assetId:'result-pdf',taskId:a.task.id,dataId:a.task.dataId,originalHash:a.original.hash,version:a.original.version,bytes:100,hash:'b'.repeat(64),completeTransport:true,signature:true});},removeLeases:async()=>{},pause(){}},{id:()=>`pdf-probe-${++sequence}`,now:()=>1000,sleep:async()=>{}});
    await service.initialize();return {service,calls,saved:()=>saved,fail:v=>{fail=v;}};
  }
  return [
    ['pdf_detail_preflight_failure_stops_before_consent_and_shows_reason',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),P=h.load('domain/ParsedDocumentModels');const view=new ParsedDocumentView(),original=Object.assign(new D.DocumentOriginal(),{id:'blocked-pdf',format:D.DocumentParseFormat.Pdf,preflightReason:'PDFKit文档加载失败 [parse=2]'});let confirmations=0,submissions=0;const state=new D.DocumentParseViewState();state.snapshot.originals=[original];state.message=original.preflightReason;
      view.alive=true;view.service={state:new P.ParsedImportState()};view.parse={viewState:()=>state,retryPdfPreflight:async()=>{throw new D.DocumentParseFailure(original.preflightReason,'PDF预检');},confirm:async()=>{confirmations++;},submit:async()=>{submissions++;}};view.originals=[original];view.selectedOriginal=original.id;view.parseConsent=original.id;view.fullFile=true;view.freeEligible=true;await view.requestParse();assert.equal(confirmations,0);assert.equal(submissions,0);assert(view.message.includes('parse=2'));assert(view.selectedStatus().includes('加载失败'));assert.equal(view.selectedResult(),undefined);assert.equal(view.localBusy,false);
    }],
    ['pdf_detail_submission_no_request_message_is_not_lost_on_refresh',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),P=h.load('domain/ParsedDocumentModels');const view=new ParsedDocumentView(),original=Object.assign(new D.DocumentOriginal(),{id:'pdf-message',hash:'a'.repeat(64),format:D.DocumentParseFormat.Pdf});const state=new D.DocumentParseViewState();state.snapshot.originals=[original];let preflights=0;
      view.alive=true;view.service={state:new P.ParsedImportState()};view.parse={viewState:()=>state,retryPdfPreflight:async()=>{preflights++;},confirm:async()=>{},setEnabled:async()=>{},submit:async()=>{state.message='凭据不可用，未发送请求';}};view.originals=[original];view.selectedOriginal=original.id;view.parseConsent=original.id;view.fullFile=true;view.freeEligible=true;await view.requestParse();assert.equal(preflights,1);assert.equal(view.message,state.message);assert.equal(view.localBusy,false);
    }],
    ['pdf_detail_local_recheck_updates_stored_original_and_stays_offline',async()=>{
      const {ParsedDocumentView}=h.load('ui/ParsedDocumentView'),P=h.load('domain/ParsedDocumentModels');const s=await session(),view=new ParsedDocumentView();view.alive=true;view.service={state:new P.ParsedImportState()};view.parse=s.service;view.selectedOriginal='pdf-local';await view.retryPdfPreflight();assert(view.message.includes('预检通过'));assert.equal(view.originals[0].pages,3);assert.equal(s.calls.network,0);assert.equal(view.localBusy,false);
    }],
    ['pdf_preflight_worker_success_codes_and_native_failures',async()=>{
      const state={capability:true,encrypted:false,parse:0,pages:3,throwAt:'',release:false};const calls=[];
      h.kits.set('@kit.PDFKit',{pdfService:{ParseResult:{PARSE_SUCCESS:0},PdfDocument:class {
        constructor(){calls.push('construct');if(state.throwAt==='construct')throw {code:801};}
        isEncrypted(){if(state.throwAt==='encrypted')throw {code:77};return state.encrypted;}
        loadDocument(...args){calls.push('load');assert.equal(args.length,2,'native callback must not invoke taskpool APIs');if(state.throwAt==='load')throw {code:88};return state.parse;}
        getPageCount(){return state.pages;}
        releaseDocument(){calls.push('release');if(state.release)throw {code:99};}
      }}});
      const previous=global.canIUse;global.canIUse=()=>state.capability;
      try {
        const worker=h.load('infra/DocumentPdfWorker').documentPdfCountWorker;
        assert.deepEqual(worker('synthetic',Date.now()+10000),[1,3,0,4,0,0]);
        state.parse=2;assert.equal(worker('synthetic',Date.now()+10000)[0],4);state.parse=0;
        state.encrypted=true;assert.equal(worker('synthetic',Date.now()+10000)[0],3);state.encrypted=false;
        state.pages=51;assert.equal(worker('synthetic',Date.now()+10000)[0],5);state.pages=3;
        state.throwAt='construct';assert.equal(worker('synthetic',Date.now()+10000)[4],801);state.throwAt='load';assert.equal(worker('synthetic',Date.now()+10000)[4],88);state.throwAt='';
        state.release=true;assert.equal(worker('synthetic',Date.now()+10000)[0],9);state.release=false;
        assert.equal(worker('synthetic',0)[0],7);state.capability=false;const before=calls.length;assert.equal(worker('synthetic',Date.now()+10000)[0],2);assert.equal(calls.length,before);
      } finally {global.canIUse=previous;}
    }],
    ['pdf_preflight_failure_receipts_are_distinct_and_validated',async()=>{
      const reason=h.load('infra/DocumentPdfPreflight').documentPdfPreflightReason;
      for(const [code,text] of [[2,'核心能力'],[3,'加密'],[4,'加载失败'],[5,'1–50'],[6,'取消'],[7,'超时'],[8,'异常'],[9,'释放']])assert(reason([code,0,2,3,88,0]).includes(text));
      assert(reason([]).includes('不合法'));assert(reason([1,2,0,3,0,NaN]).includes('不合法'));
    }],
    ['pdf_preflight_adapter_rechecks_old_reason_and_validates_file_signature',async()=>{
      const previous=global.canIUse;global.canIUse=()=>true;
      try {const {DocumentPdfPreflight}=h.load('infra/DocumentPdfPreflight'),root='/synthetic-pdf-preflight',file=root+'/knowledge_parse_v1/original-facade';const bytes=Buffer.from('%PDF-1.4\nsynthetic');h.memoryFiles.set(file,bytes);const original=Object.assign(new D.DocumentOriginal(),{id:'facade',assetId:'original-facade',bytes:bytes.length,preflightReason:'PDFKit不可用或加载失败；原件保留，外发阻止'});const port=new DocumentPdfPreflight(root);await port.inspect(original,new D.DocumentParseCancellation());assert.equal(original.pages,3);assert.equal(original.preflight,D.DocumentPreflightStatus.Passed);assert.equal(original.preflightReason,'');h.memoryFiles.set(file,Buffer.from('not a PDF header'));await assert.rejects(port.inspect(original,new D.DocumentParseCancellation()),e=>e instanceof D.DocumentParseFailure&&e.category.includes('签名'));}
      finally {global.canIUse=previous;}
    }],
    ['pdf_preflight_adapter_records_missing_capability_without_fake_pages',async()=>{
      const previous=global.canIUse;global.canIUse=()=>false;
      try {const {DocumentPdfPreflight}=h.load('infra/DocumentPdfPreflight'),root='/synthetic-pdf-unavailable',bytes=Buffer.from('%PDF-1.4\nsynthetic');h.memoryFiles.set(root+'/knowledge_parse_v1/original-unavailable',bytes);const original=Object.assign(new D.DocumentOriginal(),{id:'unavailable',assetId:'original-unavailable',bytes:bytes.length,pages:3});await new DocumentPdfPreflight(root).inspect(original,new D.DocumentParseCancellation());assert.equal(original.pages,0);assert.equal(original.preflight,D.DocumentPreflightStatus.Blocked);assert(original.preflightReason.includes('核心能力'));}
      finally {global.canIUse=previous;}
    }],
    ['pdf_old_blocked_preflight_recovers_locally_without_grants_or_egress',async()=>{
      const s=await session();await s.service.retryPdfPreflight('pdf-local');const original=s.saved().originals[0];assert.equal(original.pages,3);assert.equal(original.preflight,D.DocumentPreflightStatus.Passed);assert.equal(original.preflightReason,'');assert.equal(s.saved().grants.length,0);assert.equal(s.saved().tasks.length,0);assert.deepEqual(s.calls,{verify:1,preflight:1,network:0});assert.equal(s.saved().config.enabled,false);
    }],
    ['pdf_preflight_native_hash_and_save_failure_block_and_throw',async()=>{
      for(const mode of ['native','hash','save']) {const s=await session();s.fail(mode);await assert.rejects(s.service.retryPdfPreflight('pdf-local'),e=>e instanceof D.DocumentParseFailure);assert.equal(s.service.state.busy,false);assert.equal(s.service.state.snapshot.originals[0].preflight,D.DocumentPreflightStatus.Blocked);assert.equal(s.service.state.snapshot.originals[0].pages,0);assert.equal(s.calls.network,0);assert.equal(s.service.state.snapshot.tasks.length,0);}
    }],
    ['pdf_submit_rejection_throws_visible_reason_without_creating_task',async()=>{
      const s=await session();await assert.rejects(s.service.submit('pdf-local'),e=>e instanceof D.DocumentParseFailure);assert(s.service.state.message.length>0);assert.equal(s.calls.network,0);assert.equal(s.service.state.snapshot.tasks.length,0);
    }],
    ['pdf_recovered_preflight_enters_real_service_task_pipeline_with_controlled_transport',async()=>{
      const s=await session();await s.service.retryPdfPreflight('pdf-local');const ack=Object.assign(new D.DocumentTestAcknowledgement(),{fullFile:true,embeddedImages:true,nonSensitive:true,privacyUnknown:true,freeEligible:true});await s.service.confirm('pdf-local',ack);await s.service.setEnabled(true);await s.service.submit('pdf-local');assert.equal(s.calls.network,4);assert.equal(s.saved().tasks[0].stage,D.DocumentParseStage.Received);assert.equal(s.saved().results.length,1);
    }]
  ];
};
