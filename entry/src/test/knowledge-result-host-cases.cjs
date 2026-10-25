'use strict';
const assert=require('node:assert/strict');
const path=require('node:path');
const fs=require('node:fs');
const crypto=require('node:crypto');
module.exports=(outputRoot,project)=>{
  const root=path.join(outputRoot,'entry/src/main/ets/knowledge');
  const {KnowledgeSearchService}=require(path.join(root,'application/KnowledgeSearchService.js'));
  const models=require(path.join(root,'domain/KnowledgeSearchModels.js'));
  const pdfModels=require(path.join(root,'domain/PdfKnowledgeModels.js'));
  const pages=require(path.join(root,'application/PdfPageReferenceService.js'));
  const local=require(path.join(root,'domain/PdfLocalModels.js'));
  const {prepareTextQuery}=require(path.join(root,'pipeline/QueryPreparation.js'));
  const {knowledgeMatch,knowledgeLegacyMatch}=require(path.join(root,'pipeline/KnowledgeMatchPolicy.js'));
  const identity={id:()=>crypto.randomBytes(16).toString('hex'),hash:async bytes=>crypto.createHash('sha256').update(bytes).digest('hex')};
  function session(options={}){
    let calls=0,saved=[];
    const pdf={ready:()=>true,directCandidates:async()=>{if(options.pdfFailure)throw Error('read failed');return options.direct||[];},visible:async()=>true,saveHistory:async row=>{saved.push(row);}};
    const text={directCandidates:async()=>{if(options.textFailure)throw Error('read failed');return {hits:[],channel:'host'};},get:async()=>undefined};
    const service=new KnowledgeSearchService(text,pdf,identity);
    const semantic={queryEgress:false,async searchReviewed(){calls++;this.queryEgress=true;if(options.semanticFailure)throw Error('network failed');return options.vector||[];},pause(){}};service.attachSemantic(semantic);
    service.state.question='missing phrase';service.state.selectedSpaceId='space';service.state.queryConsent=true;service.state.queryFree=true;
    service.state.queryApproval={actual:'missing phrase',space:'space',purpose:'query',approved:true,free:true};
    return {service,get calls(){return calls;},get saved(){return saved;}};
  }
  function hit(text,vector=false){const h=new models.KnowledgeHit();Object.assign(h,{id:'pdf:'+text,chunkId:text,sourceKind:models.KnowledgeSourceKind.Pdf,text,spaceId:vector?'space':'',vectorGeneration:vector?'vgen':'',vectorDistance:vector?0.3:undefined,channels:[vector?models.KnowledgeChannel.Vector:models.KnowledgeChannel.Keyword],keywordScore:101});return h;}
  return [
    {name:'direct present suppresses independently approved model and binds actual input',run:async()=>{const s=session({direct:[hit('missing phrase repeated missing phrase')]});await s.service.search();assert.equal(s.calls,0);assert.equal(s.service.state.result.hits[0].match.kind,'Direct');assert.equal(s.service.state.result.hits[0].match.ranges.length,4);assert.match(s.service.state.result.hits[0].match.textHash,/^[a-f0-9]{64}$/);s.service.state.question='changed';assert.equal(s.service.state.result.hits[0].match.actualInput,'missing phrase');assert.equal(s.saved.length,1);}},
    {name:'complete zero direct plus typed current approval returns only real similar top5',run:async()=>{const s=session({vector:Array.from({length:8},(_,i)=>hit('candidate'+i,true))});await s.service.search();assert.equal(s.calls,1);assert.equal(s.service.state.result.channel,'vector');assert.equal(s.service.state.result.hits.length,5);assert(s.service.state.result.hits.every(h=>h.match.kind==='Similar'&&h.match.ranges.length===0));assert.match(s.service.state.message,/相似结果/);}},
    ...['textFailure','pdfFailure'].map(key=>({name:key+' never claims global zero or sends embedding',run:async()=>{const s=session({[key]:true});await s.service.search();assert.equal(s.calls,0);assert.match(s.service.state.message,/不完整/);}})),
    {name:'no consent, stale input, wrong purpose, missing free reject without RPC',run:async()=>{for(const change of ['none','actual','purpose','free']){const s=session();if(change==='none')s.service.state.queryConsent=false;else if(change==='free')s.service.state.queryApproval.free=false;else s.service.state.queryApproval[change]='wrong';await s.service.search();assert.equal(s.calls,0);assert.equal(s.service.state.result.hits.length,0);}}},
    {name:'prefix-only keyword cannot become Direct or Similar, vector literal is rejected',run:async()=>{const prefix=hit('unrelated');prefix.retrievalText='missing phrase\nunrelated';const s=session({direct:[prefix],vector:[hit('missing phrase',true),hit('genuine neighbor',true),prefix]});await s.service.search();assert.equal(s.calls,1);assert.deepEqual(s.service.state.result.hits.map(h=>h.text),['genuine neighbor']);}},
    {name:'semantic failure is not fabricated no-hit success',run:async()=>{const s=session({semanticFailure:true});await s.service.search();assert.equal(s.calls,1);assert.match(s.service.state.message,/相似检索不可用/);assert.equal(s.service.state.result.hits.length,0);}},
    {name:'direct candidate invalidated after scan does not authorize a false zero fallback',run:async()=>{const s=session({direct:[hit('missing phrase')]});s.service.pdf.visible=async()=>false;await s.service.search();assert.equal(s.calls,0);assert.equal(s.service.state.result.hits.length,0);assert.match(s.service.state.message,/来源已变化/);}},
    {name:'deadline rejects late semantic and retains input-bound empty fallback',run:async()=>{let now=Date.now();const s=session();s.service.setClock(()=>now);s.service.attachSemantic({queryEgress:false,async searchReviewed(){now+=10001;return [hit('late',true)];},pause(){}});await s.service.search();assert.equal(s.service.state.result.hits.length,0);assert.match(s.service.state.message,/截止/);}},
    {name:'legacy reconstruction uses saved input not title prefix/current question',run:async()=>{const h=hit('ROC roc');const m=knowledgeLegacyMatch(h,'roc');assert.equal(m.compatibility,true);assert.equal(m.ranges.length,2);assert.equal(m.actualInput,'roc');assert.equal(knowledgeLegacyMatch(h,'other').kind,'Unclassified');}},
    {name:'page service reads exact chunk nodes, original failure and durable release guard',run:async()=>{
      const doc=new pdfModels.PdfNormalizedDocument();Object.assign(doc,{id:'snapshot',hash:'c'.repeat(64),documentId:'doc',generation:'generation'});Object.assign(doc.binding,{originalId:'original',originalHash:'a'.repeat(64),originalVersion:1,originalPages:5,zipHash:'b'.repeat(64)});doc.coverage.hardPassed=true;
      const n=new pdfModels.PdfContentNode();Object.assign(n,{id:'node',text:'reviewed evidence',verified:true,kind:pdfModels.PdfNodeKind.Text,pageIndex0:0});doc.nodes=[n];
      const chunk=require(path.join(root,'pipeline/PdfStructureChunker.js')).pdfStructureChunks(doc,'generation',new pdfModels.KnowledgeCancellation())[0];const h=hit(chunk.text);Object.assign(h,{chunkId:chunk.id,documentId:'doc',generation:'generation',snapshotId:'snapshot',snapshotHash:doc.hash,originalHash:doc.binding.originalHash,originalVersion:1,retrievalText:chunk.retrievalText});
      const proof=new local.PdfPageIdentityEvidence();Object.assign(proof,{id:'proof',documentId:'doc',originalHash:doc.binding.originalHash,originalVersion:1,originalPages:5,zipHash:doc.binding.zipHash,snapshotId:doc.id,snapshotHash:doc.hash,generation:'generation',protocol:doc.profile,nodeId:n.id,nodeHash:await identity.hash(Buffer.from(n.text)),providerPage0:0,reviewVersion:'review',reviewRecordHash:'d'.repeat(64),uniqueAnchorHash:'e'.repeat(64),structureAnchorHash:'f'.repeat(64)});const f=new local.PdfReviewedPageFragment();Object.assign(f,{end:n.text.length,originalPage1:4,textHash:proof.nodeHash});proof.fragments=[f];
      let leases=0,failRelease=false,releasePending=0,originalMissing=false,epoch=0;
      const repository={async get(){return {tombstone:false,activeContentGeneration:'generation',binding:doc.binding,epoch};},async generationJob(){return {documentId:'doc',snapshotId:doc.id,snapshotHash:doc.hash,binding:doc.binding};},async chunkSources(){return ['node'];},async pageIdentities(){return [proof];},async acquireRead(){leases++;},async releaseRead(){if(failRelease)throw Error('release');leases--;},async sourceRelease(_lease,failure){if(failure)releasePending++;}};
      const service=new pages.PdfPageReferenceService(repository,{async read(){return doc;}},identity,'session',async()=>{if(originalMissing)throw Error('missing');});
      assert.equal((await service.resolve(h,new pdfModels.KnowledgeCancellation())).physicalPages1Based.join(','),'4');assert.equal(leases,0);
      originalMissing=true;await assert.rejects(()=>service.resolve(h,new pdfModels.KnowledgeCancellation()));assert.equal(leases,0);originalMissing=false;
      failRelease=true;await assert.rejects(()=>service.resolve(h,new pdfModels.KnowledgeCancellation()));assert.equal(releasePending,1);const held=leases;await assert.rejects(()=>service.resolve(h,new pdfModels.KnowledgeCancellation()));assert.equal(leases,held);
      failRelease=false;await repository.releaseRead();service.releaseRetried();assert.equal((await service.resolve(h,new pdfModels.KnowledgeCancellation())).state,'Verified');assert.equal(leases,0);
      await assert.rejects(()=>service.registerReview(new Uint8Array([1]),'0'.repeat(64),h,new pdfModels.KnowledgeCancellation()));
    }},
    {name:'history snapshot hash mismatch invalidates range and missing original forbids jump',run:async()=>{
      const h=hit('ROC');h.match=knowledgeMatch(h,prepareTextQuery('roc'),false);h.match.textHash='0'.repeat(64);const record=new models.KnowledgeHistory();record.result.input=prepareTextQuery('roc');record.result.hits=[h];
      const repository={async history(){return {records:[record]};}};const service=new KnowledgeSearchService({},repository,identity);const page=await service.historyPage(new models.KnowledgeHistoryCursor(),20);assert.equal(page.records[0].result.hits[0].referenceState,'Invalid');assert.equal(h.match.ranges.length,0);
      h.referenceState='Current';h.match=knowledgeMatch(h,prepareTextQuery('roc'),false);h.match.textHash=await identity.hash(Buffer.from(h.text));service.attachPages({async resolve(){throw Error('original missing');}});const unavailable=await service.historyPage(new models.KnowledgeHistoryCursor(),20);assert.equal(unavailable.records[0].result.hits[0].referenceState,'Invalid');assert.equal(h.text,'ROC');
    }},
    {name:'reviewed manifest covers exact normalized nodes and all 343 unchanged chunk texts',run:async()=>{
      const {readAuthorized}=require('./result-pages-offline.cjs');const {doc,digest}=await readAuthorized(project);
      const wire=fs.readFileSync(path.join(project,'entry/src/main/resources/rawfile/pdf-page-review-v1.json'));const review=JSON.parse(wire);
      Object.assign(doc,{id:review.snapshotId,hash:review.snapshotHash,documentId:review.documentId,generation:review.generation});
      const items=await pages.pdfReviewedPageItems(new Uint8Array(wire),doc,identity,new pdfModels.KnowledgeCancellation());assert.equal(items.length,review.pages.reduce((n,row)=>n+row[2].split(' ').length,0)+5);
      const drift=Object.assign(new pdfModels.PdfNormalizedDocument(),doc);drift.generation='changed';await assert.rejects(()=>pages.pdfReviewedPageItems(new Uint8Array(wire),drift,identity,new pdfModels.KnowledgeCancellation()));const mutated=Object.assign(new pdfModels.PdfNormalizedDocument(),doc);mutated.nodes=doc.nodes.slice();mutated.nodes[0]=Object.assign(new pdfModels.PdfContentNode(),doc.nodes[0],{text:'changed'});await assert.rejects(()=>pages.pdfReviewedPageItems(new Uint8Array(wire),mutated,identity,new pdfModels.KnowledgeCancellation()));
      const normalizedHash=digest([doc.binding.originalHash,doc.binding.zipHash,doc.profile,doc.normalizationVersion,doc.filterVersion,doc.nodes.map(n=>digest(JSON.stringify(n))).join('|')].join('\n'));assert.equal(normalizedHash,review.snapshotHash);
      const {pdfStructureChunks}=require(path.join(root,'pipeline/PdfStructureChunker.js'));const chunks=pdfStructureChunks(doc,doc.generation,new pdfModels.KnowledgeCancellation());assert.equal(chunks.length,343);
      let verified=0,cross=0;for(const chunk of chunks){const nodes=chunk.nodeIds.map(id=>doc.nodes.find(n=>n.id===id));const ranges=nodes.map(n=>({start:n.table?0:chunk.sourceStart,end:n.table?n.text.length:chunk.sourceEnd}));const r=pages.pdfResolveReviewedNodes(items[0],nodes,nodes.map(n=>digest(n.text)),nodes.map(n=>items.filter(e=>e.nodeId===n.id)),ranges);assert.equal(r.state,local.PdfPageReferenceState.Verified);verified++;if(r.physicalPages1Based.length>1)cross++;}
      assert.equal(verified,343);assert.equal(cross,5);assert(!items.some(i=>['node-11','node-100','node-181','node-205','node-281'].includes(i.nodeId)));assert(!items.some(i=>i.fragments.some(f=>f.originalPage1===30)));
      const literalCounts=[];for(const query of ['过拟合','ROC','roc','查准率 查全率']){const input=prepareTextQuery(query);const hits=chunks.map(c=>{const h=hit(c.text);h.match=knowledgeMatch(h,input,false);return h;}).filter(h=>h.match.kind==='Direct');assert(hits.length>0);assert(hits.every(h=>h.match.ranges.length>0));literalCounts.push(hits.length);}assert.equal(literalCounts[1],literalCounts[2]);console.log('result_literal_counts overfit='+literalCounts[0]+' upper='+literalCounts[1]+' lower='+literalCounts[2]+' multi='+literalCounts[3]);
      const gold=JSON.parse(require('./lib/portable.cjs').readTextLf(path.join(project,'entry/src/test/eval/round2-pdf-gold-candidate.json')));const questions=gold.questions||gold.cases;const p03=questions.find(q=>q.id==='P03');assert(p03);const text=p03.question||p03.query;assert.equal(chunks.filter(c=>knowledgeMatch(hit(c.text),prepareTextQuery(text),false).kind==='Direct').length,0);
      console.log('result_pages_offline nodes='+items.length+' chunks='+verified+' cross_chunks='+cross+' unknown_empty_nodes=5 original_last_page_unbound=1 new_rpc=0');
      console.log('result_pages_review_sha256='+digest(wire));
    }}
  ];
};
