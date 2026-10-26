'use strict';
const assert=require('node:assert/strict');

exports.cases=h=>{
  const {KnowledgeStorageScope}=h.load('domain/KnowledgeStorageScope');
  const {TextChannel}=h.load('domain/TextKnowledgeModels');
  const {KnowledgeStoreHost}=h.load('infra/KnowledgeStoreHost');
  const {ParsedDocumentRepository}=h.load('infra/ParsedDocumentRepository');
  const {ParsedDocumentAssets}=h.load('infra/ParsedDocumentAssets');
  const {KnowledgeDerivedBudget}=h.load('infra/KnowledgeDerivedBudget');
  const {ParsedDocumentIngestionService}=h.load('application/ParsedDocumentIngestionService');
  const {KnowledgeDatabaseAdapter}=h.load('application/KnowledgeDatabaseAdapter');
  const {KnowledgeRuntimeSearchAdapter}=h.load('application/KnowledgeRuntimeSearchAdapter');
  const P=h.load('domain/KnowledgeDatabasePorts');
  const R=h.load('domain/KnowledgeRuntimePorts');
  const Q=h.load('domain/UnifiedQueryModels');
  const U=h.load('domain/UnifiedKnowledgeModels');
  const D=h.load('domain/ParsedDocumentModels');
  let sequence=41000;

  async function setup(){
    const key=(++sequence).toString(16).padStart(16,'0');
    const context={filesDir:'/database-'+key+'/files',cacheDir:'/database-'+key+'/cache',databaseDir:'/database-'+key+'/db'};
    const host=KnowledgeStoreHost.forContext(context,KnowledgeStorageScope.isolated(key));
    await host.acquireM1(async()=>TextChannel.Like); host.requireUnifiedProtection();
    const repository=new ParsedDocumentRepository(host,h.identity); repository.attachPhysicalBudget(new KnowledgeDerivedBudget(context,KnowledgeStorageScope.isolated(key))); await repository.open();
    const assets=new ParsedDocumentAssets(context.filesDir,context.cacheDir,KnowledgeStorageScope.isolated(key),repository,h.identity,'database');
    repository.attachPublicationVerifier(assets);
    const ingestion=new ParsedDocumentIngestionService(repository,assets,h.identity);
    return {repository,adapter:new KnowledgeDatabaseAdapter(repository,assets,ingestion,h.identity)};
  }

  function write(sourceId='backend-note',markdown='# 标题\n\n知识库正文'){
    const request=new P.KnowledgeDatabaseWriteRequest();
    Object.assign(request,{sourceId,sourceVersion:1,title:'后端资料',markdown}); return request;
  }

  return [
    ['database_adapter_writes_through_unified_publication_and_reads_exact_snapshot',async()=>{
      const s=await setup(),saved=await s.adapter.write(write());
      assert.equal(saved.summary.namespace,'Backend'); assert.equal(saved.summary.sourceId,'backend-note');
      assert.equal(saved.markdown,'# 标题\n\n知识库正文'); assert(saved.chunks.some(chunk=>chunk.text.includes('知识库正文')));
      const request=new P.KnowledgeDatabaseReadRequest(); request.documentId=saved.summary.documentId;
      const read=await s.adapter.read(request); assert(read); assert.equal(read.summary.generation,saved.summary.generation);
      const list=await s.adapter.list(new P.KnowledgeDatabaseListRequest());
      assert.deepEqual(list.map(row=>row.documentId),[saved.summary.documentId]);
    }],
    ['database_adapter_is_idempotent_and_rejects_same_source_with_changed_bytes',async()=>{
      const s=await setup(),first=await s.adapter.write(write('stable'));
      const second=await s.adapter.write(write('stable')); assert.equal(second.summary.generation,first.summary.generation);
      await assert.rejects(s.adapter.write(write('stable','已变化正文')),error=>error.category==='SourceDeletedOrVersionChanged');
      const changedTitle=write('stable'); changedTitle.title='已变化标题';
      await assert.rejects(s.adapter.write(changedTitle),error=>error.category==='BackendSourceMetadataChanged');
      const request=new P.KnowledgeDatabaseReadRequest(); request.documentId=first.summary.documentId;
      assert.equal((await s.adapter.read(request)).markdown,'# 标题\n\n知识库正文');
    }],
    ['database_adapter_hides_archived_by_default_and_bounds_inputs',async()=>{
      const s=await setup(),saved=await s.adapter.write(write('archive')); await s.repository.setUnifiedArchived(saved.summary.documentId,true);
      const request=new P.KnowledgeDatabaseReadRequest(); request.documentId=saved.summary.documentId;
      assert.equal(await s.adapter.read(request),undefined); assert.equal((await s.adapter.list(new P.KnowledgeDatabaseListRequest())).length,0);
      request.includeArchived=true; assert.equal((await s.adapter.read(request)).summary.archived,true);
      const listRequest=new P.KnowledgeDatabaseListRequest(); listRequest.includeArchived=true;
      assert.equal((await s.adapter.list(listRequest)).length,1);
      await assert.rejects(s.adapter.write(write('','正文')),error=>error.category==='BackendSourceIdentity');
      listRequest.limit=101; await assert.rejects(s.adapter.list(listRequest),error=>error.category==='BackendListRange');
    }],
    ['database_adapter_rechecks_archive_state_after_snapshot_io',async()=>{
      const s=await setup(),saved=await s.adapter.write(write('archive-race'));
      const original=s.repository.chunks.bind(s.repository); let changed=false;
      s.repository.chunks=async id=>{const chunks=await original(id); await s.repository.setUnifiedArchived(id,true); changed=true; return chunks;};
      const request=new P.KnowledgeDatabaseReadRequest(); request.documentId=saved.summary.documentId;
      assert.equal(await s.adapter.read(request),undefined); assert.equal(changed,true);
    }],
    ['database_adapter_write_rechecks_archive_state_after_publication',async()=>{
      const s=await setup(); let reads=0; const original=s.repository.chunks.bind(s.repository);
      s.repository.chunks=async id=>{reads++; const chunks=await original(id); if(reads===2){await s.repository.setUnifiedArchived(id,true);} return chunks;};
      await assert.rejects(s.adapter.write(write('archive-write-race')),error=>error.category==='BackendPublicationUnavailable');
      assert.equal(reads>=2,true);
    }],
    ['runtime_knowledge_search_returns_bounded_visible_direct_evidence_only',async()=>{
      const scope=new Q.UnifiedQueryScope(); scope.complete=true; scope.includeArchived=false;
      const source=new Q.UnifiedQueryTextSource(); source.document.id='upd-runtime'; source.document.title='运行时资料';
      const chunk=new D.ParsedTextChunk(); chunk.id='chunk-1'; chunk.documentKey='upd-runtime'; chunk.generation='generation-1';
      chunk.text='知识库工具会先执行本机确定性检索，再把有限证据交给模型。'; chunk.evidence='Body'; source.chunks=[chunk]; scope.texts=[source];
      let captureCount=0,visibleCount=0;
      const scopePort={captureLocal:async(_config,archived,cancel)=>{captureCount++; assert.equal(archived,false); cancel.check(); return scope;},
        capture:async()=>{throw Error('remote capture forbidden');},visible:async(card,archived)=>{visibleCount++; return card.documentKey==='upd-runtime'&&!archived;}};
      const config={currentConfig:()=>({})}; const adapter=new KnowledgeRuntimeSearchAdapter(scopePort,config);
      const request=new R.KnowledgeRuntimeSearchRequest(); request.query='确定性检索'; request.maxResults=3;
      const result=await adapter.search(request,new D.ParsedCancellation());
      assert.equal(result.provider,'shuvi-local-knowledge'); assert.equal(result.route,'local-direct');
      assert.equal(result.citations.length,1); assert.equal(result.citations[0].citationId,1);
      assert.equal(result.citations[0].documentId,'upd-runtime'); assert.match(result.citations[0].excerpt,/确定性检索/);
      assert.equal(captureCount,1); assert.equal(visibleCount,1);
    }],
    ['runtime_knowledge_search_fails_closed_for_archived_or_incomplete_scope',async()=>{
      const scope=new Q.UnifiedQueryScope(); scope.complete=false;
      const scopePort={captureLocal:async()=>scope,capture:async()=>scope,visible:async()=>true};
      const adapter=new KnowledgeRuntimeSearchAdapter(scopePort,{currentConfig:()=>({})});
      const request=new R.KnowledgeRuntimeSearchRequest(); request.query='资料';
      await assert.rejects(adapter.search(request,new D.ParsedCancellation()),error=>error.category==='RuntimeKnowledgeScopeIncomplete');
    }],
    ['runtime_knowledge_search_deduplicates_ocr_cards_with_same_evidence_id',async()=>{
      const scope=new Q.UnifiedQueryScope(); scope.complete=true; scope.includeArchived=false;
      const image=new U.UnifiedImageRecord(); image.occurrenceId='occ-1'; image.documentKey='upd-image'; image.generation='generation-1';
      image.imageHash='hash-1'; image.effectiveId='effective-1'; image.ocr='知识库图片完整OCR文字'; image.title='图片资料';
      const imageSource=new Q.UnifiedQueryImageSource(); imageSource.record=image; scope.images=[imageSource];
      const source=new Q.UnifiedQueryTextSource(); source.document.id='upd-image'; source.document.title='图片资料';
      const chunks=[];
      for(const id of ['chunk-1','chunk-2']){ const chunk=new D.ParsedTextChunk(); chunk.id=id; chunk.documentKey='upd-image'; chunk.generation='generation-1'; chunk.occurrenceId='occ-1'; chunk.text='知识库图片文字'; chunk.evidence='Ocr'; chunks.push(chunk); }
      source.chunks=chunks; scope.texts=[source];
      let visibleCount=0; const scopePort={captureLocal:async(_config,_archived,cancel)=>{cancel.check(); return scope;},
        capture:async()=>scope,visible:async()=>{visibleCount++; return true;}};
      const adapter=new KnowledgeRuntimeSearchAdapter(scopePort,{currentConfig:()=>({})});
      const request=new R.KnowledgeRuntimeSearchRequest(); request.query='知识库图片'; request.maxResults=5;
      const result=await adapter.search(request,new D.ParsedCancellation());
      assert.equal(result.citations.length,1);
      assert.equal(result.citations[0].evidenceId,'image:hash-1:effective-1');
      assert.equal(result.citations[0].evidence,'OcrDirect');
      assert(visibleCount>=1);
    }]
  ];
};
