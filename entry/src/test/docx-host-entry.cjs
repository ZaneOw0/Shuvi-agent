'use strict';
// Independent synthetic-only loader. No legacy runner, credentials, databases or user fixtures.
const fs=require('node:fs');
const path=require('node:path');
const Module=require('node:module');
const crypto=require('node:crypto');
const {DatabaseSync}=require('node:sqlite');
const project=path.resolve(__dirname,'../../..');
const root=path.join(project,'entry/src/main/ets/knowledge');
const allowed=[
  'domain/DocxKnowledgeModels','domain/DocxKnowledgePorts','domain/DocxXmlModels','domain/DocumentParseModels','domain/DocumentParsePorts','domain/KnowledgePorts',
  'domain/KnowledgeStorageScope','domain/PdfKnowledgeModels','domain/PdfLocalModels','domain/KnowledgeSearchModels',
  'domain/TextKnowledgeModels','domain/EmbeddingModels','domain/EmbeddingBasisModels','domain/ImageKnowledgeModels','domain/VectorWorkflowModels',
  'infra/KnowledgeStoreHost','infra/DocxStoreLayout','infra/DocxKnowledgeRepository','infra/DocumentParseRepository','infra/ImageStoreLayout','infra/ImageKnowledgeRepository','infra/PdfKnowledgeRepository','infra/PdfVectorRepository','infra/KnowledgePublicationBudget',
  'pipeline/DocumentParsePolicy','pipeline/ParseFailurePolicy','pipeline/BoundedDocumentJson','pipeline/PdfSnapshotCodec','pipeline/SafeZipPolicy','pipeline/TextNormalizer','pipeline/MarkdownStructure','pipeline/PdfStructureChunker','pipeline/KnowledgeRetrievalPolicy',
  'pipeline/ImageSnapshotCodec','pipeline/ImageContentNormalizer','pipeline/ImageHeaderPolicy','pipeline/PdfMappingPolicy','pipeline/PdfEvidenceCodec','pipeline/StructuredChunker','pipeline/Chunker','pipeline/QueryPreparation','pipeline/KnowledgeMatchPolicy','pipeline/EmbeddingPolicy','pipeline/EmbeddingBasisPolicy','pipeline/EmbeddingSpacePolicy',
  'application/PdfPageReferenceService','application/DocumentParseService','application/EmbeddingWorkflow','application/QueryConsentSession',
  'infra/DocxVectorRepository','infra/ImageVectorRepository','infra/KnowledgeReadDispatcher','infra/DocxSourceReader','infra/KnowledgeSourceRegistry','infra/DocxSourceSession',
  'infra/PdfNativeReader','infra/DocumentFileOperations','infra/DocxProcessingAdapter','infra/DocxSnapshotAssets','application/DocxIngestionService',
  'application/KnowledgeSearchService','application/KnowledgeDeadline','application/EmbeddingService','ui/DocxIngestionView',
  'pipeline/DocxPackagePolicy','infra/DocxArchiveAdapter','infra/DocxXmlAdapter','infra/DocxXmlReader','pipeline/DocxNativeReader','infra/DocxResultReader','pipeline/DocxCorrespondence','pipeline/DocxSnapshotCodec','pipeline/DocxStructureChunker'
];
exports.changedEts=[
  'domain/DocxKnowledgeModels','domain/DocxKnowledgePorts','infra/DocxStoreLayout','infra/DocxKnowledgeRepository',
  'infra/KnowledgeStoreHost','domain/DocumentParseModels','infra/DocumentParseRepository','infra/ImageStoreLayout',
  'infra/ImageKnowledgeRepository','infra/PdfKnowledgeRepository','domain/DocxXmlModels','infra/DocxArchiveAdapter','infra/DocxXmlAdapter',
  'infra/DocxResultReader','infra/DocxProcessingAdapter','infra/DocxSnapshotAssets','pipeline/DocxPackagePolicy','pipeline/DocxNativeReader',
  'pipeline/DocxCorrespondence','pipeline/DocxSnapshotCodec','pipeline/DocxStructureChunker','application/DocxIngestionService','ui/DocxIngestionView',
  'application/DocumentParseService','infra/DocumentFileAdapter','infra/DocumentFileOperations','infra/MineruTransportAdapter','domain/DocumentParsePorts','pipeline/DocumentParsePolicy','infra/KnowledgeDerivedBudget',
  'domain/KnowledgeSearchModels','domain/EmbeddingModels','infra/DocxVectorRepository','infra/DocxSourceReader','infra/DocxSourceSession',
  'infra/KnowledgePublicationBudget','infra/TextRdbRepository','infra/KnowledgeReadDispatcher','infra/ImageVectorRepository','infra/KnowledgeSourceRegistry',
  'infra/EmbeddingTransportAdapter','infra/KnowledgeAssembly','application/EmbeddingWorkflow','application/KnowledgeLifecycleService',
   'pipeline/EmbeddingPolicy','pipeline/KnowledgeMatchPolicy','ui/DocxSourceView','ui/DocumentParseView','ui/KnowledgeResultCard','ui/KnowledgeView','platformtests/DocxPlatformCases','infra/DocxXmlReader'
].map(n=>'entry/src/main/ets/knowledge/'+n+'.ets').concat(['entry/src/main/ets/pages/Index.ets','entry/src/main/ets/entryability/EntryAbility.ets']);
function harness(){
  const ts=require(path.join(process.env.DEVECO_SDK_HOME||'/Applications/DevEco-Studio.app/Contents/sdk','default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
  const cache=new Map(),stores=new Map();let fault='';
  class Rows{constructor(stmt,args){this.names=stmt.columns().map(c=>c.name);this.rows=stmt.all(...args);this.at=-1;}goToNextRow(){return ++this.at<this.rows.length;}getColumnIndex(n){const at=this.names.indexOf(n);if(at<0)throw Error('ColumnMissing');return at;}getString(at){return String(this.rows[this.at][this.names[at]]??'');}getLong(at){return Number(this.rows[this.at][this.names[at]]);}getDouble(at){return this.getLong(at);}isColumnNull(at){return this.rows[this.at][this.names[at]]==null;}close(){}}
  class Store{constructor(){this.db=new DatabaseSync(':memory:');this.version=0;}async querySql(sql,args=[]){return new Rows(this.db.prepare(sql),args);}async executeSql(sql,args=[]){if(fault&&sql.includes(fault))throw Error('Injected');this.db.prepare(sql).run(...args);}async createTransaction(){this.db.exec('BEGIN');return {querySql:(s,a=[])=>this.querySql(s,a),execute:(s,a=[])=>this.executeSql(s,a),commit:async()=>this.db.exec('COMMIT'),rollback:async()=>this.db.exec('ROLLBACK')};}async close(){}}
  const ark={relationalStore:{SecurityLevel:{S3:3},Tokenizer:{CUSTOM_TOKENIZER:1,NONE_TOKENIZER:0},isTokenizerSupported:()=>false,getRdbStore:async(ctx,cfg)=>{const key=ctx.filesDir+'|'+cfg.name;if(!stores.has(key))stores.set(key,new Store());return stores.get(key);}}};
  const memoryFiles=new Map(),handles=new Map();let fd=0;
  const io={OpenMode:{READ_ONLY:0,READ_WRITE:1,CREATE:2,NOFOLLOW:128},access:async name=>memoryFiles.has(name),mkdir:async name=>memoryFiles.set(name,null),lstat:async name=>({isFile:()=>Buffer.isBuffer(memoryFiles.get(name)),isDirectory:()=>memoryFiles.get(name)===null,isSymbolicLink:()=>false,size:memoryFiles.get(name)?.length||0}),open:async(name,mode)=>{if(!memoryFiles.has(name)){if(!(mode&2))throw Error('HostFileMissing');memoryFiles.set(name,Buffer.alloc(0));}handles.set(++fd,name);return {fd};},close:async f=>{handles.delete(typeof f==='number'?f:f.fd);},stat:async id=>({isFile:()=>true,size:memoryFiles.get(handles.get(id))?.length||0,mtime:1}),read:async(id,buffer,options)=>{const data=memoryFiles.get(handles.get(id));if(!data)throw Error('HostFileMissing');const n=Math.max(0,Math.min(options.length,data.length-options.offset));new Uint8Array(buffer).set(data.subarray(options.offset,options.offset+n));return n;},write:async(id,buffer,options)=>{const name=handles.get(id),old=memoryFiles.get(name),data=Buffer.from(buffer),next=Buffer.alloc(Math.max(old.length,options.offset+options.length));old.copy(next);data.copy(next,options.offset,0,options.length);memoryFiles.set(name,next);return options.length;},fsync:async()=>{},rename:async(from,to)=>{memoryFiles.set(to,memoryFiles.get(from));memoryFiles.delete(from);},unlink:async name=>memoryFiles.delete(name)};
  const checksum=require('./docx-fixtures.cjs').crc32;
  const basic={zlib:{ReturnStatus:{OK:0,STREAM_END:1},CompressFlushMode:{NO_FLUSH:0},createChecksum:async()=>({crc32:async(_seed,bytes)=>checksum(Buffer.from(bytes))}),createZip:async()=>{let state={};return {inflateInit2:async()=>0,inflate:async stream=>{const input=Buffer.from(stream.nextIn);const output=require('node:zlib').inflateRawSync(input);if(output.length>stream.nextOut.byteLength)throw Error('HostSmallFixtureOnly');new Uint8Array(stream.nextOut).set(output);state={totalIn:input.length,totalOut:output.length,availableIn:0,availableOut:stream.nextOut.byteLength-output.length};return 1;},getZStream:async()=>state,inflateEnd:async()=>0};}}};
  class Task{constructor(work,...args){this.work=work;this.args=args;}}
  const events={START_DOCUMENT:0,END_DOCUMENT:1,START_TAG:2,END_TAG:3,TEXT:4,CDSECT:5,COMMENT:6,DOCDECL:7,INSTRUCTION:8,ENTITY_REFERENCE:9,WHITESPACE:10};
  class Pull{constructor(buffer){this.text=Buffer.from(buffer).toString('utf8');}parseXml(options){const root=require('./docx-pipeline-host-cases.cjs').tree(this.text);let stopped=false;const visit=(node,depth,type,text='')=>{const info={getDepth:()=>depth,getName:()=>node.localName,getNamespace:()=>node.namespace,getPrefix:()=>'',getText:()=>text,getAttributeCount:()=>node.attributes.length};if(options.tokenValueCallbackFunction(type,info)===false)stopped=true;};const walk=(node,depth)=>{if(stopped)return;for(const attr of node.attributes)options.attributeWithTagCallbackFunction?.(node.localName,attr.qname,attr.text);visit(node,depth,events.START_TAG);if(node.text)visit(node,depth,events.TEXT,node.text);for(const child of node.children)walk(child,depth+1);if(!stopped)visit(node,depth,events.END_TAG);};walk(root,1);if(!stopped)visit(root,0,events.END_DOCUMENT);}}
  const kits=new Map([['@kit.ArkData',ark],['@kit.AbilityKit',{}],['@kit.CoreFileKit',{fileIo:io}],['@kit.BasicServicesKit',basic],['@kit.CryptoArchitectureKit',{cryptoFramework:{createMd:()=>{const hash=crypto.createHash('sha256');return {update:async b=>hash.update(b.data),digest:async()=>({data:new Uint8Array(hash.digest())})};}}}],['@kit.ArkTS',{xml:{EventType:events,XmlPullParser:Pull},util:{TextDecoder:{create:(encoding,options)=>({decodeToString:bytes=>new TextDecoder(encoding,options).decode(bytes)})}},taskpool:{Task:{isCanceled:()=>false},GenericsTask:Task,execute:async task=>task.work(...task.args),cancel(){}}}]]);
  function load(name){const file=path.resolve(name);const relative=path.relative(root,file).replace(/\.ets$/,'');const publicTests=['TextPipelineCases.ets','KnowledgeResultCases.ets'].map(n=>path.join(project,'entry/src/test',n));if(!allowed.includes(relative)&&!publicTests.includes(file))throw Error('DOCX_ALLOWLIST:'+relative);if(cache.has(file))return cache.get(file).exports;const mod=new Module(file,module);mod.filename=file;mod.paths=Module._nodeModulePaths(path.dirname(file));cache.set(file,mod);mod.require=id=>{if(kits.has(id))return kits.get(id);if(id.startsWith('.'))return load(path.resolve(path.dirname(file),id+'.ets'));throw Error('DOCX_IMPORT_DENIED');};let source=fs.readFileSync(file,'utf8');if(relative==='ui/DocxIngestionView'){
    // Methods only: remove the ArkUI DSL and decorators; this is not an ArkUI runtime or compiler check.
    const marker='\n  build() {';const at=source.indexOf(marker);if(at<0||source.lastIndexOf(marker)!==at||!source.includes('@Component\nexport struct DocxIngestionView'))throw Error('DOCX_UI_METHOD_SHAPE');
    source=(source.slice(0,at)+'\n}').replace('@Component\nexport struct DocxIngestionView','export class DocxIngestionView').replace(/@State\s+/g,'');
  }const code=ts.transpileModule(source,{fileName:file.replace(/\.ets$/,'.ts'),compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;mod._compile(code,file);return mod.exports;}
  return {load:n=>load(path.join(root,n+'.ets')),loadPublic:n=>load(path.join(project,'entry/src/test',n+'.ets')),stores,Store,setFault:s=>{fault=s;},kits,memoryFiles,handles,compiler:ts.version};
}
exports.harness=harness;
exports.run=async()=>{
  const h=harness();let passed=0,failed=0;
  const fixture=require('./docx-fixtures.cjs'),scope=path.join(project,'.cache/m4-docx-synthetic');
  if(!fs.statSync(path.join(project,'.cache')).isDirectory())throw Error('SyntheticParentMissing');fs.mkdirSync(scope,{recursive:true});
  for(const kind of ['basic','table-media','revisions']){const f=fixture.fixture(kind,{descriptor:true,metadata:true});const name=path.join(scope,kind+'.docx');if(fs.existsSync(name)&&!fs.readFileSync(name).equals(f.bytes))throw Error('SyntheticAssetConflict');fs.writeFileSync(name,f.bytes);console.log(`DOCX_GOLD kind=${kind} bytes=${f.bytes.length} sha256=${f.hash} version=${fixture.gold.version}`);}
  for(const suite of ['docx-host-entry.cjs','docx-fixtures.cjs','docx-store-host-cases.cjs','docx-service-host-cases.cjs','docx-pipeline-host-cases.cjs','docx-ui-host-cases.cjs'])console.log(`DOCX_TEST_HASH file=entry/src/test/${suite} sha256=${crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,suite))).digest('hex')}`);
  for(const suite of ['docx-store-host-cases.cjs','docx-service-host-cases.cjs','docx-pipeline-host-cases.cjs','docx-ui-host-cases.cjs']){
    const suitePath=path.join(__dirname,suite);if(!fs.existsSync(suitePath))continue;
    for(const [id,run]of require(suitePath).cases(h)){
      try{await run();passed++;console.log(`DOCX_HOST PASS case=${id}`);}catch(error){failed++;console.log(`DOCX_HOST FAIL case=${id} category=${error?.constructor?.name||'Error'} detail=${String(error?.message||'').replace(/[^A-Za-z0-9_:./-]/g,'_').slice(0,200)}`);}
    }
  }
  for(const [file,entry]of [['TextPipelineCases','textPipelineCases'],['KnowledgeResultCases','knowledgeResultCases']]){let ordinal=0;for(const item of h.loadPublic(file)[entry]()){try{await item.run();passed++;console.log(`DOCX_PUBLIC PASS suite=${file} case=${++ordinal}`);}catch{failed++;console.log(`DOCX_PUBLIC FAIL suite=${file} case=${++ordinal}`);}}}
  for(const name of exports.changedEts)console.log(`DOCX_SOURCE_HASH file=${name} sha256=${crypto.createHash('sha256').update(fs.readFileSync(path.join(project,name))).digest('hex')}`);
  console.log(`DOCX_CHECKER_INPUTS count=${exports.changedEts.length} checker=not-run build=not-run`);
  console.log(`DOCX_HOST_SUMMARY passed=${passed} failed=${failed} requests=0 private_files=0 platform=not-run compiler=${h.compiler}`);if(failed)process.exitCode=1;
};
if(require.main===module)exports.run().catch(error=>{console.log(`DOCX_SETUP_FAIL category=${error?.constructor?.name||'Error'} detail=${String(error?.message||'').replace(/[^A-Za-z0-9_:./-]/g,'_').slice(0,200)}`);process.exitCode=1;});
