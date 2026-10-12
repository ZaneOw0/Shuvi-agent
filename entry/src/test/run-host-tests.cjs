// Supplemental host checks of pure logic, NOT ArkUI/Hypium/device execution.
// Reuses the installed SDK compiler; adds no dependency and never ships in the HAP.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
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
  'knowledge/pipeline/TextNormalizer', 'knowledge/pipeline/MarkdownStructure',
  'knowledge/pipeline/StructuredChunker', 'knowledge/pipeline/QueryPreparation',
  'knowledge/application/TextKnowledgeService'
].map(s => `entry/src/main/ets/${s}.ets`).concat([
  'entry/src/test/TextPipelineCases.ets', 'entry/src/test/TextServiceCases.ets'
]);
for (const source of optionalSources) {
  if (fs.existsSync(path.join(project, source))) sources.push(source);
}
console.log(`[工具] Node=${process.version} SDK=${sdkHome} compiler=${ts.version} golden=text-m1-golden-v1`);
for (const source of sources.concat(['entry/src/main/ets/pages/Index.ets', 'entry/src/test/eval/text-m1-golden.json'])) {
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
for (const suite of ['TextPipeline', 'TextService']) {
  const source = path.join(project, `entry/src/test/${suite}Cases.ets`);
  if (fs.existsSync(source)) {
    const module = require(path.join(outputRoot, `entry/src/test/${suite}Cases.js`));
    for (const item of module[suite === 'TextPipeline' ? 'textPipelineCases' : 'textServiceCases']()) {
      test(`${suite} · ${item.name}`, item.run);
    }
  }
}
