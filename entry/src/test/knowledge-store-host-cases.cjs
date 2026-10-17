'use strict';
// Host SQLite is an injected SQL engine, NOT ArkData/device evidence.
const path=require('node:path');
const fs=require('node:fs');
const Module=require('node:module');
const assert=require('node:assert/strict');
const {DatabaseSync}=require('node:sqlite');
module.exports=(outputRoot)=>{
  const cache=new Map(); const stores=[]; let fault='';
  class Rows {
    constructor(statement,args) { this.columns=statement.columns().map(c=>c.name); this.rows=statement.all(...args); this.at=-1; }
    goToNextRow(){return ++this.at<this.rows.length;}
    getColumnIndex(name){const at=this.columns.indexOf(name); if(at<0)throw Error('ColumnMissing');return at;}
    getString(at){return String(this.rows[this.at][this.columns[at]]??'');}
    getLong(at){return Number(this.rows[this.at][this.columns[at]]??0);}
    getDouble(at){return this.getLong(at);}
    getValue(at){return this.rows[this.at][this.columns[at]];}
    isColumnNull(at){return this.rows[this.at][this.columns[at]]==null;}
    close(){}
  }
  class Store {
    constructor(){this.db=new DatabaseSync(':memory:');this.closes=0;}
    async querySql(sql,args=[]){return new Rows(this.db.prepare(sql),args);}
    async executeSql(sql,args=[]){if(fault&&sql.includes(fault))throw Error('InjectedSqlFailure');this.db.prepare(sql).run(...args);}
    async createTransaction(){await this.executeSql('BEGIN IMMEDIATE');return {execute:(sql,args=[])=>this.executeSql(sql,args),querySql:(sql,args=[])=>this.querySql(sql,args),commit:()=>this.executeSql('COMMIT'),rollback:()=>this.executeSql('ROLLBACK')};}
    async close(){this.closes++;}
  }
  const ark={relationalStore:{SecurityLevel:{S3:3},Tokenizer:{CUSTOM_TOKENIZER:1,NONE_TOKENIZER:0},isTokenizerSupported:()=>false,getRdbStore:async()=>{const store=new Store();stores.push(store);return store;}}};
  function load(relative){
    const file=path.resolve(outputRoot,relative);if(cache.has(file))return cache.get(file).exports;
    const mod=new Module(file,module);mod.filename=file;mod.paths=Module._nodeModulePaths(path.dirname(file));cache.set(file,mod);
    mod.require=id=>id==='@kit.ArkData'?ark:id==='@kit.AbilityKit'?{}:id.startsWith('.')?load(path.relative(outputRoot,path.resolve(path.dirname(file),id+'.js'))):require(id);
    mod._compile(fs.readFileSync(file,'utf8'),file);return mod.exports;
  }
  const infra='entry/src/main/ets/knowledge/infra/';
  const {KnowledgeStoreHost}=load(infra+'KnowledgeStoreHost.js');
  const {TextRdbRepository}=load(infra+'TextRdbRepository.js');
  const {PdfKnowledgeRepository}=load(infra+'PdfKnowledgeRepository.js');
  const d=load('entry/src/main/ets/knowledge/domain/PdfKnowledgeModels.js');
  const {KnowledgeLifecycleService}=load('entry/src/main/ets/knowledge/application/KnowledgeLifecycleService.js');
  let number=0;
  async function session(){const context={filesDir:'host-only-'+(++number)}; const host=KnowledgeStoreHost.forContext(context);const text=new TextRdbRepository(context,host);await text.open();const pdf=new PdfKnowledgeRepository(host);await pdf.open();return {host,text,pdf,store:stores.at(-1),guard:new KnowledgeLifecycleService(pdf)};}
  function input(){const doc=new d.PdfKnowledgeDocument();doc.id='kb-'+'1'.repeat(32);doc.sourceKey='source:hash:1';doc.binding.originalId='source';doc.binding.originalAssetId='original-source';doc.binding.originalHash='a'.repeat(64);doc.binding.originalVersion=1;doc.binding.originalBytes=100;doc.binding.originalPages=2;doc.binding.resultAssetId='result-source';doc.binding.zipHash='b'.repeat(64);doc.binding.zipBytes=100;const job=new d.PdfIngestionJob();job.id='job';job.documentId=doc.id;job.sourceId='source';job.generation='generation';job.processingKey='processing';const pins=['original-source','result-source'].map((asset,i)=>{const p=new d.KnowledgePin();p.id='pin-'+i;p.assetId=asset;p.sourceId='source';p.assetHash=i?'b'.repeat(64):'a'.repeat(64);p.ownerId=job.id;p.documentId=doc.id;p.generation=job.generation;return p;});return {doc,job,pins};}
  const cases=[
    {name:'unknown extension residual fails closed without resetting M1',run:async()=>{
      const context={filesDir:'host-residual-'+(++number)},host=KnowledgeStoreHost.forContext(context),text=new TextRdbRepository(context,host);await text.open();
      const store=stores.at(-1);await store.executeSql('CREATE TABLE kb_interrupted (id TEXT)');const pdf=new PdfKnowledgeRepository(host);await assert.rejects(()=>pdf.open());
      assert.equal(host.m1Ready,true);assert.equal(store.db.prepare("SELECT count(*) n FROM sqlite_master WHERE name='kb_interrupted'").get().n,1);assert.deepEqual(await text.list(),[]);
    }},
    {name:'M1-first shared lease and additive extension rollback',run:async()=>{
      const context={filesDir:'host-rollback-'+(++number)},host=KnowledgeStoreHost.forContext(context),text=new TextRdbRepository(context,host);
      const premature=new PdfKnowledgeRepository(host);await assert.rejects(()=>premature.open());await text.open();
      fault='CREATE TABLE kb_pin';const pdf=new PdfKnowledgeRepository(host);await assert.rejects(()=>pdf.open());fault='';
      assert.equal(host.m1Ready,true);assert.deepEqual(await text.list(),[]);const store=stores.at(-1);
      assert.equal(store.db.prepare("SELECT count(*) n FROM sqlite_master WHERE name GLOB 'kb_*'").get().n,0);
      await pdf.open();await text.close();assert.equal(store.closes,0);assert.equal(pdf.ready(),true);await pdf.close();assert.equal(store.closes,1);
    }},
    {name:'atomic pin owner rollback and idempotency',run:async()=>{
      const s=await session(),i=input();fault='INSERT INTO kb_pin';await assert.rejects(()=>s.pdf.register(i.doc,i.job,i.pins));fault='';
      assert.equal((await s.pdf.list()).length,0);assert.equal((await s.pdf.jobs()).length,0);
      await s.pdf.register(i.doc,i.job,i.pins);await s.pdf.register(i.doc,i.job,i.pins);assert.equal((await s.pdf.jobs()).length,1);assert.equal((await s.pdf.pins('source',[])).length,2);
      await assert.rejects(()=>s.guard.assertDeletable('source',['original-source']));
    }},
    {name:'explicit abandon waits reader then cleanup claim prevents late checkpoint',run:async()=>{
      const s=await session(),i=input();await s.pdf.register(i.doc,i.job,i.pins);
      const lease=new d.KnowledgeReadLease();lease.id='read';lease.sourceId='source';lease.generation=i.job.generation;lease.sessionId='session';await s.pdf.acquireRead(lease);
      await s.pdf.abandon(i.job.id);const intent=(await s.pdf.cleanups())[0];assert.equal(await s.pdf.claimCleanup(intent.id),undefined);
      await s.pdf.releaseRead(lease.id);const claim=await s.pdf.claimCleanup(intent.id);assert(claim&&claim.claim);
      await assert.rejects(()=>s.pdf.checkpoint(i.job));await assert.rejects(()=>s.pdf.acquireRead(lease));await s.pdf.finishCleanup(claim,'disk-failed');assert.equal((await s.pdf.cleanups()).length,1);
      await s.pdf.finishCleanup(claim,'');await s.guard.assertDeletable('source',['original-source']);
    }},
    {name:'keyword publication approval and deleted late publication hidden',run:async()=>{
      const s=await session(),i=input();await s.pdf.register(i.doc,i.job,i.pins);i.job.snapshotId='snapshot';i.job.snapshotHash='c'.repeat(64);i.job.reportHash='report';i.job.stage=d.PdfStage.Review;i.job.checkpoint=d.PdfStage.Review;await s.pdf.checkpoint(i.job);
      const chunk=new d.PdfChunk();chunk.id='generation-c0';chunk.documentId=i.doc.id;chunk.generation=i.job.generation;chunk.snapshotId='snapshot';chunk.snapshotHash=i.job.snapshotHash;chunk.originalHash=i.doc.binding.originalHash;chunk.originalVersion=1;chunk.retrievalText='unit evidence';chunk.text='unit evidence';
      const approval=new d.PdfPartialApproval();approval.reportHash='report';approval.snapshotHash=i.job.snapshotHash;approval.confirmedAt=Date.now();
      await s.pdf.prepare(i.doc,i.job,[chunk],approval);assert.equal(await s.pdf.publish(i.doc,i.job,approval),true);
      const query={terms:['evidence']};const hits=await s.pdf.candidates(query,false,false,new d.KnowledgeCancellation());assert.equal(hits.length,1);assert.equal(await s.pdf.visible(hits[0],false),true);
      await s.pdf.archive(i.doc.id,true);assert.equal((await s.pdf.candidates(query,false,false,new d.KnowledgeCancellation())).length,0);assert.equal((await s.pdf.pins('source',[])).length,2);
      await s.pdf.deleteDocument(i.doc.id);assert.equal(await s.pdf.publish(i.doc,i.job,approval),false);assert.equal((await s.pdf.candidates(query,true,true,new d.KnowledgeCancellation())).length,0);
    }},
    {name:'single new history preserves full question and leaves legacy tables unchanged',run:async()=>{
      const s=await session();const models=load('entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.js');const record=new models.KnowledgeHistory();record.id='q1';record.createdAt=10;record.result.input.fullQuestion='unit-question-'.repeat(2000);record.result.input.actualInput='unit';
      await s.pdf.saveHistory(record);const page=await s.pdf.history(new models.KnowledgeHistoryCursor(),20);assert.equal(page.records.length,1);assert.equal(page.records[0].result.input.fullQuestion,record.result.input.fullQuestion);
      assert.equal(s.store.db.prepare('SELECT count(*) n FROM text_query').get().n,0);await s.pdf.saveHistory(record);assert.equal((await s.pdf.history(new models.KnowledgeHistoryCursor(),20)).records.length,1);record.result.input.actualInput='changed';await assert.rejects(()=>s.pdf.saveHistory(record));
    }},
    {name:'result sidecar migration reopens without rewriting content or old history',run:async()=>{
      const s=await session();const before=s.store.db.prepare("SELECT sql FROM sqlite_master WHERE name IN ('text_doc','text_chunk','text_query','kb_chunk','kb_content_generation') ORDER BY name").all();
      s.store.db.exec("DROP TABLE kb_page_identity; DROP TABLE kb_result_presentation; DELETE FROM kb_migration WHERE id='KB-PDF-RESULT-1'");await s.pdf.close();await s.pdf.open();
      assert.deepEqual(s.store.db.prepare("SELECT sql FROM sqlite_master WHERE name IN ('text_doc','text_chunk','text_query','kb_chunk','kb_content_generation') ORDER BY name").all(),before);
      assert.equal(s.store.db.prepare("SELECT state FROM kb_migration WHERE id='KB-PDF-RESULT-1'").get().state,'Committed');await s.pdf.close();await s.pdf.open();assert.equal(s.pdf.ready(),true);
    }},
    {name:'both direct SQL ports find later body hits before top20 despite title prefixes',run:async()=>{
      const s=await session(),i=input();await s.pdf.register(i.doc,i.job,i.pins);i.job.snapshotId='snapshot';i.job.snapshotHash='c'.repeat(64);i.job.reportHash='report';i.job.stage=d.PdfStage.Review;await s.pdf.checkpoint(i.job);
      const chunks=Array.from({length:26},(_,at)=>{const c=new d.PdfChunk();Object.assign(c,{id:'chunk-'+String(at).padStart(2,'0'),documentId:i.doc.id,generation:i.job.generation,snapshotId:'snapshot',snapshotHash:i.job.snapshotHash,originalHash:i.doc.binding.originalHash,originalVersion:1,ordinal:at,retrievalText:'needle\n'+(at===25?'Needle 正文':'unrelated'),text:at===25?'Needle 正文':'unrelated'});return c;});
      const approval=new d.PdfPartialApproval();Object.assign(approval,{reportHash:'report',snapshotHash:i.job.snapshotHash,confirmedAt:Date.now()});await s.pdf.prepare(i.doc,i.job,chunks,approval);await s.pdf.publish(i.doc,i.job,approval);
      const query={actualInput:'needle',terms:['needle']};const pdf=await s.pdf.directCandidates(query,false,false,new d.KnowledgeCancellation());assert.deepEqual(pdf.map(h=>h.chunkId),['chunk-25']);assert((await s.pdf.candidates(query,false,false,new d.KnowledgeCancellation())).length===20);
      const td=load('entry/src/main/ets/knowledge/domain/TextKnowledgeModels.js');const doc=new td.TextDocument();Object.assign(doc,{id:'text',title:'needle',activeGeneration:'g',version:1});doc.original.hash='d'.repeat(64);doc.original.assetId='original-t';doc.original.bytes=1;const job=new td.TextJob();Object.assign(job,{id:'tjob',documentId:'text',generation:'g'});await s.text.add(doc,job);
      const textChunks=chunks.map((c,at)=>{const t=new td.TextChunk();Object.assign(t,{id:'tc'+at,documentId:'text',generation:'g',snapshotId:'tsnap',ordinal:at,retrievalText:c.retrievalText,evidenceText:c.text});return t;});job.stage=td.TextStage.Prepared;job.startedAt=Date.now();await s.text.prepare(doc,job,textChunks);await s.text.publish(doc,job,26);
      const text=await s.text.directCandidates(query,false,new td.TextCancellation());assert.deepEqual(text.hits.map(h=>h.chunkId),['tc25']);assert.equal((await s.text.candidates(query,false,new td.TextCancellation())).hits.length,20);
      await s.pdf.archive(i.doc.id,true);assert.equal((await s.pdf.directCandidates(query,false,false,new d.KnowledgeCancellation())).length,0);await s.pdf.deleteDocument(i.doc.id);assert.equal((await s.pdf.directCandidates(query,true,true,new d.KnowledgeCancellation())).length,0);
    }},
    {name:'result presentation new sidecar roundtrip legacy no-sidecar and deleted snapshot',run:async()=>{
      const s=await session();const m=load('entry/src/main/ets/knowledge/domain/KnowledgeSearchModels.js');const {knowledgeMatch}=load('entry/src/main/ets/knowledge/pipeline/KnowledgeMatchPolicy.js');const {prepareTextQuery}=load('entry/src/main/ets/knowledge/pipeline/QueryPreparation.js');
      const record=new m.KnowledgeHistory();record.id='presentation';record.createdAt=11;record.result.input=prepareTextQuery('roc');const h=new m.KnowledgeHit();Object.assign(h,{id:'pdf:removed',sourceKind:m.KnowledgeSourceKind.Pdf,documentId:'removed',text:'ROC roc'});h.match=knowledgeMatch(h,record.result.input,false);h.match.textHash=require('node:crypto').createHash('sha256').update(h.text).digest('hex');record.result.hits=[h];
      await s.pdf.saveHistory(record);const page=await s.pdf.history(new m.KnowledgeHistoryCursor(),20);assert.equal(page.records[0].result.hits[0].match.ranges.length,2);assert.equal(page.records[0].result.hits[0].match.actualInput,'roc');assert.equal(page.records[0].result.hits[0].referenceState,'Invalid');assert.equal(s.store.db.prepare('SELECT count(*) n FROM text_query').get().n,0);
      const old=s.store.db.prepare('SELECT * FROM kb_citation').all();s.store.db.exec('DELETE FROM kb_result_presentation');const legacy=await s.pdf.history(new m.KnowledgeHistoryCursor(),20);assert.equal(legacy.records[0].result.hits[0].match.compatibility,true);assert.equal(legacy.records[0].result.hits[0].match.ranges.length,2);assert.deepEqual(s.store.db.prepare('SELECT * FROM kb_citation').all(),old);
    }}
  ];
  return cases;
};
