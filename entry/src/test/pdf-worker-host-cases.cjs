'use strict';
// Injected scheduling/crypto only. No TaskPool threads, ImageKit, files, device or provider.
const fs=require('node:fs');
const path=require('node:path');
const Module=require('node:module');
const crypto=require('node:crypto');
const assert=require('node:assert/strict');
module.exports=(outputRoot,project)=>{
  const cache=new Map();let rejectCode,taskCanceled=false;
  const forbidden=()=>{throw Error('Platform access forbidden in host worker test');};
  class InjectedTask {constructor(fn,...args){this.fn=fn;this.args=args;}static isCanceled(){return taskCanceled;}}
  const kits={
    '@kit.ArkTS':{taskpool:{Task:InjectedTask,GenericsTask:InjectedTask,cancel(){taskCanceled=true;},async execute(task,...args){if(rejectCode!==undefined)throw {code:rejectCode,message:'withheld-body'};const fn=typeof task==='function'?task:task.fn;const values=typeof task==='function'?args:task.args;return structuredClone(await fn(...structuredClone(values)));}},util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder('utf-8',{fatal:true}).decode(bytes)})}}},
    '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd(name){assert.equal(name,'SHA256');const hash=crypto.createHash('sha256');return {async update(blob){hash.update(blob.data);},async digest(){return {data:new Uint8Array(hash.digest())};}};}}},
    '@kit.CoreFileKit':{fileIo:new Proxy({},{get:()=>forbidden})},'@kit.ImageKit':{},'@kit.BasicServicesKit':{}
  };
  function load(relative){
    const filename=path.resolve(outputRoot,relative);if(cache.has(filename))return cache.get(filename).exports;
    const mod=new Module(filename,module);mod.filename=filename;mod.paths=Module._nodeModulePaths(path.dirname(filename));cache.set(filename,mod);
    mod.require=id=>Object.hasOwn(kits,id)?kits[id]:id.startsWith('.')?load(path.relative(outputRoot,path.resolve(path.dirname(filename),id+'.js'))):require(id);
    mod._compile(fs.readFileSync(filename,'utf8'),filename);return mod.exports;
  }
  const base='entry/src/main/ets/knowledge/';
  const d=load(base+'domain/PdfKnowledgeModels.js'),w=load(base+'domain/PdfWorkerModels.js'),p=load(base+'pipeline/PdfWorkerPolicy.js');
  const {PdfProcessingAdapter}=load(base+'infra/PdfProcessingAdapter.js');
  const {PdfAssetAdapter}=load(base+'infra/PdfAssetAdapter.js');
  const workers=load(base+'infra/PdfSnapshotWorker.js');
  const {pdfWorkerAwait}=load(base+'infra/PdfWorkerSupport.js');
  const {PdfProfileTestArchive}=load('entry/src/test/PdfStructureCases.js');
  const codec=load(base+'pipeline/PdfSnapshotCodec.js');
  async function snapshot(){const archive=new PdfProfileTestArchive(),binding=new d.PdfSourceBinding();binding.originalPages=1;binding.zipHash='b'.repeat(64);const cancel=new d.KnowledgeCancellation(),manifest=await archive.inspect(binding,cancel);return new PdfProcessingAdapter().normalize(binding,manifest,archive,cancel);}
  function controlled(category,stage){return error=>error instanceof d.KnowledgeFailure&&error.category===category&&error.stage===stage&&!error.message.includes('withheld');}
  const cases=[
    {name:'seven consumers decode data-only success payloads without changing snapshot bytes',run:async()=>{
      const adapter=new PdfProcessingAdapter(),doc=await snapshot(),cancel=new d.KnowledgeCancellation();doc.id='snap';doc.documentId='doc';doc.generation='gen';
      const sealed=await adapter.sealSnapshot(doc,cancel);await adapter.verifySnapshot(sealed,cancel);assert.equal(sealed.profile,'MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1');assert.equal(adapter.active,undefined);
      const chunks=await adapter.chunks(sealed,'gen',cancel);assert.equal(chunks.length,1);assert.equal(chunks[0].text,'fixture');
      const asset=new PdfAssetAdapter('host','host',{}),bytes=await asset.encodeNode(sealed.nodes[0],cancel);assert.deepEqual(await asset.hydrateNode(bytes,cancel),sealed.nodes[0]);
      const header=p.pdfWorkerSnapshotParts(sealed,cancel)[0];assert.deepEqual(await asset.hydrateHeader(header,cancel),codec.pdfDecodeSnapshotHeader(header,cancel));
      sealed.hash='wrong';await assert.rejects(()=>adapter.verifySnapshot(sealed,cancel),controlled('SnapshotContentHashMismatch','readback'));
    }},
    {name:'normalizer domain rejection survives injected copy and release of active task',run:async()=>{
      const archive=new PdfProfileTestArchive();archive.layout=archive.layout.replace('3.4.4','4.0.0');const binding=new d.PdfSourceBinding();binding.originalPages=1;binding.zipHash='b'.repeat(64);const cancel=new d.KnowledgeCancellation(),adapter=new PdfProcessingAdapter();
      await assert.rejects(async()=>adapter.normalize(binding,await archive.inspect(binding,cancel),archive,cancel),controlled('ProtocolProfileUnrecognized','normalize'));
      assert.equal(adapter.active,undefined);
    }},
    {name:'all operation scheduler rejections retain stage code and never raw message',run:async()=>{
      const doc=await snapshot(),cancel=new d.KnowledgeCancellation(),adapter=new PdfProcessingAdapter(),assets=new PdfAssetAdapter('host','host',{}),archive=new PdfProfileTestArchive();
      rejectCode=10200006;
      try{for(const [op,action] of [['normalize',async()=>adapter.normalize(doc.binding,await archive.inspect(doc.binding,cancel),archive,cancel)],['chunks',()=>adapter.chunks(doc,'gen',cancel)],['seal',()=>adapter.sealSnapshot(doc,cancel)],['verify',()=>adapter.verifySnapshot(doc,cancel)],['encode-node',()=>assets.encodeNode(doc.nodes[0],cancel)],['hydrate-node',()=>assets.hydrateNode(new Uint8Array([0]),cancel)],['hydrate-header',()=>assets.hydrateHeader(new Uint8Array([0]),cancel)]]){await assert.rejects(action,error=>controlled('WorkerOperationFailed','pdf-'+op)(error)&&error.code===10200006);assert.equal(adapter.active,undefined);}}
      finally{rejectCode=undefined;}
      const invalid=await pdfWorkerAwait(Promise.reject({code:1.5,message:'withheld'}),'verify',cancel).catch(error=>error);assert.equal(invalid.code,undefined);
    }},
    {name:'invalid envelope types branches fields and sensitive extra metadata rejected',run:async()=>{
      const good=p.pdfWorkerSuccess('verify',[new Uint8Array([1])]);
      const failure=p.pdfWorkerCaught('verify',new d.KnowledgeFailure('Timeout','session'));
      for(const value of [undefined,null,0,'text',{}, {...good,wire:0},{...good,status:true},{...good,payload:null},{...good,payload:[1]},{...good,message:'withheld'}, {...failure,failure:null},{...failure,payload:[]},{...failure,failure:{category:'Timeout',stage:'session',message:'withheld'}},{...failure,failure:{category:'Timeout',stage:42}},{...failure,failure:{category:'Timeout',stage:'session',code:'10200006'}},{...failure,failure:{category:'Timeout',stage:'session',code:Number.MAX_SAFE_INTEGER+1}}]){
        assert.throws(()=>p.pdfWorkerPayload(value,'verify',new d.KnowledgeCancellation()),controlled('WorkerResultInvalid','pdf-verify'));
      }
      assert.throws(()=>p.pdfWorkerReadNode([],new d.KnowledgeCancellation(),'hydrate-node'));
      assert.throws(()=>p.pdfWorkerReadSnapshot([],new d.KnowledgeCancellation(),'normalize'));
      const doc=await snapshot();assert.throws(()=>p.pdfWorkerReadChunks([new Uint8Array([123,125])],doc,'gen',new d.KnowledgeCancellation()));
      const chunks=await new PdfProcessingAdapter().chunks(doc,'unit',new d.KnowledgeCancellation());const changed={...chunks[0],text:'forged',retrievalText:'forged',embeddingText:'forged'};
      assert.throws(()=>p.pdfWorkerReadChunks([codec.pdfCodecUtf8(JSON.stringify(changed))],doc,'unit',new d.KnowledgeCancellation()),controlled('WorkerResultInvalid','pdf-chunks'));
      assert.equal(p.pdfWorkerCaught('seal',new Error('withheld'),17).failure.code,17);
    }},
    {name:'all worker consumers reject missing malformed or wrong-operation success data',run:async()=>{
      const doc=await snapshot(),adapter=new PdfProcessingAdapter(),assets=new PdfAssetAdapter('host','host',{}),cancel=new d.KnowledgeCancellation(),archive=new PdfProfileTestArchive();const execute=kits['@kit.ArkTS'].taskpool.execute;
      const actions=[['normalize',async()=>adapter.normalize(doc.binding,await archive.inspect(doc.binding,cancel),archive,cancel)],['seal',()=>adapter.sealSnapshot(doc,cancel)],['chunks',()=>adapter.chunks(doc,'gen',cancel)],['verify',()=>adapter.verifySnapshot(doc,cancel)],['encode-node',()=>assets.encodeNode(doc.nodes[0],cancel)],['hydrate-node',()=>assets.hydrateNode(new Uint8Array([123,125]),cancel)],['hydrate-header',()=>assets.hydrateHeader(new Uint8Array([123,125]),cancel)]];
      try{for(const [op,action] of actions){for(const result of [p.pdfWorkerSuccess(op,[]),p.pdfWorkerSuccess(op,[new Uint8Array([0])]),p.pdfWorkerSuccess('invalid',[new Uint8Array([1])])]){kits['@kit.ArkTS'].taskpool.execute=async()=>result;await assert.rejects(action,error=>error instanceof d.KnowledgeFailure);assert.equal(adapter.active,undefined);}}}finally{kits['@kit.ArkTS'].taskpool.execute=execute;}
    }},
    {name:'deadline canceled worker and late success never become success',run:async()=>{
      const doc=await snapshot(),adapter=new PdfProcessingAdapter(),cancel=new d.KnowledgeCancellation();
      cancel.deadline=0;await assert.rejects(()=>adapter.sealSnapshot(doc,cancel),controlled('Timeout','session'));
      taskCanceled=true;try{const result=workers.pdfHydrateNodeWorker(new Uint8Array([123,125]),Date.now()+10000);assert.throws(()=>p.pdfWorkerPayload(result,'hydrate-node',new d.KnowledgeCancellation()),controlled('Canceled','pdf-worker'));}finally{taskCanceled=false;}
    }},
    {name:'worker allowlist covers all literal failures reachable from seven operations',run:async()=>{
      const names=['pipeline/MineruPdfNormalizer','pipeline/BoundedDocumentJson','pipeline/PdfTableDecoder','pipeline/PdfSnapshotCodec','pipeline/PdfStructureChunker','infra/PdfProcessingAdapter','infra/PdfSnapshotWorker','infra/PdfWorkerSupport'];
      for(const name of names){const source=fs.readFileSync(path.join(project,'entry/src/main/ets/knowledge',name+'.ets'),'utf8');for(const match of source.matchAll(/new KnowledgeFailure\('([^']+)'\s*,\s*'([^']+)'/g)){const result=p.pdfWorkerCaught('normalize',new d.KnowledgeFailure(match[1],match[2]));assert.equal(result.failure.category,match[1]);assert.equal(result.failure.stage,match[2]);}}
    }},
    {name:'old true package seal verify and chunks keep frozen snapshot report hashes',run:async()=>{
      const {doc}=await require('./result-pages-offline.cjs').readAuthorized(project);const adapter=new PdfProcessingAdapter(),cancel=new d.KnowledgeCancellation();
      const sealed=await adapter.sealSnapshot(doc,cancel);await adapter.verifySnapshot(sealed,cancel);
      console.log('ocr_fix_old_snapshot_sha256='+sealed.hash);console.log('ocr_fix_old_report_sha256='+sealed.coverage.hash);
      assert.equal(sealed.hash,'7cc6022572ca890114c4e90e3096ddc5318eaceee755ba44ebcb5e83b847e281');assert.equal(sealed.coverage.hash,'6b57aaa8827b25325bf41c1a2f82fb4c81fb3a95f6c0af1ee4d92d06a55ac864');
      assert.equal((await adapter.chunks(sealed,'legacy',cancel)).length,343);
    }},
    {name:'successful resume checkpoints false profile and reuses same candidate without republish',run:async()=>{
      const {PdfIngestionService}=load(base+'application/PdfIngestionService.js'),doc=new d.PdfKnowledgeDocument(),job=new d.PdfIngestionJob();doc.id='document';doc.binding.originalPages=1;doc.binding.zipHash='b'.repeat(64);job.id='existing';job.documentId=doc.id;job.generation='generation';job.processingKey='legacy-key';job.binding=doc.binding;
      let stored,checkpoints=0,reads=0,releases=0,normalizations=0,number=0;const adapter=new PdfProcessingAdapter();const archive=new PdfProfileTestArchive();const normalizer={normalize:async(...args)=>{normalizations++;return adapter.normalize(...args);},verifySnapshot:(...args)=>adapter.verifySnapshot(...args),sealSnapshot:(...args)=>adapter.sealSnapshot(...args)};
      const repository={async resumeJob(){return job;},async get(){return doc;},async jobs(){return [job];},async acquireRead(){reads++;},async releaseRead(){releases++;},async releaseFailure(){},async checkpoint(row){assert.equal(row.id,'existing');assert.equal(row.processingKey,'legacy-key');assert.equal(row.profile,'MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1');checkpoints++;}};
      const assets={async saveImages(){},async save(row){stored=row;},async read(){return stored;}};
      const service=new PdfIngestionService(repository,{},archive,normalizer,assets,{id:()=> 'synthetic-'+(++number)});await service.resume(job.id);assert.equal(service.state.stage,d.PdfStage.Review);assert.equal(service.state.report.issues.filter(i=>i.code==='NodeTypeUnsupported').length,1);assert.equal(checkpoints,1);assert.equal(normalizations,1);
      const identity=job.snapshotId;await service.resume(job.id);assert.equal(service.state.stage,d.PdfStage.Review);assert.equal(job.snapshotId,identity);assert.equal(checkpoints,1);assert.equal(normalizations,1);assert.equal(reads,releases);assert.equal(doc.activeContentGeneration,'');assert.equal(job.processingKey,'legacy-key');
    }},
    {name:'service resume persists typed worker failure same job and preserves finally release pending',run:async()=>{
      const {PdfIngestionService}=load(base+'application/PdfIngestionService.js');const job=new d.PdfIngestionJob(),doc=new d.PdfKnowledgeDocument();job.id='existing';job.generation='existing-generation';job.documentId='document';job.binding=doc.binding;doc.id='document';let saved=[],reads=0,releases=0,registered=0;
      const repository={async resumeJob(){return job;},async get(){return doc;},async jobs(){return [job];},async checkpoint(row){saved.push({...row});},async acquireRead(){reads++;},async releaseRead(){releases++;},async releaseFailure(){},async register(){registered++;throw Error('unexpected');}};
      const archive={async inspect(){throw new d.KnowledgeFailure('ProtocolProfileUnrecognized','normalize');},async release(){}};
      const service=new PdfIngestionService(repository,{},archive,{}, {},{id:()=> 'lease'});await service.resume(job.id);
      assert.equal(service.state.message,'ProtocolProfileUnrecognized / normalize');assert.equal(saved.at(-1).failure,service.state.message);assert.equal(service.state.busy,false);assert.equal(service.state.releasing,false);assert.equal(reads,releases);assert.equal(registered,0);assert.equal(saved.at(-1).generation,'existing-generation');
      archive.release=async()=>{throw Error('withheld');};await service.resume(job.id);assert.equal(service.state.releasing,true);assert.equal(service.state.busy,false);assert(!service.state.message.includes('withheld'));
    }}
  ];
  return cases;
};
