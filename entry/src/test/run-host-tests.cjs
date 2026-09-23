// Supplemental host checks of pure Mock logic, NOT ArkUI/Hypium/device execution.
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
const outputRoot = path.join(project, '.cache/ux-mock-tests');
const sources = [
  'entry/src/main/ets/model/AssistantModels.ets',
  'entry/src/main/ets/mock/MockAssistantService.ets',
  'entry/src/test/MockAssistantCases.ets'
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
const { mockAssistantCases } = require(path.join(outputRoot, 'entry/src/test/MockAssistantCases.js'));
for (const testCase of mockAssistantCases()) {
  test(testCase.name, testCase.run);
}
