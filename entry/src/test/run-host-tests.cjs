// Supplemental host checks of pure logic, NOT ArkUI/Hypium/device execution.
// Reuses the installed SDK compiler; adds no dependency and never ships in the HAP.
const fs = require('node:fs');
const path = require('node:path');
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
  'entry/src/test/MockAssistantCases.ets',
  'entry/src/test/ChunkerCases.ets',
  'entry/src/test/CorpusCases.ets'
];
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
