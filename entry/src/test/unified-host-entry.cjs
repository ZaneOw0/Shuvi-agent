'use strict';
// Exact source allowlist. This entry never imports the legacy host runners.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');
const { DatabaseSync } = require('node:sqlite');
const { toPosix, relativePosix, readTextLf } = require('./lib/portable.cjs');
const project = path.resolve(__dirname, '../../..');
const root = path.join(project, 'entry/src/main/ets/knowledge');
const allowed = [
  'domain/ParsedDocumentModels', 'domain/ParsedDocumentPorts', 'domain/UnifiedKnowledgeModels', 'domain/VisionModels',
  'domain/KnowledgeStorageScope', 'domain/PdfKnowledgeModels', 'domain/TextKnowledgeModels',
  'domain/TextKnowledgePorts', 'domain/DocumentParseModels', 'domain/KnowledgePorts',
  'domain/EmbeddingModels', 'domain/EmbeddingBasisModels', 'domain/KnowledgeSearchModels', 'domain/PdfLocalModels',
  'domain/ImageKnowledgeModels', 'domain/ImageKnowledgePorts', 'domain/DocxKnowledgeModels', 'domain/DocxKnowledgePorts', 'domain/VectorWorkflowModels',
  'pipeline/ParsedDocumentCodec', 'pipeline/BoundedDocumentJson', 'pipeline/SafeZipPolicy',
  'pipeline/ImageHeaderPolicy', 'pipeline/StructuredChunker', 'pipeline/TextNormalizer', 'pipeline/MarkdownStructure',
  'pipeline/ImageSnapshotCodec', 'pipeline/ImageContentNormalizer', 'pipeline/PdfSnapshotCodec',
  'pipeline/DocxSnapshotCodec', 'pipeline/DocxPackagePolicy', 'pipeline/DocumentParsePolicy',
  'pipeline/Chunker', 'pipeline/QueryPreparation',
  'infra/ParsedDocumentStoreLayout', 'infra/ParsedDocumentRepository', 'infra/ParsedDocumentAssets',
  'infra/ImageStoreLayout', 'infra/DocxStoreLayout',
  'infra/KnowledgeStoreHost', 'infra/KnowledgeIdentity', 'infra/KnowledgeDerivedBudget', 'application/TextKnowledgeService',
  'application/KnowledgeLifecycleService'
  ,'pipeline/ParsedOutputDecoder','pipeline/ParsedDocumentChunker','pipeline/PdfTableDecoder',
  'infra/ParsedDocumentAdapters','application/ParsedDocumentIngestionService','infra/PdfImagePayload',
  'infra/ParsedDocumentImportAdapter','infra/DocxResultReader','infra/DocxProcessingAdapter','infra/DocxArchiveAdapter',
  'infra/PdfNativeReader','infra/DocumentFileOperations','infra/DocxXmlReader','infra/DocxXmlAdapter',
  'domain/DocxXmlModels','pipeline/DocxNativeReader','pipeline/DocxCorrespondence',
  'infra/TextFileAdapter','infra/TextProcessingAdapter'
  ,'infra/ParsedPublicationBudget'
  ,'ui/ParsedDocumentView'
  ,'domain/UnifiedProcessingPorts','domain/UnifiedEmbeddingPorts','pipeline/VisionPolicy','pipeline/UnifiedTextPolicy','pipeline/UnifiedProcessingCodec',
  'application/ImageKnowledgeService','application/UnifiedProcessingQueue','application/UnifiedEmbeddingService','application/UnifiedSettingsService','application/EmbeddingService',
  'infra/UnifiedVectorRepository','pipeline/EmbeddingBasisPolicy','pipeline/EmbeddingPolicy','pipeline/EmbeddingSpacePolicy',
  'infra/VisionCredentialStore','infra/VisionTransportAdapter','infra/EmbeddingCredentialStore','infra/EmbeddingTransportAdapter',
  'infra/EmbeddingTokenAdapter','infra/EmbeddingTokenCounter','infra/EmbeddingCountWorker'
  ,'ui/VisionSettingsView','ui/ImageKnowledgeView','ui/EmbeddingSettingsView'
  ,'infra/VectorRdbRepository','infra/KnowledgeCapabilityAudit'
  ,'domain/ParsedMigrationModels','pipeline/ParsedMigrationCodec','infra/ParsedMigrationStore','infra/LegacyParsedDocumentReader','infra/PdfLegacySnapshotFiles','application/ParsedDocumentMigrationService','ui/KnowledgeMigrationView'
  ,'domain/UnifiedQueryModels','domain/UnifiedQueryPorts','infra/UnifiedQueryRepository','application/UnifiedQueryService','application/KnowledgeQuerySession','infra/UnifiedKnowledgeHistoryRepository','pipeline/UnifiedHistoryCodec',
  'pipeline/KnowledgeRetrievalPolicy','pipeline/KnowledgeMatchPolicy','application/QueryConsentSession','application/KnowledgeSearchService','application/KnowledgeDeadline'
  ,'pipeline/UnifiedProcessingPresentation','ui/DocumentParseView','application/DocumentParseService','domain/DocumentParsePorts','pipeline/ParseFailurePolicy'
  ,'ui/UnifiedKnowledgeView'
  ,'domain/ParsedLifecyclePorts'
];
exports.allowed = allowed;
exports.changedEts = [
  'domain/ParsedDocumentModels', 'domain/ParsedDocumentPorts', 'domain/UnifiedKnowledgeModels', 'domain/VisionModels',
  'pipeline/ParsedDocumentCodec', 'infra/ParsedDocumentStoreLayout', 'infra/ParsedDocumentRepository', 'infra/ParsedDocumentAssets',
  'infra/KnowledgeStoreHost', 'infra/KnowledgeDerivedBudget', 'infra/KnowledgeAssembly',
  'application/TextKnowledgeService', 'application/KnowledgeLifecycleService',
  'infra/TextFileAdapter', 'infra/TextKnowledgeAssembly', 'infra/TextRdbRepository', 'infra/DocumentFileAdapter',
  'infra/PdfAssetAdapter', 'infra/PdfKnowledgeRepository', 'infra/ImageSnapshotAssets', 'infra/ImageKnowledgeRepository',
  'infra/DocxSnapshotAssets', 'infra/DocxKnowledgeRepository',
  'pipeline/ParsedOutputDecoder','pipeline/ParsedDocumentChunker','infra/ParsedDocumentAdapters','infra/ParsedDocumentImportAdapter',
  'infra/PdfImagePayload','infra/DocxProcessingAdapter','infra/DocxResultReader','pipeline/DocxNativeReader',
  'application/ParsedDocumentIngestionService','application/PdfIngestionService','application/ImageIngestionService','domain/KnowledgePorts',
  'application/DocumentParseService','ui/ParsedDocumentView','infra/ParsedPublicationBudget','infra/KnowledgePublicationBudget','infra/ImageStoreLayout','infra/DocxStoreLayout'
  ,'domain/UnifiedProcessingPorts','domain/UnifiedEmbeddingPorts','pipeline/VisionPolicy','pipeline/UnifiedTextPolicy','pipeline/UnifiedProcessingCodec',
  'application/ImageKnowledgeService','application/UnifiedProcessingQueue','application/UnifiedEmbeddingService','application/UnifiedSettingsService','application/EmbeddingService',
  'infra/UnifiedVectorRepository','pipeline/EmbeddingBasisPolicy','infra/VisionCredentialStore','infra/VisionTransportAdapter',
  'infra/EmbeddingTransportAdapter','infra/EmbeddingTokenAdapter','infra/VectorRdbRepository','domain/EmbeddingModels',
  'ui/VisionSettingsView','ui/ImageKnowledgeView','ui/EmbeddingSettingsView',
  'domain/ParsedMigrationModels','pipeline/ParsedMigrationCodec','infra/ParsedMigrationStore','infra/LegacyParsedDocumentReader','infra/PdfLegacySnapshotFiles','application/ParsedDocumentMigrationService','ui/KnowledgeMigrationView'
  ,'infra/KnowledgeSourceReaders','infra/DocxSourceReader'
  ,'pipeline/UnifiedProcessingPresentation','ui/DocumentParseView'
  ,'domain/UnifiedQueryModels','domain/UnifiedQueryPorts','infra/UnifiedQueryRepository','application/UnifiedQueryService','application/KnowledgeQuerySession','infra/UnifiedKnowledgeHistoryRepository','pipeline/UnifiedHistoryCodec',
   'pipeline/KnowledgeRetrievalPolicy','pipeline/KnowledgeMatchPolicy','application/QueryConsentSession','application/KnowledgeSearchService','infra/KnowledgeSourceRegistry','pipeline/EmbeddingPolicy','ui/UnifiedKnowledgeView','ui/KnowledgeView','ui/KnowledgeResultCard','ui/KnowledgeVisuals','domain/KnowledgeSearchModels','domain/ParsedLifecyclePorts'
].map(n => 'entry/src/main/ets/knowledge/'+n+'.ets').concat(['entry/src/main/ets/pages/Index.ets','entry/src/main/ets/entryability/EntryAbility.ets','entry/src/main/ets/components/FeaturePages.ets']);
exports.harness = () => {
  const ts = require(path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
    'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
  const cache = new Map(), stores = new Map(), memoryFiles = new Map(), handles = new Map();let selection=[],fetchHandler;
  const assetRows=new Map(),assetCalls=[];
  let fault = '', sequence = 0, requests = 0;
  class Rows {
    constructor(stmt, args) { this.names = stmt.columns().map(c => c.name); this.rows = stmt.all(...args); this.at = -1; }
    goToNextRow() { return ++this.at < this.rows.length; }
    getColumnIndex(name) { const at = this.names.indexOf(name); if (at < 0) throw Error('ColumnMissing'); return at; }
    getString(at) { return String(this.rows[this.at][this.names[at]] ?? ''); }
    getLong(at) { return Number(this.rows[this.at][this.names[at]]); }
    getDouble(at) { return this.getLong(at); }
    close() {}
  }
  class Store {
    constructor() { this.db = new DatabaseSync(':memory:'); }
    async querySql(sql, args = []) { return new Rows(this.db.prepare(sql), args); }
    async executeSql(sql, args = []) { if (fault && !['write','fsync','rename','unlink'].includes(fault) && sql.includes(fault)) throw Error('InjectedSql'); this.db.prepare(sql).run(...args); }
    async createTransaction() { this.db.exec('BEGIN'); return { querySql: (s,a=[]) => this.querySql(s,a),
      execute: (s,a=[]) => this.executeSql(s,a), commit: async () => this.db.exec('COMMIT'), rollback: async () => this.db.exec('ROLLBACK') }; }
    async close() {}
  }
  const stat = name => { if (!memoryFiles.has(name)) throw Error('HostFileMissing'); const b = memoryFiles.get(name);
    return { isFile: () => Buffer.isBuffer(b), isDirectory: () => b === null, isSymbolicLink: () => false, size: b?.length || 0, mtime: 1 }; };
  const io = { OpenMode: { READ_ONLY: 0, READ_WRITE: 1, CREATE: 2, NOFOLLOW: 128 },
    access: async p => memoryFiles.has(p), mkdir: async p => { if (memoryFiles.has(p)) throw Error('Exists'); memoryFiles.set(p,null); },
    lstat: async p => stat(p), stat: async fd => stat(typeof fd==='string'?fd:handles.get(fd)),
    listFile: async p => { const base = toPosix(p); return [...memoryFiles.keys()].filter(k => k.startsWith(base+'/') && !k.slice(base.length+1).includes('/')).map(k => k.slice(base.length+1)); },
    open: async (p, mode) => { if (!memoryFiles.has(p)) { if (!(mode & 2)) throw Error('HostFileMissing'); memoryFiles.set(p,Buffer.alloc(0)); } handles.set(++sequence,p); return { fd: sequence }; },
    close: async f => handles.delete(typeof f === 'number' ? f : f.fd),
    read: async (fd, target, o) => { const bytes = memoryFiles.get(handles.get(fd)); const n = Math.max(0,Math.min(o.length,bytes.length-o.offset)); new Uint8Array(target).set(bytes.subarray(o.offset,o.offset+n)); return n; },
    write: async (fd, bytes, o) => { if (fault === 'write') throw Error('InjectedWrite'); const p=handles.get(fd), old=memoryFiles.get(p), next=Buffer.alloc(Math.max(old.length,o.offset+o.length)); old.copy(next); Buffer.from(bytes).copy(next,o.offset,0,o.length); memoryFiles.set(p,next); return o.length; },
    fsync: async () => { if (fault === 'fsync') throw Error('InjectedFsync'); },
    rename: async (a,b) => { if (fault === 'rename') throw Error('InjectedRename'); memoryFiles.set(b,memoryFiles.get(a)); memoryFiles.delete(a); },
    unlink: async p => { if (fault === 'unlink') throw Error('InjectedUnlink'); memoryFiles.delete(p); }
  };
  class Task { constructor(work,...args){this.work=work;this.args=args;} static isCanceled(){return false;} }
  const events={START_DOCUMENT:0,END_DOCUMENT:1,START_TAG:2,END_TAG:3,TEXT:4,CDSECT:5,COMMENT:6,DOCDECL:7,INSTRUCTION:8,ENTITY_REFERENCE:9,WHITESPACE:10};
  class Pull { constructor(bytes){this.text=Buffer.from(bytes).toString('utf8');} parseXml(o){const root=require('./docx-pipeline-host-cases.cjs').tree(this.text);let stop=false;const emit=(n,d,t,text='')=>{if(o.tokenValueCallbackFunction(t,{getDepth:()=>d,getName:()=>n.localName,getNamespace:()=>n.namespace,getText:()=>text,getAttributeCount:()=>n.attributes.length})===false)stop=true;};const visit=(n,d)=>{if(stop)return;emit(n,d,events.START_TAG);if(n.text)emit(n,d,events.TEXT,n.text);for(const child of n.children)visit(child,d+1);if(!stop)emit(n,d,events.END_TAG);};visit(root,1);if(!stop)emit(root,0,events.END_DOCUMENT);} }
  const crc32=require('./docx-fixtures.cjs').crc32;
  const kits = new Map([
    ['@kit.AbilityKit', {}], ['@kit.CoreFileKit', { fileIo: io,
      picker:{DocumentSelectMode:{FILE:0},DocumentSelectOptions:class{},DocumentViewPicker:class{async select(){return selection.slice();}}},fileUri:{FileUri:class{constructor(uri){this.name=uri.split('/').pop();}isRemoteUri(){return false;}}} }],
    ['@kit.ArkData', { relationalStore: { SecurityLevel: { S3:3 }, Tokenizer: { CUSTOM_TOKENIZER:1, NONE_TOKENIZER:0 }, isTokenizerSupported: () => false,
      getRdbStore: async (ctx,cfg) => { const k=ctx.filesDir+'|'+cfg.name; if (!stores.has(k)) stores.set(k,new Store()); return stores.get(k); } } }],
    ['@kit.CryptoArchitectureKit',{cryptoFramework:{createMd:()=>{const hash=crypto.createHash('sha256');return {update:async b=>{if(b.data.length===0)throw Error('update failed');hash.update(b.data);},digest:async()=>({data:new Uint8Array(hash.digest())})};}}}],
    ['@kit.BasicServicesKit',{zlib:{createChecksum:async()=>({crc32:async(seed,bytes)=>{if(seed!==0)throw Error('SyntheticStoredMemberSingleBlockOnly');return crc32(Buffer.from(bytes));}})}}],
    ['@kit.AssetStoreKit',{asset:{Tag:{ALIAS:1,SECRET:2,RETURN_TYPE:3,ACCESSIBILITY:4,SYNC_TYPE:5,CONFLICT_RESOLUTION:6},ReturnType:{ATTRIBUTES:1,ALL:2},Accessibility:{DEVICE_UNLOCKED:2},SyncType:{NEVER:0},ConflictResolution:{THROW_ERROR:0},query:async q=>{assetCalls.push(['query',q.get(3)]);const row=assetRows.get(Buffer.from(q.get(1)).toString());if(!row)return [];const copy=new Map(row);if(q.get(3)===1)copy.delete(2);else if(copy.has(2))copy.set(2,new Uint8Array(copy.get(2)));return [copy];},add:async a=>{assetCalls.push(['add']);const copy=new Map(a);copy.set(2,new Uint8Array(a.get(2)));assetRows.set(Buffer.from(a.get(1)).toString(),copy);},update:async(q,a)=>{assetCalls.push(['update']);const row=assetRows.get(Buffer.from(q.get(1)).toString());row.set(2,new Uint8Array(a.get(2)));},remove:async q=>assetRows.delete(Buffer.from(q.get(1)).toString())}}],
    ['@kit.RemoteCommunicationKit',{rcp:{Request:class{constructor(url,method){this.url=url;this.method=method;}},createSession:cfg=>({fetch:async req=>{if(!fetchHandler)throw Error('HostNetworkDenied');return fetchHandler(req,cfg);},cancel(){},close(){}})}}],
    ['@kit.PerformanceAnalysisKit',{hilog:{info(){},error(){}}}],
    ['@kit.ArkTS', { taskpool:{Task,GenericsTask:Task,execute:async(t,...args)=>typeof t==='function'?t(...args):t.work(...t.args),cancel(){}},xml:{EventType:events,XmlPullParser:Pull},util: { TextEncoder:class{encodeInto(t){return new Uint8Array(Buffer.from(t));}},Type:{BASIC:0},Base64Helper:class{async encodeToString(bytes){return Buffer.from(bytes).toString('base64');}},TextDecoder: { create: (e,o) => ({ decodeToString: bytes => new TextDecoder(e,o).decode(bytes) }) } } }]
  ]);
  const identity = { id: () => 'upd-'+String(++sequence).padStart(16,'0'), hash: async b => crypto.createHash('sha256').update(b).digest('hex') };
  function load(file) {
    const relative = relativePosix(root,file).replace(/\.ets$/,'');
    if (!allowed.includes(relative) && file!==path.join(root,'../components/Theme.ets')) throw Error('UPD_ALLOWLIST:'+relative);
    if (cache.has(file)) return cache.get(file).exports;
    const mod = new Module(file,module); mod.filename=file; cache.set(file,mod);
    mod.require = id => { if (kits.has(id)) return kits.get(id); if(relative==='ui/UnifiedKnowledgeView' && id==='./KnowledgeResultCard')return {}; if(relative==='ui/EmbeddingSettingsView' && id==='../infra/EmbeddingPublicAudit')return {embeddingPublicAudit:async()=>{throw Error('HostPublicAuditForbidden');}}; if (id.startsWith('.')) return load(path.resolve(path.dirname(file),id+'.ets')); throw Error('UPD_IMPORT_DENIED'); };
    let source=readTextLf(file);if(relative==='ui/ParsedDocumentView'){
      const start=source.indexOf('\n  build() {'),end=source.indexOf('\nclass ParsedViewParseListener');if(start<0||end<0)throw Error('UPD_UI_METHOD_SHAPE');
      source=(source.slice(0,start)+'\n}\n'+source.slice(end)).replace('@Component\nexport struct ParsedDocumentView','export class ParsedDocumentView').replace(/@(State|Prop)(?:\s+@Watch\('[^']+'\))?\s+/g,'');
    }
    if(relative==='ui/DocumentParseView'||relative==='ui/VisionSettingsView'||relative==='ui/ImageKnowledgeView'||relative==='ui/KnowledgeMigrationView'||relative==='ui/UnifiedKnowledgeView'||relative==='ui/EmbeddingSettingsView'){
      const name=relative.split('/').pop(),start=source.indexOf('\n  build() {');if(start<0)throw Error('UPD_UI_METHOD_SHAPE');
      source=(source.slice(0,start)+'\n}').replace('@Component\nexport struct '+name,'export class '+name).replace(/@(State|Prop|Link)(?:\s+@Watch\('[^']+'\))?\s+/g,'');
    }
    if (relative.startsWith('ui/')) source='class TextInputController { stopEditing() {} }\n'+source;
    mod._compile(ts.transpileModule(source, { fileName:file.replace(/\.ets$/,'.ts'),
      compilerOptions:{ target:ts.ScriptTarget.ES2020, module:ts.ModuleKind.CommonJS } }).outputText,file); return mod.exports;
  }
  return { load: n => load(path.join(root,n+'.ets')), identity, stores, Store, memoryFiles, handles,
    requests: () => requests, denyNetwork: () => { requests++; throw Error('BusinessNetworkForbidden'); },
    fault: s => { fault=s; }, select: paths=>{selection=paths.slice();},fetchHandler:fn=>{fetchHandler=fn;},kits,assetCalls,assetRows,compiler:ts.version };
};
exports.run = async () => {
  if (process.env.CAPTURE_SAFE_HOST !== '1' || process.env.CAPTURE_HOST_ONLY !== '1') throw Error('CaptureHostBoundaryRequired');
  const h=exports.harness(); let passed=0, failed=0;
  if (new Set(allowed).size!==allowed.length || new Set(exports.changedEts).size!==exports.changedEts.length) throw Error('DuplicateCanonicalInput');
  for (const [id,run] of require('./unified-store-host-cases.cjs').cases(h).concat(require('./unified-parsing-host-cases.cjs').cases(h),require('./unified-automation-host-cases.cjs').cases(h),require('./unified-migration-host-cases.cjs').cases(h),require('./unified-search-host-cases.cjs').cases(h),require('./unified-lifecycle-host-cases.cjs').cases(h),require('./unified-interruption-host-cases.cjs').cases(h))) {
    let watchdog;
    try { await Promise.race([run(),new Promise((resolve,reject)=>{watchdog=setTimeout(()=>reject(Error('HostCaseTimeout')),15000);})]); passed++; console.log(`UPD_HOST PASS case=${id}`); }
    catch (error) { failed++; console.log(`UPD_HOST FAIL case=${id} category=${error?.constructor?.name || 'Error'}`); }
    finally { clearTimeout(watchdog); }
  }
  for (const [ordinal,name] of allowed.entries()) { const file=path.join(root,name+'.ets'); if (fs.existsSync(file)) console.log(`UPD_SOURCE_HASH ordinal=${ordinal} sha256=${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`); }
  for (const name of ['unified-host-entry.cjs','unified-store-host-cases.cjs','unified-parsing-host-cases.cjs','unified-automation-host-cases.cjs','unified-migration-host-cases.cjs','unified-search-host-cases.cjs','unified-lifecycle-host-cases.cjs','unified-interruption-host-cases.cjs','unified-fixtures.cjs']) console.log(`UPD_TEST_HASH file=${name} sha256=${crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname,name))).digest('hex')}`);
  for (const [ordinal,name] of exports.changedEts.entries()) console.log(`UPD_CHANGED_ETS_HASH ordinal=${ordinal} sha256=${crypto.createHash('sha256').update(fs.readFileSync(path.join(project,name))).digest('hex')}`);
  console.log(`UPD_CHECKER_LIST_HASH sha256=${crypto.createHash('sha256').update(exports.changedEts.join('\n')+'\n').digest('hex')}`);
  console.log(`UPD_CHANGED_SOURCE_SET_HASH sha256=${crypto.createHash('sha256').update(exports.changedEts.map(name=>name+'\t'+crypto.createHash('sha256').update(fs.readFileSync(path.join(project,name))).digest('hex')).join('\n')+'\n').digest('hex')}`);
  const gold=require('./unified-fixtures.cjs').gold;
  console.log(`UPD_GOLD version=${gold.version} legacy_wire_sha256=${gold.legacyHash} image_sha256=${gold.pngHash} pdf_payload_sha256=${gold.pdfPayloadHash} pdf_container_sha256=${gold.pdfContainerHash}`);
  console.log(`UPD_CHECKER_INPUTS count=${exports.changedEts.length} checker=not-run`);
  console.log(`UPD_HOST_SUMMARY passed=${passed} failed=${failed} requests=${h.requests()} private_files=0 checker=not-run build=not-run platform=not-run compiler=${h.compiler}`);
  if (failed) process.exitCode=1;
};
if (require.main === module) exports.run().catch(e => { console.log(`UPD_HOST_SETUP_FAIL category=${e.constructor.name}`); process.exitCode=1; });
