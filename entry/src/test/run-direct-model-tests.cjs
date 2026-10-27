// Host tests: real ArkTS protocol/provider logic, injected network only; no real credentials or requests.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '../../..');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('Set DEVECO_SDK_HOME to the installed SDK.');
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
let nativeFactory = () => { throw new Error('Network is not available in host tests'); };
const http = { createHttp: () => nativeFactory(), RequestMethod: { POST: 'POST' }, HttpDataType: { ARRAY_BUFFER: 2 } };
class Encoder { encodeInto(text) { return new TextEncoder().encode(text); } }
class Decoder {
  constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
  decodeToString(bytes) { return this.decoder.decode(bytes); }
}
const nativeModules = {
  '@ohos.net.http': http,
  '@ohos.util': { TextEncoder: Encoder, TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID() },
  '@ohos.security.asset': {},
  '@kit.BasicServicesKit': {},
  '@ohos.app.ability.common': {},
  '@ohos.data.relationalStore': {
    SecurityLevel: { S1: 1, S2: 2, S3: 3, S4: 4 },
    getRdbStore() { throw new Error('Native device storage is not available in host tests'); }
  },
  '@ohos.security.cryptoFramework': {
    createMd(algorithm) {
      assert.equal(algorithm, 'SHA256');
      const hash = crypto.createHash('sha256');
      return { updateSync(blob) { hash.update(blob.data); }, digestSync() { return { data: hash.digest() }; } };
    }
  }
};
function load(file, overrides = {}, fixtureNames = []) {
  const absolute = path.resolve(file);
  if (cache.has(absolute) && Object.keys(overrides).length === 0 && fixtureNames.length === 0) return cache.get(absolute).exports;
  const module = { exports: {} };
  if (Object.keys(overrides).length === 0 && fixtureNames.length === 0) cache.set(absolute, module);
  let source = fs.readFileSync(absolute, 'utf8');
  // Reuse upstream test fixtures; the imported Hypium suite is not executed by this Node runner.
  if (fixtureNames.length) source = source.split('export default function')[0] + '\nexport { ' + fixtureNames.join(', ') + ' };';
  const output = ts.transpileModule(source, {
    fileName: absolute.replace(/\.ets$/, '.ts'),
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', output)(id => {
    if (Object.hasOwn(overrides, id)) return overrides[id];
    if (Object.hasOwn(nativeModules, id)) return { ...nativeModules[id], default: nativeModules[id] };
    if (id.startsWith('@harmony_agent/')) {
      const directory = id.slice('@harmony_agent/'.length).replaceAll('-', '_');
      return load(path.join(root, 'modules/harmony_agent', directory, 'Index.ets'));
    }
    assert(id.startsWith('.'), `Unexpected import: ${id}`);
    return load(path.resolve(path.dirname(absolute), id + '.ets'));
  }, module, module.exports);
  return module.exports;
}
const services = path.join(root, 'entry/src/main/ets/services/model');
const protocol = load(path.join(services, 'DeepSeekProtocol.ets'));
const connectors = load(path.join(root, 'modules/harmony_agent/agent_connectors/Index.ets'));
const contracts = load(path.join(root, 'modules/harmony_agent/agent_contracts/Index.ets'));
const runtime = load(path.join(root, 'modules/harmony_agent/agent_runtime/Index.ets'));
const { DeepSeekModelTransport, DeepSeekProfile, createDeepSeekModelProfile } = protocol;
const { ArkTsDeepSeekHttpClient } = load(path.join(services, 'DeepSeekHttpClient.ets'));
const { createDeepSeekProvider } = load(path.join(services, 'DeepSeekProvider.ets'));
function profile() {
  return Object.assign(new DeepSeekProfile(), {
    modelId: 'test-model', modelVersion: 'test-revision', region: 'test-region',
    maxInputTokens: 4096, maxOutputTokens: 512, privacyClasses: [contracts.PrivacyClass.PUBLIC], available: true
  });
}
function request() {
  const value = new connectors.ModelInvocation();
  Object.assign(value.context, { requestId: 'request-1', taskId: 'task-1', stepId: 'step-1', operationId: 'operation-1',
    providerId: 'deepseek-direct', region: 'test-region', credentialScope: 'deepseek.invoke',
    priceSnapshotId: 'test-price', timeoutMs: 200 });
  Object.assign(value, { modelId: 'test-model', modelVersion: 'test-revision', maxOutputTokens: 64,
    messages: [{ role: 'user', content: 'Return a JSON object with an ok field.' }], responseSchemaJson: '{"type":"object"}' });
  return value;
}
function credential() { return { headers: { Authorization: 'Bearer test-only-not-a-real-key' } }; }
function response(change = {}) {
  return { statusCode: 200, body: JSON.stringify({ object: 'chat.completion', model: 'test-model',
    choices: [{ index: 0, message: { role: 'assistant', content: '{"ok":true}' }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 15, completion_tokens: 5, total_tokens: 20 }, ...change }) };
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function transportHarness(reply = response()) {
  const sent = [];
  const client = { start(value) { sent.push(value); return { result: Promise.resolve(reply), cancel() {} }; } };
  return { sent, client, transport: new DeepSeekModelTransport(profile(), client) };
}
test('official request uses top-level non-thinking JSON mode, actual model id and no gateway alias', async () => {
  const h = transportHarness();
  const result = await h.transport.start(request(), credential()).result;
  const sent = JSON.parse(h.sent[0].body);
  assert.equal(sent.model, 'test-model');
  assert.deepEqual(sent.thinking, { type: 'disabled' });
  assert.equal(sent.stream, false);
  assert.deepEqual(sent.response_format, { type: 'json_object' });
  assert.equal(sent.extra_body, undefined);
  assert.equal(result.outputJson, '{"ok":true}');
  assert.equal(result.usage.totalTokens, 20);
});
test('plain text omits JSON mode and does not forge streaming callbacks', async () => {
  const h = transportHarness(response({ choices: [{ index: 0, message: { role: 'assistant', content: 'Hello' }, finish_reason: 'stop' }] }));
  const r = request(); r.responseSchemaJson = '{}'; r.messages[0].content = 'Hello';
  let chunks = 0;
  const result = await h.transport.start(r, credential(), { onChunk() { chunks++; } }).result;
  assert.equal(JSON.parse(h.sent[0].body).response_format, undefined);
  assert.equal(result.outputText, 'Hello'); assert.equal(result.outputJson, undefined); assert.equal(chunks, 0);
});
test('profile is copied; missing identity/limits and unavailable profile cannot send', () => {
  const p = profile(); const h = transportHarness(); const transport = new DeepSeekModelTransport(p, h.client);
  p.modelId = 'changed'; p.privacyClasses.length = 0;
  assert.doesNotThrow(() => transport.start(request(), credential()));
  assert.throws(() => createDeepSeekModelProfile(new DeepSeekProfile()));
  assert.throws(() => new DeepSeekModelTransport({ ...profile(), modelId: 'https://other' }, h.client));
  assert.throws(() => new DeepSeekModelTransport({ ...profile(), available: false }, h.client).start(request(), credential()));
});
test('invalid invocation is rejected before network', () => {
  const h = transportHarness();
  for (const alter of [r => r.modelId = 'aigw/default', r => r.context.region = 'other', r => r.context.providerId = 'other',
    r => r.context.credentialScope = 'other', r => r.context.timeoutMs = 0, r => r.maxOutputTokens = 513,
    r => r.temperature = NaN, r => r.messages = [], r => r.messages[0].role = 'tool',
    r => r.messages[0].content = '', r => r.messages[0].content = 'no formatting instruction',
    r => r.responseSchemaJson = '[]', r => r.responseSchemaJson = 'null', r => r.responseSchemaJson = '{']) {
    const r = request(); alter(r); assert.throws(() => h.transport.start(r, credential()));
  }
  assert.equal(h.sent.length, 0);
});
test('extra headers, line breaks and empty Bearer values are rejected before network', () => {
  const h = transportHarness();
  for (const headers of [{}, { Authorization: 'Bearer ' }, { Authorization: 'Bearer x\r\nInjected: y' },
    { authorization: 'Bearer test' }, { Authorization: 'Bearer test', Other: 'x' }, { Authorization: 'Bearer a b' }]) {
    assert.throws(() => h.transport.start(request(), { headers }));
  }
  assert.equal(h.sent.length, 0);
});
test('UTF-8 request size is bounded', () => {
  const h = transportHarness(); const p = profile(); p.maxRequestBytes = 200;
  const r = request(); r.messages[0].content = 'JSON' + '休'.repeat(100);
  assert.throws(() => new DeepSeekModelTransport(p, h.client).start(r, credential()));
  assert.equal(h.sent.length, 0);
});
for (const [status, code] of [[401, 'AUTHENTICATION'], [402, 'PROVIDER'], [403, 'FORBIDDEN'], [422, 'INVALID_REQUEST'],
  [429, 'RATE_LIMITED'], [500, 'PROVIDER'], [503, 'PROVIDER'], [302, 'PROVIDER']]) {
  test(`HTTP ${status} is a safe failure without response echo`, async () => {
    const h = transportHarness({ statusCode: status, body: 'private upstream details' });
    await assert.rejects(h.transport.start(request(), credential()).result,
      error => error.code === code && !error.message.includes('private upstream details'));
    assert.equal(h.sent.length, 1);
  });
}
test('malformed response fields never become success', async () => {
  const normal = JSON.parse(response().body);
  const invalid = ['{', 'null', '[]', '1', ...[
    { ...normal, model: 'another-model' }, { ...normal, object: 'chat.completion.chunk' },
    { ...normal, choices: [] }, { ...normal, choices: [null] }, { ...normal, choices: 'not-array' },
    { ...normal, choices: [{ index: 0, message: null, finish_reason: 'stop' }] },
    { ...normal, choices: [{ index: 0, message: { role: 'assistant', content: null }, finish_reason: 'stop' }] },
    { ...normal, choices: [{ index: 0, message: { role: 'assistant', content: '{}' }, finish_reason: 'tool_calls' }] },
    { ...normal, usage: null }, { ...normal, usage: {} },
    { ...normal, usage: { prompt_tokens: '15', completion_tokens: 5, total_tokens: 20 } },
    { ...normal, usage: { prompt_tokens: -1, completion_tokens: 5, total_tokens: 4 } },
    { ...normal, usage: { prompt_tokens: 15, completion_tokens: 5, total_tokens: 99 } }
  ].map(JSON.stringify)];
  for (const body of invalid) await assert.rejects(transportHarness({ statusCode: 200, body }).transport
    .start(request(), credential()).result, error => error.code === 'PROVIDER');
});
test('JSON success must contain an object; incomplete finish never becomes valid structured output', async () => {
  for (const content of ['[]', 'null', '', 'not json']) {
    const h = transportHarness(response({ choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }] }));
    await assert.rejects(h.transport.start(request(), credential()).result);
  }
  const h = transportHarness(response({ choices: [{ index: 0, message: { role: 'assistant', content: '{' }, finish_reason: 'length' }] }));
  const result = await h.transport.start(request(), credential()).result;
  assert.equal(result.finishReason, 'length'); assert.equal(result.outputJson, undefined);
});
test('late completion after cancellation is discarded and repeated cancel is idempotent', async () => {
  const gate = deferred(); let cancelled = 0;
  const transport = new DeepSeekModelTransport(profile(), { start() { return { result: gate.promise, cancel() { cancelled++; } }; } });
  const operation = transport.start(request(), credential());
  operation.cancel(); operation.cancel(); gate.resolve(response());
  await assert.rejects(operation.result, error => error.code === 'CANCELLED'); assert.equal(cancelled, 1);
});
function nativeHarness() {
  const status = deferred(); const handlers = {}; let destroyed = 0; let sent;
  nativeFactory = () => ({ on(event, callback) { handlers[event] = callback; },
    destroy() { destroyed++; }, requestInStream(endpoint, options) { sent = { endpoint, options }; return status.promise; } });
  const input = { authorization: 'Bearer test-only-not-a-real-key', body: '{}', connectTimeoutMs: 5, timeoutMs: 100, maxResponseBytes: 512 };
  const start = () => new ArkTsDeepSeekHttpClient().start(input);
  const data = text => handlers.dataReceive(new TextEncoder().encode(text).buffer);
  return { start, input, handlers, data, status, get sent() { return sent; }, get destroyed() { return destroyed; } };
}
test('native HTTPS disables redirects/cache and accepts dataEnd before status', async () => {
  const h = nativeHarness(); const op = h.start();
  assert.equal(h.sent.endpoint, 'https://api.deepseek.com/chat/completions');
  assert.equal(h.sent.options.maxRedirects, 0); assert.equal(h.sent.options.usingCache, false);
  h.data('休比'); h.handlers.dataEnd(); h.status.resolve(200);
  assert.equal((await op.result).body, '休比'); assert.equal(h.destroyed, 1);
  op.cancel(); assert.equal(h.destroyed, 1);
});
test('native request accepts status before dataEnd and drops error bodies', async () => {
  const h = nativeHarness(); const op = h.start();
  h.status.resolve(401); await Promise.resolve(); h.data('private upstream details'); h.handlers.dataEnd();
  assert.deepEqual(await op.result, Object.assign(new protocol.DeepSeekHttpResponse(), { statusCode: 401 }));
  assert.equal(h.destroyed, 1);
});
test('native byte limit and malformed UTF-8 destroy the connection', async () => {
  for (const invalidUtf8 of [false, true]) {
    const h = nativeHarness(); h.input.maxResponseBytes = 4; const op = h.start();
    if (invalidUtf8) h.handlers.dataReceive(new Uint8Array([0xff]).buffer); else h.data('过长');
    h.status.resolve(200); h.handlers.dataEnd();
    await assert.rejects(op.result, error => error.code === (invalidUtf8 ? 'PROVIDER' : 'RESPONSE_TOO_LARGE'));
    assert.equal(h.destroyed, 1);
  }
});
test('native absolute deadline and explicit cancel terminate a stalled request', async () => {
  for (const cancel of [false, true]) {
    const h = nativeHarness(); h.input.timeoutMs = 10; const op = h.start();
    if (cancel) { op.cancel(); op.cancel(); }
    await assert.rejects(op.result, error => error.code === (cancel ? 'CANCELLED' : 'TIMEOUT'));
    h.data('late'); h.handlers.dataEnd(); h.status.resolve(200); assert.equal(h.destroyed, 1);
  }
});
test('native network errors are classified by code without echoing original error', async () => {
  for (const code of [2300028, 2300047, 999]) {
    const h = nativeHarness(); const op = h.start(); h.status.reject({ code, message: 'private detail' });
    await assert.rejects(op.result, error => error.code === (code === 2300028 ? 'TIMEOUT' : 'NETWORK') && !error.message.includes('private detail'));
    assert.equal(h.destroyed, 1);
  }
});
function price() {
  return Object.assign(new connectors.ProviderPriceSnapshot(), { snapshotId: 'test-price', providerId: 'deepseek-direct',
    capabilityId: 'test-model', capabilityVersion: 'test-revision', region: 'test-region',
    inputMicrosPerMillionTokens: 1000000, outputMicrosPerMillionTokens: 2000000,
    effectiveAt: '2026-10-23T00:00:00.000Z', snapshotDigest: 'test-price-digest' });
}
const digest = { digest(value) { return crypto.createHash('sha256').update(value).digest('hex'); } };
test('real GenericModelProvider resolves credentials, runs direct transport and settles test pricing', async () => {
  const h = transportHarness(); let reads = 0;
  const bundle = createDeepSeekProvider(profile(), price(), digest, { async resolve(provider, scope) {
    reads++; assert.equal(provider, 'deepseek-direct'); assert.equal(scope, 'deepseek.invoke'); return credential();
  } }, h.client);
  assert.equal(reads, 0); assert.equal(h.sent.length, 0);
  const r = request(); r.modelId = bundle.registered.modelId();
  const result = await bundle.provider.generate(r, new connectors.ProviderCancellationSource());
  assert.equal(reads, 1); assert.equal(h.sent.length, 1);
  assert.equal(result.modelId, 'model.deepseek.direct'); assert.equal(result.usage.settledCostMicros, 25);
});
test('missing pricing and mismatched model metadata do not produce a provider', () => {
  const p = price(); p.inputMicrosPerMillionTokens = 0;
  assert.throws(() => createDeepSeekProvider(profile(), p, digest, {}, {}));
  p.inputMicrosPerMillionTokens = 1; p.capabilityVersion = 'wrong';
  assert.throws(() => createDeepSeekProvider(profile(), p, digest, {}, {}));
});
test('credential failure and already cancelled provider calls do not touch HTTP', async () => {
  const h = transportHarness();
  const bundle = createDeepSeekProvider(profile(), price(), digest, { async resolve() { throw new Error('private detail'); } }, h.client);
  const r = request(); r.modelId = bundle.registered.modelId();
  await assert.rejects(bundle.provider.generate(r, new connectors.ProviderCancellationSource()), error => error.code === 'AUTHENTICATION');
  const cancelled = new connectors.ProviderCancellationSource(); cancelled.cancel();
  await assert.rejects(bundle.provider.generate(r, cancelled), error => error.code === 'CANCELLED');
  assert.equal(h.sent.length, 0);
});
test('composition rejects missing resources and caller conflicts before any start', () => {
  const { ShuviModelBackendConfig, ShuviModelBackendPorts, createShuviModelBackend } = load(path.join(services, 'ShuviModelBackend.ets'));
  assert.throws(() => createShuviModelBackend(new ShuviModelBackendConfig(), new ShuviModelBackendPorts(), {}, {}));
});
test('generic composition injects the selected provider and preserves required search/recovery ports', async () => {
  let captured, opened = 0;
  class HostResource { async open() { opened++; } async close() { opened--; } }
  class Backend { constructor(config, ports) { this.config = config; this.ports = ports; } }
  const mockedConnectors = { ...connectors, ShuviWebSearchMcpHostResource: HostResource,
    async createRecoveredProviderMcpProductionAgentRuntime(...args) { captured = args; return 'test-facade'; } };
  const composition = load(path.join(services, 'ShuviModelBackend.ets'), {
    '@harmony_agent/agent-connectors': mockedConnectors, '@harmony_agent/agent-runtime': { ...runtime, AgentApplicationBackend: Backend }
  });
  const config = new composition.ShuviModelBackendConfig(); const ports = new composition.ShuviModelBackendPorts();
  Object.assign(ports, { digest, adapter: {}, registry: new runtime.ToolRegistry(), manager: {}, providers: {}, policies: {} });
  Object.assign(ports.runtime, { ids: {}, persistence: {}, recovery: {} });
  Object.assign(ports.host, { credentialStore: new HostResource(), executionStorage: new HostResource(), memoryStorage: new HostResource() });
  const selected = { registered: {}, provider: {} };
  const backend = composition.createShuviModelBackend(config, ports, selected.registered, selected.provider);
  assert.equal(opened, 0); assert.equal(ports.runtime.toolPreparer, undefined); assert.equal(ports.host.runtimeFactory, undefined);
  assert.equal(await backend.ports.runtimeFactory.create(), 'test-facade');
  assert.equal(captured[4], selected.registered); assert.equal(captured[5], selected.provider);
  assert.equal(captured[1].persistence, ports.runtime.persistence); assert.equal(captured[1].recovery, ports.runtime.recovery);
  assert(captured[1].toolPreparer); assert.deepEqual(captured[9], [connectors.SHUVI_WEB_SEARCH_TOOL_ID]);
  ports.host.mcpClient = {};
  assert.throws(() => composition.createShuviModelBackend(config, ports, selected.registered, selected.provider));
});

const { DirectModelCheckSession } = load(path.join(services, 'DirectModelCheckSession.ets'));
const { SearchAuthorizationPreviews, PreviewingSearchPreparer, decideSearchAuthorization } =
  load(path.join(services, 'SearchAuthorizationPreview.ets'));

function preparedSearch() {
  const entry = new runtime.ToolRegistryEntry();
  Object.assign(entry.descriptor, {
    toolId: connectors.SHUVI_WEB_SEARCH_TOOL_ID, sourceType: contracts.ToolSourceType.MCP,
    providerId: connectors.SHUVI_WEB_SEARCH_SERVER_ID, capabilityName: connectors.SHUVI_WEB_SEARCH_TOOL_NAME,
    capabilityVersion: 'test-search-v1', toolIdentityVersion: 'tool-v1', inputSchemaJson: '{"type":"object"}',
    schemaDigest: 'test-schema', capabilityTags: ['web-search'], permissionRequirements: ['network.search.public'],
    riskLevel: contracts.RiskLevel.LOW, sideEffect: contracts.SideEffect.NONE,
    dataBoundary: contracts.DataBoundary.REMOTE_ALLOWED, availability: 'available',
    idempotencyMode: contracts.IdempotencyMode.NONE, adapterRef: 'mcp:' + connectors.SHUVI_WEB_SEARCH_SERVER_ID
  });
  Object.assign(entry, { registryVersion: 'v1', registryDigest: 'test-registry', descriptionDigest: 'test-description',
    retrievalRelationVersion: 'v1', estimatedCostMicros: 7, requiresNetwork: true, enabled: true });
  const registry = new runtime.ToolRegistry(); assert.equal(registry.register(entry).accepted, true);
  const request = new runtime.PlanningRequest();
  Object.assign(request.envelope, { requestId: 'r1', taskId: 't1', userId: 'u1', userIntent: 'Original question, not the search query' });
  request.envelope.executionBudget.maxMonetaryCostMicros = 100;
  const step = new contracts.WorkflowStep();
  Object.assign(step, { stepId: 's1', kind: contracts.WorkflowStepKind.TOOL, goal: 'Actual search query',
    sideEffect: contracts.SideEffect.NONE, riskLevel: contracts.RiskLevel.LOW,
    idempotencyMode: contracts.IdempotencyMode.NONE, timeoutMs: 10000,
    capabilityRequirements: ['web-search'], permissionRequirements: ['network.search.public'] });
  let sequence = 0;
  const delegate = new connectors.ShuviWebSearchToolInvocationPreparer(registry, digest, { nextId(kind) { return kind + (++sequence); } });
  const previews = new SearchAuthorizationPreviews();
  const prepared = new PreviewingSearchPreparer(delegate, previews, digest).prepare(request, step, 1000);
  const prompt = new runtime.AgentFrontendAuthorizationPrompt();
  for (const key of ['requestId', 'taskId', 'toolId', 'providerId', 'riskLevel', 'estimatedCostMicros', 'requestedAt', 'expiresAt']) {
    prompt[key] = prepared.policyRequest[key];
  }
  return { previews, prepared, prompt, request, step };
}

test('authorization preview captures the real upstream prepared query, not the original question', () => {
  const h = preparedSearch(); const preview = h.previews.resolve(h.prompt, 1001);
  assert(preview); assert.equal(preview.query, 'Actual search query'); assert.equal(preview.maxResults, 5);
  assert.equal(preview.argumentsDigest, digest.digest(h.prepared.invocation.argumentsJson));
  preview.query = 'UI mutation'; h.prepared.invocation.argumentsJson = '{}';
  assert.equal(h.previews.resolve(h.prompt, 1002).query, 'Actual search query');
});

test('authorization previews reject cross-task, tool, provider, cost, time and unknown request mismatches', () => {
  const h = preparedSearch();
  for (const patch of [{ taskId: 'other' }, { toolId: 'other' }, { providerId: 'other' },
    { riskLevel: 'high' }, { estimatedCostMicros: 0 }, { requestedAt: 'other' },
    { expiresAt: 'other' }, { requestId: 'other' }]) {
    assert.equal(h.previews.resolve({ ...h.prompt, ...patch }, 1002), undefined);
  }
  assert.equal(h.previews.resolve(h.prompt, NaN), undefined);
  assert.equal(h.previews.resolve(h.prompt, 61000), undefined);
});

test('authorization capture rejects wrong digest, identity and unsupported argument fields', () => {
  for (const mutate of [p => p.invocation.taskId = 'other', p => p.invocation.argumentsDigest = 'wrong',
    p => p.policyRequest.providerId = 'other', p => p.policyRequest.expiresAt = 'invalid',
    p => p.invocation.argumentsJson = JSON.stringify({ query: 'actual', maxResults: 5, extra: true })]) {
    const h = preparedSearch(); mutate(h.prepared);
    assert.equal(new SearchAuthorizationPreviews().capture(h.prepared, digest, 1002), false);
  }
});

test('authorization capture rejects changed data under an existing request id and discards its preview', () => {
  const h = preparedSearch(); assert(h.previews.capture(h.prepared, digest, 1001));
  h.prepared.invocation.argumentsJson = '{"query":"changed","maxResults":5}';
  h.prepared.invocation.argumentsDigest = digest.digest(h.prepared.invocation.argumentsJson);
  h.prepared.policyRequest.argumentsDigest = h.prepared.invocation.argumentsDigest;
  assert.equal(h.previews.capture(h.prepared, digest, 1002), false);
  assert.equal(h.previews.resolve(h.prompt, 1003), undefined);
});

test('even matching digests cannot admit malformed, oversized or extra search arguments', () => {
  for (const args of [null, [], { query: 'q', maxResults: 0 }, { query: 'q', maxResults: 11 },
    { query: 'q', maxResults: 1.5 }, { query: ' q', maxResults: 5 },
    { query: 'q', maxResults: 5, extra: true }, { query: '😀'.repeat(501), maxResults: 5 }]) {
    const h = preparedSearch();
    h.prepared.invocation.argumentsJson = JSON.stringify(args);
    h.prepared.invocation.argumentsDigest = digest.digest(h.prepared.invocation.argumentsJson);
    h.prepared.policyRequest.argumentsDigest = h.prepared.invocation.argumentsDigest;
    assert.equal(new SearchAuthorizationPreviews().capture(h.prepared, digest, 1002), false);
  }
  const h = preparedSearch(); h.prepared.invocation.argumentsJson = JSON.stringify({ query: '😀'.repeat(500), maxResults: 10 });
  h.prepared.invocation.argumentsDigest = digest.digest(h.prepared.invocation.argumentsJson);
  h.prepared.policyRequest.argumentsDigest = h.prepared.invocation.argumentsDigest;
  assert(new SearchAuthorizationPreviews().capture(h.prepared, digest, 1002));
});

test('preparation for a different user or step fails before its preview becomes available', () => {
  for (const patch of [{ userId: 'other' }, { stepId: 'other' }]) {
    const h = preparedSearch(); Object.assign(h.prepared.policyRequest, patch);
    const previews = new SearchAuthorizationPreviews();
    const wrapper = new PreviewingSearchPreparer({ prepare() { return h.prepared; } }, previews, digest);
    assert.equal(wrapper.prepare(h.request, h.step, 1001).policyRequest.requestId, '');
    assert.equal(previews.resolve(h.prompt, 1002), undefined);
  }
});

test('missing or expired previews never call backend approval; explicit denial remains available', async () => {
  const h = preparedSearch(); const decisions = [];
  const backend = { async authorize(decision) { decisions.push(decision); return { accepted: true }; } };
  await assert.rejects(decideSearchAuthorization(backend, h.previews, h.prompt, true, 61000), /PREVIEW_UNAVAILABLE/);
  assert.equal(decisions.length, 0);
  await decideSearchAuthorization(backend, h.previews, h.prompt, false, 61001);
  assert.equal(decisions.length, 1); assert.equal(decisions[0].approved, false);
});

test('confirmed decisions use the original policy id and discard the preview only after acceptance', async () => {
  const h = preparedSearch(); let accepted = false; const decisions = [];
  const backend = { async authorize(decision) { decisions.push(decision); return { accepted }; } };
  await decideSearchAuthorization(backend, h.previews, h.prompt, true, 1001);
  assert(h.previews.resolve(h.prompt, 1002)); accepted = true;
  await decideSearchAuthorization(backend, h.previews, h.prompt, true, 1002);
  assert.equal(decisions[1].policyRequestId, h.prompt.requestId);
  assert.equal(decisions[1].taskId, h.prompt.taskId); assert.equal(h.previews.resolve(h.prompt, 1003), undefined);
});

test('preview memory is bounded, expires, and can be cleared without touching stored user data', () => {
  const h = preparedSearch();
  for (let i = 1; i < 32; i++) { h.prepared.policyRequest.requestId = 'request-' + i; assert(h.previews.capture(h.prepared, digest, 1002)); }
  h.prepared.policyRequest.requestId = 'overflow'; assert.equal(h.previews.capture(h.prepared, digest, 1002), false);
  h.previews.forgetTask('t1'); assert.equal(h.previews.resolve(h.prompt, 1003), undefined);
  assert(h.previews.capture(h.prepared, digest, 1003)); h.previews.clear();
  assert.equal(h.previews.resolve({ ...h.prompt, requestId: 'overflow' }, 1004), undefined);
});

function checkHarness(reply, enabled = true) {
  const sent = [], states = [];
  const session = new DirectModelCheckSession({ start(input) {
    sent.push(input); return { result: Promise.resolve(reply), cancel() {} };
  } }, enabled);
  session.attach(state => states.push(state));
  return { session, sent, states };
}
const okReply = () => response({ choices: [{ index: 0, message: { role: 'assistant', content: 'OK' }, finish_reason: 'stop' }] });
test('diagnostic sends exactly one fixed public prompt without a gateway or tool call', async () => {
  const h = checkHarness(okReply()); assert.equal(h.sent.length, 0);
  await h.session.run('test-model', 'test-only-not-a-real-key');
  assert.equal(h.sent.length, 1);
  const body = JSON.parse(h.sent[0].body);
  assert.deepEqual(body.messages, [{ role: 'user', content: 'Reply with exactly OK.' }]);
  assert.equal(body.max_tokens, 64); assert.equal(body.tools, undefined);
  assert.match(h.states.at(-1).message, /测试通过/);
  assert(!JSON.stringify(h.states).includes('test-only-not-a-real-key'));
});
test('release diagnostic and invalid input never invoke the transport', async () => {
  for (const [enabled, model, key] of [[false, 'test-model', 'test-key'], [true, '', 'test-key'],
    [true, 'test-model', ''], [true, 'test-model', 'test\nkey']]) {
    const h = checkHarness(okReply(), enabled); await h.session.run(model, key); assert.equal(h.sent.length, 0);
  }
});
test('diagnostic does not report a non-OK or incomplete answer as success', async () => {
  for (const [content, finish_reason] of [['something else', 'stop'], ['OK', 'length']]) {
    const h = checkHarness(response({ choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason }] }));
    await h.session.run('test-model', 'test-key');
    assert(!h.states.at(-1).message.includes('测试通过')); assert.equal(h.states.at(-1).busy, false);
  }
});
test('diagnostic exposes safe errors and stops without automatic retries', async () => {
  for (const statusCode of [401, 402, 429, 500]) {
    const h = checkHarness({ statusCode, body: 'private detail' }); await h.session.run('test-model', 'test-key');
    assert.equal(h.sent.length, 1); assert.equal(h.states.at(-1).busy, false);
    assert(!h.states.at(-1).message.includes('private detail'));
    if (statusCode === 402) assert.match(h.states.at(-1).message, /余额不足/);
  }
});
test('diagnostic ignores duplicate sends and isolates late completion after leaving', async () => {
  const gate = deferred(); let calls = 0, cancellations = 0; const states = [];
  const session = new DirectModelCheckSession({ start() { calls++; return { result: gate.promise, cancel() { cancellations++; } }; } }, true);
  session.attach(state => states.push(state));
  const running = session.run('test-model', 'test-key'); await session.run('test-model', 'test-key');
  session.cancel(); session.cancel(); session.detach(); const count = states.length; gate.resolve(okReply()); await running;
  assert.equal(calls, 1); assert.equal(cancellations, 1); assert.equal(states.length, count);
  session.attach(state => states.push(state)); assert.match(states.at(-1).message, /已停止/);
  assert.equal(states.at(-1).busy, false);
});

// Device-host resources: real storage/bridge/host code, injected RDB handles and crypto primitive.
const storage = load(path.join(root, 'modules/harmony_agent/agent_storage/Index.ets'));
const invoiceCore = load(path.join(root, 'modules/harmony_agent/agent_core/Index.ets'));
const hypiumFixture = { expect: value => ({ assertTrue: () => assert.equal(value, true), assertEqual: expected => assert.equal(value, expected) }) };
const billingFixture = load(path.join(root, 'modules/harmony_agent/agent_storage/src/test/ExecutionRecoveryStore.test.ets'),
  { '@ohos/hypium': hypiumFixture }, ['preparedStore', 'outcome', 'actualBudget', 'FixtureIntegrity', 'FixtureDurableBackend']);
const billingRuntimeFixture = load(path.join(root, 'modules/harmony_agent/agent_storage/src/test/RuntimeExecutionRecoveryBridge.test.ets'),
  { '@ohos/hypium': hypiumFixture }, ['openBridgeFixture', 'authorize', 'bridgeOutcome', 'reopenRecoveredBridgeFixture']);
function pendingInvoice(outcome = billingFixture.outcome()) {
  return Object.assign(new storage.PendingInvoice(), { provider: 'tavily', accountScope: 'test-account', currency: 'USD',
    requestId: 'test-service-request', providerRequestId: 'test-provider-request', usageState: 'known', credits: 1,
    resultDigest: outcome.resultDigest });
}
function verifiedInvoice() {
  return Object.assign(new storage.VerifiedInvoice(), { operationId: 'operation-1', provider: 'tavily',
    accountScope: 'test-account', currency: 'USD', providerRequestId: 'test-provider-request', resultDigest: 'sha256:result',
    invoiceId: 'invoice-1', lineId: 'line-1', period: '2026-10', evidenceSource: 'test-verified-provider-export',
    evidenceDigest: digest.digest('test-invoice-evidence'), verifiedBy: 'test-reviewer', verifiedAt: '2026-10-24T00:00:00Z', amountMicros: 80 });
}
function inFlightBilling() {
  const store = billingFixture.preparedStore();
  const lease = store.acquireLease('task-1', 'owner', 5000, 100);
  assert.equal(lease.accepted, true);
  assert.equal(store.markOperationInFlight('operation-1', 'owner', lease.lease.fencingToken, 101).accepted, true);
  return { store, token: lease.lease.fencingToken };
}
function savedPendingBilling() {
  const h = inFlightBilling();
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', billingFixture.outcome(), pendingInvoice(), 'owner', h.token, 102).accepted, true);
  assert.equal(h.store.releaseLease('task-1', 'owner', h.token).accepted, true);
  return h;
}
test('pending invoice persists a successful outcome without settling or releasing money', () => {
  const h = savedPendingBilling();
  const op = h.store.getOperation('operation-1');
  assert.equal(op.state, invoiceCore.OperationJournalState.RESULT_RECORDED);
  assert.equal(op.invoice, undefined);
  assert.equal(op.pendingInvoice.amountMicros, undefined);
  assert.equal(h.store.getBudgetReservation('reservation-1').snapshot.state, invoiceCore.BudgetReservationState.RESERVED);
  for (const scope of h.store.getBudgetScopes('task-1')) {
    assert.equal(scope.snapshot.reserved.monetaryCostMicros, 100);
    assert.equal(scope.snapshot.consumed.monetaryCostMicros, 0);
  }
  const reopened = storage.ExecutionRecoveryStore.restore(h.store.checkpoint(digest), digest);
  assert.equal(reopened.accepted, true);
  assert.deepEqual(reopened.store.getOperation('operation-1'), op);
  assert.equal(reopened.store.recoveryCandidates().length, 0);
  op.pendingInvoice.credits = 99;
  assert.equal(reopened.store.getOperation('operation-1').pendingInvoice.credits, 1);
});
test('pending result replay is idempotent; changed receipt, wrong fence and malformed amount fail closed', () => {
  const h = inFlightBilling(); const outcome = billingFixture.outcome(); const pending = pendingInvoice();
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, pending, 'owner', h.token + 1, 102).accepted, false);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', { ...outcome, resultJson: 'broken' }, pending, 'owner', h.token, 102).accepted, false);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', { ...outcome, resultJson: undefined }, pending, 'owner', h.token, 102).accepted, false);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, { ...pending, amountMicros: 0 }, 'owner', h.token, 102).accepted, false);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, pending, 'owner', h.token, 102).accepted, true);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, pending, 'owner', h.token, 102).duplicate, true);
  assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, { ...pending, credits: 2 }, 'owner', h.token, 102).accepted, false);
});
test('only verified per-request invoice settles once; conflicting or account totals cannot overwrite', () => {
  const h = savedPendingBilling(); const invoice = verifiedInvoice(); const actual = billingFixture.actualBudget();
  for (const change of [{ currency: 'CNY' }, { accountScope: 'another' }, { providerRequestId: 'another' },
    { resultDigest: 'other' }, { amountMicros: -1 }, { amountMicros: 81 }, { providerRequestId: '' }, { lineId: '' },
    { verifiedBy: '' }, { evidenceDigest: '' }, { amountMicros: Number.MAX_SAFE_INTEGER + 1 }]) {
    assert.equal(h.store.settleInvoice({ ...invoice, ...change }, actual, 110).accepted, false);
  }
  assert.equal(h.store.settleInvoice(invoice, actual, 110).accepted, true);
  const before = h.store.checkpoint(digest);
  assert.equal(h.store.settleInvoice(invoice, actual, 120).duplicate, true);
  assert.equal(h.store.settleInvoice({ ...invoice, evidenceDigest: 'different' }, actual, 120).accepted, false);
  assert.equal(h.store.settleInvoice(invoice, { ...actual, toolCalls: 2 }, 120).accepted, false);
  assert.deepEqual(h.store.checkpoint(digest), before);
  for (const scope of h.store.getBudgetScopes('task-1')) {
    assert.equal(scope.snapshot.reserved.monetaryCostMicros, 0);
    assert.equal(scope.snapshot.consumed.monetaryCostMicros, 80);
  }
  assert.equal(storage.ExecutionRecoveryStore.restore(before, digest).accepted, true);
});
test('zero credits remain pending; unknown usage cannot invent a per-call bill', () => {
  for (const usage of [{ credits: 0 }, { usageState: 'unknown', credits: undefined, providerRequestId: undefined }]) {
    const h = inFlightBilling();
    assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', billingFixture.outcome(), { ...pendingInvoice(), ...usage }, 'owner', h.token, 102).accepted, true);
    h.store.releaseLease('task-1', 'owner', h.token);
    assert.equal(h.store.getOperation('operation-1').invoice, undefined);
    if (usage.usageState === 'unknown') assert.equal(h.store.settleInvoice(verifiedInvoice(), billingFixture.actualBudget(), 110).accepted, false);
  }
});
test('CAS failure exposes neither the result nor pending invoice; reopen does not repeat the provider call', async () => {
  const h = inFlightBilling(); const backend = new billingFixture.FixtureDurableBackend();
  backend.snapshot = h.store.checkpoint(digest);
  const durable = (await storage.DurableExecutionRecoveryStore.openForRuntimeRecovery(backend, digest)).store;
  const transaction = { apply: candidate => candidate.recordOutcomeAwaitingInvoice('operation-1', billingFixture.outcome(), pendingInvoice(), 'owner', h.token, 102) };
  backend.failNextWrite = true;
  assert.equal((await durable.transact(transaction)).accepted, false);
  assert.equal(durable.getOperation('operation-1').state, invoiceCore.OperationJournalState.IN_FLIGHT);
  assert.equal((await durable.transact(transaction)).accepted, true);
  const reopened = (await storage.DurableExecutionRecoveryStore.open(backend, digest)).store;
  assert.equal(reopened.getOperation('operation-1').state, invoiceCore.OperationJournalState.RESULT_RECORDED);
  assert.equal(reopened.recoveryCandidates().length, 0);
});
test('schema 1.2 upgrades by validated CAS; corrupt or disguised newer payloads cannot migrate', async () => {
  const backend = new billingFixture.FixtureDurableBackend();
  const original = billingFixture.preparedStore().checkpoint(digest); original.schemaVersion = '1.2';
  backend.snapshot = structuredClone(original); backend.failNextWrite = true;
  assert.equal((await storage.DurableExecutionRecoveryStore.openForRuntimeRecovery(backend, digest)).accepted, false);
  assert.deepEqual(backend.snapshot, structuredClone(original));
  const opened = await storage.DurableExecutionRecoveryStore.openForRuntimeRecovery(backend, digest);
  assert.equal(opened.accepted, true); assert.equal(backend.snapshot.schemaVersion, '1.3');
  assert.equal(backend.snapshot.revision, original.revision + 1);
  assert.equal(storage.ExecutionRecoveryStore.restore({ ...original, payloadDigest: 'bad' }, digest).accepted, false);
  const disguised = savedPendingBilling().store.checkpoint(digest); disguised.schemaVersion = '1.2';
  assert.equal(storage.ExecutionRecoveryStore.restore(disguised, digest).accepted, false);
});
test('production Runtime continues after durable pending result; crash-window recovery restores success without dispatch', async () => {
  const f = await billingRuntimeFixture.openBridgeFixture();
  // Replace only accounting configuration, retaining real Runtime/policy/dispatch/storage behavior.
  f.bridge.config.pendingInvoice = { receiptForOutcome: (_operation, outcome) => pendingInvoice(outcome) };
  f.bridge.config.outcomeAccounting = { actualForOutcome() { throw Error('No monetary invoice exists'); } };
  const taskId = await billingRuntimeFixture.authorize(f, 'pending-bill-task');
  const dispatched = f.factory.adapter.requests[0];
  const result = billingRuntimeFixture.bridgeOutcome(dispatched, contracts.ToolOutcomeStatus.SUCCEEDED);
  const context = dispatched.persistenceContext;
  assert.equal((await f.bridge.recordOutcome(taskId, dispatched.step.stepId, dispatched.dispatchId, result, 1000)).accepted, true);
  const operation = f.store.getOperation(context.operationId);
  assert.equal(operation.state, invoiceCore.OperationJournalState.RESULT_RECORDED);
  // The task checkpoint still says running, simulating process loss before coordinator completion.
  const recovered = await billingRuntimeFixture.reopenRecoveredBridgeFixture(f);
  assert.equal(recovered.factory.adapter.requests.length, 0);
  assert.equal((await recovered.runtime.getTaskSnapshot(taskId)).status, contracts.AgentTaskStatus.COMPLETED);
  assert.equal((await recovered.runtime.getTaskSnapshot(taskId)).resultJson, result.resultJson);
  assert.equal(recovered.store.getOperation(context.operationId).state, invoiceCore.OperationJournalState.RESULT_RECORDED);
  assert.equal(recovered.store.getBudgetReservation(context.budgetReservationId).snapshot.state, invoiceCore.BudgetReservationState.RESERVED);
});
test('normal production completion saves sources and finishes while monetary invoice remains absent', async () => {
  const f = await billingRuntimeFixture.openBridgeFixture();
  f.bridge.config.pendingInvoice = { receiptForOutcome: (_operation, outcome) => pendingInvoice(outcome) };
  f.bridge.config.outcomeAccounting = { actualForOutcome() { return undefined; } };
  const taskId = await billingRuntimeFixture.authorize(f, 'live-pending-bill');
  const dispatched = f.factory.adapter.requests[0];
  const outcome = billingRuntimeFixture.bridgeOutcome(dispatched, contracts.ToolOutcomeStatus.SUCCEEDED);
  await f.factory.adapter.sink.complete(taskId, dispatched.step.stepId, dispatched.dispatchId, outcome);
  assert.equal((await f.runtime.getTaskSnapshot(taskId)).status, contracts.AgentTaskStatus.COMPLETED);
  assert.equal(f.store.getOperation(dispatched.persistenceContext.operationId).invoice, undefined);
  assert.equal(f.store.getOperation(dispatched.persistenceContext.operationId).outcome.resultJson, outcome.resultJson);
});
test('invoice CAS failure retains pending result; success and duplicate remain durable after reopening', async () => {
  const h = savedPendingBilling(); const backend = new billingFixture.FixtureDurableBackend();
  backend.snapshot = h.store.checkpoint(digest);
  const live = (await storage.DurableExecutionRecoveryStore.openForRuntimeRecovery(backend, digest)).store;
  assert.equal((await live.settleInvoice(verifiedInvoice(), billingFixture.actualBudget(), 110)).accepted, false);
  const store = (await storage.DurableExecutionRecoveryStore.openForInvoiceReconciliation(backend, digest)).store;
  assert.throws(() => new storage.RuntimeExecutionRecoveryBridge(store, recoveryConfig()), /cannot run tasks/);
  const invoice = verifiedInvoice(); const actual = billingFixture.actualBudget();
  backend.failNextWrite = true;
  assert.equal((await store.settleInvoice(invoice, actual, 110)).accepted, false);
  assert.equal(store.getOperation('operation-1').invoice, undefined);
  assert.equal((await store.settleInvoice(invoice, actual, 110)).accepted, true);
  const reopened = (await storage.DurableExecutionRecoveryStore.openForInvoiceReconciliation(backend, digest)).store;
  const revision = reopened.revision();
  assert.equal((await reopened.settleInvoice(invoice, actual, 120)).duplicate, true);
  assert.equal(reopened.revision(), revision);
  assert.equal(reopened.getOperation('operation-1').outcome.resultJson, billingFixture.outcome().resultJson);
});
test('search billing adapter binds exact stored intent and leaves missing credits unpriced', () => {
  const { SearchPendingInvoice } = load(path.join(services, 'SearchPendingInvoice.ets'));
  const { SearchUsageReceipts } = load(path.join(services, 'SearchUsageReceipts.ets'));
  const ledger = new SearchUsageReceipts(digest); const fixture = usageFixture();
  const invocation = usageInvocation(); const outcome = usageOutcome(invocation, fixture);
  ledger.capture(JSON.parse(invocation.argumentsJson), fixture); ledger.bind(invocation, outcome);
  const op = new storage.StoredOperation();
  Object.assign(op.intent, invocation, { idempotencyKey: invocation.idempotencyKey ?? 'attempt:' + invocation.attemptId });
  assert.throws(() => new SearchPendingInvoice(ledger, '', 'USD'));
  const adapter = new SearchPendingInvoice(ledger, 'test-account', 'USD');
  assert.equal(adapter.receiptForOutcome(op, outcome).credits, 1);
  op.intent.attemptId = 'wrong'; assert.equal(adapter.receiptForOutcome(op, outcome), undefined);
  op.intent.attemptId = invocation.attemptId; ledger.close();
  assert.equal(adapter.receiptForOutcome(op, outcome), undefined);
});
test('restart after saved search pauses remaining work and never retries the successful step', async () => {
  const f = await billingRuntimeFixture.openBridgeFixture();
  const plan = f.runtime.coordinator.planner.plan.bind(f.runtime.coordinator.planner);
  f.runtime.coordinator.planner.plan = async request => {
    const value = await plan(request);
    const next = Object.assign(new contracts.WorkflowStep(), structuredClone(value.workflow.steps[0]), {
      stepId: 'answer-step', kind: contracts.WorkflowStepKind.LLM, sideEffect: contracts.SideEffect.NONE,
      idempotencyMode: contracts.IdempotencyMode.NONE, dependencies: ['step-1'], capabilityRequirements: []
    });
    value.workflow.steps.push(next); return value;
  };
  f.bridge.config.pendingInvoice = { receiptForOutcome: (_operation, outcome) => pendingInvoice(outcome) };
  const taskId = await billingRuntimeFixture.authorize(f, 'pending-answer-task');
  const dispatched = f.factory.adapter.requests[0];
  const result = billingRuntimeFixture.bridgeOutcome(dispatched, contracts.ToolOutcomeStatus.SUCCEEDED);
  assert.equal((await f.bridge.recordOutcome(taskId, dispatched.step.stepId, dispatched.dispatchId, result, 1000)).accepted, true);
  const recovered = await billingRuntimeFixture.reopenRecoveredBridgeFixture(f);
  assert.equal(recovered.factory.adapter.requests.length, 0);
  const checkpoint = await recovered.bridge.loadCheckpoint(taskId);
  assert.equal(checkpoint.paused, true); assert.equal(checkpoint.snapshot.status, contracts.AgentTaskStatus.PAUSED);
  assert.equal(checkpoint.snapshot.resultJson, result.resultJson);
  assert.equal(checkpoint.scheduler.steps.find(step => step.stepId === 'step-1').state, invoiceCore.WorkflowStepState.SUCCEEDED);
});
test('failed, denied, cancelled and uncertain outcomes cannot masquerade as pending success', () => {
  for (const status of [contracts.ToolOutcomeStatus.FAILED, contracts.ToolOutcomeStatus.DENIED,
    contracts.ToolOutcomeStatus.CANCELLED, contracts.ToolOutcomeStatus.UNKNOWN_OUTCOME]) {
    const h = inFlightBilling(); const before = h.store.checkpoint(digest);
    const outcome = billingFixture.outcome(status);
    assert.equal(h.store.recordOutcomeAwaitingInvoice('operation-1', outcome, pendingInvoice(), 'owner', h.token, 102).accepted, false);
    assert.deepEqual(h.store.checkpoint(digest), before);
  }
});
const { AgentHostDigest } = load(path.join(services, 'AgentHostDigest.ets'));
const { SessionModelCredentials } = load(path.join(services, 'SessionModelCredentials.ets'));
const { AgentExecutionResource, AgentMemoryResource, NativeAgentRdbOpen } = load(path.join(services, 'AgentRdbResources.ets'));
const { ShuviDeviceHostResources } = load(path.join(services, 'ShuviDeviceHostResources.ets'));
const hostDigest = new AgentHostDigest();
const { SearchUsageReceipts, SearchUsageMcpAdapter, readSearchUsage } = load(path.join(services, 'SearchUsageReceipts.ets'));
function usageFixture(id = crypto.randomUUID(), credits = 1) {
  const structuredContent = { schemaVersion: '1.0', requestId: id, provider: 'tavily', query: 'same query',
    searchedAt: '2026-10-24T00:00:00.000Z', results: [] };
  const meta = { schemaVersion: '1.0', requestId: id, provider: 'tavily', state: 'known', unit: 'credits', credits };
  return { isError: false, structuredContent, content: [{ type: 'text', text: JSON.stringify(structuredContent) }],
    raw: { structuredContent, _meta: { shuviSearchUsage: meta } } };
}
function usageInvocation(id = '1') {
  return Object.assign(new contracts.ToolInvocation(), {
    invocationId: 'inv-' + id, taskId: 'task-' + id, stepId: 'step-' + id, operationId: 'op-' + id, attemptId: 'attempt-' + id,
    toolId: connectors.SHUVI_WEB_SEARCH_TOOL_ID, toolIdentityVersion: 'test-identity', schemaDigest: 'test-schema',
    argumentsJson: '{"maxResults":5,"query":"same query"}', authorizationGrantId: 'test-grant',
    argumentsDigest: digest.digest('{"maxResults":5,"query":"same query"}'), timeoutMs: 3000,
    createdAt: '2026-10-24T00:00:00.000Z'
  });
}
function usageOutcome(inv, result) {
  const resultJson = connectors.canonicalJson(result.structuredContent);
  return Object.assign(new contracts.ToolOutcome(), { invocationId: inv.invocationId, status: contracts.ToolOutcomeStatus.SUCCEEDED,
    resultJson, resultDigest: digest.digest(resultJson), startedAt: inv.createdAt, finishedAt: inv.createdAt });
}
test('search usage validates metadata, units, version, result binding and absent versus explicit zero', () => {
  assert.equal(readSearchUsage(usageFixture(undefined, 0)).credits, 0);
  assert.equal(readSearchUsage(usageFixture(undefined, 0.5)).credits, 0.5);
  for (const change of [u => { delete u.raw; }, u => { u.raw._meta = null; }, u => { u.raw._meta.shuviSearchUsage = []; },
    u => { u.raw.structuredContent = { ...u.structuredContent, query: 'other' }; },
    u => { u.isError = true; }]) {
    const value = usageFixture(); change(value); assert.equal(readSearchUsage(value), undefined);
  }
  for (const change of [{ schemaVersion: '2' }, { requestId: crypto.randomUUID() }, { provider: 'other' },
    { state: 'other' }, { unit: 'USD' }, { credits: '1' }, { credits: -1 }, { credits: Infinity },
    { credits: 1e100 }, { providerRequestId: 'bad\nvalue' }, { extra: true }, { state: 'unknown' }]) {
    const value = usageFixture(); Object.assign(value.raw._meta.shuviSearchUsage, change);
    assert.equal(readSearchUsage(value), undefined, JSON.stringify(change));
  }
  const value = usageFixture(); const meta = value.raw._meta.shuviSearchUsage;
  delete meta.unit; delete meta.credits; meta.state = 'unknown';
  assert.equal(readSearchUsage(value).credits, undefined);
});
test('usage binds full invocation and exact outcome; returned records are independent copies', () => {
  const ledger = new SearchUsageReceipts(digest), inv = usageInvocation(), result = usageFixture();
  const outcome = usageOutcome(inv, result);
  ledger.capture(JSON.parse(inv.argumentsJson), result); ledger.bind(inv, outcome);
  assert.equal(ledger.lookup(inv, outcome).credits, 1);
  ledger.lookup(inv, outcome).credits = 99; result.raw._meta.shuviSearchUsage.credits = 88;
  assert.equal(ledger.lookup(inv, outcome).credits, 1);
  for (const field of ['taskId', 'operationId', 'attemptId', 'invocationId', 'argumentsDigest', 'toolIdentityVersion']) {
    assert.equal(ledger.lookup({ ...inv, [field]: 'other' }, outcome), undefined);
  }
  assert.equal(ledger.lookup(inv, { ...outcome, resultDigest: 'other' }), undefined);
  ledger.bind(inv, outcome); assert.equal(ledger.lookup(inv, outcome).credits, 1);
});
test('malformed and legacy metadata never fabricate zero; changed arguments/content cannot bind', () => {
  for (const change of [u => { delete u.raw._meta; }, u => { u.raw._meta.shuviSearchUsage.credits = '1'; }]) {
    const ledger = new SearchUsageReceipts(digest), inv = usageInvocation(), result = usageFixture(); change(result);
    const outcome = usageOutcome(inv, result); ledger.capture(JSON.parse(inv.argumentsJson), result); ledger.bind(inv, outcome);
    assert.equal(ledger.lookup(inv, outcome).state, 'unknown'); assert.equal(ledger.lookup(inv, outcome).credits, undefined);
  }
  for (const mode of ['arguments', 'content']) {
    const ledger = new SearchUsageReceipts(digest), inv = usageInvocation(), result = usageFixture();
    ledger.capture(mode === 'arguments' ? { query: 'other' } : JSON.parse(inv.argumentsJson), result);
    if (mode === 'content') result.structuredContent.query = 'changed';
    const outcome = usageOutcome(inv, result); ledger.bind(inv, outcome); assert.equal(ledger.lookup(inv, outcome), undefined);
  }
});
test('reused server/provider receipt and conflicting replay invalidate previous bindings', () => {
  for (const mode of ['request', 'provider', 'invocation', 'outcome']) {
    const ledger = new SearchUsageReceipts(digest), inv = usageInvocation(), result = usageFixture();
    result.raw._meta.shuviSearchUsage.providerRequestId = 'supplier-test-id';
    const outcome = usageOutcome(inv, result); ledger.capture(JSON.parse(inv.argumentsJson), result); ledger.bind(inv, outcome);
    if (mode === 'request') ledger.capture(JSON.parse(inv.argumentsJson), result);
    if (mode === 'provider') {
      const next = usageFixture(); next.raw._meta.shuviSearchUsage.providerRequestId = 'supplier-test-id';
      ledger.capture(JSON.parse(inv.argumentsJson), next);
    }
    if (mode === 'invocation') ledger.bind({ ...inv, operationId: 'other-operation' }, outcome);
    if (mode === 'outcome') ledger.bind(inv, { ...outcome, resultDigest: 'different' });
    assert.equal(ledger.lookup(inv, outcome), undefined, mode);
  }
});
test('usage ledger is bounded, closes permanently, and rejects late completions', () => {
  const ledger = new SearchUsageReceipts(digest);
  for (let n = 0; n < 129; n++) {
    const inv = usageInvocation(String(n)), result = usageFixture(), outcome = usageOutcome(inv, result);
    ledger.capture(JSON.parse(inv.argumentsJson), result); ledger.bind(inv, outcome);
    assert.equal(ledger.lookup(inv, outcome)?.credits, n < 128 ? 1 : undefined);
  }
  ledger.close();
  const inv = usageInvocation('late'), result = usageFixture(), outcome = usageOutcome(inv, result);
  ledger.capture(JSON.parse(inv.argumentsJson), result); ledger.bind(inv, outcome);
  assert.equal(ledger.lookup(inv, outcome), undefined);
});
test('production MCP adapter binds out-of-order identical queries to their own invocation; denial calls no provider', async () => {
  const mcp = load(path.join(root, 'modules/harmony_agent/mcp_client/Index.ets'));
  const providers = new connectors.McpProviderRegistry(digest), policies = new connectors.McpReadOnlyToolPolicyRegistry();
  const config = new connectors.ShuviWebSearchMcpConfig();
  assert(providers.register(connectors.createShuviWebSearchProfile(config), 'test-profile'));
  assert(policies.register(connectors.createShuviWebSearchPolicy(config)));
  const bridge = new connectors.McpInvocationPolicyBridge(digest), ledger = new SearchUsageReceipts(digest);
  const gates = [deferred(), deferred()]; let calls = 0, allowed = true;
  const client = { async listTools() { return { errors: [], items: [{ name: 'web_search',
    ref: { serverId: 'shuvi-web-search', kind: mcp.McpCapabilityKind.TOOL, name: 'web_search' },
    inputSchema: { type: 'object' }, outputSchema: { type: 'object' } }] }; },
    async callTool() { return gates[calls++].promise; } };
  const adapter = new SearchUsageMcpAdapter(new connectors.ShuviWebSearchMcpClientToolPort(client), providers, policies,
    digest, { nowIso() { return '2026-10-24T00:00:00.000Z'; } }, { verify() { return { allowed, code: 'DENIED' }; } }, bridge, ledger);
  const catalog = await adapter.refreshCatalog(); const descriptor = catalog.entries[0].descriptor;
  const invocations = [usageInvocation('a'), usageInvocation('b')];
  invocations.forEach(inv => Object.assign(inv, { toolIdentityVersion: descriptor.toolIdentityVersion, schemaDigest: descriptor.schemaDigest }));
  const pending = invocations.map(inv => adapter.invoke(inv));
  gates[1].resolve(usageFixture(undefined, 2)); const second = await pending[1];
  gates[0].resolve(usageFixture(undefined, 1)); const first = await pending[0];
  assert.equal(ledger.lookup(invocations[0], first)?.credits, 1);
  assert.equal(ledger.lookup(invocations[1], second)?.credits, 2);
  assert.equal(ledger.lookup(invocations[0], second), undefined);
  allowed = false; const denied = await adapter.invoke({ ...invocations[0], invocationId: 'denied' });
  assert.equal(denied.status, contracts.ToolOutcomeStatus.DENIED); assert.equal(calls, 2);
});
function recoveryConfig() {
  return Object.assign(new storage.RuntimeExecutionRecoveryBridgeConfig(), {
    ownerId: 'test-host-owner', policyVersion: 'test-policy-v1', leaseTtlMs: 60000,
    // Unknown accounting fails closed; never a fake free search.
    outcomeAccounting: { actualForOutcome() { return undefined; } }
  });
}
function rdbHarness(envelope) {
  const h = { opens: [], closes: 0, queries: 0, writes: 0, resultCloses: 0, failClose: false,
    failInitialize: false, envelope, initialized: [] };
  h.handle = {
    async execute(sql) {
      h.initialized.push(sql);
      if (h.failInitialize) throw new Error('private database detail');
      assert.match(sql, /^CREATE TABLE IF NOT EXISTS harmony_agent_/);
    },
    async querySql(sql, args) {
      h.queries++;
      assert.match(sql, /WHERE slot_id = \?/); assert.deepEqual(args, [1]);
      const row = h.envelope;
      return {
        goToFirstRow() { return row !== undefined; }, getLong(index) { assert.equal(index, 0); return row.revision; },
        getString(index) { return [row.revision, row.schemaVersion, row.payloadJson, row.payloadDigest][index]; },
        close() { h.resultCloses++; }
      };
    },
    async update() { h.writes++; throw new Error('Unexpected write'); },
    async insert() { h.writes++; throw new Error('Unexpected write'); },
    async close() { h.closes++; if (h.failClose) throw new Error('private close detail'); }
  };
  h.opener = { async open(config) { h.opens.push({ ...config }); return h.handle; } };
  return h;
}
function memoryRequest() {
  return Object.assign(new runtime.PlanningMemoryContextRequest(), {
    taskId: 'task-1', ownerId: 'owner-1', queryTerms: ['alpha'], maxItems: 4, maxCharacters: 256
  });
}

test('session key is consumed, scoped, available only while open, and erased on close', async () => {
  const credentialStore = new SessionModelCredentials();
  await assert.rejects(credentialStore.open(), /REQUIRED/);
  const bytes = new TextEncoder().encode('test-only-key'); credentialStore.configure(bytes);
  assert(bytes.every(value => value === 0));
  await assert.rejects(credentialStore.resolve('deepseek-direct', 'deepseek.invoke'), /UNAVAILABLE/);
  await credentialStore.open();
  assert.equal((await credentialStore.resolve('deepseek-direct', 'deepseek.invoke')).headers.Authorization,
    'Bearer test-only-key');
  await assert.rejects(credentialStore.resolve('another-provider', 'deepseek.invoke'), /UNAVAILABLE/);
  await assert.rejects(credentialStore.resolve('deepseek-direct', 'another-scope'), /UNAVAILABLE/);
  const replacement = new TextEncoder().encode('replacement');
  assert.throws(() => credentialStore.configure(replacement), /ACTIVE/);
  assert(replacement.every(value => value === 0));
  await credentialStore.close(); await credentialStore.close();
  await assert.rejects(credentialStore.resolve('deepseek-direct', 'deepseek.invoke'), /UNAVAILABLE/);
  await assert.rejects(credentialStore.open(), /REQUIRED/);
});

test('invalid session key consumes input and cannot retain a previous inactive key', async () => {
  for (const input of ['', 'space key', 'line\nkey', '中文', 'x'.repeat(4097)]) {
    const credentialStore = new SessionModelCredentials();
    credentialStore.configure(new TextEncoder().encode('old-test-key'));
    const bytes = new TextEncoder().encode(input);
    assert.throws(() => credentialStore.configure(bytes), /INVALID/);
    assert(bytes.every(value => value === 0)); await assert.rejects(credentialStore.open(), /REQUIRED/);
  }
});

test('host SHA-256 covers UTF-8, independent calls and bounded inputs', () => {
  for (const input of ['', 'abc', '休比 Shuvi']) {
    assert.equal(hostDigest.digest(input), crypto.createHash('sha256').update(input).digest('hex'));
  }
  assert.throws(() => hostDigest.digest('a'.repeat(2 * 1024 * 1024 + 1)), /TOO_LARGE/);
  assert.throws(() => hostDigest.digest('中'.repeat(800000)), /TOO_LARGE/);
});

test('host binding is side-effect free and cannot overwrite caller ports', () => {
  const h = rdbHarness(); const bundle = new ShuviDeviceHostResources(h.opener, recoveryConfig());
  const ports = new (load(path.join(services, 'ShuviModelBackend.ets')).ShuviModelBackendPorts)();
  bundle.bind(ports);
  assert.equal(ports.runtime.persistence, bundle.execution); assert.equal(ports.runtime.recovery, bundle.execution);
  assert.equal(ports.host.credentialStore, bundle.credentials); assert.equal(ports.memoryContext, bundle.memory);
  assert.equal(h.opens.length, 0);
  assert.throws(() => bundle.bind(ports), /CONFLICT/);
  assert.throws(() => bundle.bind(new (load(path.join(services, 'ShuviModelBackend.ets')).ShuviModelBackendPorts)()), /CONFLICT/);
  const config = recoveryConfig(); config.outcomeAccounting = undefined;
  assert.throws(() => new ShuviDeviceHostResources(h.opener, config), /CONFIGURATION_REQUIRED/);
});

test('native opener passes the supplied Ability context and encrypted configuration to RDB', async () => {
  const api = nativeModules['@ohos.data.relationalStore']; const original = api.getRdbStore;
  // The loader copies the native module at import; use a fresh app module with an explicit native override.
  const ctx = {}; const config = { name: 'test.db', securityLevel: 3, encrypt: true, persist: true }; const handle = {};
  const module = load(path.join(services, 'AgentRdbResources.ets'), {
    '@ohos.data.relationalStore': { default: { async getRdbStore(context, options) {
      assert.equal(context, ctx); assert.equal(options, config); return handle;
    } } }
  });
  assert.equal(await new module.NativeAgentRdbOpen(ctx).open(config), handle);
  assert.equal(api.getRdbStore, original);
});

test('execution resource opens once, uses encrypted independent database and rejects access after close', async () => {
  const h = rdbHarness(); const resource = new AgentExecutionResource(h.opener, recoveryConfig(), hostDigest);
  await assert.rejects(resource.listRecoveryTaskIds(), /NOT_READY/);
  await Promise.all([resource.open(), resource.open()]);
  assert.deepEqual(h.opens, [{ name: 'shuvi_agent_execution_v1.db', securityLevel: 3, encrypt: true, persist: true }]);
  assert.deepEqual(await resource.listRecoveryTaskIds(), []);
  assert.equal(await resource.loadCheckpoint('missing'), undefined);
  assert.equal(await resource.loadRecoveryAuthority('missing'), undefined);
  const invalid = await resource.saveCheckpoint(new runtime.RuntimeTaskRecoveryCheckpoint(), 0,
    new runtime.RuntimeDurableAuthorityPayload(), 1000);
  assert.equal(invalid.accepted, false); assert.equal(h.writes, 0);
  await Promise.all([resource.close(), resource.close()]);
  assert.equal(h.closes, 1); assert.equal(h.resultCloses, 1);
  await assert.rejects(resource.listRecoveryTaskIds(), /NOT_READY/);
});

test('persisted execution records are loaded through the real RDB snapshot backend without being reset', async () => {
  const source = new storage.ExecutionRecoveryStore();
  const snapshot = Object.assign(new contracts.AgentTaskSnapshot(), { requestId: 'request-1', taskId: 'task-1',
    sessionId: 'session-1', snapshotVersion: 1, lastEventSequence: 1, resultJson: '{"status":"running"}',
    updatedAt: '2026-10-23T00:00:00.000Z' });
  const checkpoint = { checkpointVersion: '1.1', taskId: 'task-1', snapshotVersion: 1 };
  assert.equal(source.saveTask(snapshot, '1.1', JSON.stringify(checkpoint), 0, 1000).accepted, true);
  const h = rdbHarness(source.checkpoint(hostDigest));
  const resource = new AgentExecutionResource(h.opener, recoveryConfig(), hostDigest);
  await resource.open(); assert.deepEqual(await resource.listRecoveryTaskIds(), ['task-1']);
  assert.deepEqual(await resource.loadCheckpoint('task-1'), checkpoint);
  await resource.close(); await resource.open();
  assert.deepEqual(await resource.listRecoveryTaskIds(), ['task-1']); assert.equal(h.writes, 0);
  await resource.close();
});

test('memory restores actual records and only exposes the requesting owner non-sensitive context', async () => {
  const source = new storage.DeterministicMemoryStore(hostDigest);
  for (const [memoryId, ownerId, privacyClass, sourceKind] of [
    ['allowed', 'owner-1', storage.MemoryPrivacyClass.SHAREABLE, storage.MemorySourceKind.USER_EXPLICIT],
    ['other-owner', 'owner-2', storage.MemoryPrivacyClass.SHAREABLE, storage.MemorySourceKind.USER_EXPLICIT],
    ['sensitive', 'owner-1', storage.MemoryPrivacyClass.SENSITIVE, storage.MemorySourceKind.USER_EXPLICIT],
    ['trace', 'owner-1', storage.MemoryPrivacyClass.PRIVATE, storage.MemorySourceKind.RAW_PERSONAL_TRACE]
  ]) {
    const content = 'alpha ' + memoryId;
    const record = Object.assign(new storage.MemoryRecord(), { memoryId, ownerId, privacyClass, sourceKind,
      title: memoryId, content, contentDigest: hostDigest.digest(content), tags: ['project'],
      version: 1, createdAtMs: 100, updatedAtMs: 101 });
    assert.equal(source.saveMemory(record, 0).accepted, true);
  }
  const h = rdbHarness(source.checkpoint(hostDigest, 1));
  const resource = new AgentMemoryResource(h.opener, hostDigest);
  assert.throws(() => resource.retrieve(memoryRequest()), /NOT_READY/);
  await resource.open();
  assert.equal(h.opens[0].name, 'shuvi_agent_memory_v1.db'); assert.equal(h.opens[0].encrypt, true);
  assert.deepEqual(resource.retrieve(memoryRequest()).items.map(item => item.memoryId), ['allowed']);
  await resource.close(); assert.throws(() => resource.retrieve(memoryRequest()), /NOT_READY/);
  assert.equal(h.writes, 0); assert.equal(h.resultCloses, 1);
});

for (const kind of ['execution', 'memory']) {
  test(`${kind} corruption and unsupported schemas fail without overwriting data`, async () => {
    for (const schemaVersion of ['invalid-future-version', kind === 'execution' ? '1.2' : '1.0']) {
      const envelope = { revision: 1, schemaVersion, payloadJson: '{"private":"invalid"}', payloadDigest: 'bad' };
      const h = rdbHarness(envelope);
      const resource = kind === 'execution' ? new AgentExecutionResource(h.opener, recoveryConfig(), hostDigest) :
        new AgentMemoryResource(h.opener, hostDigest);
      await assert.rejects(resource.open(), /OPEN_FAILED/);
      assert.equal(h.closes, 1); assert.equal(h.writes, 0); assert.equal(h.envelope, envelope);
      assert.equal(h.resultCloses, 1);
      await resource.close(); assert.equal(h.closes, 1);
    }
  });
}

test('initialization failure releases RDB; failed close retains handle and blocks reopen until cleanup', async () => {
  const h = rdbHarness(); h.failInitialize = true;
  const resource = new AgentExecutionResource(h.opener, recoveryConfig(), hostDigest);
  await assert.rejects(resource.open(), /OPEN_FAILED/); assert.equal(h.closes, 1);
  h.failInitialize = false; await resource.open(); h.failClose = true;
  await assert.rejects(resource.close(), /CLOSE_FAILED/);
  await assert.rejects(resource.open(), /NOT_CLOSED/);
  await assert.rejects(resource.listRecoveryTaskIds(), /NOT_READY/);
  h.failClose = false; await resource.close(); await resource.open(); await resource.close();
  assert.equal(h.opens.length, 3); assert.equal(h.closes, 4);
});

test('close while opening does not leak a late database handle or expose ready resources', async () => {
  const gate = deferred(); const h = rdbHarness();
  const resource = new AgentExecutionResource({ open() { return gate.promise; } }, recoveryConfig(), hostDigest);
  const opening = resource.open(); const openingCheck = assert.rejects(opening, /OPEN_FAILED/);
  const closing = resource.close();
  await assert.rejects(resource.open(), /NOT_CLOSED/);
  gate.resolve(h.handle); await openingCheck; await closing;
  assert.equal(h.closes, 1); assert.equal(h.initialized.length, 0);
  await assert.rejects(resource.listRecoveryTaskIds(), /NOT_READY/);
});

test('close drains accepted durable calls and rejects new calls without invoking the bridge', async () => {
  const h = rdbHarness(); const resource = new AgentExecutionResource(h.opener, recoveryConfig(), hostDigest);
  await resource.open(); const gate = deferred();
  const prototype = storage.RuntimeExecutionRecoveryBridge.prototype; const original = prototype.loadCheckpoint;
  let calls = 0;
  prototype.loadCheckpoint = function () { calls++; return gate.promise; };
  try {
    const pending = resource.loadCheckpoint('test-task'); const closing = resource.close();
    await assert.rejects(resource.loadCheckpoint('later-task'), /NOT_READY/);
    assert.equal(h.closes, 0); gate.resolve(undefined); await pending; await closing;
    assert.equal(calls, 1); assert.equal(h.closes, 1);
  } finally { prototype.loadCheckpoint = original; }
});

test('upstream host rolls back real owned resources and clears credentials when memory open fails', async () => {
  const execution = rdbHarness(); const memory = rdbHarness(); memory.failInitialize = true;
  const bundle = new ShuviDeviceHostResources({ open(config) {
    return (config.name.includes('execution') ? execution : memory).opener.open(config);
  } }, recoveryConfig());
  const ports = new (load(path.join(services, 'ShuviModelBackend.ets')).ShuviModelBackendPorts)(); bundle.bind(ports);
  bundle.credentials.configure(new TextEncoder().encode('test-only-key'));
  let reachedNetwork = false;
  ports.host.mcpClient = { async open() { reachedNetwork = true; }, async close() {} };
  ports.host.runtimeFactory = { async create() { throw new Error('Must not reach Runtime'); } };
  await assert.rejects(runtime.createSingleAgentHostRuntime('1.0', ports.host), /resource open failed/);
  assert.equal(reachedNetwork, false); assert.equal(execution.closes, 1); assert.equal(memory.closes, 1);
  await assert.rejects(bundle.credentials.open(), /REQUIRED/);
});

test('upstream host opens resources before Runtime and shuts them down after Runtime, once', async () => {
  const execution = rdbHarness(); const memory = rdbHarness(); const events = [];
  const bundle = new ShuviDeviceHostResources({ async open(config) {
    const h = config.name.includes('execution') ? execution : memory;
    events.push(config.name.includes('execution') ? 'execution' : 'memory');
    return await h.opener.open(config);
  } }, recoveryConfig());
  const ports = new (load(path.join(services, 'ShuviModelBackend.ets')).ShuviModelBackendPorts)(); bundle.bind(ports);
  bundle.credentials.configure(new TextEncoder().encode('test-only-key'));
  ports.host.mcpClient = { async open() { events.push('mcp'); }, async close() { events.push('mcp-close'); } };
  ports.host.runtimeFactory = { async create() {
    events.push('runtime');
    assert.deepEqual(await bundle.execution.listRecoveryTaskIds(), []);
    assert.equal(bundle.memory.retrieve(memoryRequest()).items.length, 0);
    await bundle.credentials.resolve('deepseek-direct', 'deepseek.invoke');
    return { async shutdown(mode) {
      assert.equal(mode, runtime.ShutdownMode.IMMEDIATE);
      assert.equal(execution.closes, 0); assert.equal(memory.closes, 0); events.push('runtime-stop');
    } };
  } };
  const facade = await runtime.createSingleAgentHostRuntime('1.0', ports.host);
  await Promise.all([facade.shutdown(runtime.ShutdownMode.IMMEDIATE), facade.shutdown(runtime.ShutdownMode.IMMEDIATE)]);
  assert.deepEqual(events, ['execution', 'memory', 'mcp', 'runtime', 'runtime-stop', 'mcp-close']);
  assert.equal(execution.closes, 1); assert.equal(memory.closes, 1);
  await assert.rejects(bundle.credentials.open(), /REQUIRED/);
});

const { SessionModelHttpClient } = load(path.join(services, 'SessionModelHttpClient.ets'));
const { ShuviRuntimeSession } = load(path.join(services, 'ShuviRuntimeSession.ets'));
const { ShuviRuntimeController, ShuviRuntimeState } = load(path.join(services, 'ShuviRuntimeController.ets'));

test('session HTTP stop rejects immediately, cancels all handles once and rejects late responses', async () => {
  const gates = [deferred(), deferred()]; let calls = 0, cancelled = 0;
  const client = new SessionModelHttpClient({ start() {
    return { result: gates[calls++].promise, cancel() { cancelled++; } };
  } });
  const one = client.start({}); const two = client.start({});
  const rejected = [assert.rejects(one.result, error => error.code === 'CANCELLED' && error.operationStarted),
    assert.rejects(two.result, error => error.code === 'CANCELLED' && error.operationStarted)];
  client.stop(); client.stop(); one.cancel();
  await Promise.all(rejected); assert.equal(cancelled, 2);
  assert.throws(() => client.start({}), error => error.code === 'CANCELLED' && !error.operationStarted);
  gates[0].resolve(response()); gates[1].reject(new Error('late upstream detail')); await Promise.resolve();
});

test('session HTTP completed requests are removed and cancellation failure does not skip remaining handles', async () => {
  const completed = new SessionModelHttpClient({ start() {
    return { result: Promise.resolve(response()), cancel() { throw new Error('completed request must not cancel'); } };
  } });
  assert.equal((await completed.start({}).result).statusCode, 200); assert.doesNotThrow(() => completed.stop());
  let cancelled = 0;
  const client = new SessionModelHttpClient({ start() {
    return { result: new Promise(() => {}), cancel() { cancelled++; throw new Error('native cancellation failed'); } };
  } });
  const one = client.start({}); const two = client.start({});
  const rejected = [assert.rejects(one.result, /stopped/), assert.rejects(two.result, /stopped/)];
  assert.throws(() => client.stop(), /CANCEL_FAILED/); await Promise.all(rejected); assert.equal(cancelled, 2);
});

function controlledSession(overrides = {}) {
  const calls = { start: 0, stop: 0, submit: 0, authorize: 0, cancel: 0, reads: 0, closed: 0, listener: undefined };
  const session = {
    async start(key) { calls.start++; key.fill(0); }, async stop() { calls.stop++; },
    async submit() { calls.submit++; return { taskId: 'task-1' }; },
    async authorize() { calls.authorize++; return { accepted: true }; },
    async cancel() { calls.cancel++; return { accepted: true }; },
    async getTask() { calls.reads++; return { taskId: 'task-1' }; },
    async subscribe(taskId, listener) {
      calls.listener = listener; let closed = false;
      return { close() { if (!closed) calls.closed++; closed = true; }, isClosed() { return closed; } };
    }, ...overrides
  };
  return { calls, session, factory: { create() { return session; } } };
}
async function activeController(overrides = {}) {
  const h = controlledSession(overrides); h.controller = new ShuviRuntimeController();
  h.controller.onForeground(); await h.controller.start(h.factory, new TextEncoder().encode('fake-key'));
  return h;
}

test('foreground alone does not start; rejected start consumes key and ready start is not duplicated', async () => {
  const h = controlledSession(); const controller = new ShuviRuntimeController();
  const key = new TextEncoder().encode('fake-key');
  await assert.rejects(controller.start(h.factory, key), /NOT_ALLOWED/);
  assert(key.every(value => value === 0)); assert.equal(h.calls.start, 0);
  controller.onForeground(); assert.equal(h.calls.start, 0);
  await controller.start(h.factory, new TextEncoder().encode('fake-key'));
  await assert.rejects(controller.start(h.factory, new TextEncoder().encode('fake-key')), /NOT_ALLOWED/);
  assert.equal(h.calls.start, 1); assert.equal(controller.lifecycleState(), ShuviRuntimeState.READY);
  await controller.stop();
});

test('background synchronously gates all commands; foreground does not restart the stopped session', async () => {
  const gate = deferred(); const h = await activeController({ stop() { return gate.promise; } });
  await h.controller.submit({ intent: 'question' }); await h.controller.authorize({}, false);
  await h.controller.cancel('task-1'); await h.controller.getTask('task-1');
  const stopped = h.controller.onBackground();
  for (const command of [() => h.controller.submit({ intent: 'question' }), () => h.controller.authorize({}, true),
    () => h.controller.cancel('task-1'), () => h.controller.getTask('task-1'), () => h.controller.subscribe('task-1', {})]) {
    await assert.rejects(command(), /NOT_READY/);
  }
  assert.equal(h.calls.submit, 1); assert.equal(h.calls.authorize, 1);
  h.controller.onForeground(); assert.equal(h.controller.lifecycleState(), ShuviRuntimeState.STOPPING);
  gate.resolve(); await stopped;
  assert.equal(h.controller.lifecycleState(), ShuviRuntimeState.STOPPED); assert.equal(h.calls.start, 1);
  await assert.rejects(h.controller.submit({ intent: 'question' }), /NOT_READY/);
});

test('background during startup prevents late ready and duplicate start, even after returning to foreground', async () => {
  const startup = deferred(), shutdown = deferred();
  const h = controlledSession({ start(key) { key.fill(0); return startup.promise; }, stop() { return shutdown.promise; } });
  const controller = new ShuviRuntimeController(); controller.onForeground();
  const starting = controller.start(h.factory, new TextEncoder().encode('fake-key'));
  const interrupted = assert.rejects(starting, /INTERRUPTED/);
  await assert.rejects(controller.start(h.factory, new TextEncoder().encode('fake-key')), /NOT_ALLOWED/);
  const stopping = controller.onBackground(); controller.onForeground(); startup.resolve(); await interrupted;
  assert.equal(controller.lifecycleState(), ShuviRuntimeState.STOPPING);
  shutdown.resolve(); await stopping; assert.equal(controller.lifecycleState(), ShuviRuntimeState.STOPPED);
});

test('late task results from a prior session cannot become new-session UI results', async () => {
  const reply = deferred(); const h = await activeController({ submit() { return reply.promise; } });
  const request = h.controller.submit({ intent: 'question' }); const discarded = assert.rejects(request, /DISCARDED/);
  await h.controller.onBackground(); h.controller.onForeground();
  const next = controlledSession(); await h.controller.start(next.factory, new TextEncoder().encode('fake-key'));
  reply.resolve({ taskId: 'old-task' }); await discarded;
  assert.equal(h.controller.lifecycleState(), ShuviRuntimeState.READY);
  assert.equal((await h.controller.submit({ intent: 'question' })).taskId, 'task-1');
  await h.controller.stop();
});

test('subscriptions close on stop and old event/authorization/clarification callbacks are gated', async () => {
  const h = await activeController(); const delivered = [];
  const listener = { onEvent(value) { delivered.push(value); }, onAuthorizationRequired(value) { delivered.push(value); },
    onClarificationRequired(value) { delivered.push(value); } };
  await h.controller.subscribe('task-1', listener);
  h.calls.listener.onEvent('current'); await h.controller.onBackground();
  h.calls.listener.onEvent('late'); h.calls.listener.onAuthorizationRequired('late');
  h.calls.listener.onClarificationRequired('late');
  assert.deepEqual(delivered, ['current']); assert.equal(h.calls.closed, 1);
});

test('subscription resolving after shutdown is immediately closed', async () => {
  const gate = deferred(); let closed = 0;
  const h = await activeController({ subscribe() { return gate.promise; } });
  const pending = h.controller.subscribe('task-1', {}); const discarded = assert.rejects(pending, /DISCARDED/);
  await h.controller.stop(); gate.resolve({ close() { closed++; }, isClosed() { return false; } });
  await discarded; assert.equal(closed, 1);
});

test('failed startup cleans up and allows explicit retry; failed shutdown blocks unsafe reuse', async () => {
  const h = controlledSession({ async start() { throw new Error('private startup detail'); } });
  const controller = new ShuviRuntimeController(); controller.onForeground();
  await assert.rejects(controller.start(h.factory, new TextEncoder().encode('fake-key')), /START_FAILED/);
  assert.equal(h.calls.stop, 1); assert.equal(controller.lifecycleState(), ShuviRuntimeState.FAILED);
  const next = controlledSession({ async stop() { throw new Error('private cleanup detail'); } });
  await controller.start(next.factory, new TextEncoder().encode('fake-key'));
  await assert.rejects(controller.stop(), /SHUTDOWN_FAILED/);
  assert.equal(controller.lifecycleState(), ShuviRuntimeState.BLOCKED);
  controller.onForeground();
  await assert.rejects(controller.start(h.factory, new TextEncoder().encode('fake-key')), /NOT_ALLOWED/);
});

function realSessionHarness(options = {}) {
  const execution = rdbHarness(), memory = rdbHarness(); memory.failInitialize = !!options.failMemory;
  const resources = new ShuviDeviceHostResources({ open(config) {
    return (config.name.includes('execution') ? execution : memory).opener.open(config);
  } }, recoveryConfig());
  const ports = new (load(path.join(services, 'ShuviModelBackend.ets')).ShuviModelBackendPorts)(); resources.bind(ports);
  const events = [];
  ports.host.mcpClient = { async open() { events.push('mcp-open'); if (options.startGate) await options.startGate.promise; },
    async close() { events.push('mcp-close'); } };
  ports.host.runtimeFactory = { async create() {
    events.push('runtime-create');
    return { async shutdown(mode) { assert.equal(mode, runtime.ShutdownMode.IMMEDIATE); events.push('runtime-stop'); } };
  } };
  const config = new runtime.AgentApplicationBackendConfig(); config.userId = 'test-user';
  const backend = new runtime.AgentApplicationBackend(config, ports.host);
  const gate = deferred(); let cancelled = 0;
  const http = new SessionModelHttpClient({ start() { return { result: gate.promise, cancel() { cancelled++; } }; } });
  const manager = { async disconnectAll() { events.push('disconnect'); } };
  const previews = new (load(path.join(services, 'SearchAuthorizationPreview.ets')).SearchAuthorizationPreviews)();
  const usage = new SearchUsageReceipts(digest);
  const session = new ShuviRuntimeSession(backend, resources, http, manager, previews, usage);
  return { session, backend, resources, execution, memory, http, usage, events, cancelled: () => cancelled };
}

test('real backend session stops active HTTP, revokes credentials, closes stores and cannot reopen', async () => {
  const h = realSessionHarness(); await h.session.start(new TextEncoder().encode('fake-key'));
  const pending = h.http.start({}); const rejected = assert.rejects(pending.result, /stopped/);
  const stopping = h.session.stop();
  const inv = usageInvocation(), result = usageFixture(), outcome = usageOutcome(inv, result);
  h.usage.capture(JSON.parse(inv.argumentsJson), result); h.usage.bind(inv, outcome);
  assert.equal(h.usage.lookup(inv, outcome), undefined); // Closed before asynchronous shutdown drains.
  await assert.rejects(h.resources.credentials.resolve('deepseek-direct', 'deepseek.invoke'), /UNAVAILABLE/);
  await rejected; await stopping;
  assert.equal(h.cancelled(), 1); assert.equal(h.execution.closes, 1); assert.equal(h.memory.closes, 1);
  assert.equal(h.backend.lifecycleState(), runtime.AgentApplicationBackendState.STOPPED);
  assert(h.events.indexOf('runtime-stop') < h.events.indexOf('mcp-close'));
  await h.session.stop(); assert.equal(h.cancelled(), 1);
  await assert.rejects(h.session.start(new TextEncoder().encode('fake-key')), /ALREADY_USED/);
});

test('real backend startup failure is rolled back and does not pretend shutdown itself failed', async () => {
  const h = realSessionHarness({ failMemory: true }); const controller = new ShuviRuntimeController(); controller.onForeground();
  await assert.rejects(controller.start({ create() { return h.session; } }, new TextEncoder().encode('fake-key')), /START_FAILED/);
  assert.equal(controller.lifecycleState(), ShuviRuntimeState.FAILED);
  assert.equal(h.execution.closes, 1); assert.equal(h.memory.closes, 1);
  await assert.rejects(h.resources.credentials.open(), /REQUIRED/);
});

test('real backend shutdown drains late discovery, does not publish ready, and clears credentials', async () => {
  const startGate = deferred(); const h = realSessionHarness({ startGate });
  const starting = h.session.start(new TextEncoder().encode('fake-key'));
  const interrupted = assert.rejects(starting, /INTERRUPTED/);
  for (let i = 0; i < 25 && !h.events.includes('mcp-open'); i++) await Promise.resolve();
  assert(h.events.includes('mcp-open'));
  const stopping = h.session.stop(); startGate.resolve(); await interrupted; await stopping;
  assert.equal(h.execution.closes, 1); assert.equal(h.memory.closes, 1);
  await assert.rejects(h.resources.credentials.open(), /REQUIRED/);
  await assert.rejects(h.session.submit({ intent: 'question' }), /NOT_READY/);
});

// Startup-only UI assembly: actual production Runtime, adapter, catalog and RDB implementations;
// only native storage and the MCP network manager are replaced.
function startupHarness({ badCatalog = false, failConnect = false } = {}) {
  const execution = rdbHarness(), memory = rdbHarness();
  const events = [];
  const mcp = load(path.join(root, 'modules/harmony_agent/mcp_client/Index.ets'));
  class Manager {
    registerServer(profile) { events.push('register'); assert.equal(profile.endpoint, 'http://127.0.0.1:8787/mcp'); }
    async connect() { events.push('connect'); if (failConnect) throw new Error('private detail'); }
    async refreshServer() { events.push('refresh'); }
    async listTools() {
      events.push('list');
      return { errors: [], items: badCatalog ? [] : [{
        name: 'web_search', description: 'Search public web',
        ref: { serverId: 'shuvi-web-search', kind: mcp.McpCapabilityKind.TOOL, name: 'web_search' },
        inputSchema: { type: 'object', additionalProperties: false, required: ['query'], properties: {
          query: { type: 'string' }, maxResults: { type: 'integer', minimum: 1, maximum: 10, default: 5 }
        } }, outputSchema: { type: 'object' }
      }] };
    }
    async callTool() { events.push('TOOL_CALLED'); throw new Error('Must not call a tool'); }
    async disconnectAll() { events.push('disconnect'); }
    async unregisterServer() { events.push('unregister'); }
  }
  const assembly = load(path.join(services, 'RuntimeStartupAssembly.ets'), {
    '@harmony_agent/mcp-client': { ...mcp, McpClientManager: Manager }
  });
  const factory = new assembly.RuntimeStartupFactory({ open(config) {
    return (config.name.includes('execution') ? execution : memory).opener.open(config);
  } }, true);
  return { factory, assembly, execution, memory, events };
}

test('startup factory creates a real Runtime with discovery only and blocks every task command', async () => {
  const h = startupHarness(); const session = h.factory.create();
  assert.deepEqual(h.events, []); assert.equal(h.execution.opens.length, 0);
  const key = new TextEncoder().encode('test-only-key');
  await session.start(key); assert(key.every(value => value === 0));
  assert(h.events.includes('list')); assert(!h.events.includes('TOOL_CALLED'));
  for (const operation of [() => session.submit({ intent: 'search' }), () => session.authorize({}, true),
    () => session.cancel('task'), () => session.getTask('task'), () => session.subscribe('task', {}, 0)]) {
    await assert.rejects(operation(), /STARTUP_CHECK_ONLY/);
  }
  await session.stop(); assert.equal(h.execution.closes, 1); assert.equal(h.memory.closes, 1);
});

test('startup discovery failure rolls back real stores and allows an explicit retry', async () => {
  for (const option of [{ badCatalog: true }, { failConnect: true }]) {
    const h = startupHarness(option); const controller = new ShuviRuntimeController(); controller.onForeground();
    await assert.rejects(controller.start(h.factory, new TextEncoder().encode('fake-key')), /START_FAILED/);
    assert.equal(controller.lifecycleState(), ShuviRuntimeState.FAILED);
    assert.equal(h.execution.closes, 1); assert.equal(h.memory.closes, 1);
    assert(!h.events.includes('TOOL_CALLED'));
  }
});

test('startup assembly fails closed for release, grants and unknown search accounting', () => {
  const h = startupHarness();
  assert.throws(() => new h.assembly.RuntimeStartupFactory({}, false).create(), /DEBUG_ONLY/);
  assert.equal(new h.assembly.StartupDeniedGrants().verify({}).allowed, false);
  assert.equal(new h.assembly.UnsettledSearchAccounting().actualForOutcome({}, {}), undefined);
  const config = h.assembly.startupBackendConfig();
  assert.equal(config.frontend.requestedBudget.maxToolCalls, 0);
  assert.equal(config.frontend.requestedBudget.maxMonetaryCostMicros, 0);
  assert.equal(config.search.estimatedCostMicros, 8000);
});

test('lifecycle view observes background and cleanup, detaches, and cannot break resource cleanup by throwing', async () => {
  const controller = new ShuviRuntimeController(); const states = [];
  controller.attach(state => states.push(state));
  await controller.onBackground(); // Clears an unsubmitted key even when there is no session.
  assert.deepEqual(states, [ShuviRuntimeState.IDLE, ShuviRuntimeState.IDLE]);
  controller.onForeground(); const h = controlledSession();
  await controller.start(h.factory, new TextEncoder().encode('fake-key'));
  assert.equal(states.at(-1), ShuviRuntimeState.READY);
  await controller.onBackground(); assert.equal(states.at(-1), ShuviRuntimeState.STOPPED);
  controller.detach(); const count = states.length; await controller.onBackground(); assert.equal(states.length, count);
  controller.attach(() => { throw new Error('view failure'); }); controller.onForeground();
  await controller.start(h.factory, new TextEncoder().encode('fake-key')); await controller.stop();
  assert.equal(h.calls.stop, 2);
});


// Model-only UX: real Runtime, durable journal and Provider; only native I/O is injected.
const chatAssembly = load(path.join(services, 'ChatRuntimeAssembly.ets'));
const { ChatExecutionStore } = load(path.join(services, 'ChatExecutionStore.ets'));
const { RuntimeChatSession } = load(path.join(services, 'RuntimeChatSession.ets'));
const calendarContract = load(path.join(services, '../calendar/CalendarDraftContract.ets'));
const { CalendarDraftSession } = load(path.join(services, '../calendar/CalendarDraftSession.ets'));
function chatJournalBackend() {
  const h = { value: undefined, fail: false };
  h.port = { async initialize() {}, async load() { return h.value; }, async compareAndSet(rev, next) {
    if (h.fail || rev !== (h.value?.revision || 0)) return false;
    h.value = structuredClone(next); return true;
  } }; return h;
}
function chatHarness(options = {}) {
  const journalBackend = chatJournalBackend();
  let journal; let calls = 0; let closed = 0; let modelCancelled = 0;
  const requests = []; const proposals = [];
  class Resource {
    closed = false;
    async open() { journal = new ChatExecutionStore(journalBackend.port, new AgentHostDigest()); await journal.open(); }
    async close() { if (!this.closed) closed++; this.closed = true; }
    saveCheckpoint(...args) { return journal.saveCheckpoint(...args); }
    loadCheckpoint(...args) { return journal.loadCheckpoint(...args); }
    beforeDispatch(...args) { return journal.beforeDispatch(...args); }
    recordOutcome(...args) { return journal.recordOutcome(...args); }
    recordDispatchRejected(...args) { return journal.recordDispatchRejected(...args); }
    normalizeRecoveredOperation(...args) { return journal.normalizeRecoveredOperation(...args); }
    recordReconciliation(...args) { return journal.recordReconciliation(...args); }
  }
  class Client {
    start(request) {
      calls++;
      assert.equal(request.authorization, 'Bearer test-only-key');
      const body = JSON.parse(request.body); assert.equal(body.model, 'deepseek-flash');
      requests.push(body);
      assert.equal(body.messages.length, 2); assert.equal(body.max_tokens, 1024); assert.equal(body.tools, undefined);
      const result = options.gate ? options.gate.promise : Promise.resolve({ statusCode: options.status || 200,
        body: JSON.stringify({ object: 'chat.completion', model: 'deepseek-flash', choices: [{index: 0,
          message: {role: 'assistant', content: options.texts?.[calls - 1] || options.text || 'Test model answer'}, finish_reason: options.finish || 'stop'}],
          usage: {prompt_tokens: 52, completion_tokens: 18, total_tokens: 70} }) });
      return {result, cancel() { modelCancelled++; }};
    }
  }
  const assembly = load(path.join(services, 'ChatRuntimeAssembly.ets'), {
    './ChatExecutionStore': { ChatExecutionResource: Resource },
    './DeepSeekHttpClient': { ArkTsDeepSeekHttpClient: Client }
  });
  const controller = new ShuviRuntimeController(); controller.onForeground();
  const {AssistantRuntimeSession} = load(path.join(services,'../calendar/AssistantRuntimeSession.ets'));
  const ui = options.assistant ? new AssistantRuntimeSession(controller) : options.calendar ? new CalendarDraftSession(controller) : new RuntimeChatSession(controller);
  if (options.calendar) ui.attach(() => {}, proposal => proposals.push(proposal));
  return {ui, controller, journalBackend, requests, proposals,
    factory: new assembly.ChatRuntimeFactory({}, true, options.calendar || options.assistant ? ui.context : undefined,
      options.assistant ? assembly.ChatPurpose.ASSISTANT : options.calendar ? assembly.ChatPurpose.CALENDAR_DRAFT : assembly.ChatPurpose.PUBLIC_CHAT),
    calls: () => calls, closed: () => closed, cancelled: () => modelCancelled, store: () => journal};
}
async function waitChat(ui) {
  for (let i=0; i<100 && ui.snapshot().busy; i++) await new Promise(resolve=>setTimeout(resolve, 1));
  assert.equal(ui.snapshot().busy, false, 'chat must reach a terminal UI state');
}
test('model-only real Runtime submits, persists and returns a validated answer with no MCP discovery', async () => {
  const h = chatHarness(); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  assert.equal(h.controller.lifecycleState(), ShuviRuntimeState.READY); assert.equal(h.calls(), 0);
  await h.ui.send('Explain Runtime'); await waitChat(h.ui);
  assert.equal(h.calls(), 1); assert.equal(h.ui.snapshot().reply, 'Test model answer');
  const record = JSON.parse(h.journalBackend.value.payloadJson).records[0];
  assert.equal(record.checkpoint.snapshot.status, contracts.AgentTaskStatus.COMPLETED);
  assert.equal(record.outcome.status, contracts.ToolOutcomeStatus.SUCCEEDED);
  assert.equal(JSON.parse(record.outcome.resultJson).inputTokens, 52);
  assert.equal(JSON.parse(record.outcome.resultJson).settledCostMicros, undefined);
  await h.ui.stop(); assert.equal(h.closed(), 1);
});
test('model-only failures and truncated output are terminal and never fake success', async () => {
  for (const opts of [{status:401}, {status:429}, {finish:'length'}]) {
    const h = chatHarness(opts); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
    await h.ui.send('question'); await waitChat(h.ui);
    assert.match(h.ui.snapshot().reply, /失败/); assert.equal(h.calls(), 1); await h.ui.stop();
  }
});
test('chat rejects missing opt-in, release and malformed reply before sending or rendering success', async () => {
  const h = chatHarness(); await h.ui.send('question'); assert.equal(h.calls(), 0);
  assert.throws(() => new chatAssembly.ChatRuntimeFactory({}, false).create(), /DEBUG_ONLY/);
  for (const raw of ['null','[]','{}','not-json', JSON.stringify({...new chatAssembly.ChatAnswer(), text:'ok', outputTokens:2048})])
    assert.equal(chatAssembly.parseChatAnswer(raw), undefined);
});
test('chat cancellation stops actual HTTP and a late result cannot overwrite cancelled UI', async () => {
  const gate = deferred(); const h = chatHarness({gate}); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  await h.ui.send('question'); assert.equal(h.calls(), 1); await h.ui.cancel(); await waitChat(h.ui);
  assert.match(h.ui.snapshot().reply, /取消/); assert.equal(h.cancelled(), 1);
  const reply = h.ui.snapshot().reply; gate.resolve(response()); await new Promise(resolve=>setTimeout(resolve,5));
  assert.equal(h.ui.snapshot().reply, reply); await h.ui.stop();
});
test('chat session allows at most ten calls and never retries model failures automatically', async () => {
  const h = chatHarness(); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  for(let i=0;i<11;i++) { await h.ui.send('question'); await waitChat(h.ui); }
  assert.equal(h.calls(),10); assert.match(h.ui.snapshot().reply,/失败/); await h.ui.stop();
});
test('journal failure before dispatch prevents network and prevents success publication', async () => {
  const h = chatHarness(); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  h.journalBackend.fail = true; await h.ui.send('question'); await waitChat(h.ui);
  assert.equal(h.calls(),0); assert.match(h.ui.snapshot().reply,/失败/);
  await assert.rejects(h.ui.stop(), /SHUTDOWN_FAILED/);
  assert.equal(h.controller.lifecycleState(), ShuviRuntimeState.BLOCKED);
});
test('chat journal retains outcomes, rejects conflicting replay and validates reopened data', async () => {
  const h = chatHarness(); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  await h.ui.send('question'); await waitChat(h.ui);
  const record=JSON.parse(h.journalBackend.value.payloadJson).records[0];
  const reopened=new ChatExecutionStore(h.journalBackend.port,new AgentHostDigest()); await reopened.open();
  assert.equal((await reopened.loadCheckpoint(record.checkpoint.snapshot.taskId)).snapshot.status,contracts.AgentTaskStatus.COMPLETED);
  const binding=[record.checkpoint.snapshot.taskId,record.stepId,record.dispatchId];
  assert.equal((await reopened.recordOutcome(...binding,record.outcome,Date.now())).duplicate,true);
  assert.equal((await reopened.recordOutcome(...binding,{...record.outcome,resultJson:'{}'},Date.now())).accepted,false);
  h.journalBackend.value.payloadDigest='invalid'; await assert.rejects(new ChatExecutionStore(h.journalBackend.port,new AgentHostDigest()).open(),/INVALID/);
  await h.ui.stop();
});

test('checkpoint copies preserve nested evidence and cannot mutate the durable chat journal', async () => {
  const h = chatHarness(); await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  await h.ui.send('snapshot isolation'); await waitChat(h.ui);
  const row = JSON.parse(h.journalBackend.value.payloadJson).records[0];
  const original = await h.store().loadCheckpoint(row.checkpoint.snapshot.taskId);
  const { copyRuntimeTaskRecoveryCheckpoint } = load(path.join(services, 'ChatSnapshotCopies.ets'));
  // Exercise optional branches that the completed model-only workflow does not populate.
  original.pendingClarification = new contracts.ClarificationRequest();
  original.pendingPolicyRequest = new contracts.PolicyRequest();
  original.pendingInvocation = new contracts.ToolInvocation();
  original.activeInvocation = new contracts.ToolInvocation();
  original.planningRequest.previousWorkflow = structuredClone(original.workflow);
  original.submission.inputRefs.push(Object.assign(new contracts.TaskInputRef(), {refId: 'input-test'}));
  original.envelope.inputRefs = structuredClone(original.submission.inputRefs);
  original.submission.consentContext.grantedPolicyIds.push('test-policy');
  original.frame.constraints.push('preserve'); original.frame.capabilityCategories.push('test-capability');
  original.envelope.executionBudget.deadlineAt = '2026-10-24T00:00:00Z';
  original.workflow.steps[0].inputBindings.push(Object.assign(new contracts.WorkflowInputBinding(), {name: 'test-input'}));
  const expected = JSON.stringify(original);
  const copied = copyRuntimeTaskRecoveryCheckpoint(original);
  assert.deepEqual(JSON.parse(JSON.stringify(copied)), JSON.parse(expected), 'all persisted fields survive copying');
  function mutate(value) {
    for (const key of Object.keys(value)) {
      const item = value[key];
      if (item && typeof item === 'object') mutate(item);
      else if (typeof item === 'string') value[key] = 'changed';
      else if (typeof item === 'number') value[key] = 12345;
      else if (typeof item === 'boolean') value[key] = !item;
    }
    if (Array.isArray(value)) value.push('changed');
  }
  mutate(copied);
  assert.equal(JSON.stringify(original), expected, 'copy shares no mutable descendants');
  mutate(original);
  assert.deepEqual(JSON.parse(JSON.stringify(await h.store().loadCheckpoint(row.checkpoint.snapshot.taskId))), row.checkpoint);
  assert.deepEqual(JSON.parse(h.journalBackend.value.payloadJson).records[0], row, 'in-memory reads cannot change stored evidence');
  await h.ui.stop();
});

test('background during chat ends loading, clears input epoch and never auto-restarts', async () => {
  const gate=deferred(); const h=chatHarness({gate}); await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.send('question'); const epoch=h.ui.snapshot().clearEpoch;
  await h.controller.onBackground(); assert.equal(h.ui.snapshot().busy,false); assert(h.ui.snapshot().clearEpoch>epoch);
  assert.equal(h.cancelled(),1); h.controller.onForeground(); await h.ui.send('another'); assert.equal(h.calls(),1);
});
test('synchronous completed subscription replay is shown once and the late subscription is closed', async () => {
  const answer=JSON.stringify(Object.assign(new chatAssembly.ChatAnswer(), {text:'answer'}));
  let closed=0;
  const h=await activeController({async subscribe(id,listener) {
    listener.onEvent({taskId:id,sequence:1,eventType:contracts.AgentRuntimeEventType.TASK_COMPLETED,payloadJson:answer});
    return {close(){closed++;},isClosed(){return closed>0;}};
  }});
  const ui=new RuntimeChatSession(h.controller); await ui.send('question');
  assert.equal(ui.snapshot().reply,'answer'); assert.equal(ui.snapshot().replyId,1); assert.equal(closed,1); await ui.stop();
});
test('cancel before submit resolves stops the session and rejects late task and events', async () => {
  const gate=deferred(); const h=await activeController({submit(){return gate.promise;}});
  const ui=new RuntimeChatSession(h.controller); const sending=ui.send('question'); await ui.cancel();
  gate.resolve({taskId:'late'}); await sending;
  assert.equal(ui.snapshot().busy,false); assert.equal(h.calls.stop,1); assert.equal(h.calls.listener,undefined);
});

test('after cancellation a new question succeeds; the cancelled request never corrupts the Runtime', async () => {
  const options={gate:deferred()}; const h=chatHarness(options);
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.send('first'); await h.ui.cancel();
  const old=options.gate; options.gate=undefined;
  old.resolve(response()); await new Promise(resolve=>setTimeout(resolve,5));
  await h.ui.send('second'); await waitChat(h.ui);
  assert.equal(h.calls(),2); assert.equal(h.ui.snapshot().reply,'Test model answer'); await h.ui.stop();
});

test('persisted answer failure cannot publish success; watchdog stops the session', async () => {
  const options={gate:deferred()}; const h=chatHarness(options);
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  const original=global.setTimeout; let deadline;
  global.setTimeout=(fn,delay,...args)=>delay===45000?(deadline=fn,-1):original(fn,delay,...args);
  try { await h.ui.send('question'); } finally { global.setTimeout=original; }
  h.journalBackend.fail=true;
  options.gate.resolve({statusCode:200,body:JSON.stringify({object:'chat.completion',model:'deepseek-flash',
    choices:[{index:0,message:{role:'assistant',content:'must not display'},finish_reason:'stop'}],
    usage:{prompt_tokens:52,completion_tokens:18,total_tokens:70}})});
  await new Promise(resolve=>original(resolve,5));
  assert.equal(h.ui.snapshot().replyId,0); assert.equal(h.ui.snapshot().busy,true);
  deadline(); await new Promise(resolve=>original(resolve,5));
  assert.equal(h.ui.snapshot().busy,false); assert.doesNotMatch(h.ui.snapshot().reply,/must not display/);
  assert.equal(h.calls(),1);
});

test('journal rejects unknown schema without overwriting the stored evidence', async () => {
  const h=chatHarness(); await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.send('question'); await waitChat(h.ui); await h.ui.stop();
  h.journalBackend.value.schemaVersion='future-version'; const saved=structuredClone(h.journalBackend.value);
  await assert.rejects(new ChatExecutionStore(h.journalBackend.port,new AgentHostDigest()).open(),/INVALID/);
  assert.deepEqual(h.journalBackend.value,saved);
});

test('native chat resource uses its own encrypted database and reopens the actual RDB snapshot adapter', async () => {
  nativeModules['@ohos.data.relationalStore'].RdbPredicates=class {
    equalTo(key,value) { this[key]=value; return this; } and() { return this; }
  };
  nativeModules['@ohos.data.relationalStore'].ConflictResolution={ON_CONFLICT_IGNORE:1};
  const h=rdbHarness();
  h.handle.update=async(values,predicate)=>{
    if(!h.envelope || h.envelope.revision!==predicate.revision) return 0;
    h.envelope={revision:values.revision,schemaVersion:values.schema_version,payloadJson:values.payload_json,payloadDigest:values.payload_digest}; return 1;
  };
  h.handle.insert=async(_table,values)=>{
    if(h.envelope) return -1;
    h.envelope={revision:values.revision,schemaVersion:values.schema_version,payloadJson:values.payload_json,payloadDigest:values.payload_digest}; return 1;
  };
  const {ChatExecutionResource}=load(path.join(services,'ChatExecutionStore.ets'));
  const resource=new ChatExecutionResource(h.opener,new AgentHostDigest()); await resource.open();
  assert.equal(h.opens[0].name,'shuvi_chat_execution_v1.db'); assert.equal(h.opens[0].encrypt,true);
  const ready=chatHarness(); await ready.ui.start(ready.factory,new TextEncoder().encode('test-only-key'));
  await ready.ui.send('question'); await waitChat(ready.ui);
  // Loading validated retained evidence goes through the real RdbSnapshotBackend, not a fake success result.
  h.envelope=structuredClone(ready.journalBackend.value); await resource.close(); await resource.open();
  const row=JSON.parse(h.envelope.payloadJson).records[0];
  assert.equal((await resource.loadCheckpoint(row.checkpoint.snapshot.taskId)).snapshot.status,contracts.AgentTaskStatus.COMPLETED);
  await resource.close(); await ready.ui.stop(); assert.equal(h.closes,2);
});

// Search UX integration: actual Runtime, grant verifier, MCP adapter, durable bridge and model Provider.
// Only the device database handle, MCP network manager and model HTTP are replaced.
const searchSupport = load(path.join(services, 'SearchTaskSupport.ets'));
const { RuntimeSearchSession } = load(path.join(services, 'RuntimeSearchSession.ets'));
function writableRdb() {
  nativeModules['@ohos.data.relationalStore'].RdbPredicates = class {
    equalTo(key, value) { this[key] = value; return this; } and() { return this; }
  };
  nativeModules['@ohos.data.relationalStore'].ConflictResolution = { ON_CONFLICT_IGNORE: 1 };
  const h = rdbHarness(); h.failWrites = false;
  function row(values) { return { revision: values.revision, schemaVersion: values.schema_version,
    payloadJson: values.payload_json, payloadDigest: values.payload_digest }; }
  h.handle.update = async (values, predicate) => {
    if (h.failWrites || !h.envelope || h.envelope.revision !== predicate.revision) return 0;
    h.envelope = row(values); return 1;
  };
  h.handle.insert = async (_table, values) => {
    if (h.failWrites || h.envelope) return -1; h.envelope = row(values); return 1;
  };
  return h;
}
function liveSearchHarness(options = {}, existing) {
  const dbs = existing || { search: writableRdb(), chat: writableRdb() };
  const trace = { tools: 0, models: 0, requests: [], profiles: [], disconnects: 0 };
  const mcp = load(path.join(root, 'modules/harmony_agent/mcp_client/Index.ets'));
  const opener = { open(config) { return (config.name === 'shuvi_search_execution_v1.db' ? dbs.search : dbs.chat).opener.open(config); } };
  class Manager {
    registerServer(profile) { trace.profiles.push(profile); }
    async connect() { if (options.failConnect) throw Error('connection failure'); }
    async refreshServer() {}
    async listTools() {
      return { errors: [], items: [{ name: 'web_search', description: 'public search',
        ref: { serverId: 'shuvi-web-search', kind: mcp.McpCapabilityKind.TOOL, name: 'web_search' },
        inputSchema: { type: 'object', additionalProperties: false, required: ['query'], properties: {
          query: { type: 'string' }, maxResults: { type: 'integer', minimum: 1, maximum: 10, default: 5 } } },
        outputSchema: { type: 'object' } }] };
    }
    async callTool(_ref, args) {
      trace.tools++; trace.requests.push(structuredClone(args));
      if (options.toolGate) await options.toolGate.promise;
      if (options.failTool) throw Error('private upstream body');
      const result = usageFixture(); result.structuredContent.query = args.query;
      result.structuredContent.results = options.empty ? [] : [{ title: 'Official documentation',
        url: 'https://developer.huawei.com/consumer/cn/arkui', snippet: 'Declarative UI documentation.' }];
      if (options.badResult) result.structuredContent.query = 'mismatched';
      result.content[0].text = JSON.stringify(result.structuredContent);
      if (options.unknownUsage) delete result.raw._meta;
      return result;
    }
    async disconnectAll() { trace.disconnects++; }
    async unregisterServer() {}
  }
  class ModelClient {
    start(request) {
      trace.models++; trace.body = JSON.parse(request.body);
      if (options.modelGate) return { result: options.modelGate.promise, cancel() {} };
      return { result: Promise.resolve({ statusCode: options.modelStatus || 200, body: JSON.stringify({
        object: 'chat.completion', model: 'deepseek-flash', choices: [{ index: 0, message: { role: 'assistant',
          content: 'See the official documentation [1].' }, finish_reason: 'stop' }],
        usage: { prompt_tokens: 180, completion_tokens: 20, total_tokens: 200 } }) }), cancel() {} };
    }
  }
  const assembly = load(path.join(services, 'SearchRuntimeAssembly.ets'), {
    '@harmony_agent/mcp-client': { ...mcp, McpClientManager: Manager }
  });
  const chat = load(path.join(services, 'ChatRuntimeAssembly.ets'), { './DeepSeekHttpClient': { ArkTsDeepSeekHttpClient: ModelClient } });
  const ui = new RuntimeSearchSession(); ui.onForeground();
  const factory = new assembly.SearchRuntimeFactory(opener, true);
  const answerFactory = new chat.ChatRuntimeFactory(opener, true, ui.context);
  return { ui, factory, answerFactory, trace, dbs, assembly, async start() {
    await ui.start(factory, answerFactory, new TextEncoder().encode('test-only-key'));
    assert.equal(ui.snapshot().lifecycle, ShuviRuntimeState.READY, ui.snapshot().message);
  } };
}
async function waitSearch(ui, predicate) {
  for (let i = 0; i < 100; i++) { if (predicate(ui.snapshot())) return; await new Promise(resolve => setTimeout(resolve, 2)); }
  assert.fail('Search state did not arrive: ' + JSON.stringify(ui.snapshot()));
}
async function authorizeSearch(h) {
  assert.equal(await h.ui.send('same query'), true);
  await waitSearch(h.ui, view => view.preview !== undefined);
  assert.equal(h.trace.tools, 0); assert.equal(h.trace.models, 0);
  assert.equal(h.ui.snapshot().preview.query, 'same query');
  await h.ui.decide(true);
}
test('search UX: actual grant, one MCP call, durable pending CNY bill, then real model answer', async () => {
  const h = liveSearchHarness(); await h.start();
  try {
    assert.equal(h.trace.profiles[0].retryToolCallOnExpiredSession, false);
    await authorizeSearch(h); await waitSearch(h.ui, view => !view.busy);
    assert.equal(h.ui.snapshot().stage, 'complete', h.ui.snapshot().message);
    assert.equal(h.trace.tools, 1); assert.equal(h.trace.models, 1);
    assert.equal(h.ui.snapshot().sources.length, 1); assert.match(h.ui.snapshot().answer, /\[1\]/);
    assert.match(h.trace.body.messages[1].content, /Declarative UI/);
    assert.equal(h.trace.body.tools, undefined);
    const payload = JSON.parse(h.dbs.search.envelope.payloadJson);
    assert.equal(payload.operations.length, 1);
    assert.equal(payload.operations[0].pendingInvoice.currency, 'CNY');
    assert.equal(payload.operations[0].pendingInvoice.accountScope, 'shuvi-dev-tavily');
    assert.equal(payload.operations[0].invoice, undefined);
    assert.equal(payload.operations[0].state, invoiceCore.OperationJournalState.RESULT_RECORDED);
    assert.equal(await h.ui.send('second query'), false); assert.equal(h.trace.tools, 1);
  } finally { await h.ui.stop(); }
  const reopened = liveSearchHarness({}, h.dbs); await reopened.start();
  assert.equal(reopened.ui.snapshot().allowance, false);
  assert.equal(await reopened.ui.send('same query'), false); assert.equal(reopened.trace.tools, 0);
  await reopened.ui.stop();
});
test('search deny never calls provider and does not consume dispatch allowance', async () => {
  const h = liveSearchHarness(); await h.start();
  let denialEvidence;
  const authorize = h.ui.search.authorize.bind(h.ui.search);
  h.ui.search.authorize = async (...args) => {
    try { const receipt = await authorize(...args); denialEvidence = receipt; return receipt; }
    catch (error) { denialEvidence = String(error); throw error; }
  };
  try {
    await h.ui.send('same query'); await waitSearch(h.ui, v => !!v.preview); await h.ui.decide(false);
    await waitSearch(h.ui, v => !v.busy);
    assert.equal(h.trace.tools, 0); assert.equal(h.trace.models, 0);
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY, JSON.stringify(denialEvidence));
    assert.equal(h.ui.snapshot().stage, 'denied');
    assert.equal(h.factory.available(), true);
  } finally { await h.ui.stop(); }
});
test('expired or missing authorization preview cannot be approved', async () => {
  const h = liveSearchHarness(); await h.start();
  try {
    await h.ui.send('same query'); await waitSearch(h.ui, v => !!v.preview);
    h.factory.previews.clear(); await h.ui.decide(true);
    assert.equal(h.trace.tools, 0); assert.equal(h.ui.snapshot().busy, false);
  } finally { await h.ui.stop(); }
});
test('empty actual sources end search without calling the model, retaining unknown billing', async () => {
  const h = liveSearchHarness({ empty: true, unknownUsage: true }); await h.start();
  try {
    await authorizeSearch(h); await waitSearch(h.ui, v => !v.busy);
    assert.equal(h.ui.snapshot().stage, 'empty'); assert.equal(h.trace.models, 0);
    assert.equal(JSON.parse(h.dbs.search.envelope.payloadJson).operations[0].pendingInvoice.usageState, 'unknown');
  } finally { await h.ui.stop(); }
});
test('model failure retains real sources; explicit retry answers without another search', async () => {
  const options = { modelStatus: 401 }; const h = liveSearchHarness(options); await h.start();
  try {
    await authorizeSearch(h); await waitSearch(h.ui, v => !v.busy);
    assert.equal(h.ui.snapshot().stage, 'answerFailed'); assert.equal(h.ui.snapshot().sources.length, 1);
    options.modelStatus = 200; await h.ui.retryAnswer(); await waitSearch(h.ui, v => !v.busy);
    assert.equal(h.ui.snapshot().stage, 'complete'); assert.equal(h.trace.tools, 1); assert.equal(h.trace.models, 2);
  } finally { await h.ui.stop(); }
});
test('background stops search, discards late results and keeps persistent trial occupied', async () => {
  const gate = deferred(); const h = liveSearchHarness({ toolGate: gate }); await h.start();
  await authorizeSearch(h); await waitSearch(h.ui, () => h.trace.tools === 1);
  await h.ui.onBackground(); gate.resolve(); await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(h.ui.snapshot().sources.length, 0); assert.equal(h.trace.models, 0);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.STOPPED);
  h.ui.onForeground(); assert.equal(h.trace.tools, 1);
  const reopen = liveSearchHarness({}, h.dbs); await reopen.start(); assert.equal(reopen.ui.snapshot().allowance, false); await reopen.ui.stop();
});
test('bad result never becomes a source or answer; no automatic network retry', async () => {
  const h = liveSearchHarness({ badResult: true }); await h.start();
  try {
    await authorizeSearch(h); await waitSearch(h.ui, () => h.trace.tools === 1);
    await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(h.ui.snapshot().sources.length, 0); assert.equal(h.trace.models, 0);
    assert.equal(h.ui.snapshot().allowance, false);
    assert.equal(h.ui.snapshot().busy, false);
    assert.equal(h.ui.snapshot().stage, 'failed');
  } finally { await h.ui.stop(); }
});
test('dispatch persistence failure prevents provider call', async () => {
  const h = liveSearchHarness(); await h.start();
  try {
    await h.ui.send('same query'); await waitSearch(h.ui, v => !!v.preview);
    h.dbs.search.failWrites = true; await h.ui.decide(true);
    assert.equal(h.trace.tools, 0); assert.equal(h.trace.models, 0);
  } finally { h.dbs.search.failWrites = false; await h.ui.stop(); }
});
test('search URL and model context reject unsafe sources and mismatched questions', () => {
  for (const url of ['file:///etc/passwd', 'https://user:pass@example.com/', 'http://127.0.0.1/', 'http://[::1]/',
    'https://example.com@evil.com/', 'https://example.com\\@evil.com/', 'https://host.local/']) {
    assert.equal(searchSupport.safeSearchUrl(url), false, url);
  }
  assert.equal(searchSupport.safeSearchUrl('https://developer.huawei.com/consumer/cn/arkui'), true);
  const context = new searchSupport.SearchAnswerContext();
  assert.equal(context.promptFor('question'), undefined);
  const result = usageFixture().structuredContent; result.results = [{title:'title',url:'https://example.com/page',snippet:'untrusted data'}];
  assert.equal(context.set(JSON.stringify(result), 'same query'), true);
  assert.equal(context.promptFor('different query'), undefined); assert.match(context.promptFor('same query'), /untrusted data/);
  context.clear(); assert.equal(context.promptFor('same query'), undefined);
  assert.equal(searchSupport.validSearchCitations('answer [1]', 1), true);
  assert.equal(searchSupport.validSearchCitations('answer [2]', 1), false);
  assert.equal(searchSupport.validSearchCitations('answer without sources', 1), false);
});

test('concurrent approval clicks cannot dispatch a second billed request', async () => {
  const h = liveSearchHarness(); await h.start();
  try {
    await h.ui.send('same query'); await waitSearch(h.ui, v => !!v.preview);
    await Promise.all([h.ui.decide(true), h.ui.decide(true), h.ui.decide(true)]);
    await waitSearch(h.ui, v => !v.busy); assert.equal(h.trace.tools, 1); assert.equal(h.trace.models, 1);
  } finally { await h.ui.stop(); }
});
test('cancel before approval performs no network search and keeps allowance after reopen', async () => {
  const h = liveSearchHarness(); await h.start();
  await h.ui.send('same query'); await waitSearch(h.ui, v => !!v.preview); await h.ui.stop();
  assert.equal(h.trace.tools, 0); assert.equal(h.trace.models, 0);
  const reopened = liveSearchHarness({}, h.dbs); await reopened.start();
  assert.equal(reopened.ui.snapshot().allowance, true); await reopened.ui.stop();
});
test('tool failure ends waiting promptly without fake success, free settlement or retry', async () => {
  const h = liveSearchHarness({ failTool: true }); await h.start();
  await authorizeSearch(h); await waitSearch(h.ui, v => v.lifecycle === ShuviRuntimeState.STOPPED);
  assert.equal(h.ui.snapshot().stage, 'failed'); assert.equal(h.ui.snapshot().sources.length, 0);
  assert.equal(h.trace.tools, 1); assert.equal(h.trace.models, 0);
  const operation = JSON.parse(h.dbs.search.envelope.payloadJson).operations[0];
  assert.equal(operation.invoice, undefined); assert.equal(operation.pendingInvoice, undefined);
  const reopened = liveSearchHarness({}, h.dbs); await reopened.start();
  assert.equal(reopened.ui.snapshot().allowance, false); await reopened.ui.stop();
});
test('search result write failure exposes neither source nor answer and retains dispatch evidence', async () => {
  const gate = deferred(); const h = liveSearchHarness({ toolGate: gate }); await h.start();
  await authorizeSearch(h); await waitSearch(h.ui, () => h.trace.tools === 1);
  h.dbs.search.failWrites = true; gate.resolve(); await waitSearch(h.ui, v => v.lifecycle === ShuviRuntimeState.STOPPED);
  assert.equal(h.ui.snapshot().sources.length, 0); assert.equal(h.trace.models, 0);
  h.dbs.search.failWrites = false;
  const reopened = liveSearchHarness({}, h.dbs); await reopened.start();
  assert.equal(reopened.ui.snapshot().allowance, false); await reopened.ui.stop();
});
test('search quota is enforced before dispatch even when two tasks already awaited consent', async () => {
  const h = liveSearchHarness(); const session = h.factory.create(); await session.start(new TextEncoder().encode('test-only-key'));
  const prompts = [];
  try {
    for (let i = 0; i < 2; i++) {
      const handle = await session.submit({ intent: 'same query' });
      await session.subscribe(handle.taskId, { onEvent() {}, onClarificationRequired() {}, onAuthorizationRequired(p) { prompts.push(p); } }, 0);
    }
    assert.equal(prompts.length, 2);
    await session.authorize(prompts[0], true);
    for (let i = 0; i < 100 && h.trace.tools === 0; i++) await new Promise(r => setTimeout(r, 2));
    try { await session.authorize(prompts[1], true); } catch { /* Durable allowance rejects the queued task. */ }
    assert.equal(h.trace.tools, 1);
  } finally { await session.stop(); }
});


for (const kind of ['execution', 'memory']) {
  test(`RDB ${kind} insert is awaited and its rejection is propagated`, async () => {
    nativeModules['@ohos.data.relationalStore'].RdbPredicates = class {
      equalTo() { return this; } and() { return this; }
    };
    nativeModules['@ohos.data.relationalStore'].ConflictResolution = {ON_CONFLICT_IGNORE: 1};
    const file = kind === 'execution' ? 'storage/RdbSnapshotBackend.ets' : 'memory/RdbMemorySnapshotBackend.ets';
    const name = kind === 'execution' ? 'RdbSnapshotBackend' : 'RdbMemorySnapshotBackend';
    const Backend = load(path.join(root, 'modules/harmony_agent/agent_storage/src/main/ets', file))[name];
    const envelope = {revision: 1, schemaVersion: 'test', payloadJson: '{}', payloadDigest: 'test-digest'};
    for (const failing of [false, true]) {
      let resolveInsert, rejectInsert, settled = false, calls = 0;
      const pending = new Promise((resolve, reject) => { resolveInsert = resolve; rejectInsert = reject; });
      const backend = new Backend({update: async () => 0, insert: () => { calls++; return pending; }});
      const operation = backend.compareAndSet(0, envelope);
      const observed = operation.then(value => { settled = true; return value; }, error => { settled = true; throw error; });
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(calls, 1); assert.equal(settled, false, 'CAS must not finish before the native insert');
      if (failing) {
        const rejection = assert.rejects(observed, /injected-write-failure/);
        rejectInsert(new Error('injected-write-failure')); await rejection;
      } else { resolveInsert(1); assert.equal(await observed, true); }
    }
  });
}

function calendarModelReply(change = {}) {
  return JSON.stringify({schemaVersion:'1.0', kind:'draft', draft: {
    title:'项目讨论', startAt:'2099-10-27T15:00:00+08:00', endAt:'2099-10-27T16:00:00+08:00',
    timeZone:'Asia/Shanghai', reminderMinutes:10, ...change
  }});
}
test('calendar proposal rejects untrusted, missing, rolled-over, stale and out-of-scope fields', () => {
  const parse = raw => calendarContract.parseCalendarProposal(raw, Date.parse('2026-10-26T10:00:00+08:00'));
  assert.equal(parse(calendarModelReply()).draft.title, '项目讨论');
  for (const raw of ['null', '[]', '{}', '```json\n'+calendarModelReply()+'\n```',
    calendarModelReply({timeZone:'UTC'}), calendarModelReply({startAt:'2099-02-30T15:00:00+08:00'}),
    calendarModelReply({reminderMinutes:undefined}), calendarModelReply({title:''}),
    calendarModelReply({reminderMinutes:'10'}), calendarModelReply({repeat:'daily'}),
    calendarModelReply({startAt:'2026-10-26T10:05:00+08:00'}),
    calendarModelReply({endAt:'2099-10-27T14:00:00+08:00'})]) assert.equal(parse(raw).draft, undefined, raw);
  const clarify = JSON.stringify({schemaVersion:'1.0', kind:'clarify', message:'请补充结束时间'});
  assert.match(parse(clarify).message, /需要补充/); assert.equal(parse(clarify).draft, undefined);
  assert.equal(parse(JSON.stringify({...JSON.parse(clarify), draft:JSON.parse(calendarModelReply()).draft})).draft, undefined);
});
test('calendar context binds exact approved description and reference time without history', () => {
  const context = new calendarContract.CalendarDraftContext();
  assert.equal(context.promptFor('明天开会'), undefined);
  context.bind('明天开会', Date.parse('2026-10-26T23:58:00+08:00'));
  assert.match(context.promptFor('明天开会'), /2026-10-26T23:58:00\+08:00/);
  assert.equal(context.promptFor('更改描述'), undefined);
  context.clear(); assert.equal(context.promptFor('明天开会'), undefined);
});
test('calendar Runtime requires per-request approval and PERSONAL scope, returns only a proposal', async () => {
  const h = chatHarness({calendar:true, text:calendarModelReply()});
  await h.ui.generate('安排项目讨论', true); assert.equal(h.calls(), 0);
  await h.ui.start(h.factory, new TextEncoder().encode('test-only-key'));
  await h.ui.generate('安排项目讨论', false); assert.equal(h.calls(), 0);
  await h.ui.generate('安排项目讨论', true); await waitChat(h.ui);
  assert.equal(h.calls(), 1); assert.equal(h.proposals.length, 1);
  assert.equal(h.proposals[0].title, '项目讨论');
  const record = JSON.parse(h.journalBackend.value.payloadJson).records[0];
  assert.equal(record.checkpoint.envelope.privacyClass, contracts.PrivacyClass.PERSONAL);
  assert.equal(record.checkpoint.workflow.steps[0].kind, contracts.WorkflowStepKind.LLM);
  assert.match(h.requests[0].messages[0].content, /不能臆造/);
  assert.match(h.requests[0].messages[1].content, /参考当前时间/);
  assert.equal(h.requests[0].tools, undefined);
  assert.equal(h.ui.context.promptFor('安排项目讨论'), undefined);
  assert.equal(chatAssembly.chatFrontendConfig().privacyClass, contracts.PrivacyClass.PUBLIC);
  assert.throws(() => new chatAssembly.ChatRuntimeFactory({},true,undefined,chatAssembly.ChatPurpose.CALENDAR_DRAFT).create(), /CONTEXT_REQUIRED/);
  await h.ui.stop();
});
test('calendar model clarification, failed request and malformed result never publish a draft', async () => {
  for (const opts of [{text:JSON.stringify({schemaVersion:'1.0',kind:'clarify',message:'何时结束？'})},
    {status:401}, {text:'已创建日程'}, {text:calendarModelReply({reminderMinutes:undefined})}, {finish:'length'}]) {
    const h = chatHarness({calendar:true,...opts});
    await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
    await h.ui.generate('明天开会',true); await waitChat(h.ui);
    assert.equal(h.calls(),1); assert.equal(h.proposals.length,0);
    assert.notEqual(h.ui.snapshot().message,''); await h.ui.stop();
  }
});
test('calendar stop, background and detach revoke draft delivery even when HTTP resolves late', async () => {
  for (const action of ['stop','background','detach']) {
    const gate=deferred(); const h=chatHarness({calendar:true,gate});
    await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
    await h.ui.generate('安排项目讨论',true); assert.equal(h.calls(),1);
    if(action==='stop') await h.ui.stop();
    else if(action==='background') await h.controller.onBackground();
    else { h.ui.detach(); await h.controller.stop(); }
    gate.resolve(response({model:'deepseek-flash',choices:[{index:0,message:{role:'assistant',content:calendarModelReply()},finish_reason:'stop'}]}));
    await new Promise(resolve=>setTimeout(resolve,10));
    assert.equal(h.proposals.length,0); assert.equal(h.ui.snapshot().busy,false); assert.equal(h.cancelled(),1);
  }
});
test('calendar storage failure blocks request; separate database is encrypted', async () => {
  const h=chatHarness({calendar:true,text:calendarModelReply()});
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key')); h.journalBackend.fail=true;
  await h.ui.generate('安排项目讨论',true); await waitChat(h.ui);
  assert.equal(h.calls(),0); assert.equal(h.proposals.length,0);
  await assert.rejects(h.ui.stop(),/SHUTDOWN_FAILED/);
  const db=writableRdb();
  const {ChatExecutionResource}=load(path.join(services,'ChatExecutionStore.ets'));
  const resource=new ChatExecutionResource(db.opener,new AgentHostDigest(),true); await resource.open();
  assert.equal(db.opens[0].name,'shuvi_calendar_draft_execution_v1.db'); assert.equal(db.opens[0].encrypt,true);
  await resource.close();
});
test('calendar Runtime proposal cannot write until separate user confirmation and native permission', async () => {
  const {CalendarProbeSession} = load(path.join(services,'../calendar/CalendarProbeSession.ets'));
  for (const action of ['confirm','cancel','deny']) {
    let writes=0; let authorizations=0; let view;
    const records=[];
    const port={async authorize(){authorizations++; if(action==='deny') throw new Error('permission denied');},
      async prepare(){},async add(){writes++;return 42;},
      async read(){return {eventId:42,matches:true,reminderConfigured:true};}};
    const store={async load(){return records[0];},async list(){return records;},async save(record){
      const idx=records.findIndex(item=>item.operationId===record.operationId);
      if(idx<0) records.push(structuredClone(record)); else records[idx]=structuredClone(record);
    }};
    const calendar=new CalendarProbeSession(port,store,()=> 'shuvi-calendar-test-draft',Date.now);
    calendar.attach(next=>{view=next;}); await new Promise(resolve=>setImmediate(resolve));
    const h=chatHarness({calendar:true,text:calendarModelReply()});
    h.ui.attach(()=>{},draft=>calendar.preview(draft));
    await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
    await h.ui.generate('2099年10月27日15点到16点项目讨论，提前10分钟提醒',true); await waitChat(h.ui);
    assert.equal(view.phase,'confirm'); assert.equal(writes,0); assert.equal(authorizations,0);
    await h.ui.stop();
    if(action==='cancel') calendar.cancelDraft();
    await calendar.confirm();
    assert.equal(writes,action==='confirm'?1:0);
    assert.equal(authorizations,action==='cancel'?0:1);
    if(action==='confirm') { assert.equal(view.eventId,42); assert.equal(view.records[0].verified,true); }
    calendar.detach();
  }
});
test('calendar confirmation and new-draft panel changes reuse the enabled session without another key', async () => {
  const h=chatHarness({calendar:true,text:calendarModelReply()});
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.generate('第一条日程',true); await waitChat(h.ui);
  assert.equal(h.proposals.length,1);
  h.ui.detachView(); // Confirmation, result/history, then new draft on the same page.
  assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY); assert.equal(h.closed(),0);
  h.ui.attach(()=>{},draft=>h.proposals.push(draft));
  await h.ui.generate('第二条日程',true); await waitChat(h.ui);
  assert.equal(h.calls(),2); assert.equal(h.proposals.length,2); assert.equal(h.closed(),0);
  h.ui.detach(); await h.controller.stop(); // Actual calendar page exit owns cleanup.
  assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.STOPPED); assert.equal(h.closed(),1);
  await h.ui.generate('离页后不能发送',true); assert.equal(h.calls(),2);
});
test('calendar cancellation revokes the current proposal while preserving the session for another request', async () => {
  const gate=deferred(); const h=chatHarness({calendar:true,gate});
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.generate('取消这一条',true); await h.ui.cancel();
  assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY); assert.equal(h.closed(),0);
  assert.equal(h.ui.snapshot().busy,false); assert.equal(h.proposals.length,0);
  gate.resolve(response({model:'deepseek-flash',choices:[{index:0,message:{role:'assistant',content:calendarModelReply()},finish_reason:'stop'}]}));
  await new Promise(resolve=>setTimeout(resolve,10)); assert.equal(h.proposals.length,0);
  await h.ui.generate('重新描述另一条',true); await waitChat(h.ui);
  assert.equal(h.calls(),2); assert.equal(h.proposals.length,1); await h.ui.stop();
});
test('removing a busy calendar draft panel still stops the unfinished request', async () => {
  const gate=deferred(); const h=chatHarness({calendar:true,gate});
  await h.ui.start(h.factory,new TextEncoder().encode('test-only-key'));
  await h.ui.generate('未完成的描述',true); h.ui.detachView(); await h.controller.stop();
  assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.STOPPED);
  assert.equal(h.cancelled(),1); assert.equal(h.proposals.length,0); assert.equal(h.closed(),1);
});

function assistantHarness(options = {}) {
  const h = chatHarness({assistant:true, text:calendarModelReply(), ...options});
  const db = options.db || writableRdb(); const records = options.records || [];
  const trace = {permissions:0, writes:0, reads:0};
  const {CalendarProbeSession} = load(path.join(services,'../calendar/CalendarProbeSession.ets'));
  const probe = new CalendarProbeSession({
    async authorize() { trace.permissions++; if(options.deny) throw Error('permission denied'); if(options.permissionGate) await options.permissionGate.promise; },
    async prepare() {},
    async add(record) { trace.writes++; if(options.writeGate) await options.writeGate.promise; return records.length + 100; },
    async read(record) { trace.reads++; return {eventId:record.eventId,matches:!options.mismatch,reminderConfigured:true}; }
  }, {
    async load(){return records.at(-1);}, async list(){return structuredClone(records);},
    async save(record){ const idx = records.findIndex(item=>item.operationId===record.operationId);
      if(idx<0) records.push(structuredClone(record)); else records[idx]=structuredClone(record); }
  }, ()=>'shuvi-calendar-must-use-runtime-id', Date.now);
  const {CalendarRuntimeFactory} = load(path.join(services,'../calendar/CalendarRuntimeAssembly.ets'));
  const factory = new CalendarRuntimeFactory(db.opener, {
    create(draft,id,cancelled){return probe.executeAuthorized(draft,id,cancelled);}, cancel(){probe.stop();}
  }, true);
  h.ui.calendar.onForeground();
  return {...h, db, records, trace, probe, calendarFactory:factory,
    async start(){await h.ui.start(h.factory,factory,new TextEncoder().encode('test-only-key'));}};
}
async function waitCalendarCard(ui) {
  for(let i=0;i<200 && ui.snapshot().busy && !ui.snapshot().preview;i++) await new Promise(resolve=>setTimeout(resolve,2));
  assert.equal(ui.snapshot().calendarStage,'authorization',JSON.stringify(ui.snapshot()));
}

test('assistant uses real Runtime policy/grant and native tool; confirmation writes once and returns verified result', async () => {
  const h=assistantHarness(); await h.start();
  try {
    assert.equal(h.ui.snapshot().lifecycle,ShuviRuntimeState.READY);
    await h.ui.send('2099年10月27日15到16点项目讨论，提前10分钟提醒');
    await waitCalendarCard(h.ui);
    assert.equal(h.trace.writes,0); assert.equal(h.trace.permissions,0);
    const preview=h.ui.snapshot().preview; assert.equal(preview.draft.title,'项目讨论');
    await Promise.all([h.ui.decide(true),h.ui.decide(true)]); await waitChat(h.ui);
    assert.equal(h.trace.writes,1); assert.equal(h.trace.reads,1); assert.equal(h.ui.snapshot().succeeded,true);
    assert.match(h.ui.snapshot().reply,/已创建日程并读回核对/);
    assert.equal(h.records[0].operationId,preview.operationId); assert.equal(h.records[0].verified,true);
    const stored=JSON.stringify(JSON.parse(h.db.envelope.payloadJson));
    assert(stored.includes(preview.operationId)); assert(stored.includes('shuvi.calendar.create'));
    assert.equal(h.db.opens[0].encrypt,true); assert.equal(h.db.opens[0].name,'shuvi_calendar_runtime_v1.db');
  } finally { await h.ui.stop(); }
});

test('assistant normal answers, clarification and malformed replies never create tools; session is reused', async () => {
  const texts=[JSON.stringify({schemaVersion:'1.0',kind:'answer',message:'普通回答'}),
    JSON.stringify({schemaVersion:'1.0',kind:'clarify',message:'何时结束？'}),calendarModelReply(), '已创建日程'];
  const h=assistantHarness({texts}); await h.start();
  try {
    await h.ui.send('解释日历'); await waitChat(h.ui); assert.equal(h.ui.snapshot().reply,'普通回答');
    assert.equal(h.trace.writes,0); assert.equal(h.db.envelope,undefined);
    await h.ui.send('2099年10月27日下午3点项目讨论，提前10分钟提醒'); await waitChat(h.ui);
    assert.equal(h.ui.snapshot().reply,'何时结束？');
    await h.ui.send('4点结束'); await waitCalendarCard(h.ui);
    assert.match(h.requests[2].messages[1].content,/2099年10月27日/);
    await h.ui.decide(false); await waitChat(h.ui); assert.equal(h.trace.permissions,0);
    await h.ui.send('再次试试'); await waitChat(h.ui); assert.match(h.ui.snapshot().reply,/格式未通过/);
    assert.equal(h.calls(),4); assert.equal(h.closed(),0); assert.equal(h.trace.writes,0);
  } finally {await h.ui.stop();}
});

test('assistant denial and cancellation preserve enabled model session; another calendar needs fresh confirmation', async () => {
  const h=assistantHarness({texts:[calendarModelReply(),calendarModelReply({title:'另一条日程'})]}); await h.start();
  try {
    await h.ui.send('第一条'); await waitCalendarCard(h.ui); const first=h.ui.snapshot().preview;
    await h.ui.decide(false); await waitChat(h.ui); assert.equal(h.trace.writes,0);
    assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY);
    await h.ui.send('另一条'); await waitCalendarCard(h.ui);
    assert.notEqual(h.ui.snapshot().preview.operationId,first.operationId);
    await h.ui.decide(true); await waitChat(h.ui);
    assert.equal(h.trace.writes,1); assert.equal(h.calls(),2); assert.equal(h.closed(),0);
  } finally {await h.ui.stop();}
});

test('assistant system permission refusal and mismatched readback never claim successful calendar creation', async () => {
  for(const options of [{deny:true},{mismatch:true}]) {
    const h=assistantHarness(options); await h.start();
    try {
      await h.ui.send('日程安排'); await waitCalendarCard(h.ui); await h.ui.decide(true); await waitChat(h.ui);
      assert.equal(h.ui.snapshot().succeeded,false); assert.equal(h.trace.writes,options.deny?0:1);
      if(options.mismatch) assert.equal(h.records[0].verified,false);
    } finally {await h.ui.stop();}
  }
});

test('assistant cancellation during permission wait prevents native write and ignores late completion', async () => {
  const gate=deferred(); const h=assistantHarness({permissionGate:gate}); await h.start();
  try {
    await h.ui.send('日程安排'); await waitCalendarCard(h.ui); await h.ui.decide(true);
    for(let i=0;i<100 && !h.trace.permissions;i++) await new Promise(r=>setTimeout(r,1));
    await h.ui.cancel(); const reply=h.ui.snapshot().reply;
    gate.resolve(); await new Promise(r=>setTimeout(r,10));
    assert.equal(h.trace.writes,0); assert.equal(h.ui.snapshot().reply,reply);
    assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY);
  } finally {gate.resolve();await h.ui.stop();}
});

test('assistant lost UI after native write retains late event id and never repeats creation after restart', async () => {
  const gate=deferred(); const h=assistantHarness({writeGate:gate}); await h.start();
  await h.ui.send('日程安排'); await waitCalendarCard(h.ui); await h.ui.decide(true);
  for(let i=0;i<100 && !h.trace.writes;i++) await new Promise(r=>setTimeout(r,1));
  assert.equal(h.trace.writes,1); await h.ui.stop(); gate.resolve(); await new Promise(r=>setTimeout(r,10));
  assert(h.records[0].eventId>0); assert.equal(h.records[0].verified,false);
  const next=assistantHarness({db:h.db,records:h.records}); await next.start();
  try {
    await next.ui.send('相同日程'); await waitCalendarCard(next.ui); await next.ui.decide(true); await waitChat(next.ui);
    assert.equal(next.trace.writes,0); assert.equal(next.ui.snapshot().succeeded,false);
  } finally {await next.ui.stop();}
});

test('assistant journal failure blocks tools before calendar permission and write', async () => {
  const h=assistantHarness(); await h.start(); h.db.failWrites=true;
  await h.ui.send('日程安排'); await waitChat(h.ui);
  assert.equal(h.trace.permissions,0); assert.equal(h.trace.writes,0); assert.equal(h.ui.snapshot().succeeded,false);
  await h.ui.stop();
});

test('native calendar verifier rejects altered and expired grants and consumes the valid invocation only once', async () => {
  const {CalendarExecutionResource}=load(path.join(services,'../calendar/CalendarExecutionResource.ets'));
  const original=CalendarExecutionResource.prototype.verify; let checked=0;
  CalendarExecutionResource.prototype.verify=function(invocation) {
    for(const delta of [{authorizationGrantId:'forged'},{operationId:'shuvi-calendar-other'},
      {argumentsDigest:'changed'},{schemaDigest:'changed'},{toolIdentityVersion:'2'},{taskId:'other'}]) {
      assert.equal(original.call(this,{...invocation,...delta}),false);
    }
    const clock=Date.now;
    try {Date.now=()=>clock()+120000;assert.equal(original.call(this,invocation),false);} finally {Date.now=clock;}
    assert.equal(original.call(this,invocation),true);
    assert.equal(original.call(this,invocation),false);checked++;return true;
  };
  const h=assistantHarness();
  try {
    await h.start();await h.ui.send('完整日程');await waitCalendarCard(h.ui);await h.ui.decide(true);await waitChat(h.ui);
    assert.equal(checked,1);assert.equal(h.trace.writes,1);assert.equal(h.ui.snapshot().succeeded,true);
  } finally {CalendarExecutionResource.prototype.verify=original;await h.ui.stop();}
});

test('calendar confirmation snapshot cannot mutate the authorized draft; duplicate request is not written again', async () => {
  const h=assistantHarness();await h.start();
  try {
    await h.ui.send('完整日程');await waitCalendarCard(h.ui);
    const snapshot=h.ui.snapshot();snapshot.preview.draft.title='篡改标题';snapshot.preview.operationId='shuvi-calendar-forged';
    await h.ui.decide(true);await waitChat(h.ui);assert.equal(h.records[0].draft.title,'项目讨论');
    await h.ui.send('同一日程');await waitCalendarCard(h.ui);await h.ui.decide(true);await waitChat(h.ui);
    assert.equal(h.trace.writes,1);assert.equal(h.ui.snapshot().succeeded,false);assert.match(h.ui.snapshot().reply,/已有同标题/);
  } finally {await h.ui.stop();}
});

test('expired calendar confirmation cannot dispatch a tool, and new conversation forgets clarification context', async () => {
  const h=assistantHarness({texts:[JSON.stringify({schemaVersion:'1.0',kind:'clarify',message:'补充结束时间'}),calendarModelReply()]});
  await h.start();
  try {
    await h.ui.send('待澄清的日程');await waitChat(h.ui);h.ui.clearConversation();
    await h.ui.send('新的完整安排');await waitCalendarCard(h.ui);
    assert(!h.requests[1].messages[1].content.includes('待澄清的日程'));
    const clock=Date.now;
    try {Date.now=()=>clock()+130000;await h.ui.decide(true);} finally {Date.now=clock;}
    assert.equal(h.trace.permissions,0);assert.equal(h.trace.writes,0);assert.equal(h.ui.snapshot().busy,false);
  } finally {await h.ui.stop();}
});

test('assistant cancelling model generation does not prompt for another key and discards a late draft', async () => {
  const gate=deferred();const h=assistantHarness({gate});await h.start();
  try {
    await h.ui.send('停止生成');await h.ui.cancel();assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY);
    gate.resolve(response({model:'deepseek-flash',choices:[{index:0,message:{role:'assistant',content:calendarModelReply()},finish_reason:'stop'}]}));
    await new Promise(r=>setTimeout(r,10));assert.equal(h.ui.snapshot().preview,undefined);assert.equal(h.trace.writes,0);
    await h.ui.send('重新安排');await waitCalendarCard(h.ui);assert.equal(h.calls(),2);assert.equal(h.closed(),0);
  } finally {await h.ui.stop();}
});

test('assistant malformed model drafts and provider failures are terminal without native permission requests', async () => {
  for(const opts of [{text:calendarModelReply({reminderMinutes:'10'})},{text:calendarModelReply({timeZone:'UTC'})},
    {text:calendarModelReply({startAt:'2099-02-30T15:00:00+08:00'})},{status:401},{finish:'length'}]) {
    const h=assistantHarness(opts);await h.start();
    try {await h.ui.send('日程');await waitChat(h.ui);assert.equal(h.trace.permissions,0);assert.equal(h.trace.writes,0);assert.equal(h.ui.snapshot().succeeded,false);}
    finally {await h.ui.stop();}
  }
});

test('return to edit declines the old Runtime policy, restores absolute schedule text and requires a fresh confirmation', async () => {
  const h=assistantHarness({texts:[calendarModelReply(),calendarModelReply({title:'修改后的讨论',reminderMinutes:20})]});await h.start();
  try {
    await h.ui.send('安排讨论');await waitCalendarCard(h.ui);const oldPreview=h.ui.snapshot().preview;
    const text=await h.ui.revise();
    assert.match(text,/项目讨论/);assert.match(text,/2099-10-27 15:00/);assert.match(text,/2099-10-27 16:00/);assert.match(text,/提前 10 分钟/);
    assert.equal(h.ui.snapshot().busy,false);assert.match(h.ui.snapshot().reply,/原草稿已撤销/);
    assert.equal(h.trace.permissions,0);assert.equal(h.trace.writes,0);assert.equal(h.calls(),1);assert.equal(h.closed(),0);
    assert.equal(h.controller.lifecycleState(),ShuviRuntimeState.READY);
    assert.equal(await h.ui.decide(true),false);assert.equal(h.trace.writes,0);
    await h.ui.send(text.replace('项目讨论','修改后的讨论').replace('10 分钟','20 分钟'));await waitCalendarCard(h.ui);
    assert.notEqual(h.ui.snapshot().preview.operationId,oldPreview.operationId);
    assert.equal(h.ui.snapshot().preview.draft.reminderMinutes,20);assert.equal(h.trace.writes,0);
    await h.ui.decide(true);await waitChat(h.ui);
    assert.equal(h.trace.writes,1);assert.equal(h.records[0].draft.title,'修改后的讨论');assert.equal(h.calls(),2);
  } finally {await h.ui.stop();}
});

test('return to edit cannot race confirmation or repeat dismissal', async () => {
  const h=assistantHarness();await h.start();
  try {
    await h.ui.send('安排讨论');await waitCalendarCard(h.ui);
    const [text,second,confirmed]=await Promise.all([h.ui.revise(),h.ui.revise(),h.ui.decide(true)]);
    assert.equal(typeof text,'string');assert.equal(second,undefined);assert.equal(confirmed,false);assert.equal(h.trace.writes,0);
    assert.equal(await h.ui.revise(),undefined);
  } finally {await h.ui.stop();}
});

test('edit is unavailable after write dispatch and concurrent stop waits for actual model cleanup', async () => {
  const gate=deferred();const h=assistantHarness({writeGate:gate});await h.start();
  try {
    await h.ui.send('安排讨论');await waitCalendarCard(h.ui);await h.ui.decide(true);
    assert.equal(await h.ui.revise(),undefined);
    const closeGate=deferred();const originalStop=h.ui.calendar.stop.bind(h.ui.calendar);
    h.ui.calendar.stop=async()=>{await closeGate.promise;return originalStop();};
    const first=h.ui.stop();let secondDone=false;const second=h.ui.stop().then(()=>{secondDone=true;});
    await new Promise(r=>setTimeout(r,5));assert.equal(secondDone,false);assert.equal(h.ui.snapshot().lifecycle,ShuviRuntimeState.STOPPING);
    assert.doesNotMatch(h.ui.snapshot().message,/已就绪/);assert.equal(h.closed(),0);
    closeGate.resolve();await Promise.all([first,second]);assert.equal(h.closed(),1);assert.equal(h.ui.snapshot().lifecycle,ShuviRuntimeState.STOPPED);
    assert.doesNotMatch(h.ui.snapshot().message,/已就绪/);
  } finally {gate.resolve();await h.ui.stop();}
});
