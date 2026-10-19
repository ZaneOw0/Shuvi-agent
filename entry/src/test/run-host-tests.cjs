// Supplemental host checks of pure logic, NOT ArkUI/Hypium/device execution.
// Reuses the installed SDK compiler; adds no dependency and never ships in the HAP.
if (process.argv.includes('--image-only') || process.argv.includes('--image-happy-path')) {
  require('./image-host-entry.cjs');
  return;
}
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const { test } = require('node:test');

const sdkHome = process.env.DEVECO_SDK_HOME;
if (!sdkHome) {
  throw new Error('Set DEVECO_SDK_HOME to the DevEco Studio sdk directory.');
}
const ts = require(path.join(sdkHome,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const project = path.resolve(__dirname, '../../..');
const outputRoot = path.join(project, '.cache/host-tests');
const sources = [
  'entry/src/main/ets/model/AssistantModels.ets',
  'entry/src/main/ets/mock/MockAssistantService.ets',
  'entry/src/main/ets/knowledge/domain/KnowledgeTypes.ets',
  'entry/src/main/ets/knowledge/pipeline/Chunker.ets',
  'entry/src/main/ets/knowledge/domain/TextKnowledgeModels.ets',
  'entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets',
  'entry/src/test/MockAssistantCases.ets',
  'entry/src/test/ChunkerCases.ets',
  'entry/src/test/CorpusCases.ets'
];
const optionalSources = [
  'knowledge/domain/PdfWorkerModels','knowledge/pipeline/PdfWorkerPolicy',
  'knowledge/infra/PdfWorkerSupport','knowledge/infra/PdfSnapshotWorker','knowledge/infra/PdfProcessingAdapter','knowledge/infra/PdfAssetAdapter','knowledge/application/PdfIngestionService',
  'knowledge/pipeline/KnowledgeMatchPolicy','knowledge/application/PdfPageReferenceService',
  'knowledge/application/QueryConsentSession','knowledge/application/KnowledgeOperationSession','knowledge/application/KnowledgeDeadline',
  'knowledge/platformtests/SemanticQualityPolicy',
  'knowledge/domain/PdfKnowledgeModels', 'knowledge/domain/EmbeddingModels',
  'knowledge/domain/KnowledgeSearchModels', 'knowledge/domain/KnowledgePorts',
  'knowledge/domain/KnowledgeStorageScope','knowledge/domain/PdfLocalModels','knowledge/pipeline/PdfEvidenceCodec',
  'knowledge/domain/VectorWorkflowModels','knowledge/pipeline/EmbeddingSpacePolicy','knowledge/application/EmbeddingWorkflow','knowledge/infra/PdfVectorRepository',
  'knowledge/infra/KnowledgeDerivedBudget',
  'knowledge/domain/EmbeddingBasisModels','knowledge/pipeline/EmbeddingBasisPolicy',
  'knowledge/pipeline/EmbeddingPolicy', 'knowledge/application/EmbeddingService',
  'knowledge/pipeline/SafeZipPolicy',
  'knowledge/pipeline/BoundedDocumentJson', 'knowledge/pipeline/PdfTableDecoder',
  'knowledge/pipeline/MineruPdfNormalizer',
  'knowledge/pipeline/PdfSnapshotCodec',
  'knowledge/pipeline/PdfStructureChunker',
  'knowledge/pipeline/PdfMappingPolicy',
  'knowledge/pipeline/KnowledgeRetrievalPolicy', 'knowledge/application/KnowledgeSearchService',
  'knowledge/application/KnowledgeLifecycleService',
  'knowledge/infra/KnowledgeStoreHost', 'knowledge/infra/TextRdbRepository', 'knowledge/infra/PdfKnowledgeRepository',
  'knowledge/infra/EmbeddingCredentialStore',
  'knowledge/pipeline/TextNormalizer', 'knowledge/pipeline/MarkdownStructure',
  'knowledge/pipeline/StructuredChunker', 'knowledge/pipeline/QueryPreparation',
  'knowledge/application/TextKnowledgeService',
  'knowledge/domain/DocumentParseModels', 'knowledge/domain/DocumentParsePorts',
  'knowledge/pipeline/DocumentParsePolicy', 'knowledge/pipeline/MineruProtocolCodec',
  'knowledge/application/DocumentParseService', 'knowledge/infra/MineruCredentialStore',
  'knowledge/infra/MineruTransportAdapter', 'knowledge/infra/DocumentFileOperations', 'knowledge/infra/DocumentFileAdapter', 'knowledge/infra/DocumentParseRepository'
].map(s => `entry/src/main/ets/${s}.ets`).concat([
  'entry/src/test/TextPipelineCases.ets', 'entry/src/test/TextServiceCases.ets',
  'entry/src/test/DocumentParseCases.ets', 'entry/src/test/DocumentParseServiceCases.ets',
  'entry/src/test/MineruCredentialStoreCases.ets',
  'entry/src/test/EmbeddingCases.ets', 'entry/src/test/PdfArchiveCases.ets',
  'entry/src/test/PdfStructureCases.ets', 'entry/src/test/PdfWorkerCases.ets', 'entry/src/test/KnowledgeIntegrationCases.ets', 'entry/src/test/KnowledgeResultCases.ets'
]);
for (const source of optionalSources) {
  if (fs.existsSync(path.join(project, source))) sources.push(source);
}
console.log(`[工具] Node=${process.version} SDK=${sdkHome} compiler=${ts.version} golden=text-m1-golden-v1`);
console.log('[执行边界] host transpilation/injected ports only; NOT ArkTS checker, native zlib, ArkData, PDFKit, device, UI or provider verification');
for (const source of sources.concat(['entry/src/main/ets/pages/Index.ets', 'entry/src/test/eval/text-m1-golden.json',
  'entry/src/test/run-host-tests.cjs', 'entry/src/test/mineru-host-loader.cjs', 'entry/src/test/mineru-transfer-host-cases.cjs', 'entry/src/test/mineru-repository-host-cases.cjs',
  'entry/src/test/pdf-offline-host-cases.cjs','entry/src/test/pdf-worker-host-cases.cjs','entry/src/test/pdf-ocr-profile-host-cases.cjs','entry/src/test/knowledge-store-host-cases.cjs','entry/src/test/embedding-credential-host-cases.cjs',
  'entry/src/test/knowledge-scope-host-cases.cjs','entry/src/test/run-host-summary.cjs'])) {
  console.log(`[源与题集SHA256] ${source} ${crypto.createHash('sha256').update(fs.readFileSync(path.join(project, source))).digest('hex')}`);
}
const fingerprintRoot = path.join(project, 'entry/src/main/ets/knowledge');
for (const entry of fs.readdirSync(fingerprintRoot, { recursive: true }).sort()) {
  const file = path.join(fingerprintRoot, entry);
  if (entry.endsWith('.ets') && fs.statSync(file).isFile()) {
    console.log(`[源码SHA256] ${entry} ${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`);
  }
}
for (const source of sources) {
  const output = path.join(outputRoot, source.replace(/\.ets$/, '.js'));
  const result = ts.transpileModule(fs.readFileSync(path.join(project, source), 'utf8'), {
    fileName: source.replace(/\.ets$/, '.ts'),
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, result.outputText);
}

const fixtureRoot = path.join(project, 'entry/src/test/fixtures');
for (const item of require('./pdf-worker-host-cases.cjs')(outputRoot,project)) { test(`PDF worker injected host boundary · ${item.name}`,item.run); }
for (const item of require('./pdf-ocr-profile-host-cases.cjs')(outputRoot,project)) { test(`PDF OCR profile offline host · ${item.name}`,item.run); }
for (const item of require('./knowledge-result-host-cases.cjs')(outputRoot,project)) { test(`KnowledgeResult host · ${item.name}`,item.run); }
for (const testCase of require('./vector-quality-host-cases.cjs')(project)) { test(testCase.name,testCase.run); }
const golden = JSON.parse(fs.readFileSync(path.join(project, 'entry/src/test/eval/text-m1-golden.json'), 'utf8'));
for (const item of golden.fixtures) {
  const bytes = fs.readFileSync(path.join(fixtureRoot, item.file));
  const hash = crypto.createHash('sha256').update(bytes).digest('hex');
  if (hash !== item.sha256 || bytes.length !== item.bytes) throw new Error(`fixture changed: ${item.file}`);
  const original = bytes.toString('utf8');
  if (original.slice(item.start, item.end) !== item.evidence || original.slice(0, item.start).split('\n').length !== item.line) {
    throw new Error(`frozen locator mismatch: ${item.file}`);
  }
  console.log(`[语料SHA256] ${item.file} ${hash}`);
}
const { TextDocument, TextFormat } = require(path.join(outputRoot, 'entry/src/main/ets/knowledge/domain/TextKnowledgeModels.js'));
const pipelineFile = path.join(outputRoot, 'entry/src/main/ets/knowledge/pipeline/StructuredChunker.js');
if (fs.existsSync(pipelineFile)) {
  const { processText } = require(pipelineFile);
  const { prepareTextQuery, textKeywordScore, compareTextHits } = require(path.join(outputRoot, 'entry/src/main/ets/knowledge/pipeline/QueryPreparation.js'));
  for (const item of golden.fixtures) {
    test(`固定golden · ${item.file} 原文结构与关键词证据`, () => {
      const doc = new TextDocument(); doc.id = item.file; doc.format = item.file.endsWith('.md') ? TextFormat.Markdown : TextFormat.Txt;
      const output = processText(new Uint8Array(fs.readFileSync(path.join(fixtureRoot, item.file))), doc, 'golden');
      const node = output.snapshot.nodes.find(n => n.kind === item.kind && n.range.originalStart <= item.start && n.range.originalEnd >= item.end);
      if (!node || (item.heading && !node.headingPath.includes(item.heading))) throw new Error('frozen structure/heading missing');
      const query = prepareTextQuery(item.query);
      const hits = output.chunks.filter(c => textKeywordScore(c.retrievalText, query.terms) > 0);
      if (!hits.some(c => c.ranges.some(r => r.originalStart <= item.start && r.originalEnd >= item.end))) {
        throw new Error('frozen evidence locator not retrieved');
      }
      for (const negative of golden.negativeQueries) {
        if (output.chunks.some(c => textKeywordScore(c.retrievalText, [negative]) > 0)) throw new Error('negative query unexpectedly hits');
      }
    });
    const serviceCasesFile = path.join(outputRoot, 'entry/src/test/TextServiceCases.js');
    if (fs.existsSync(serviceCasesFile)) {
      const { TextTestSession } = require(serviceCasesFile);
      test(`固定golden服务 · ${item.file} 选中原件到历史定位`, async () => {
        const session = new TextTestSession();
        session.assets.bytes = new Uint8Array(fs.readFileSync(path.join(fixtureRoot, item.file)));
        session.assets.selected.files[0].name = item.file;
        session.assets.selected.files[0].bytes = item.bytes;
        session.assets.selected.files[0].format = item.file.endsWith('.md') ? TextFormat.Markdown : TextFormat.Txt;
        await session.service.initialize(); await session.service.importFiles();
        session.service.questionChanged(item.query); await session.service.search();
        const hit = session.service.state.result.hits.find(h => h.ranges.some(r => r.role === 'EVIDENCE' && r.originalStart <= item.start && r.originalEnd >= item.end));
        if (!hit) throw new Error('service lost frozen evidence');
        await session.service.openHit(hit);
        if (!session.service.state.detail.originalText.includes(item.evidence)) throw new Error('original detail mismatch');
        if (session.repository.records[0].result.input.fullQuestion !== item.query) throw new Error('golden query not saved');
      });
    }
  }
}
const fixtureManifest = [
  { file: 'deepseek-chat-completions.md', kind: '工程接口文档/JSON/Markdown' },
  { file: 'who-hypertension-factsheet.md', kind: '医学' },
  { file: 'apache-license-2.0.txt', kind: '法律条款' },
  { file: 'engineering-readme-mixed.md', kind: '混合格式工程文档' },
  { file: 'project-design-zh.md', kind: '中文长文档' },
  { file: 'unicode-edge-cases.txt', kind: 'Unicode 边界' }
];
const corpusDocs = fixtureManifest.map((entry) => {
  return {
    name: entry.file,
    kind: entry.kind,
    text: fs.readFileSync(path.join(fixtureRoot, entry.file), 'utf8')
  };
});
console.log(`[语料] 共加载 ${corpusDocs.length} 份，合计 ${corpusDocs.reduce((sum, d) => sum + d.text.length, 0)} 字符`);
for (const doc of corpusDocs) {
  console.log(`[语料] ${doc.file ?? doc.name} (${doc.kind}) 字符数=${doc.text.length}`);
}

const { mockAssistantCases } = require(path.join(outputRoot, 'entry/src/test/MockAssistantCases.js'));
const { chunkerCases } = require(path.join(outputRoot, 'entry/src/test/ChunkerCases.js'));
const { corpusCases } = require(path.join(outputRoot, 'entry/src/test/CorpusCases.js'));
for (const testCase of mockAssistantCases()) {
  test(testCase.name, testCase.run);
}
for (const testCase of chunkerCases()) {
  test(`分块 · ${testCase.name}`, testCase.run);
}
for (const testCase of corpusCases(corpusDocs)) {
  test(`语料 · ${testCase.name}`, testCase.run);
}
const suiteEntrypoints = {
  TextPipeline: 'textPipelineCases', TextService: 'textServiceCases',
  DocumentParse: 'documentParseCases', DocumentParseService: 'documentParseServiceCases',
  Embedding: 'embeddingCases', PdfArchive: 'pdfArchiveCases',
  PdfStructure: 'pdfStructureCases', PdfWorker: 'pdfWorkerCases', KnowledgeIntegration: 'knowledgeIntegrationCases', KnowledgeResult: 'knowledgeResultCases'
};
for (const suite of Object.keys(suiteEntrypoints)) {
  const source = path.join(project, `entry/src/test/${suite}Cases.ets`);
  if (fs.existsSync(source)) {
    const module = require(path.join(outputRoot, `entry/src/test/${suite}Cases.js`));
    const entrypoint = suiteEntrypoints[suite];
    for (const item of module[entrypoint]()) {
      test(`${suite} · ${item.name}`, item.run);
    }
  }
}

const credentialHost = require('./mineru-host-loader.cjs')(outputRoot, sdkHome, ts);
for (const item of require('./pdf-offline-host-cases.cjs')(outputRoot,project)) {
  test(`PDF authorized offline host boundary · ${item.name}`, item.run);
}
for (const item of require('./knowledge-store-host-cases.cjs')(outputRoot)) {
  test(`Knowledge SQLite injected host boundary · ${item.name}`,item.run);
}
for (const item of require('./knowledge-scope-host-cases.cjs')(project)) {
  test(`Knowledge source scope audit · ${item.name}`,item.run);
}
const { mineruCredentialStoreCases } = credentialHost;
for (const item of require('./embedding-credential-host-cases.cjs')(outputRoot,credentialHost.hostAssetEnums)) {
  test(`Embedding credential injected host boundary · ${item.name}`,item.run);
}
for (const item of mineruCredentialStoreCases()) {
  test(`MineruCredentialStore host boundary · ${item.name}`, item.run);
}
for (const item of require('./mineru-transfer-host-cases.cjs')(outputRoot, credentialHost.hostAssetEnums)) {
  test(`Mineru transfer host boundary · ${item.name}`, item.run);
}
for (const item of require('./mineru-repository-host-cases.cjs')(outputRoot)) {
  test(`Mineru repository host boundary · ${item.name}`, item.run);
}

test('保存视图源码契约 · 服务缺失可见且提交捕获输入先于清理', () => {
  const view = fs.readFileSync(path.join(project, 'entry/src/main/ets/knowledge/ui/DocumentParseView.ets'), 'utf8');
  const action = view.slice(view.indexOf('private async saveCredential()'), view.indexOf('  build()'));
  const expected = ['let input: string = this.tokenInput', 'const service: DocumentParseService | undefined = this.service',
    'this.clearSecret()', 'if (service === undefined)', 'await service.saveToken(input, replace)'];
  let prior = -1;
  for (const step of expected) {
    const at = action.indexOf(step);
    if (at <= prior) throw new Error('Save action ordering changed');
    prior = at;
  }
  if (action.includes('service?.saveToken') || !action.includes('catch { this.credentialFeedback =') ||
    !action.includes("finally { input = ''; this.clearSecret(); }") || !view.includes("@Prop @Watch('clearSecret') clearEpoch")) {
    throw new Error('Save feedback or input lifetime contract missing');
  }
  if (view.indexOf('Text(this.parseState.message)') > view.indexOf('TextInput({') ||
    !view.includes('Text(this.credentialFeedback)') || view.includes('this.credentialFeedback || this.parseState.message') ||
    !view.includes('.enabled(this.service !== undefined && !this.parseState.busy && this.tokenInput.length > 0)') ||
    !view.includes('.onClick((): void => { this.saveCredential(); })')) throw new Error('Save action visibility or wiring missing');
});

test('转发视图源码契约 · V1可观察任务进度前置且前台导航不暂停', () => {
  const view = fs.readFileSync(path.join(project, 'entry/src/main/ets/knowledge/ui/DocumentParseView.ets'), 'utf8');
  const index = fs.readFileSync(path.join(project, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const close = index.slice(index.indexOf('private closeParse()'), index.indexOf('private async openParse('));
  if (close.includes('.pause(') || !close.includes('.clearInput(')) throw new Error('Foreground navigation canceled transfer');
  if (!view.includes('@Observed\nclass DocumentParseTaskPresentation') || !view.includes('@ObjectLink taskRow: DocumentParseTaskPresentation') ||
    !view.includes("@Link @Watch('updateTaskRows') parseState") || !view.includes('(row: DocumentParseTaskPresentation): string => row.taskId')) throw new Error('Stable-key V1 observation missing');
  if (view.indexOf('ForEach(this.taskRows') > view.indexOf('DocumentParseOriginalRow({')) throw new Error('Task progress buried under consent rows');
  for (const required of ['本次已供给 SDK', '未确认上传成功', 'ZIP 本次实际写入', '总长度未知', '服务未报告页进度', '失败阶段', '最后响应', 'resultDirectory', '内容待结构校验']) {
    if (!view.includes(required)) throw new Error('Truthful progress summary missing');
  }
  const ability = fs.readFileSync(path.join(project, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  if (!ability.slice(ability.indexOf('onBackground()')).includes('DocumentParseAssembly.background()')) throw new Error('Background pause boundary missing');
});

test('M2边界审计 · M1核心题集脚本字节保留及平台隔离', () => {
  const protectedFiles = {
    'entry/src/main/ets/knowledge/domain/TextKnowledgeModels.ets': '530e82f28659c7febdfe74c9e7c7f265c0217ba9ed933fad5b168a0310c1be7f',
    'entry/src/main/ets/knowledge/application/TextKnowledgeService.ets': '7bb0f0bd519fff14ea1ba869a4f0267a956ebffdd8123ab8553ddc8bd34da0b5',
    'entry/src/main/ets/knowledge/infra/TextFileAdapter.ets': 'c65bc087f958b28ad04dcf18bf3c43482defd98a3a8ff9b96cdfaa4fa4d7200a',
    'entry/src/main/ets/knowledge/pipeline/TextNormalizer.ets': 'dc4e861e99dc69883350b4d23e9289e455e9a3e7bb8eb880a7e6dad8595a3760',
    'entry/src/test/eval/text-m1-golden.json': 'f060e0ed13451a56e89625b32946b906b718d9238996bc85d30e8edd7e1f9494',
    'scripts/dev-run-mac.sh': 'c8d74af19a7cf3fb702ee50770507394f03e0c6a2f15ad5fdb4f09720dd19216',
    'scripts/capture-test-log.sh': '9ce0bc2acdda0736175d65fad4389493c7c180960fa524c79bc9a8528a089526',
    'oh-package.json5': '8707e54246dcaad85b94274888d84f0b7f0dabcc074d5d092f80d4e2fef87657'
  };
  for (const file of Object.keys(protectedFiles)) {
    const hash = crypto.createHash('sha256').update(fs.readFileSync(path.join(project, file))).digest('hex');
    if (hash !== protectedFiles[file]) throw new Error('Protected baseline bytes changed');
  }
  // Approved M2-B connection points are additive, not exempt from compatibility.
  const baseline = file => cp.execFileSync('git', ['show', `9f5992c:${file}`], { cwd: project, encoding: 'utf8' });
  const portsFile = 'entry/src/main/ets/knowledge/domain/TextKnowledgePorts.ets';
  if (!fs.readFileSync(path.join(project, portsFile), 'utf8').startsWith(baseline(portsFile))) throw new Error('M1 original port contract changed');
  const repoFile = 'entry/src/main/ets/knowledge/infra/TextRdbRepository.ets';
  const repo = fs.readFileSync(path.join(project, repoFile), 'utf8');
  const legacy = baseline(repoFile);
  const frozenStatements = text => text.split('\n').filter(line => /const TEXT_LAYOUT|transaction.execute\('CREATE |TEXT_FTS_DDL/.test(line)).map(line => line.trim());
  if (JSON.stringify(frozenStatements(repo)) !== JSON.stringify(frozenStatements(legacy))) throw new Error('M1 SQL layout/FTS statements changed');
  if (!repo.includes('return this.recall(input, archived, cancel, 5)') || !repo.includes('return this.recall(input, archived, cancel, 20)') || !repo.includes('hits.length > limit')) throw new Error('M1 top5/candidate20 contract lost');
  if (!repo.includes('await this.host.release()') || repo.includes('await this.store.close()')) throw new Error('M1 bypasses shared handle leases');
  if (repo.slice(repo.indexOf('  async saveHistory(')) !== legacy.slice(legacy.indexOf('  async saveHistory('))) throw new Error('M1 history wire changed');
  for (const source of sources.filter(s => /knowledge\/(domain|pipeline|application)\/(Document|Mineru)/.test(s))) {
    const text = fs.readFileSync(path.join(project, source), 'utf8');
    if (/@kit\.|\b(any|unknown|as)\b|JSON\.parse|TextNormalizer|TextKnowledgeService/.test(text)) throw new Error('Pure M2 boundary violated');
  }
  const permissions = fs.readFileSync(path.join(project, 'entry/src/main/module.json5'), 'utf8').match(/ohos\.permission\.[A-Z_]+/g) || [];
  if (JSON.stringify(permissions) !== JSON.stringify(['ohos.permission.INTERNET'])) throw new Error('Permission scope changed');
  const backup = JSON.parse(fs.readFileSync(path.join(project, 'entry/src/main/resources/base/profile/backup_config.json'), 'utf8'));
  const oldBackup = JSON.parse(baseline('entry/src/main/resources/base/profile/backup_config.json'));
  if (backup.allowToBackupRestore !== true || !oldBackup.excludes.every(p=>backup.excludes.includes(p)) || backup.excludes.some(p => !p.includes('knowledge_parse_v1') && !p.includes('shuvi_parse_stage_v1.db') && !p.includes('knowledge_pdf_v1') && !p.includes('shuvi_kb_vector_v1.db'))) throw new Error('M1 backup isolation changed');
});
