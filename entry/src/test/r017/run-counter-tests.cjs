// Standalone host suite. Does not load or change the shared runner, policy, service or storage.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const { test } = require('node:test');
const root = path.resolve(__dirname, '../../../..');
const cache = path.join(root, '.cache/r017-tokenizer');
const resources = path.join(root, 'entry/src/main/resources/rawfile/embedding/bge_m3');
const compiler = path.join(process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk',
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const ts = require(compiler);
const sourceFile = path.join(root, 'entry/src/main/ets/knowledge/infra/EmbeddingTokenCounter.ets');
const outputFile = path.join(cache, 'EmbeddingTokenCounter.js');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
fs.mkdirSync(cache, { recursive: true });
fs.writeFileSync(outputFile, ts.transpileModule(fs.readFileSync(sourceFile, 'utf8'), {
  fileName: 'EmbeddingTokenCounter.ts', compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText);
const mod = require(outputFile);
const weightsText = fs.readFileSync(path.join(resources, 'scalar-weights.txt'), 'utf8');
const counter = new mod.BgeM3TokenCounter(weightsText);
const profile = JSON.parse(fs.readFileSync(path.join(resources, 'proof-metadata.json'), 'utf8'));
const golden = JSON.parse(fs.readFileSync(path.join(__dirname, 'golden-inputs.json'), 'utf8'));
const frozen = JSON.parse(fs.readFileSync(path.join(__dirname, 'golden-reference.json'), 'utf8'));
const oracle = cp.spawnSync('python3', ['-B', path.join(__dirname, 'reference-oracle.py')], {
  encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', HF_HUB_OFFLINE: '1' }, timeout: 120000
});
if (oracle.status !== 0) throw new Error(`Official reference failed: ${oracle.stderr}`);
console.log(oracle.stdout.trim());
const reference = JSON.parse(fs.readFileSync(path.join(cache, 'oracle-results.json'), 'utf8'));
console.log(`HOST_BOUNDARY transpile-only compiler=${ts.version}; no ArkTS check, build, device or provider`);
for (const file of [sourceFile, __filename, path.join(__dirname, 'golden-inputs.json'), path.join(__dirname, 'golden-reference.json'),
  path.join(__dirname, 'reference-oracle.py'), path.join(__dirname, 'generate-bge-proof.cjs'),
  path.join(__dirname, 'prepare-oracle.cjs'), path.join(__dirname, 'fetch-bge-artifacts.cjs'), path.join(__dirname, 'capture-counter-tests.cjs'),
  path.join(resources, 'scalar-weights.txt'), path.join(resources, 'proof-metadata.json'), path.join(resources, 'NOTICE.txt')]) {
  console.log(`SOURCE_SHA256 ${path.relative(root, file)} ${digest(fs.readFileSync(file))}`);
}
function count(text, change) {
  const input = new mod.BgeM3CountInput(); input.fullInput = text; input.policyVersion = 'R017-SYNTHETIC-1';
  if (change) change(input);
  return counter.count(input);
}
const results = [];
for (const item of golden.cases) {
  test(`R017 golden ${item.id}`, () => {
    const text = item.text.repeat(item.repeat || 1), actual = count(text);
    const expected = reference.golden.find(row => row.id === item.id);
    assert.equal(expected.fastCount, frozen.counts.find(row => row[0] === item.id)[1]);
    assert.equal(actual.upperBound, item.bound);
    assert.equal(actual.textHash, digest(Buffer.from(text, 'utf8')));
    assert.equal(actual.textHash, expected.textHash);
    assert.ok(expected.fastCount <= actual.upperBound);
    assert.equal(actual.profileBoundProven, true);
    assert.equal(actual.providerConsistency, 'UnverifiedRevisionAndHiddenProcessing');
    assert.equal(actual.state, actual.upperBound <= 8192 ? 'SafeUnderPinnedProfile' : 'BoundUnproven');
    results.push({ id: item.id, fastCount: expected.fastCount, slowRawCountPlus2: expected.slowRawCountPlus2,
      upperBound: actual.upperBound, state: actual.state, textHash: actual.textHash });
  });
}
test('R017 exact resource identities and all-rule derivation', () => {
  assert.equal(digest(Buffer.from(weightsText)), mod.BgeM3TokenProfile.weightsSha256);
  assert.equal(digest(fs.readFileSync(path.join(resources, 'proof-metadata.json'))), mod.BgeM3TokenProfile.metadataSha256);
  assert.equal(profile.fast.modelType, 'Unigram'); assert.equal(profile.fast.byteFallback, false);
  assert.equal(profile.sentencepiece.byteFallback, false); assert.equal(profile.fast.emptyPieces, 0);
  const rules = JSON.parse(fs.readFileSync(path.join(cache, 'charsmap-rules.json'), 'utf8'));
  assert.equal(rules.length, 224711);
  const weights = new Map();
  for (const [source, target] of rules) {
    const cp = source.codePointAt(0), length = [...target].length;
    weights.set(cp, Math.max(weights.get(cp) || 1, length));
  }
  const ranges = weightsText.trimEnd().split('\n').map(line => line.split(':').map(Number));
  for (const [cp, weight] of weights) {
    const range = ranges.find(row => row[0] <= cp && row[1] >= cp);
    assert.equal(range ? range[2] : 1, weight);
  }
  for (const [first, last, weight] of ranges) for (let cp = first; cp <= last; cp++) assert.equal(weights.get(cp), weight);
  const { charsmapRules, protobuf } = require('./generate-bge-proof.cjs');
  const original = fs.readFileSync(path.join(cache, 'sentencepiece.bpe.model'));
  const model = protobuf(original), normalizer = protobuf(model.get(3)[0]);
  const enumerated = charsmapRules(normalizer.get(2)[0]).rules;
  assert.equal(digest(Buffer.from(JSON.stringify(enumerated))), profile.derivation.ruleSha256);
  assert.equal(digest(Buffer.from(JSON.stringify(ranges))), profile.derivation.weightsSha256);
  for (const [name, id] of [['<s>', 0], ['<pad>', 1], ['</s>', 2], ['<unk>', 3], ['<mask>', 250001]]) {
    const added = profile.fast.addedTokens.find(row => row.content === name);
    assert.equal(added.id, id); assert.equal(added.normalized, false); assert.equal(added.rstrip, false);
    assert.equal(added.single_word, false); assert.equal(added.lstrip, name === '<mask>');
  }
});
test('R017 resource corruption fails closed', () => {
  for (const text of ['', weightsText.replace('168:168:2', '168:168:1'), weightsText.replace(/\n/g, '\r\n')]) {
    assert.throws(() => new mod.BgeM3TokenCounter(text), /R017:WeightResourceIntegrity/);
  }
});
test('R017 malformed UTF16 and empty input explicitly invalid', () => {
  for (const text of ['', '\ud800', '\udc00', 'a\ud800z', 'a'.repeat(131073)]) {
    const result = count(text); assert.equal(result.state, 'InvalidInput'); assert.equal(result.profileBoundProven, false);
    assert.equal(result.upperBound, -1); assert.equal(result.textHash, '');
  }
});
test('R017 unsupported model, revision and profile never gain proof', () => {
  for (const change of [input => input.modelId = 'Pro/BAAI/bge-m3', input => input.profileRevision = 'master',
    input => input.profileId = 'other']) assert.equal(count('abc', change).state, 'UnsupportedProfile');
});
test('R017 invalid policy, role and budget explicitly rejected', () => {
  for (const change of [input => input.policyVersion = '', input => input.policyVersion = '\ud800',
    input => input.role = 'Pairs', input => input.tokenBudget = 8193, input => input.tokenBudget = NaN,
    input => input.tokenBudget = 1, input => input.tokenBudget = 2.5]) assert.equal(count('abc', change).state, 'InvalidInput');
});
test('R017 binding includes actual prefix, policy, role, budget and exact bytes', () => {
  const baseline = count('abc');
  const changes = [count('query: abc'), count('abc', input => input.policyVersion = 'other'),
    count('abc', input => input.role = mod.BgeM3InputRole.Query), count('abc', input => input.tokenBudget = 500)];
  for (const row of changes) assert.notEqual(row.bindingHash, baseline.bindingHash);
  const fields = [baseline.evidenceVersion, baseline.modelId, baseline.profileId, baseline.profileRevision,
    baseline.tokenizerSha256, baseline.role, baseline.policyVersion, '8192', baseline.textHash];
  assert.equal(baseline.bindingHash, digest(Buffer.from(fields.map(field => `${field.length}:${field}`).join(''))));
  assert.notEqual(count('é').textHash, count('e\u0301').textHash);
  assert.notEqual(count('\n').textHash, count('\\n').textHash);
  assert.equal(count('abc', input => input.role = mod.BgeM3InputRole.Query).upperBound, baseline.upperBound);
});
test('R017 over-wide estimate is not reported as actual overflow', () => {
  const result = count('a'.repeat(8190));
  assert.equal(result.state, 'BoundUnproven'); assert.equal(result.profileBoundProven, true);
  assert.equal(result.reason, 'UpperBoundExceedsBudgetNotActualTokenOverflow');
});
test('R017 SHA256 UTF8 padding and Unicode vectors agree with Node', () => {
  for (const length of [1, 2, 55, 56, 63, 64, 65, 127, 128, 129, 131072]) {
    const text = 'a'.repeat(length); assert.equal(count(text).textHash, digest(Buffer.from(text)));
  }
  for (const text of ['\ufeffa', '\u0000', '😀', 'e\u0301', '\udbff\udfff']) assert.equal(count(text).textHash, digest(Buffer.from(text)));
});
test('R017 deterministic mixed inputs checked against official fast encoder', () => {
  assert.equal(reference.normalizerRuleCases, 224711); assert.equal(reference.combinedCases, 2000);
  const combinations = JSON.parse(fs.readFileSync(path.join(cache, 'oracle-combinations.json'), 'utf8'));
  for (const row of combinations) {
    const result = count(row.text); assert.equal(result.profileBoundProven, true);
    assert.ok(row.count <= result.upperBound); assert.equal(result.textHash, digest(Buffer.from(row.text)));
  }
});
test('R017 every supported artifact identity and base model type stays fixed', () => {
  for (const item of profile.artifacts) {
    const bytes = fs.readFileSync(path.join(cache, item.file));
    assert.equal(bytes.length, item.bytes); assert.equal(digest(bytes), item.sha256);
  }
  assert.equal(profile.baseModelType, 'xlm-roberta'); assert.equal(profile.license.identifier, 'MIT');
  assert.equal(profile.fast.byteFallbackFieldPresent, true);
});
process.on('exit', () => {
  fs.writeFileSync(path.join(cache, 'host-results.json'), JSON.stringify({ schema: 'R017-HOST-RESULT-1',
    sourceSha256: digest(fs.readFileSync(sourceFile)), golden: results, reference }, null, 2) + '\n');
});
