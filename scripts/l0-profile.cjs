'use strict';
// Synthetic, isolated host SQLite fixture. No production database or platform-quality claims.
const assert=require('node:assert/strict');
const {performance}=require('node:perf_hooks');
async function main(){
  const h=require('../entry/src/test/unified-host-entry.cjs').harness();const cases=require('../entry/src/test/knowledge-lexical-host-cases.cjs');cases.cases(h);
  const M=h.load('domain/ParsedDocumentModels'),E=h.load('domain/EmbeddingModels');
  const {UnifiedQueryRepository}=h.load('infra/UnifiedQueryRepository');const policy=h.load('pipeline/KnowledgeRetrievalPolicy');
  const percentile=(samples,p)=>samples.slice().sort((a,b)=>a-b)[Math.ceil(samples.length*p)-1].toFixed(2);
  for(const count of [1000,10000,30000]){
    const s=await cases.fixture();await s.fill(count);const raw=s.store.db.prepare('SELECT SUM(length(CAST(text AS BLOB))) n FROM upd_chunk').get().n;
    const before=s.store.db.prepare('PRAGMA page_count').get().page_count;let rounds=0,r;const buildAt=performance.now();
    do{r=await s.search(s.request('needleunique'));rounds++;assert(rounds<200);}while(r.indexState!=='Ready');
    const buildMs=performance.now()-buildAt;
    const after=s.store.db.prepare('PRAGMA page_count').get().page_count,pageSize=s.store.db.prepare('PRAGMA page_size').get().page_size;
    const config=new E.EmbeddingConfig();const source=new UnifiedQueryRepository(s.host,s.repo,{}, {currentConfig:()=>config},h.identity);
    const indexed=[],scan=[];let readback=0;
    for(let i=0;i<7;i++){
      let start=performance.now();r=await s.search(s.request('needleunique'));indexed.push(performance.now()-start);assert.equal(r.engine,'fts5');assert.equal(r.cards.length,1);assert.equal(r.scanned,0);readback=r.readback;
      start=performance.now();const scope=await source.captureLocal(config,false,new M.ParsedCancellation());const old=policy.unifiedLocalDirect(scope,'needleunique');scan.push(performance.now()-start);assert.equal(old.length,1);
    }
    assert(Number(percentile(indexed,.5))<Number(percentile(scan,.5)));
    console.log('L0_PROFILE rows='+count+' body_utf8_bytes='+raw+' chinese=7_chars_per_regular_row samples=7 analyzer=host_unicode61 index_rounds='+rounds+' maintenance_ms='+buildMs.toFixed(2)+' fts_p50_ms='+percentile(indexed,.5)+' fts_p95_ms='+percentile(indexed,.95)+' scan_p50_ms='+percentile(scan,.5)+' scan_p95_ms='+percentile(scan,.95)+' candidate_readback='+readback+' scanned=0 derived_page_delta_bytes='+((after-before)*pageSize)+' process_heap_bytes='+process.memoryUsage().heapUsed);
  }
}
main().catch(e=>{console.log('L0_PROFILE_FAIL '+e.constructor.name+' '+String(e.message).replace(/token/gi,'term'));process.exitCode=1;});
