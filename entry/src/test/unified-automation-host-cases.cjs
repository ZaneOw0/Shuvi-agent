'use strict';
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const fixture=require('./unified-fixtures.cjs');
const fs=require('node:fs'),path=require('node:path');
exports.cases=h=>{
  const P=h.load('pipeline/VisionPolicy');
  const M=h.load('domain/ParsedDocumentModels');
  const U=h.load('domain/UnifiedKnowledgeModels');
  const E=h.load('domain/EmbeddingModels');
  const {KnowledgeStoreHost}=h.load('infra/KnowledgeStoreHost'),{KnowledgeStorageScope}=h.load('domain/KnowledgeStorageScope'),{TextChannel}=h.load('domain/TextKnowledgeModels');
  const {ParsedDocumentRepository}=h.load('infra/ParsedDocumentRepository'),{ParsedDocumentAssets}=h.load('infra/ParsedDocumentAssets'),{KnowledgeDerivedBudget}=h.load('infra/KnowledgeDerivedBudget');
  const {ParsedDocumentAdapters}=h.load('infra/ParsedDocumentAdapters'),{ParsedDocumentIngestionService}=h.load('application/ParsedDocumentIngestionService'),{ParsedImportRequest}=h.load('domain/ParsedDocumentPorts');
  const {ImageKnowledgeService}=h.load('application/ImageKnowledgeService'),{UnifiedVectorRepository}=h.load('infra/UnifiedVectorRepository'),{UnifiedEmbeddingService}=h.load('application/UnifiedEmbeddingService'),{UnifiedProcessingQueue}=h.load('application/UnifiedProcessingQueue'),{UnifiedSettingsService}=h.load('application/UnifiedSettingsService');
  let serial=12000;
  async function session(options={}){
    const key=(++serial).toString(16).padStart(16,'0'),scope=KnowledgeStorageScope.isolated(key),ctx={filesDir:'/us2-'+key+'/files',cacheDir:'/us2-'+key+'/cache',databaseDir:'/us2-'+key+'/db'};
    const host=KnowledgeStoreHost.forContext(ctx,scope);await host.acquireM1(async()=>TextChannel.Like);host.requireUnifiedProtection();const repo=new ParsedDocumentRepository(host,h.identity);repo.attachPhysicalBudget(new KnowledgeDerivedBudget(ctx,scope));await repo.open();
    const assets=new ParsedDocumentAssets(ctx.filesDir,ctx.cacheDir,scope,repo,h.identity,'us2');repo.attachPublicationVerifier(assets);const ingestion=new ParsedDocumentIngestionService(repo,assets,h.identity);
    let visual=0,corpus=0;const vectorRows=new Map(),spaces=new Map();
    const numeric={open:async()=>{},register:async s=>{spaces.set(s.id,s);},put:async row=>{vectorRows.set(row.spaceId+'|'+row.chunkId+'|'+row.vectorGeneration,{...row,values:new Float32Array(row.values)});},read:async(s,c,g)=>vectorRows.get(s+'|'+c+'|'+g),synchronizeUnified:async(s,owner,content,g,epoch)=>{for(const r of vectorRows.values())if(r.spaceId===s&&r.documentId===owner){r.eligible=r.contentGeneration===content&&r.vectorGeneration===g;r.epoch=epoch;}}};
    const config=new E.EmbeddingConfig();config.modelId='BAAI/bge-m3';config.revision=1;config.credentialRevision=1;const configPort={currentConfig:()=>config};
    const counter={unifiedEvidence:async(_cfg,text,textHash)=>{const b=h.load('domain/EmbeddingBasisModels').EmbeddingPinnedBasis;return Object.assign(new E.TokenEligibilityEvidence(),{policyVersion:U.UNIFIED_TEXT_POLICY,profileBoundProven:true,localState:'SafeUnderPinnedProfile',upperBound:100,contextLimit:8192,profileId:b.profile,profileRevision:b.revision,tokenizerSha256:b.tokenizer,evidenceVersion:b.evidence,provenance:'ModelScopePublicSnapshot;FixedTokenizerJson;EnumeratedCharsmap',modelId:config.modelId,role:'document',bindingHash:hash('binding'+text),textHash});}};
    const visionPort={describe:async(req,bytes,cancel,admit)=>{assert.equal(hash(bytes),req.imageHash);await admit(()=>{visual++;});if(options.visionAuthFailure)throw new (h.load('domain/VisionModels').VisionFailure)('Http:401','auth',true);if(options.visionError)throw Error('SyntheticUnknown');if(options.visionWait)await options.visionWait();return P.visionDecode(vision('{"description":"合成图形描述","tags":["图形","删除标签"]}'));}};
    const embeddingPort={embedUnifiedCorpus:async(cfg,text,proof,cancel,admit)=>{if(options.beforeEmbedding)await options.beforeEmbedding(repo);await admit(()=>{corpus++;});if(options.embeddingWait)await options.embeddingWait();if(options.embeddingFailAt===corpus)throw Error('SyntheticUnknown');const r=new E.EmbeddingVectorResponse();r.model=cfg.modelId;r.index=0;r.vector=new Float32Array([1,text.length+1,0.5]);return r;}};
    const imageService=new ImageKnowledgeService(repo,assets,repo,h.identity,visionPort),vectors=new UnifiedVectorRepository(repo,numeric,h.identity),embedding=new UnifiedEmbeddingService(repo,vectors,counter,embeddingPort,configPort,h.identity),queue=new UnifiedProcessingQueue(repo,repo,assets,h.identity,imageService,embedding);
    const credentials={status:async()=>({present:true,failure:''}),save:async()=>{},remove:async()=>{}};const settings=new UnifiedSettingsService(repo,credentials,configPort,queue);
    ingestion.attachPublished(async d=>queue.enqueue(d));
    async function importDoc(id='doc',body='正文\n\n![图](images/a.png)') {const r=new ParsedImportRequest();Object.assign(r,{namespace:'Import',sourceId:id,sourceHash:hash('src'+id),title:id,format:M.ParsedFormat.Pdf,parserSignature:'fixture',engine:'synthetic',outputIdentity:'result-'+id});const a=new ParsedDocumentAdapters(h.identity);a.setOutput(body,undefined,'fixture-output');a.addImage('images/a.png',new Uint8Array(fixture.png()),M.ParsedProvenance.Derived);await ingestion.ingest(r,a);return ingestion.state.document;}
    return {repo,assets,ingestion,queue,settings,imageService,vectors,embedding,config,configPort,importDoc,counts:()=>({visual,corpus}),vectorRows,spaces,numeric};
  }
  function configService(s) {
    const {EmbeddingService,copyEmbeddingConfig}=h.load('application/EmbeddingService');
    let persisted=copyEmbeddingConfig(s.config);let saves=0,revocations=0;
    const metadata={configs:async()=>[copyEmbeddingConfig(persisted)],saveConfig:async c=>{saves++;persisted=copyEmbeddingConfig(c);},revokeGrants:async()=>{revocations++;}};
    const credential={status:async()=>E.EmbeddingCredentialStatus.Configured,clearTransient:()=>{},save:async()=>E.EmbeddingCredentialStatus.Configured,remove:async()=>E.EmbeddingCredentialStatus.Missing};
    const service=new EmbeddingService(metadata,credential,{cancel:()=>{}},h.identity);service.state.config=copyEmbeddingConfig(persisted);
    s.configPort.currentConfig=()=>service.state.config;service.attachConfigInvalidation(()=>s.settings.invalidateEmbedding());
    return {service,counts:()=>({saves,revocations}),copyEmbeddingConfig};
  }
  const vision=(content,finish='stop',usage)=>JSON.stringify({id:'synthetic-response',object:'chat.completion',model:'deepseek-flash',choices:[{index:0,finish_reason:finish,message:{role:'assistant',content}}],...(usage?{usage}:{})});
  return [
    ['embedding_entry_async_load_keeps_loading_until_service_ready',async()=>{
      const source=fs.readFileSync(path.resolve(__dirname,'../main/ets/pages/Index.ets'),'utf8');const start=source.indexOf('  private async openEmbedding()'),end=source.indexOf('  private async preparePdf',start);assert(start>0&&end>start);
      const ts=require(path.join(process.env.DEVECO_SDK_HOME,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));const Module=require('node:module');const loaded=new Module(__filename,module);let release;const gate=new Promise(r=>release=r);const service={};loaded.assembly={forContext:()=>({acquire:()=>gate,repository:{ready:()=>true},embedding:service})};
      loaded._compile('const KnowledgeAssembly=module.assembly;const Edge={Top:0};'+ts.transpileModule('class EmbeddingEntryProbe {\n'+source.slice(start,end)+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText+'\nmodule.exports=EmbeddingEntryProbe;',__filename+'.entry-probe');
      const view=new loaded.exports();view.scroller={scrollEdge(){}};view.getUIContext=()=>({getHostContext:()=>({})});const pending=view.openEmbedding();assert.equal(view.embeddingOpening,true);assert.equal(view.embeddingService,undefined);await view.openEmbedding();release();await pending;assert.equal(view.embeddingOpening,false);assert.equal(view.embeddingService,service);assert(source.includes('if (this.embeddingOpening) {'));
    }],
    ['embedding_entry_failed_load_releases_loading_and_can_retry',async()=>{
      const source=fs.readFileSync(path.resolve(__dirname,'../main/ets/pages/Index.ets'),'utf8'),start=source.indexOf('  private async openEmbedding()'),end=source.indexOf('  private async preparePdf',start);const ts=require(path.join(process.env.DEVECO_SDK_HOME,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));const Module=require('node:module'),loaded=new Module(__filename,module);let fail=true;const service={};loaded.assembly={forContext:()=>({acquire:async()=>{if(fail)throw Error('SyntheticLoadFailure');},repository:{ready:()=>true},embedding:service})};
      loaded._compile('const KnowledgeAssembly=module.assembly;const Edge={Top:0};'+ts.transpileModule('class EmbeddingEntryProbe {\n'+source.slice(start,end)+'\n}',{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText+'\nmodule.exports=EmbeddingEntryProbe;',__filename+'.entry-failure-probe');const view=new loaded.exports();view.scroller={scrollEdge(){}};view.getUIContext=()=>({getHostContext:()=>({})});await view.openEmbedding();assert.equal(view.embeddingOpening,false);assert.equal(view.sharedKnowledge,undefined);assert.equal(view.embeddingService,undefined);fail=false;await view.openEmbedding();assert.equal(view.embeddingService,service);assert.equal(view.embeddingOpening,false);
    }],
    ['mid_job_config_change_preserves_received_vectors_and_uses_new_generation',async()=>{
      let changed=false;const s=await session({beforeEmbedding:async()=>{if(!changed&&s.counts().corpus===1){changed=true;s.config.revision++;}}});await s.settings.enableEmbedding(true,true,true);await s.importDoc('mid-job-config','第一段\n\n第二段');await s.queue.drain();
      const original=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(original.completed,1);assert.equal(original.state,'AwaitingConfig');assert.equal(s.counts().corpus,1);const retained=[...s.vectorRows.values()].filter(r=>r.vectorGeneration===original.id);assert.equal(retained.length,1);
      await s.settings.enableEmbedding(true,true,true);await s.queue.drain();const jobs=await s.repo.jobs();assert.equal(jobs.find(j=>j.id===original.id).state,'Canceled');assert(jobs.some(j=>j.id!==original.id&&j.stage==='BodyEmbedding'&&j.state==='Complete'&&j.completed===2));assert.equal(s.counts().corpus,3);assert.equal([...s.vectorRows.values()].filter(r=>r.vectorGeneration===original.id).length,1);
    }],
    ['failed_consent_invalidation_prevents_configuration_and_credential_write',async()=>{
      const s=await session(),c=configService(s);c.service.attachConfigInvalidation(async()=>{throw Error('SyntheticConsentStoreFailure');});const before=c.copyEmbeddingConfig(c.service.state.config);const next=c.copyEmbeddingConfig(before);next.modelSource=E.EmbeddingModelSource.Remote;
      await c.service.saveConfiguration(next);await c.service.changeCredential('synthetic-not-a-key',true);assert.deepEqual(c.service.state.config,before);assert.deepEqual(c.counts(),{saves:0,revocations:0});assert.equal(s.counts().corpus,0);
    }],
    ['embedding_settings_ui_exposes_stale_binding_and_clears_old_checks',async()=>{
      const s=await session(),c=configService(s);await s.settings.enableEmbedding(true,true,true);
      const {EmbeddingSettingsView}=h.load('ui/EmbeddingSettingsView');const view=new EmbeddingSettingsView();view.service=c.service;view.unifiedSettings=s.settings;view.changed();await view.refreshUnified();assert.equal(view.unifiedOn,true);
      view.unifiedCost=true;view.unifiedBaseline=true;await c.service.changeCredential('synthetic-not-a-key',true);view.changed();await view.refreshUnified();assert.equal(view.unifiedOn,false);assert.equal(view.unifiedNeedsConfirmation,true);assert.equal(view.unifiedCost,false);assert.equal(view.unifiedBaseline,false);assert.equal(s.counts().corpus,0);
      view.unifiedCost=true;view.unifiedBaseline=true;await view.saveUnified();assert.equal(view.unifiedOn,true);assert.equal(view.unifiedNeedsConfirmation,false);
    }],
    ['identical_config_save_preserves_binding_revision_and_consent',async()=>{
      const s=await session(),c=configService(s);await s.settings.enableEmbedding(true,true,true);const before=await s.settings.setting('Embedding');
      await c.service.saveConfiguration(c.copyEmbeddingConfig(c.service.state.config));
      assert.equal(c.service.state.config.revision,1);assert.deepEqual(c.counts(),{saves:0,revocations:0});assert.deepEqual(await s.settings.setting('Embedding'),before);assert.equal(s.counts().corpus,0);
    }],
    ['config_change_invalidates_before_save_and_reconfirmation_resumes_no_send_job',async()=>{
      const s=await session(),c=configService(s);s.queue.background();await s.settings.enableEmbedding(true,true,true);await s.importDoc('config-change','正文一\n\n正文二');
      const input=c.copyEmbeddingConfig(c.service.state.config);input.modelSource=E.EmbeddingModelSource.Remote;await c.service.saveConfiguration(input);
      const setting=await s.settings.setting('Embedding');assert.equal(setting.enabled,false);assert.equal(setting.baselineAccepted,false);assert.equal(setting.costAcknowledged,false);assert.equal(c.service.state.config.revision,2);
      let job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.state,'AwaitingConfig');assert.equal(job.failure,'UnifiedConfigChanged');assert.equal(job.inputs.length,2);assert.equal(s.counts().corpus,0);
      await assert.rejects(s.settings.enableEmbedding(true,false,true));assert.equal((await s.settings.setting('Embedding')).configBinding,setting.configBinding);
      await s.settings.enableEmbedding(true,true,true);s.queue.resumeForeground();await s.queue.drain();job=(await s.repo.jobs()).find(j=>j.id===job.id);assert.equal(job.state,'Complete');assert.equal(job.completed,2);assert.equal(s.counts().corpus,2);
      assert.equal((await s.settings.setting('Embedding')).configBinding,h.load('pipeline/EmbeddingBasisPolicy').embeddingConfigBinding(c.service.state.config));
    }],
    ['credential_update_invalidates_consent_and_binds_only_after_confirmation',async()=>{
      const s=await session(),c=configService(s);await s.settings.enableEmbedding(true,true,true);const old=await s.settings.setting('Embedding');
      await c.service.changeCredential('synthetic-not-a-key',true);assert.equal(c.service.state.config.credentialRevision,2);assert.equal(c.service.state.config.mutationPending,false);
      const invalid=await s.settings.setting('Embedding');assert.equal(invalid.enabled,false);assert.equal(invalid.configBinding,old.configBinding);assert.equal(invalid.credentialRevision,1);assert.equal(s.counts().corpus,0);
      await s.settings.enableEmbedding(true,true,true);assert.equal((await s.settings.setting('Embedding')).credentialRevision,2);
    }],
    ['restart_reconciles_legacy_failed_config_without_cloud_or_input_rewrite',async()=>{
      const s=await session();s.queue.background();await s.settings.enableEmbedding(true,true,true);await s.importDoc('old-config','正文');let job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');
      job.state='Failed';job.failure='UnifiedConfigOrExpectedSet';await s.repo.saveJob(job);const frozen=JSON.stringify(job.inputs);s.config.revision=6;s.config.credentialRevision=2;
      await s.settings.reconcileEmbeddingConfig();await s.queue.initialize();await s.queue.drain();job=(await s.repo.jobs()).find(j=>j.id===job.id);assert.equal(job.state,'AwaitingConfig');assert.equal(JSON.stringify(job.inputs),frozen);assert.equal((await s.repo.attempts(job.id)).length,0);assert.equal(s.counts().corpus,0);
      await s.settings.enableEmbedding(true,true,true);await s.queue.drain();assert.equal((await s.repo.jobs()).find(j=>j.id===job.id).state,'Complete');assert.equal(s.counts().corpus,1);
    }],
    ['reconfirmation_preserves_unknown_and_other_failures_without_resending',async()=>{
      const s=await session({embeddingFailAt:1});await s.settings.enableEmbedding(true,true,true);await s.importDoc('unknown-config','正文');await s.queue.drain();const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.state,'Unknown');
      s.config.revision++;await s.settings.reconcileEmbeddingConfig();await s.settings.enableEmbedding(true,true,true);await s.queue.drain();assert.equal((await s.repo.jobs()).find(j=>j.id===job.id).state,'Unknown');assert.equal(s.counts().corpus,1);
      job.state='Failed';job.failure='ActualInputHash';await s.repo.saveJob(job);await s.settings.enableEmbedding(true,true,true);await s.queue.drain();assert.equal((await s.repo.jobs()).find(j=>j.id===job.id).state,'Failed');assert.equal(s.counts().corpus,1);
    }],
    ['config_and_expected_set_failures_are_distinct_and_zero_send',async()=>{
      const s=await session();s.queue.background();await s.settings.enableEmbedding(true,true,true);await s.importDoc('invalid-set','正文');const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');
      job.expected=2;await assert.rejects(s.embedding.process(job,new M.ParsedCancellation(),async()=>{}),e=>e.category==='UnifiedExpectedSetInvalid');
      s.config.revision++;await assert.rejects(s.embedding.process(job,new M.ParsedCancellation(),async()=>{}),e=>e.category==='UnifiedConfigChanged');assert.equal(s.counts().corpus,0);
      const presentation=h.load('pipeline/UnifiedProcessingPresentation');job.state='AwaitingConfig';job.failure='UnifiedConfigChanged';assert(presentation.processingFailureText(job).includes('重新确认'));assert.equal(presentation.processingJobStateName(job),'等待重新确认配置');job.state='Unknown';assert(presentation.processingFailureText(job).includes('重复计费'));job.state='Failed';job.failure='UnifiedExpectedSetInvalid';assert(presentation.processingFailureText(job).includes('输入数量'));
    }],
    ['background_between_admission_write_and_launch_is_not_sent_and_resumable',async()=>{
      const s=await session();const original=s.repo.admitAttempt.bind(s.repo);let blocked=false;
      s.repo.admitAttempt=async(job,attempt,launch)=>original(job,attempt,()=>{blocked=true;s.queue.background();launch();});
      await s.settings.enableEmbedding(true,true,true);await s.importDoc('admission-background','单段正文');await s.queue.drain();
      assert(blocked);assert.equal(s.counts().corpus,0);const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.state,'Paused');assert.equal((await s.repo.attempts(job.id))[0].outcome,'NotSent');
      s.repo.admitAttempt=original;s.queue.resumeForeground();await s.queue.drain();assert.equal(s.counts().corpus,1);assert.equal((await s.repo.jobs()).find(j=>j.id===job.id).state,'Complete');
    }],
    ['idle_vision_lane_starts_during_existing_long_embedding_job',async()=>{
      let release,entered;const gate=new Promise(r=>release=r),ready=new Promise(r=>entered=r);let first=true;
      const s=await session({embeddingWait:async()=>{if(first){first=false;entered();await gate;}}});
      await s.settings.enableEmbedding(true,true,true);await s.importDoc('long-body','第一段\n\n第二段');await ready;
      await s.settings.enableVision(true,true);await s.importDoc('new-image');
      let completed=false;for(let i=0;i<100;i++){await new Promise(r=>setTimeout(r,5));completed=(await s.repo.jobs()).some(j=>j.stage==='Vision'&&j.state==='Complete');if(completed)break;}
      try{assert(completed,'new vision must finish before the blocked corpus request is released');assert.equal(s.counts().visual,1);assert((await s.repo.jobs()).some(j=>j.stage==='BodyEmbedding'&&j.state==='Running'));}finally{release();await s.queue.drain();}
      assert((await s.repo.jobs()).every(j=>j.state==='Complete'));
    }],
    ['vision_confirmed_auth_rejection_is_failed_and_no_automatic_retry',async()=>{
      const s=await session({visionAuthFailure:true});await s.settings.enableVision(true,true);await s.importDoc('auth-rejected');await s.queue.drain();const job=(await s.repo.jobs()).find(j=>j.stage==='Vision');assert.equal(job.state,'Failed');assert.equal(job.failure,'Http:401');assert.equal(job.completed,0);assert.equal((await s.repo.attempts(job.id))[0].outcome,'Failed');await s.queue.drain();assert.equal(s.counts().visual,1);assert.equal((await s.repo.imageRecords())[0].effectiveId,'None');
    }],

    ['vision_fixed_single_image_json_request_no_context',async()=>{
      const raw=P.visionPayload('image/png','c3ludGhldGlj');const body=JSON.parse(raw);
      assert.equal(body.model,'deepseek-flash');assert.equal(body.stream,false);assert.equal(body.thinking.type,'disabled');assert.equal(body.max_tokens,2048);assert.equal(body.response_format.type,'json_object');
      assert.equal(body.messages.length,1);assert.equal(body.messages[0].content.length,2);assert.equal(body.messages[0].content[1].image_url.detail,'original');assert.equal(body.messages[0].content[1].image_url.url,'data:image/png;base64,c3ludGhldGlj');assert(body.messages[0].content[0].text.includes('JSON'));assert(!raw.includes('caption')&&!raw.includes('chatHistory'));
    }],
    ['vision_typed_json_finish_usage_boundaries',async()=>{
      const ok=P.visionDecode(vision('{"description":"一幅合成图形","tags":[" 图形 ","图形"]}'));assert.equal(ok.description,'一幅合成图形');assert.deepEqual(ok.tags,['图形']);assert.equal(ok.usage.state,'NotReported');assert.equal(ok.usage.totalTokens,undefined);
      for(const reason of ['length','content_filter','tool_calls','insufficient_system_resource','aborted','future'])assert.throws(()=>P.visionDecode(vision('{"description":"图","tags":[]}',reason)));
      for(const content of ['```json\n{}\n```','{"description":"图","description":"重复","tags":[]}','{"description":"","tags":[]}','{"description":"图","tags":[1]}','{"description":"图","tags":[]','{"description":"图","tags":[],"ocr":"不准新增"}'])assert.throws(()=>P.visionDecode(vision(content)));
      const usage=P.visionDecode(vision('{"description":"图","tags":[]}','stop',{prompt_tokens:7,completion_tokens:3,total_tokens:10}));assert.equal(usage.usage.totalTokens,10);assert.equal(usage.usage.state,'Reported');
    }],
    ['image_proxy_exact_text_order_trim_dedup_no_ocr_prefix',async()=>{
      const {unifiedProxyText}=h.load('pipeline/UnifiedTextPolicy');assert.equal(unifiedProxyText('描述',[' a ','a','B']),'描述\na\nB');assert.equal(unifiedProxyText('',[]),'');assert.equal(unifiedProxyText('',['标签']),'标签');
    }],
    ['import_automatic_full_more_than_three_and_both_owner_mirrors',async()=>{
      const s=await session();await s.settings.enableVision(true,true);await s.settings.enableEmbedding(true,true,true);const d=await s.importDoc('full',Array.from({length:7},(_,i)=>'正文段'+i).join('\n\n')+'\n\n![图](images/a.png)');await s.queue.drain();
      const jobs=await s.repo.jobs();assert(jobs.every(j=>j.state==='Complete'),JSON.stringify(jobs.map(j=>[j.stage,j.state,j.failure])));assert.equal(s.counts().visual,1);assert.equal(s.counts().corpus,8);assert.equal((await s.repo.binding('upd-body',d.documentKey)).expected,7);assert.equal((await s.repo.binding('upd-body',d.documentKey)).state,'Synced');assert([...s.spaces.values()].every(sp=>sp.preprocessing===U.UNIFIED_TEXT_POLICY));assert([...s.vectorRows.values()].every(r=>r.documentId.startsWith('upd:')));
    }],
    ['default_off_and_local_migration_never_dispatched_when_enabled',async()=>{
      const s=await session(),d=await s.importDoc('local');await s.queue.drain();assert.deepEqual(s.counts(),{visual:0,corpus:0});const jobs=await s.repo.jobs();for(const j of jobs){j.state=U.UnifiedJobState.Canceled;await s.repo.saveJob(j);}await s.queue.enqueue(d,U.UnifiedJobOrigin.LocalMigration,'');await s.settings.enableVision(true,true);await s.settings.enableEmbedding(true,true,true);await s.queue.drain();assert.deepEqual(s.counts(),{visual:0,corpus:0});
    }],
    ['vision_cache_second_parent_zero_send_and_overlay_survives_rerun',async()=>{
      const s=await session();await s.settings.enableVision(true,true);await s.importDoc('parent1');await s.queue.drain();await s.importDoc('parent2');await s.queue.drain();assert.equal(s.counts().visual,1);let records=await s.repo.imageRecords();assert.equal(records.length,2);assert.equal(records[0].effectiveId,records[1].effectiveId);
      await s.imageService.edit(records[0].occurrenceId,'用户修正图形',['图形']);records=await s.repo.imageRecords();const edited=records.find(r=>r.documentKey===records[0].documentKey);const before=await s.repo.annotation(edited.effectiveId);assert.equal(before.description,'用户修正图形');assert(!before.tags.includes('删除标签'));const visionJob=(await s.repo.jobs()).find(j=>j.stage==='Vision'&&j.occurrenceId===edited.occurrenceId);visionJob.state=U.UnifiedJobState.Failed;await s.repo.saveJob(visionJob);await s.queue.retry(visionJob.id,true);await s.queue.drain();const after=await s.repo.annotation((await s.repo.imageRecords()).find(r=>r.occurrenceId===edited.occurrenceId).effectiveId);assert.equal(after.description,'用户修正图形');assert(!after.tags.includes('删除标签'));assert.equal(s.counts().visual,1);
    }],
    ['unknown_does_not_auto_resend_restart_or_pagination_equivalent_drain',async()=>{
      const s=await session({visionError:true});await s.settings.enableVision(true,true);await s.importDoc('unknown');await s.queue.drain();assert.equal(s.counts().visual,1);const job=(await s.repo.jobs()).find(j=>j.stage==='Vision');assert.equal(job.state,'Unknown');await s.queue.initialize();await s.queue.drain();await s.queue.drain();assert.equal(s.counts().visual,1);await assert.rejects(s.queue.retry(job.id,false));
    }],
    ['settings_revision_changed_before_launch_blocks_egress',async()=>{
      let once=false;const s=await session({beforeEmbedding:async repo=>{if(!once){once=true;const cfg=await repo.settings('Embedding');cfg.revision++;cfg.enabled=false;await repo.saveSettings(cfg);}}});await s.settings.enableEmbedding(true,true,true);await s.importDoc('revoke');await s.queue.drain();assert.equal(s.counts().corpus,0);assert((await s.repo.jobs()).some(j=>j.stage==='BodyEmbedding'&&j.state==='Failed'));
    }],
    ['editing_annotation_invalidates_image_binding_not_body_ocr',async()=>{
      const s=await session();await s.settings.enableVision(true,true);await s.settings.enableEmbedding(true,true,true);const d=await s.importDoc('edit');await s.queue.drain();const body=await s.repo.binding('upd-body',d.documentKey),record=(await s.repo.imageRecords())[0];assert.equal(body.state,'Synced');await s.settings.pausePurpose('Embedding',true);await s.imageService.edit(record.occurrenceId,'修正描述',['新标签']);const old=await s.repo.binding('upd-image',record.lineage);assert.equal(old.state,'Invalid');assert.equal((await s.repo.binding('upd-body',d.documentKey)).state,'Synced');assert((await s.repo.chunks(d.documentKey)).some(c=>c.text==='正文'));
    }],
    ['real_vision_credential_rcp_adapter_single_image_safe_configuration',async()=>{
      const {VisionCredentialStore,VISION_CREDENTIAL_ALIAS}=h.load('infra/VisionCredentialStore'),{VisionTransportAdapter}=h.load('infra/VisionTransportAdapter'),V=h.load('domain/VisionModels');
      const credential=new VisionCredentialStore();await credential.save('synthetic-host-only-not-a-key');const before=h.assetCalls.length;assert((await credential.status()).present);assert.deepEqual(h.assetCalls.slice(before),[['query',1]]);assert(h.assetRows.has(VISION_CREDENTIAL_ALIAS));assert(!VISION_CREDENTIAL_ALIAS.includes('embedding'));
      const req=new V.VisionRequestIdentity();req.asset=Object.assign(new M.ParsedImageAsset(),{id:'asset',state:'Ready',payloadHash:fixture.gold.pngHash,bytes:fixture.png().length,mime:'image/png',pixelWidth:1,pixelHeight:1,frames:1});req.imageHash=fixture.gold.pngHash;
      let calls=0,admissions=0;
      h.fetchHandler(async(request,cfg)=>{calls++;assert.equal(request.url,P.VISION_ENDPOINT);assert.equal(cfg.requestConfiguration.transfer.autoRedirect,false);assert.equal(cfg.requestConfiguration.tracing.verbose,false);assert.equal(cfg.requestConfiguration.tracing.plaintextInException,false);const body=JSON.parse(request.content);assert.equal(body.messages[0].content[1].image_url.url,'data:image/png;base64,'+fixture.png().toString('base64'));const raw=new Uint8Array(Buffer.from(vision('{"description":"原字节合成图","tags":[]}')));request.destination(raw.buffer);cfg.requestConfiguration.tracing.httpEventsHandler.onDataEnd();return {statusCode:200};});
      try{const result=await new VisionTransportAdapter(credential,h.identity).describe(req,new Uint8Array(fixture.png()),new M.ParsedCancellation(),async launch=>{admissions++;launch();});assert.equal(result.description,'原字节合成图');assert.equal(calls,1);assert.equal(admissions,1);}finally{h.fetchHandler(undefined);}
      const rcp=h.kits.get('@kit.RemoteCommunicationKit').rcp;await assert.rejects(credential.fetch(new rcp.Request('https://invalid.example/no-secret','POST'),rcp.createSession({}),()=>{},async f=>f()),/CredentialDestinationRejected/);
    }],
    ['real_counter_new_policy_bound_without_old_pdf_baseline',async()=>{
      const {EmbeddingTokenAdapter}=h.load('infra/EmbeddingTokenAdapter'),B=h.load('pipeline/EmbeddingBasisPolicy');const publicRoot=path.resolve(__dirname,'../main/resources/rawfile');const exact=new Set(['embedding/bge_m3/scalar-weights.txt','embedding/bge_m3/proof-metadata.json','embedding/bge_m3/NOTICE.txt']);
      const counter=new EmbeddingTokenAdapter({resourceManager:{getRawFileContent:async name=>{assert(exact.has(name));return new Uint8Array(fs.readFileSync(path.join(publicRoot,name)));}}},h.identity),config=new E.EmbeddingConfig();config.modelId='BAAI/bge-m3';const text='正文与图片标签😀';const proof=await counter.unifiedEvidence(config,text,hash(text));assert.equal(proof.policyVersion,U.UNIFIED_TEXT_POLICY);assert.equal(proof.textHash,hash(text));const settings=new U.UnifiedProcessingSettings();settings.policy=U.UNIFIED_TEXT_POLICY;settings.configBinding=B.embeddingConfigBinding(config);assert.equal(B.unifiedEmbeddingEligible(proof,config,settings),false);settings.baselineAccepted=true;assert(B.unifiedEmbeddingEligible(proof,config,settings));assert.equal(B.embeddingLocalEligible(proof,config),false);
    }],
    ['partial_embedding_unknown_explicit_resume_reuses_completed_inputs',async()=>{
      const s=await session({embeddingFailAt:3});await s.settings.enableEmbedding(true,true,true);await s.importDoc('partial',Array.from({length:6},(_,i)=>'正文'+i).join('\n\n'));await s.queue.drain();let job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.state,'Unknown');assert.equal(job.completed,2);assert.equal(job.expected,6);assert.equal(await s.repo.binding('upd-body',job.ownerId),undefined);await s.queue.drain();assert.equal(s.counts().corpus,3);await s.queue.retry(job.id,true);await s.queue.drain();job=(await s.repo.jobs()).find(j=>j.id===job.id);assert.equal(job.state,'Complete');assert.equal(job.completed,6);assert.equal(s.counts().corpus,7);assert.equal((await s.repo.binding('upd-body',job.ownerId)).state,'Synced');
    }],
    ['delete_all_annotation_rerun_keeps_tombstone_and_tag_index_current_only',async()=>{
      const s=await session();await s.settings.enableVision(true,true);await s.importDoc('deleted');await s.queue.drain();const record=(await s.repo.imageRecords())[0];assert.equal((await s.repo.tagMatches('图形')).length,1);await s.imageService.edit(record.occurrenceId,'',[],true);assert.equal((await s.repo.tagMatches('图形')).length,0);let r=(await s.repo.imageRecords())[0];assert((await s.repo.annotation(r.effectiveId)).overlay.deleted);const job=(await s.repo.jobs()).find(j=>j.stage==='Vision');job.state=U.UnifiedJobState.Failed;await s.repo.saveJob(job);await s.queue.retry(job.id,true);await s.queue.drain();r=(await s.repo.imageRecords())[0];assert.equal((await s.repo.annotation(r.effectiveId)).description,'');assert.equal((await s.repo.tagMatches('图形')).length,0);assert.equal(s.counts().visual,1);
    }],
    ['explicit_upgrade_without_frozen_batch_denied_and_persistent_pause',async()=>{
      const s=await session();s.queue.pause();await s.queue.drain();await s.settings.enableVision(true,true);const d=await s.importDoc('paused');await s.queue.drain();assert.equal(s.counts().visual,0);await s.queue.initialize();await s.queue.drain();assert.equal(s.counts().visual,0);for(const j of await s.repo.jobs()){j.state=U.UnifiedJobState.Canceled;await s.repo.saveJob(j);}await s.queue.enqueue(d,U.UnifiedJobOrigin.ExplicitUpgrade,'missing-batch');s.queue.resume();await s.queue.drain();assert.equal(s.counts().visual,0);assert((await s.repo.jobs()).some(j=>j.failure==='NoRequestFrozenBatchMissing'));
    }],
    ['real_embedding_rcp_corpus_new_policy_paid_admission_not_old_free',async()=>{
      const {EmbeddingCredentialStore}=h.load('infra/EmbeddingCredentialStore'),{EmbeddingTransportAdapter}=h.load('infra/EmbeddingTransportAdapter');const cfg=new E.EmbeddingConfig();cfg.modelId='BAAI/bge-m3';cfg.revision=1;cfg.credentialRevision=1;
      const credentials=new EmbeddingCredentialStore();await credentials.save(cfg,'synthetic-host-only-not-a-key',false);const adapter=new EmbeddingTransportAdapter(credentials,h.identity);const input='当前正文';const proof=Object.assign(new E.TokenEligibilityEvidence(),{policyVersion:U.UNIFIED_TEXT_POLICY,profileBoundProven:true,localState:'SafeUnderPinnedProfile',upperBound:5,textHash:hash(input),bindingHash:hash('binding')});adapter.attachUnifiedCounter({unifiedEvidence:async()=>proof});let sent=0,admitted=0;
      h.fetchHandler(async(req,settings)=>{sent++;assert.equal(settings.requestConfiguration.transfer.autoRedirect,false);assert.equal(settings.requestConfiguration.tracing.plaintextInException,false);const payload=JSON.parse(req.content);assert.deepEqual(payload,{model:'BAAI/bge-m3',input,encoding_format:'float'});const bytes=new Uint8Array(Buffer.from(JSON.stringify({object:'list',model:'BAAI/bge-m3',data:[{index:0,object:'embedding',embedding:[1,2,3]}]})));req.destination(bytes.buffer);settings.requestConfiguration.tracing.httpEventsHandler.onDataEnd();return {statusCode:200};});
      try{const result=await adapter.embedUnifiedCorpus(cfg,input,proof,new M.ParsedCancellation(),async launch=>{admitted++;launch();});assert.equal(result.vector.length,3);assert.equal(result.usage.totalTokens,undefined);assert.equal(sent,1);assert.equal(admitted,1);}finally{h.fetchHandler(undefined);}
      await assert.rejects(adapter.embedUnifiedCorpus(cfg,'different',proof,new M.ParsedCancellation(),async f=>f()));assert.equal(adapter.queryEgress,false);
    }],
    ['mirror_failure_never_synced_and_does_not_touch_old_owner',async()=>{
      const s=await session();s.vectorRows.set('legacy',{spaceId:'old-space',documentId:'legacy-doc',eligible:true});s.numeric.synchronizeUnified=async()=>{throw Error('MirrorFailed');};await s.settings.enableEmbedding(true,true,true);const d=await s.importDoc('mirror');await s.queue.drain();const b=await s.repo.binding('upd-body',d.documentKey);assert.equal(b.state,'Pending');assert.equal(s.vectorRows.get('legacy').eligible,true);const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.notEqual(job.state,'Complete');
    }],
    ['background_no_next_request_local_results_preserved_then_explicit_resume',async()=>{
      const s=await session({beforeEmbedding:async()=>{s.queue.background();}});await s.settings.enableEmbedding(true,true,true);const d=await s.importDoc('background');await s.queue.drain();assert.equal(s.counts().corpus,0);assert((await s.repo.chunks(d.documentKey)).length>0);assert((await s.repo.jobs()).some(j=>j.stage==='BodyEmbedding'&&j.state==='Paused'));
    }],
    ['formal_settings_and_image_edit_handlers_are_connected_not_render_requests',async()=>{
      const {VisionSettingsView}=h.load('ui/VisionSettingsView'),{ImageKnowledgeView}=h.load('ui/ImageKnowledgeView');const v=new VisionSettingsView();let saves=0,edits=0,subs=0,unsubs=0;v.queue={subscribe:()=>subs++,unsubscribe:()=>unsubs++,jobs:async()=>[]};v.service={setting:async()=>({enabled:false}),credentialStatus:async()=>({present:false}),enableVision:async(on,cost)=>{assert(on&&cost);saves++;}};v.aboutToAppear();v.costConsent=true;await v.saveEnabled();assert.equal(saves,1);v.aboutToDisappear();assert.equal(subs,unsubs);
      const i=new ImageKnowledgeView();i.selected=new U.UnifiedImageRecord();i.selected.occurrenceId='occ';i.descriptionInput='修改描述';i.tagsInput='标签';i.service={edit:async(id,desc,tags)=>{assert.equal(id,'occ');assert.equal(desc,'修改描述');assert.deepEqual(tags,['标签']);edits++;},records:async()=>[]};await i.save();assert.equal(edits,1);
      const root=path.resolve(__dirname,'../../..'),index=fs.readFileSync(path.join(root,'entry/src/main/ets/pages/Index.ets'),'utf8');const features=fs.readFileSync(path.join(root,'entry/src/main/ets/components/FeaturePages.ets'),'utf8');assert(features.includes("id: 'upd-profile-vision', onOpen: $$.onVisionSettings"));assert(features.includes(".id($$.id ??"));assert(index.includes('onVisionSettings: (): void => { this.openVisionSettings(); }'));assert(index.includes('VisionSettingsView({service:this.sharedKnowledge?.unifiedSettings'));assert(index.includes('ImageKnowledgeView({service:this.sharedKnowledge?.imageKnowledge'));const embedding=fs.readFileSync(path.join(root,'entry/src/main/ets/knowledge/ui/EmbeddingSettingsView.ets'),'utf8');assert(embedding.includes("id('upd-embedding-enable')"));assert(embedding.includes('enableEmbedding(!this.unifiedOn'));
    }],
    ['late_auto_receipt_never_overwrites_user_overlay_or_revives_tags',async()=>{
      let ready,release;const arrived=new Promise(r=>ready=r),wait=new Promise(r=>release=r);const s=await session({visionWait:async()=>{ready();await wait;}});await s.settings.enableVision(true,true);await s.importDoc('late');await arrived;const record=(await s.repo.imageRecords())[0];await s.imageService.edit(record.occurrenceId,'用户先改描述',['用户标签']);release();await s.queue.drain();const current=(await s.repo.imageRecords())[0],effective=await s.imageService.effective(current);assert.equal(effective.description,'用户先改描述');assert.deepEqual(effective.tags,['用户标签']);assert.equal(effective.automatic.description,'合成图形描述');assert.equal(s.counts().visual,1);
    }],
    ['body_duplicate_text_keeps_distinct_input_ids_and_full_denominator',async()=>{
      const s=await session();await s.settings.enableEmbedding(true,true,true);await s.importDoc('duplicates','重复正文\n\n重复正文\n\n重复正文\n\n重复正文');await s.queue.drain();const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.expected,4);assert.equal(new Set(job.inputs.map(i=>i.id)).size,4);assert.equal(new Set(job.inputs.map(i=>i.inputHash)).size,1);assert.equal(s.counts().corpus,4);assert.equal(job.completed,4);assert.equal(job.state,'Complete');
    }],
    ['frozen_expected_input_set_cannot_be_reduced_for_success',async()=>{
      const s=await session();await s.importDoc('frozen','一\n\n二\n\n三\n\n四');await s.queue.drain();const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');job.inputs.splice(1);job.expected=1;await assert.rejects(s.repo.saveJob(job),/FrozenJobInputsChanged/);
    }],
    ['production_numeric_sync_only_new_space_and_namespaced_owner',async()=>{
      const {VectorRdbRepository}=h.load('infra/VectorRdbRepository');const numeric=new VectorRdbRepository({});const sp=new E.EmbeddingSpace();sp.id='kb-'+'a'.repeat(32);sp.preprocessing=U.UNIFIED_TEXT_POLICY;sp.dimension=3;const old=new E.EmbeddingSpace();old.id='kb-'+'b'.repeat(32);old.preprocessing='PDF-EMBED-TEXT-1';numeric.spaces.set(sp.id,sp);numeric.spaces.set(old.id,old);const statements=[];numeric.store={beginTrans:async()=>1,execute:async(sql,tx,args)=>{statements.push([sql,args]);},commit:async()=>{},rollback:async()=>{}};
      await numeric.synchronizeUnified(sp.id,'upd:body:doc','content','generation',2);assert.equal(statements.length,2);assert(statements.every(([sql,args])=>sql.includes('v_'+'a'.repeat(32))&&!sql.includes('v_'+'b'.repeat(32))&&args.includes('upd:body:doc')));await assert.rejects(numeric.synchronizeUnified(old.id,'legacy-doc','old','old',0));
    }],
    ['same_global_annotation_multiple_parents_reuses_single_proxy_owner_job',async()=>{
      const s=await session();await s.settings.enableVision(true,true);await s.settings.enableEmbedding(true,true,true);await s.importDoc('shared-parent1');await s.queue.drain();const count=s.counts().corpus;await s.importDoc('shared-parent2');await s.queue.drain();assert.equal(s.counts().visual,1);assert.equal(s.counts().corpus,count+1,'only new parent body, same global proxy reused');const records=await s.repo.imageRecords();assert.equal(records[0].effectiveId,records[1].effectiveId);assert.equal((await s.repo.jobs()).filter(j=>j.stage==='ImageEmbedding').length,1);await s.settings.pausePurpose('Embedding',true);await s.imageService.edit(records[0].occurrenceId,'分叉描述',['分叉']);assert.equal((await s.repo.binding('upd-image',records[1].lineage)).state,'Synced','other parent still uses old global annotation');
    }],
    ['vision_lengths_usage_and_response_limits_are_client_not_provider_guesses',async()=>{
      assert.throws(()=>P.visionDecode(vision(JSON.stringify({description:'图'.repeat(2001),tags:[]}))));assert.throws(()=>P.visionDecode(vision(JSON.stringify({description:'图',tags:Array.from({length:21},(_,i)=>'标签'+i)}))));assert.throws(()=>P.visionDecode(vision(JSON.stringify({description:'图',tags:['长'.repeat(65)]}))));assert.throws(()=>P.visionDecode(vision('{"description":"图","tags":[]}','stop',{prompt_tokens:5,completion_tokens:2,total_tokens:1})));assert.throws(()=>P.visionDecode(' '.repeat(1048577)));assert.throws(()=>P.visionPayload('image/gif','YWJj'));
    }],
    ['paused_without_egress_restores_with_same_fixed_expected_inputs',async()=>{
      const s=await session();s.queue.pause();await s.queue.drain();await s.settings.enableEmbedding(true,true,true);await s.importDoc('resume','一\n\n二\n\n三\n\n四');await s.queue.drain();assert.equal(s.counts().corpus,0);s.queue.resume();await s.queue.drain();const job=(await s.repo.jobs()).find(j=>j.stage==='BodyEmbedding');assert.equal(job.expected,4);assert.equal(job.completed,4);assert.equal(job.state,'Complete');
    }],
    ['proxy_current_inputs_count_together_with_body_and_old_routes',async()=>{
      const s=await session();await s.importDoc('budget-proxy');const record=(await s.repo.imageRecords())[0];const binding=new U.UnifiedIndexBinding();Object.assign(binding,{ownerNamespace:'upd-image',ownerId:'other-proxy',version:'old',expected:30000,inputSetHash:hash('set')});await s.repo.saveBinding(binding);const input=new U.UnifiedTextInput();Object.assign(input,{id:'proxy-input',ownerNamespace:'upd-image',ownerId:'proxy',version:'version',actualText:'描述',inputHash:hash('描述')});await assert.rejects(s.repo.reserveProxyInputs('proxy','version',[input]),/AllCurrentInputBudget/);assert.equal(await s.repo.binding('upd-image','proxy'),undefined);
    }],
    ['session_stop_waits_worker_without_persisting_user_pause',async()=>{
      const s=await session();await s.queue.stop();assert.notEqual(await s.repo.meta('queue-paused'),'true');await s.settings.enableVision(true,true);await s.importDoc('stopped');await s.queue.drain();assert.equal(s.counts().visual,0);await s.queue.initialize();await s.queue.drain();assert.equal(s.counts().visual,1);await s.queue.stop();
    }]
  ];
};
