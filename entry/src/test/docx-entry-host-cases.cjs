'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

// Execute extracted entry/assembly methods only. No app imports, native kits,
// database, user documents, credentials, network or ArkUI runtime are loaded.
const project = path.resolve(__dirname, '../../..');
const inputs = [
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets'
];
const [indexSource, assemblySource] = inputs.map(file => fs.readFileSync(path.join(project, file), 'utf8'));
const ts = require(path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));

function method(source, start, end) {
  const from = source.indexOf(start), to = source.indexOf(end, from + start.length);
  assert(from >= 0 && to > from, 'MethodRangeMissing');
  assert.equal(source.indexOf(start, from + start.length), -1, 'MethodRangeAmbiguous');
  return source.slice(from, to).trim().replace(/^private\s+/, '');
}
function compile(source, name, ports = {}) {
  const output = ts.transpileModule(source + `\n${name};`, {
    fileName: 'docx-entry-extracted.ts', reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  assert.equal((output.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
    'ExtractedMethodTranspileFailed');
  return vm.runInNewContext(output.outputText, ports, { timeout: 1000 });
}
class ControlledFailure extends Error {
  constructor(category, stage) { super(category); this.category = category; this.stage = stage; }
}
class ControlledDocxService {
  constructor(parse, repository) {
    assert(parse && repository, 'ServiceRequiresParseAndRepository');
    this.parse = parse; this.repository = repository; this.adoptions = 0; this.pauses = 0;
  }
  attachProcessing(processing, identity) { this.processing = processing; this.identity = identity; }
  attachManagement(...ports) { assert.equal(ports.length, 5); assert(ports.every(p => typeof p === 'function')); }
  async adoptPrepared() { assert(this.processing && this.identity); this.adoptions++; }
  pause() { this.pauses++; }
}
class ControlledIdentity {}
class ControlledResultReader { constructor(directory, parse, identity) { Object.assign(this, { directory, parse, identity }); } }
class ControlledProcessing { constructor(directory, identity, reader) { Object.assign(this, { directory, identity, reader }); } }
const ports = {
  DocxFailure: ControlledFailure, KnowledgeFailure: ControlledFailure, ImageKnowledgeFailure: ControlledFailure,
  DocxIngestionService: ControlledDocxService, KnowledgePlatformIdentity: ControlledIdentity,
  DocxProcessingAdapter: ControlledProcessing, DocxResultReader: ControlledResultReader, Edge: { Top: 'Top' }
};
const Entry = compile(`class ExtractedDocxEntry {
${method(indexSource, '  private async openDocx():', '  private openDocxSearch():')}
${method(indexSource, '  private openDocxSearch():', '  private async openDocxSource(')}
}`, 'ExtractedDocxEntry', ports);
const Assembly = compile(`class ExtractedDocxAssembly {
${method(assemblySource, '  private async start():', '  private localFailure(')}
${method(assemblySource, '  private localFailure(', '  async ensureDocxReady():')}
${method(assemblySource, '  async ensureDocxReady():', '  async acquire():')}
}`, 'ExtractedDocxAssembly', ports);
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
function assembly(failure = '') {
  const shared = new Assembly(), calls = [];
  let extensionReady = false;
  shared.host = {};
  Object.defineProperty(shared.host, 'extensionReady', {
    get: () => extensionReady,
    set: value => { assert.equal(value, true, 'RecoveryMustNotDisableOpenedRepository'); extensionReady = value; }
  });
  const step = name => async () => { calls.push(name); if (failure === name) { throw new ControlledFailure(name, 'controlled-host'); } };
  function store(name, documents) {
    let opened = false;
    return {
      retained: 'synthetic-unchanged-' + name,
      ready: () => opened && shared.host.extensionReady,
      open: async () => { await step(name + '.open')(); opened = true; shared.host.extensionReady = true; },
      list: async () => documents,
      reconcile: step('repository.reconcile')
    };
  }
  shared.sessionId = 'synthetic-entry-session';
  shared.text = { initialize: step('text.initialize') };
  shared.repository = store('repository', [{ id: 'synthetic-pdf', activeVectorGeneration: 'synthetic-vector', tombstone: false }]);
  shared.images = store('images', [{ id: 'synthetic-image', chunkCount: 1, tombstone: false }]);
  shared.docx = store('docx', [{ id: 'synthetic-docx', chunkCount: 1, tombstone: false }]);
  shared.vectorMetadata = { bootstrap: step('vectorMetadata.bootstrap') };
  shared.assets = { reconcile: step('assets.reconcile') };
  shared.ingestion = { refreshJobs: step('ingestion.refreshJobs') };
  shared.embedding = { initialize: step('embedding.initialize'), pauses: 0, pause() { this.pauses++; } };
  shared.workflow = { restoreActive: async id => { await step('restoreActive:' + id)(); } };
  return { shared, calls };
}
function entry(shared) {
  const page = new Entry(), calls = [];
  Object.assign(page, {
    docxOpening: false, docxIngestionOpen: false, docxSourceOpen: true, imageIngestionOpen: true,
    docxEntryMessage: '', parseState: { message: '' }, knowledgeState: { message: '' },
    sharedKnowledge: shared, parseService: { kind: 'controlled-parse-port' }, parseOpen: false,
    embeddingOpen: false, tab: 0,
    scroller: { scrollEdge: edge => { calls.push('scroll:' + edge); } },
    getUIContext: () => ({ getHostContext: () => ({ filesDir: '/synthetic-entry-no-disk-access' }) }),
    openKnowledge: async () => { calls.push('openKnowledge'); },
    openParse: async settings => { calls.push('openParse:' + settings); }
  });
  return { page, calls };
}
function failedEntry(page) {
  assert.equal(page.docxIngestionOpen, true);
  assert.equal(page.docxOpening, false);
  assert(page.docxEntryMessage.length > 0, 'FailureNeedsVisibleMessage');
  assert.match(page.docxEntryMessage, /可重试/);
}

const cases = [
  ['open-switches-page-and-loading-before-first-await', async () => {
    const { shared } = assembly(); await shared.ensureDocxReady();
    const { page } = entry(shared), gate = deferred(); let started = 0;
    page.openKnowledge = async () => { started++; await gate.promise; };
    const running = page.openDocx();
    assert.equal(page.docxIngestionOpen, true); assert.equal(page.docxOpening, true);
    assert(page.docxEntryMessage.length > 0); assert.equal(page.imageIngestionOpen, false); assert.equal(page.docxSourceOpen, false);
    assert.equal(page.docxIngestionService, undefined);
    await page.openDocx(); assert.equal(started, 1);
    gate.resolve(); await running; assert.equal(page.docxOpening, false); assert.equal(page.docxEntryMessage, '');
  }],
  ['missing-parse-shared-context-reports-and-clears-loading', async () => {
    for (const missing of ['parse', 'shared', 'context']) {
      const { shared } = assembly(), { page, calls } = entry(shared);
      if (missing === 'parse') { page.parseService = undefined; page.parseState.message = 'controlled-parse-not-ready'; }
      if (missing === 'shared') { page.sharedKnowledge = undefined; page.knowledgeState.message = 'controlled-shared-not-ready'; }
      if (missing === 'context') { page.getUIContext = () => ({ getHostContext: () => undefined }); }
      await page.openDocx(); failedEntry(page); assert.equal(page.docxIngestionService, undefined);
      if (missing === 'parse') { assert(calls.includes('openParse:false')); assert.equal(page.parseOpen, false); assert.match(page.docxEntryMessage, /controlled-parse-not-ready/); }
    }
  }],
  ['repository-error-visible-and-retry-reaches-service-handoff', async () => {
    const { shared } = assembly('docx.open'), { page } = entry(shared);
    await page.openDocx(); failedEntry(page); assert.match(page.docxEntryMessage, /docx\.open/);
    assert.equal(page.docxIngestionService, undefined);
    const replacement = assembly().shared; await replacement.ensureDocxReady(); page.sharedKnowledge = replacement;
    await page.openDocx(); assert.equal(page.docxOpening, false); assert.equal(page.docxEntryMessage, '');
    assert(page.docxIngestionService instanceof ControlledDocxService); assert.equal(page.docxIngestionService.adoptions, 1);
  }],
  ['unclassified-error-visible-not-leaked-and-loading-cleared', async () => {
    const { page } = entry(assembly().shared);
    page.openKnowledge = async () => { throw new Error('controlled-unclassified-detail'); };
    await page.openDocx(); failedEntry(page); assert.match(page.docxEntryMessage, /LocalDocxPreparationFailed/);
    assert(!page.docxEntryMessage.includes('controlled-unclassified-detail'));
  }],
  ['success-invokes-constructor-ports-attachments-and-adoption-not-just-button', async () => {
    const { shared } = assembly(), { page } = entry(shared);
    await page.openDocx(); const service = page.docxIngestionService;
    assert(service instanceof ControlledDocxService); assert.equal(service.parse, page.parseService); assert.equal(service.repository, shared.docx);
    assert.equal(service.processing.reader.parse, page.parseService); assert.equal(service.processing.identity, service.identity);
    assert.equal(service.processing.directory, '/synthetic-entry-no-disk-access/knowledge_parse_v1');
    assert.equal(service.adoptions, 1); assert.equal(page.embeddingService, shared.embedding);
    assert.equal(page.docxEntryMessage, ''); assert.equal(page.docxOpening, false);
    await page.openDocx(); assert.equal(page.docxIngestionService, service); assert.equal(service.adoptions, 2);
  }],
  ['adoption-failure-visible-and-existing-service-retried', async () => {
    const { shared } = assembly(), { page } = entry(shared); await page.openDocx();
    const service = page.docxIngestionService;
    service.adoptPrepared = async () => { throw new ControlledFailure('ControlledAdoptionFailed', 'adopt'); };
    await page.openDocx(); failedEntry(page); assert.match(page.docxEntryMessage, /ControlledAdoptionFailed/);
    service.adoptPrepared = ControlledDocxService.prototype.adoptPrepared;
    await page.openDocx(); assert.equal(page.docxEntryMessage, ''); assert.equal(page.docxIngestionService, service);
  }],
  ['bootstrap-reconcile-and-vector-restore-failure-keeps-docx-and-old-repository-ready', async () => {
    for (const failure of ['vectorMetadata.bootstrap', 'repository.reconcile', 'assets.reconcile', 'ingestion.refreshJobs',
      'restoreActive:synthetic-pdf', 'restoreActive:synthetic-image', 'restoreActive:synthetic-docx']) {
      const { shared, calls } = assembly(failure), repository = shared.repository;
      await shared.start(); assert.equal(shared.repository, repository); assert.equal(repository.ready(), true);
      assert.equal(shared.images.ready(), true); assert.equal(shared.docx.ready(), true); assert.equal(shared.host.extensionReady, true);
      assert.equal(repository.retained, 'synthetic-unchanged-repository'); assert(shared.extensionMessage.length > 0);
      assert(calls.indexOf('docx.open') < calls.indexOf('vectorMetadata.bootstrap'));
      await shared.ensureDocxReady(); assert.equal(calls.filter(c => c === 'repository.open').length, 1);
      const { page } = entry(shared); await page.openDocx(); assert.equal(page.docxEntryMessage, '');
      assert.equal(page.docxIngestionService.adoptions, 1);
    }
  }],
  ['embedding-initialization-failure-does-not-block-original-docx-entry', async () => {
    const { shared, calls } = assembly('embedding.initialize'); await shared.start();
    assert.equal(shared.docx.ready(), true); assert.equal(shared.repository.ready(), true);
    assert.match(shared.extensionMessage, /嵌入设置初始化未完成/); assert(calls.includes('restoreActive:synthetic-docx'));
    const { page } = entry(shared); await page.openDocx();
    assert.equal(page.docxEntryMessage, ''); assert.equal(page.docxIngestionService.adoptions, 1);
  }],
  ['ensure-docx-ready-orders-opens-and-does-not-bootstrap-or-initialize', async () => {
    const { shared, calls } = assembly(); await shared.ensureDocxReady();
    assert.deepEqual(calls, ['repository.open', 'images.open', 'docx.open']);
    await shared.ensureDocxReady(); assert.equal(calls.length, 3);
    const stale = assembly().shared; stale.docx.open = async () => {};
    await assert.rejects(stale.ensureDocxReady(), error => error.category === 'DocxStoreNotReady' && error.stage === 'docx-open');
  }],
  ['fallback-text-retry-and-service-view-binding-contract', async () => {
    const from = indexSource.indexOf('} else if (this.docxIngestionOpen) {');
    const to = indexSource.indexOf('} else if (this.imageSourceOpen)', from);
    assert(from >= 0 && to > from); const branch = indexSource.slice(from, to);
    assert.match(branch, /this\.docxEntryMessage\.length > 0 \|\| this\.docxOpening \|\| this\.docxIngestionService === undefined/);
    assert.match(branch, /Text\(this\.docxEntryMessage \|\| '[^']+'\)\.id\('docx-entry-status'\)/);
    assert.match(branch, /Button\('重试打开DOCX'\)\.id\('docx-entry-retry'\)\.enabled\(!this\.docxOpening\)\.onClick\(\(\): void => \{ this\.openDocx\(\); \}\)/);
    assert.match(branch, /if \(this\.docxOpening\) \{ LoadingProgress\(\)/);
    assert.match(branch, /DocxIngestionView\(\{ service: this\.docxIngestionService, embedding: this\.embeddingService,/);
    assert.match(indexSource, /\.id\('m4-docx-entry'\)\.onClick\(\(\): void => \{ this\.openDocx\(\); \}\)/);
  }],
  ['on-search-parent-callback-executes-real-navigation-method', async () => {
    const line = indexSource.split('\n').find(row => row.includes('DocxIngestionView({'));
    assert(line); const callback = line.match(/onSearch:\s*(\(\): void => \{ this\.openDocxSearch\(\); \})/); assert(callback);
    const bindSearch = compile(`function bindSearch() { return ${callback[1]}; }`, 'bindSearch');
    const { shared } = assembly(), { page, calls } = entry(shared); await page.openDocx();
    page.docxSourceOpen = true; page.parseOpen = true; page.embeddingOpen = true;
    bindSearch.call(page)();
    assert.equal(page.tab, 2); assert.equal(page.docxIngestionOpen, false); assert.equal(page.docxSourceOpen, false);
    assert.equal(page.parseOpen, false); assert.equal(page.embeddingOpen, false);
    assert.equal(page.docxIngestionService.pauses, 1); assert.equal(shared.embedding.pauses, 1); assert(calls.includes('scroll:Top'));
  }]
];

(async () => {
  for (let i = 0; i < inputs.length; i++) {
    console.log(`DOCX_ENTRY_SOURCE_HASH file=${inputs[i]} sha256=${crypto.createHash('sha256').update([indexSource, assemblySource][i]).digest('hex')}`);
  }
  console.log(`DOCX_ENTRY_TEST_HASH file=entry/src/test/docx-entry-host-cases.cjs sha256=${crypto.createHash('sha256').update(fs.readFileSync(__filename)).digest('hex')}`);
  let passed = 0, failed = 0;
  for (const [id, run] of cases) {
    try { await run(); passed++; console.log(`DOCX_ENTRY_HOST PASS case=${id}`); }
    catch (error) {
      failed++; const detail = String(error.message || '').replace(/[^A-Za-z0-9_:./-]/g, '_').slice(0, 240);
      console.log(`DOCX_ENTRY_HOST FAIL case=${id} category=${error.constructor.name} detail=${detail}`);
    }
  }
  console.log('DOCX_ENTRY_SCOPE extracted-entry-and-assembly-methods controlled-ports=1 arkui=not-run app-imports=0 cache-generation-suite=unchanged-not-run');
  console.log(`DOCX_ENTRY_HOST_SUMMARY passed=${passed} failed=${failed} requests=0 databases=0 private_files=0 checker=not-run build=not-run device=not-run compiler=${ts.version}`);
  if (failed) { process.exitCode = 1; }
})().catch(error => {
  console.log(`DOCX_ENTRY_SETUP_FAIL category=${error.constructor.name}`); process.exitCode = 1;
});
