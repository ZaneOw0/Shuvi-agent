'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
exports.cases = h => {
  const M=h.load('domain/ParsedDocumentModels'), U=h.load('domain/UnifiedKnowledgeModels');
  const {KnowledgeLexicalRepository}=h.load('infra/KnowledgeLexicalRepository');
  const {KnowledgeLexicalRequest}=h.load('domain/KnowledgeLexicalPorts');
  const policy=h.load('pipeline/KnowledgeLexicalPolicy');
  let sequence=75000;
  async function setup(fts=true) {
    const key=String(++sequence).padStart(16,'0');
    const scope=h.load('domain/KnowledgeStorageScope').KnowledgeStorageScope.isolated(key);
    const ctx={filesDir:'/lex-'+key+'/files',cacheDir:'/lex-'+key+'/cache',databaseDir:'/lex-'+key+'/db'};
    const host=h.load('infra/KnowledgeStoreHost').KnowledgeStoreHost.forContext(ctx,scope);
    await host.acquireM1(async()=>h.load('domain/TextKnowledgeModels').TextChannel.Like);
    const store=host.requireStore(), original=store.executeSql.bind(store); let bodyReads=0;
    const query=store.querySql.bind(store);
    store.querySql=async(sql,args)=>{if(sql.startsWith('SELECT c.* FROM upd_chunk'))bodyReads++;return query(sql,args);};
    // Desktop SQLite is the real host FTS engine. Explicit surrogate tokenizer ONLY in tests.
    // This does not prove HarmonyOS customtokenizer Chinese behavior.
    if(fts) store.executeSql=(sql,args)=>original(sql.replace(/tokenize=customtokenizer/g,'tokenize=unicode61'),args);
    const repo=new(h.load('infra/ParsedDocumentRepository').ParsedDocumentRepository)(host,h.identity);
    repo.attachPhysicalBudget(new(h.load('infra/KnowledgeDerivedBudget').KnowledgeDerivedBudget)(ctx,scope));await repo.open();
    const assets=new(h.load('infra/ParsedDocumentAssets').ParsedDocumentAssets)(ctx.filesDir,ctx.cacheDir,scope,repo,h.identity,'lexical');repo.attachPublicationVerifier(assets);
    const ingestion=new(h.load('application/ParsedDocumentIngestionService').ParsedDocumentIngestionService)(repo,assets,h.identity);
    async function add(text,image=false) {
      const id='lex-'+(++sequence), req=new(h.load('domain/ParsedDocumentPorts').ParsedImportRequest)();
      Object.assign(req,{namespace:'Text',sourceId:id,sourceHash:hash(id),title:id,format:image?M.ParsedFormat.Image:M.ParsedFormat.Text,parserSignature:'synthetic-lexical',engine:'Local',outputIdentity:id});
      const producer=new(h.load('infra/ParsedDocumentAdapters').ParsedDocumentAdapters)(h.identity);producer.setOutput(text,undefined,id);
      if(image)producer.addImage('lex-image',new Uint8Array(require('./unified-fixtures.cjs').png()),M.ParsedProvenance.Original);
      await ingestion.ingest(req,producer);return ingestion.state.document;
    }
    const lex=new KnowledgeLexicalRepository(host,repo,h.identity);
    const request=(text,extra={})=>Object.assign(new KnowledgeLexicalRequest(),{query:text},extra);
    const search=req=>lex.search(req,new M.ParsedCancellation());
    async function all(req) {const cards=[];let r;for(let i=0;i<30;i++){r=await search(req);cards.push(...r.cards);if(!r.hasMore)return {...r,cards};req.cursor=r.cursor;req.scopeRevision=r.scopeRevision;}throw Error('LexicalContinuationLoop');}
    async function fill(count) {
      const doc=await add('synthetic base');const base=(await repo.chunks(doc.documentKey))[0];
      const tx=await store.createTransaction();
      try { for(let i=1;i<count;i++){const text=i===count-1?'needleunique 知识库 中文检索':'知识库 中文检索 alpha filler '+i;
        await tx.execute('INSERT INTO upd_chunk VALUES(?,?,?,?,?,?,?,?,?,?,?)',['profile-'+String(i).padStart(6,'0'),doc.documentKey,doc.generation,i,text,hash(text),base.blockId,'','Body',0,text.length]);}await tx.commit();}catch(e){await tx.rollback();throw e;}
      return doc;
    }
    return {host,repo,store,assets,lex,add,fill,request,search,all,reads:()=>bodyReads,reset:()=>{bodyReads=0;}};
  }
  exports.fixture=setup;
  return [
    ['lexical_real_history_does_not_revoke_semantic_review',async()=>{
      const s=await setup();await s.add('alpha evidence');
      const {KnowledgeQuerySession}=h.load('application/KnowledgeQuerySession'),Q=h.load('domain/UnifiedQueryModels'),E=h.load('domain/EmbeddingModels');
      const scope={visible:async()=>true};const history=new(h.load('infra/UnifiedKnowledgeHistoryRepository').UnifiedKnowledgeHistoryRepository)(s.repo,s.assets,scope);
      let reviewed=0;const engine={revoke:async()=>{},review:async()=>{reviewed++;return new Q.UnifiedQueryApproval();}};
      const session=new KnowledgeQuerySession(scope,engine,{currentConfig:()=>new E.EmbeddingConfig()},history,h.identity,s.lex);
      await session.start('alpha');await session.retryHistory();assert.equal((await history.list(0,10)).length,1);
      await session.review();assert.equal(reviewed,1);await session.close();
    }],
    ['lexical_active_image_asset_still_invalidates_and_old_trigger_is_upgraded',async()=>{
      const s=await setup();const doc=await s.add('',true);await s.lex.capabilities();
      await s.store.executeSql('DROP TRIGGER klex_upd_asset_UPDATE');
      await s.store.executeSql("CREATE TRIGGER klex_upd_asset_UPDATE AFTER UPDATE ON upd_asset BEGIN UPDATE klex_state SET revision=revision+1,state='Stale' WHERE id=1; END");
      const cold=new KnowledgeLexicalRepository(s.host,s.repo,h.identity);const before=await cold.capabilities();
      const record=(await s.repo.imageRecords(doc.documentKey))[0];
      await s.store.executeSql("UPDATE upd_asset SET state='Missing' WHERE id=?",[record.assetId]);
      assert.notEqual((await cold.capabilities()).revision,before.revision);
      const prior=await cold.capabilities();
      await s.assets.saveHistory('revision-history','revision-owner',new TextEncoder().encode('synthetic snapshot'),new M.ParsedCancellation());
      assert.equal((await cold.capabilities()).revision,prior.revision);
    }],
    ['lexical_real_corpus_change_still_blocks_semantic_review',async()=>{
      const s=await setup();const doc=await s.add('alpha evidence');
      const {KnowledgeQuerySession}=h.load('application/KnowledgeQuerySession'),E=h.load('domain/EmbeddingModels');let reviewed=0;
      const session=new KnowledgeQuerySession({visible:async()=>true},{revoke:async()=>{},review:async()=>{reviewed++;throw Error('MustNotReach');}},{currentConfig:()=>new E.EmbeddingConfig()},{append:async()=>{}},h.identity,s.lex);
      await session.start('alpha');await s.repo.setUnifiedArchived(doc.documentKey,true);
      await assert.rejects(()=>session.review(),/LocalMembershipChangedStartNewSession/);assert.equal(reviewed,0);await session.close();
    }],
    ['lexical_query_syntax_is_bound_data',async()=>{
      const req=new KnowledgeLexicalRequest();req.query='alpha OR NOT NEAR * "quoted"';
      const terms=policy.knowledgeLexicalTerms(req),fts=policy.knowledgeLexicalFts(terms);
      assert(fts.includes('"OR"'));assert(fts.includes('"NOT"'));assert(fts.includes('"*"'));assert(fts.includes('""quoted""'));
      req.keywords=['x'.repeat(41)];assert.throws(()=>policy.knowledgeLexicalTerms(req));
      assert.deepEqual(policy.knowledgeLexicalRanges('alpha beta',['alpha','alpha beta'],'Body').map(r=>[r.start,r.end]),[[0,10]]);
      const page=new KnowledgeLexicalRequest();page.query='a'.repeat(512);assert.equal(policy.knowledgeLexicalTerms(page)[0].length,512);page.query='a'.repeat(513);assert.throws(()=>policy.knowledgeLexicalTerms(page));
    }],
    ['lexical_real_host_fts_candidate_readback_without_full_capture',async()=>{
      const s=await setup();await s.add('alpha evidence');await s.add('unrelated material');await s.all(s.request('alpha'));
      s.reset();const r=await s.search(s.request('alpha'));assert.equal(r.engine,'fts5');assert.equal(r.cards.length,1);assert.equal(r.readback,1);assert.equal(r.scanned,0);assert.equal(s.reads(),1);assert.equal(r.cards[0].reasons[0].engine,'fts5');
    }],
    ['lexical_keyword_without_contiguous_literal_is_retained',async()=>{
      const s=await setup();await s.add('café reference');const r=await s.all(s.request('cafe'));assert.equal(r.engine,'fts5');assert.equal(r.cards.length,1);assert.equal(r.cards[0].reasons[0].matchKind,'Keyword');assert.deepEqual(r.cards[0].reasons[0].ranges,[]);
    }],
    ['lexical_literal_phrase_and_surrogate_ranges',async()=>{
      const s=await setup();await s.add('prefix 😀 alpha beta suffix');const r=await s.all(s.request('"😀 alpha"'));assert.equal(r.cards.length,1);const reason=r.cards[0].reasons[0];assert.equal(reason.text.slice(reason.ranges[0].start,reason.ranges[0].end),'😀 alpha');assert.equal(reason.engine,'literal-scan');
    }],
    ['lexical_zero_candidates_substring_probe',async()=>{
      const s=await setup();await s.add('prefixsubstringsuffix');const r=await s.all(s.request('substring'));assert.equal(r.cards.length,1);assert.equal(r.fallbackReason,'ZeroCandidatesProbe');assert.equal(r.cards[0].reasons[0].engine,'literal-scan');
    }],
    ['lexical_missing_tokenizer_falls_back_without_models',async()=>{
      const before=h.requests(),s=await setup(false);await s.add('离线 资料');const r=await s.all(s.request('资料'));assert.equal(r.cards.length,1);assert.equal(r.engine,'literal-scan');assert.equal(r.indexState,'Unavailable');assert.equal(h.requests(),before);
    }],
    ['lexical_archive_revision_invalidates_cursor_and_candidates',async()=>{
      const s=await setup();const doc=await s.add('alpha evidence');const first=await s.search(s.request('"alpha"'));await s.repo.setUnifiedArchived(doc.documentKey,true);
      await assert.rejects(()=>s.search(s.request('"alpha"',{cursor:first.cursor,scopeRevision:first.scopeRevision})),/LexicalScopeChanged|lexical/);
      assert.equal((await s.all(s.request('alpha'))).cards.length,0);assert.equal((await s.all(s.request('alpha',{includeArchived:true}))).cards.length,1);
      assert.equal(await s.lex.validate(first.cards,false,new M.ParsedCancellation()),false);
    }],
    ['lexical_cold_recovery_preserves_ordinary_schema',async()=>{
      const s=await setup();await s.add('cold alpha');await s.all(s.request('alpha'));const cold=new KnowledgeLexicalRepository(s.host,s.repo,h.identity);
      const r=await cold.search(s.request('alpha'),new M.ParsedCancellation());assert.equal(r.engine,'fts5');assert.equal(r.cards.length,1);await s.repo.close();await s.repo.open();assert.equal((await s.repo.list()).length,1);
    }],
    ['lexical_corrupt_authoritative_hash_is_never_success',async()=>{
      const s=await setup();const doc=await s.add('alpha safe');await s.all(s.request('alpha'));await s.store.executeSql('UPDATE upd_chunk SET text=? WHERE doc=?',['alpha altered',doc.documentKey]);await assert.rejects(()=>s.all(s.request('alpha')));
    }],
    ['lexical_cancel_does_not_return_old_success',async()=>{
      const s=await setup();await s.add('alpha');const cancel=new M.ParsedCancellation();cancel.invalid=true;await assert.rejects(()=>s.lex.search(s.request('alpha'),cancel));
    }],
    ['lexical_image_description_has_evidence_but_tag_only_does_not',async()=>{
      const s=await setup();const doc=await s.add('',true);const record=(await s.repo.imageRecords(doc.documentKey))[0];const a=new U.UnifiedEffectiveAnnotation();Object.assign(a,{id:'lex-effective',lineage:'lex-lineage',revision:1,imageHash:record.imageHash,description:'alpha diagram',tags:['tagonly'],textHash:hash(h.load('pipeline/UnifiedTextPolicy').unifiedProxyText('alpha diagram',['tagonly']))});assert(await s.repo.applyAnnotation(record,a,undefined));
      const r=await s.all(s.request('alpha'));assert.equal(r.cards.length,1);assert.equal(r.cards[0].kind,'Image');assert.equal(r.cards[0].reasons[0].evidenceType,'AiDescription');assert.equal((await s.all(s.request('tagonly'))).cards.length,0);
    }],
    ['lexical_failed_match_is_explicit_fallback',async()=>{
      const s=await setup();await s.add('alpha');await s.all(s.request('alpha'));const original=s.store.querySql.bind(s.store);s.store.querySql=(sql,args)=>{if(sql.includes('FROM klex_fts WHERE klex_fts MATCH'))throw Error('InjectedMatch');return original(sql,args);};
      const r=await s.all(s.request('alpha'));assert.equal(r.cards.length,1);assert.equal(r.fallbackReason,'FtsQueryFailed');assert.equal(r.engine,'literal-scan');
    }],
    ['lexical_partial_scan_cursor_does_not_report_empty_or_rescan',async()=>{
      const s=await setup(false);await s.fill(300);const req=s.request('"needleunique"');const first=await s.search(req);assert.equal(first.status,'partial');assert.equal(first.cards.length,0);assert.equal(first.scanned,256);
      req.cursor=first.cursor;req.scopeRevision=first.scopeRevision;const next=await s.search(req);assert.equal(next.scanned,44);assert.equal(next.cards.length,1);assert.notEqual(next.cursor,first.cursor);
    }],
    ['lexical_interrupted_index_checkpoint_resumes',async()=>{
      const s=await setup();await s.fill(300);const first=await s.search(s.request('needleunique'));assert.equal(first.indexState,'Building');
      const cold=new KnowledgeLexicalRepository(s.host,s.repo,h.identity);const next=await cold.search(s.request('needleunique'),new M.ParsedCancellation());assert.equal(next.indexState,'Ready');assert.equal(next.engine,'fts5');assert.equal(next.readback,1);assert.equal(next.cards.length,1);
    }],
    ['lexical_fts_dropped_table_recovers_without_reimport',async()=>{
      const s=await setup();await s.add('alpha');await s.all(s.request('alpha'));await s.store.executeSql('DROP TABLE klex_fts');await s.all(s.request('alpha'));const cold=new KnowledgeLexicalRepository(s.host,s.repo,h.identity);const r=await cold.search(s.request('alpha'),new M.ParsedCancellation());assert.equal(r.engine,'fts5');assert.equal(r.cards.length,1);
    }],
    ['lexical_l2_uses_shared_port_and_rejects_missing_consent',async()=>{
      const s=await setup();await s.add('alpha evidence');const {KnowledgeAgentSearchAdapter}=h.load('application/KnowledgeAgentSearchAdapter'),A=h.load('domain/KnowledgeAgentPorts');
      const E=h.load('domain/EmbeddingModels'),config=new E.EmbeddingConfig();
      const adapter=new KnowledgeAgentSearchAdapter({visible:async()=>true,captureLocal:async()=>{throw Error('FullCaptureForbidden');}},{currentConfig:()=>config},()=>{throw Error('NoSemantic');},async()=>{},async()=>{},undefined,s.lex);
      await adapter.open();const query=Object.assign(new A.KnowledgeAgentQuery(),{query:'alpha',keywords:['alpha'],mode:'direct'}),context=new A.KnowledgeAgentContext();
      await assert.rejects(()=>adapter.search(query,context,new M.ParsedCancellation()),/DENIED/);context.excerptEgressAllowed=true;
      const r=await adapter.search(query,context,new M.ParsedCancellation());assert.equal(r.hits.length,1);assert.equal(r.engine,'fts5');assert.equal(r.hits[0].engine,'fts5');assert.equal(r.hits[0].matchKind,'Literal');assert.equal(await adapter.validate(r.hits,new M.ParsedCancellation()),true);await adapter.close();
    }],
    ['lexical_page_semantic_failure_keeps_shared_local_results',async()=>{
      const s=await setup();await s.add('alpha evidence');const {KnowledgeQuerySession}=h.load('application/KnowledgeQuerySession'),E=h.load('domain/EmbeddingModels');
      const session=new KnowledgeQuerySession({visible:async()=>true,captureLocal:async()=>{throw Error('FullCaptureForbidden');}},{revoke:async()=>{},review:async()=>{throw Error('SemanticUnavailable');}},{currentConfig:()=>new E.EmbeddingConfig()},{append:async()=>{}},h.identity,s.lex);
      await session.start('alpha');assert.equal(session.state.direct.cards.length,1);assert.equal(session.state.direct.cards[0].reasons[0].engine,'fts5');await assert.rejects(()=>session.review());assert.equal(session.state.direct.cards.length,1);await session.close();
    }]
  ];
};
