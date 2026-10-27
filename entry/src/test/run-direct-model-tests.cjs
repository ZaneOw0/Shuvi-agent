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
  '@ohos.util': { TextEncoder: Encoder, TextDecoder: Decoder, generateRandomUUID: () => crypto.randomUUID(),
    Type: { BASIC: 0 }, Base64Helper: class {
      async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); }
    } },
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
      assert.equal(body.messages.length, 2); assert.equal(body.max_tokens, 1024); assert.equal(body.tools, undefined);
      const result = options.gate ? options.gate.promise : Promise.resolve({ statusCode: options.status || 200,
        body: JSON.stringify({ object: 'chat.completion', model: 'deepseek-flash', choices: [{index: 0,
          message: {role: 'assistant', content: options.text || 'Test model answer'}, finish_reason: options.finish || 'stop'}],
          usage: {prompt_tokens: 52, completion_tokens: 18, total_tokens: 70} }) });
      return {result, cancel() { modelCancelled++; }};
    }
  }
  const assembly = load(path.join(services, 'ChatRuntimeAssembly.ets'), {
    './ChatExecutionStore': { ChatExecutionResource: Resource },
    './DeepSeekHttpClient': { ArkTsDeepSeekHttpClient: Client }
  });
  const controller = new ShuviRuntimeController(); controller.onForeground();
  const ui = new RuntimeChatSession(controller);
  return {ui, controller, journalBackend, factory: new assembly.ChatRuntimeFactory({}, true),
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

// Knowledge UX integration: actual Runtime, durable zero-cost grant verifier, local retrieval and PERSONAL answer.
const knowledgeSupport = load(path.join(services, 'KnowledgeTaskSupport.ets'));
const knowledgeAnswerSupport = load(path.join(services, 'KnowledgeAnswerTaskSupport.ets'));
const { KnowledgeAnswerExecutionStore, KnowledgeAnswerExecutionResource } = load(path.join(services, 'KnowledgeAnswerExecutionStore.ets'));
const { RuntimeKnowledgeSession } = load(path.join(services, 'RuntimeKnowledgeSession.ets'));
function knowledgeJournalBackend() {
  const h = { value: undefined, fail: false };
  h.port = { async initialize() {}, async load() { return h.value; }, async compareAndSet(rev, next) {
    if (h.fail || rev !== (h.value?.revision || 0)) return false;
    h.value = structuredClone(next); return true;
  } }; return h;
}
function knowledgeModelResponse(text, status = 200) {
  if (status !== 200) return { statusCode: status, body: JSON.stringify({ error: { message: 'private provider body' } }) };
  return { statusCode: 200, body: JSON.stringify({ object: 'chat.completion', model: 'deepseek-flash',
    choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } }) };
}
function knowledgeCitation(id = 1, excerpt = '本机知识库片段说明 Runtime 采用持久化执行记录。') {
  return { citationId: id, evidenceId: 'internal-evidence-' + id, documentId: 'upd-internal-document',
    generation: 'generation-internal-' + id, title: '本机笔记 ' + id, excerpt, kind: 'Text', evidence: 'BodyDirect' };
}
function knowledgeCitations(options = {}) {
  if (options.empty) return [];
  if (options.tagOnly) { const item = knowledgeCitation(); item.evidence = 'Tag'; return [item]; }
  if (options.badEvidence) { const item = knowledgeCitation(); item.excerpt = ''; return [item]; }
  if (options.twoCitations) return [knowledgeCitation(1), knowledgeCitation(2, '第二条本机片段用于引用编号校验。')];
  return [knowledgeCitation()];
}
function liveKnowledgeHarness(options = {}) {
  const toolDb = writableRdb(); const answerBackend = knowledgeJournalBackend();
  const trace = { searches: 0, models: 0, acquired: 0, released: 0, answerOpened: 0, answerClosed: 0,
    modelCancelled: 0, bodies: [] };
  let journal;
  const assemblyPort = {
    async acquire() { trace.acquired++; }, async release() { trace.released++; },
    runtimeSearch: { async search(request) {
      trace.searches++;
      if (options.searchFail) throw Error('private local failure');
      if (options.searchGate) await options.searchGate.promise;
      if (options.failToolOutcome) { toolDb.failWrites = true; }
      return { schemaVersion: '1.0', provider: 'shuvi-local-knowledge', query: request.query, route: 'local-direct',
        citations: knowledgeCitations(options) };
    } }
  };
  class FakeKnowledgeAssembly { static forContext() { return assemblyPort; } }
  class AnswerResource {
    closed = false;
    async open() {
      trace.answerOpened++; journal = new KnowledgeAnswerExecutionStore(answerBackend.port, new AgentHostDigest());
      await journal.open();
    }
    async close() { if (!this.closed) trace.answerClosed++; this.closed = true; }
    saveCheckpoint(...args) { return journal.saveCheckpoint(...args); }
    loadCheckpoint(...args) { return journal.loadCheckpoint(...args); }
    beforeDispatch(...args) { return journal.beforeDispatch(...args); }
    async recordOutcome(...args) {
      try {
        const result = await journal.recordOutcome(...args);
        if (!result.accepted && !result.duplicate) this.onOutcomeRejected(args[0]);
        return result;
      } catch (error) { this.onOutcomeRejected(args[0]); throw error; }
    }
    recordDispatchRejected(...args) { return journal.recordDispatchRejected(...args); }
    normalizeRecoveredOperation(...args) { return journal.normalizeRecoveredOperation(...args); }
    recordReconciliation(...args) { return journal.recordReconciliation(...args); }
  }
  class ModelClient {
    start(request) {
      trace.models++; assert.equal(request.authorization, 'Bearer test-only-key');
      trace.bodies.push(JSON.parse(request.body));
      if (options.failAnswerWriteAfterModel) answerBackend.fail = true;
      if (options.modelGate) return { result: options.modelGate.promise, cancel() { trace.modelCancelled++; } };
      const firstFailure = options.failFirst && trace.models === 1;
      const status = firstFailure ? 401 : (options.modelStatus || 200);
      return { result: Promise.resolve(knowledgeModelResponse(options.modelText || '{"answer":"依据本机片段回答 [1]","citations":[1]}', status)),
        cancel() { trace.modelCancelled++; } };
    }
  }
  const toolAssembly = load(path.join(services, 'KnowledgeRuntimeAssembly.ets'), {
    '../../knowledge/infra/KnowledgeAssembly': { KnowledgeAssembly: FakeKnowledgeAssembly }
  });
  const answerAssembly = load(path.join(services, 'KnowledgeAnswerRuntimeAssembly.ets'), {
    './KnowledgeAnswerExecutionStore': { KnowledgeAnswerExecutionResource: AnswerResource },
    './DeepSeekHttpClient': { ArkTsDeepSeekHttpClient: ModelClient }
  });
  const ui = new RuntimeKnowledgeSession(); ui.onForeground();
  const toolFactory = new toolAssembly.KnowledgeRuntimeFactory({ open(config) { return toolDb.opener.open(config); } }, assemblyPort, true,
    (taskId) => ui.toolOutcomeRejected(taskId));
  const answerFactory = new answerAssembly.KnowledgeAnswerRuntimeFactory({}, true, ui.answerContext,
    (taskId) => ui.answerOutcomeRejected(taskId));
  return { ui, toolFactory, answerFactory, trace, toolDb, answerBackend, assemblyPort, async start(consent = true) {
    const key = new TextEncoder().encode('test-only-key');
    await ui.start(toolFactory, answerFactory, key, consent);
    if (consent) assert.equal(ui.snapshot().lifecycle, ShuviRuntimeState.READY, ui.snapshot().message);
    assert(key.every(value => value === 0), 'knowledge session must consume the key');
  } };
}
async function waitKnowledge(ui, predicate = view => !view.busy) {
  for (let i = 0; i < 200; i++) { if (predicate(ui.snapshot())) return; await new Promise(resolve => setTimeout(resolve, 2)); }
  assert.fail('Knowledge state did not arrive: ' + JSON.stringify(ui.snapshot()));
}
async function waitKnowledgeModel(ui) {
  for (let i = 0; i < 200 && ui.snapshot().stage !== 'answering'; i++) await new Promise(resolve => setTimeout(resolve, 2));
  assert.equal(ui.snapshot().stage, 'answering', JSON.stringify(ui.snapshot()));
}
test('knowledge UX auto-authorizes one zero-cost local read, then persists one PERSONAL answer', async () => {
  const h = liveKnowledgeHarness(); await h.start();
  try {
    assert.equal(h.trace.searches, 0); assert.equal(h.trace.models, 0);
    assert.equal(await h.ui.send('same query'), true);
    await waitKnowledge(h.ui);
    assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 1);
    assert.equal(h.ui.snapshot().stage, 'complete');
    assert.equal(h.ui.snapshot().citations[0].evidenceId, 'internal-evidence-1');
    assert.match(h.ui.snapshot().answer, /\[1\]/); assert.match(h.ui.snapshot().message, /本机检索与 DeepSeek 回答均已完成/);
    assert.equal(h.toolDb.opens[0].name, 'shuvi_knowledge_runtime_v1.db'); assert.equal(h.toolDb.opens[0].encrypt, true);
    const toolPayload = JSON.parse(h.toolDb.envelope.payloadJson); assert.equal(toolPayload.operations.length, 1);
    assert.equal(toolPayload.operations[0].state, invoiceCore.OperationJournalState.COMMITTED);
    assert.equal(toolPayload.operations[0].invoice, undefined); assert.equal(toolPayload.operations[0].pendingInvoice, undefined);
    const answerPayload = JSON.parse(h.answerBackend.value.payloadJson); assert.equal(answerPayload.records.length, 1);
    assert.equal(answerPayload.records[0].checkpoint.envelope.privacyClass, contracts.PrivacyClass.PERSONAL);
    assert.equal(answerPayload.records[0].checkpoint.workflow.steps[0].stepId, 'knowledge-answer');
    assert.equal(answerPayload.records[0].outcome.status, contracts.ToolOutcomeStatus.SUCCEEDED);
    assert(!JSON.stringify(answerPayload).includes('test-only-key'));
  } finally { await h.ui.stop(); }
  assert.equal(h.trace.acquired, 1); assert.equal(h.trace.released, 1);
  assert.equal(h.trace.answerOpened, 1); assert.equal(h.trace.answerClosed, 1);
});
test('knowledge empty and failed reads never fabricate citations or an answer', async () => {
  for (const options of [{empty:true},{searchFail:true}]) {
    const h = liveKnowledgeHarness(options); await h.start();
    try {
      await h.ui.send('same query'); await waitKnowledge(h.ui);
      assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 0);
      assert.equal(h.ui.snapshot().citations.length, 0);
      assert.equal(h.ui.snapshot().answer, '');
      assert.equal(h.ui.snapshot().stage, options.empty ? 'empty' : 'retrievalFailed');
    } finally { await h.ui.stop(); }
  }
});
test('knowledge result parser rejects tag-only, duplicate or unstable evidence and mismatched questions', () => {
  const base = { schemaVersion:'1.0', provider:'shuvi-local-knowledge', query:'q', route:'local-direct', citations:[
    {citationId:1,evidenceId:'e1',documentId:'d1',generation:'g1',title:'t',excerpt:'body',kind:'Text',evidence:'BodyDirect'}] };
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify(base),'q').citations.length,1);
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify(base),'other'),undefined);
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify({...base,citations:[{...base.citations[0],evidence:'Tag'}]}),'q'),undefined);
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify({...base,citations:[base.citations[0],
    {...base.citations[0],citationId:2}]}),'q'),undefined);
  const four={...base,citations:[1,2,3,4].map(i=>({...base.citations[0],citationId:i,evidenceId:'e'+i,excerpt:'x'.repeat(800)}))};
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify(four),'q').citations.length,4);
  const five={...base,citations:[1,2,3,4,5].map(i=>({...base.citations[0],citationId:i,evidenceId:'e5-'+i,excerpt:'x'.repeat(800)}))};
  assert.equal(knowledgeSupport.parseKnowledgeToolResult(JSON.stringify(five),'q'),undefined);
});
test('knowledge local-only mode keeps the citations-only page path and never calls the model', async () => {
  const h = liveKnowledgeHarness(); await h.ui.startLocal(h.toolFactory);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY);
  assert.equal(h.trace.answerOpened, 0);
  await h.ui.send('same query'); await waitKnowledge(h.ui);
  assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 0);
  assert.equal(h.ui.snapshot().stage, 'complete');
  assert.equal(h.ui.snapshot().citations.length, 1);
  assert.match(h.ui.snapshot().answer, /1 条/);
  await h.ui.stop();
});
test('knowledge local-only stop leaves the idle prompt and never claims a model request', async () => {
  const idle = liveKnowledgeHarness();
  await idle.ui.stop();
  assert.equal(idle.ui.snapshot().lifecycle, ShuviRuntimeState.IDLE);
  assert.match(idle.ui.snapshot().message, /尚未启用/);
  const h = liveKnowledgeHarness(); await h.ui.startLocal(h.toolFactory);
  await h.ui.send('same query'); await waitKnowledge(h.ui);
  await h.ui.stop();
  assert.match(h.ui.snapshot().message, /未发送模型请求/);
  assert.doesNotMatch(h.ui.snapshot().message, /模型请求仍可能计费/);
});
test('knowledge answer startup failure rolls back the tool session and keeps prior citations', async () => {
  const h = liveKnowledgeHarness(); await h.ui.startLocal(h.toolFactory);
  await h.ui.send('same query'); await waitKnowledge(h.ui);
  const previous = h.ui.snapshot().citations.length;
  await h.ui.stop();
  const failing = { create() { throw Error('injected answer start failure'); } };
  const key = new TextEncoder().encode('test-only-key');
  await h.ui.start(h.toolFactory, failing, key, true);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.FAILED, h.ui.snapshot().message);
  assert.match(h.ui.snapshot().message, /启动失败/);
  assert.equal(h.ui.snapshot().consent, false);
  assert.equal(h.ui.snapshot().citations.length, previous);
  assert(key.every(value => value === 0));
  assert.equal(h.trace.answerOpened, 0);
  assert.equal(h.trace.released, 2);
});
test('knowledge answer startup close failure keeps the BLOCKED recovery message', async () => {
  const h = liveKnowledgeHarness();
  h.assemblyPort.release = async () => { throw Error('injected close failure'); };
  const failing = { create() { throw Error('injected answer start failure'); } };
  await h.ui.start(h.toolFactory, failing, new TextEncoder().encode('test-only-key'), true);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.BLOCKED);
  assert.match(h.ui.snapshot().message, /资源关闭未确认/);
  assert.doesNotMatch(h.ui.snapshot().message, /启动失败/);
});
test('knowledge cancel during retrieval never calls the model and ignores late evidence', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness({ searchGate: gate }); await h.start();
  try {
    await h.ui.send('same query');
    for (let i = 0; i < 200 && h.trace.searches === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(h.trace.searches, 1);
    await h.ui.cancelCurrent();
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
    assert.equal(h.ui.snapshot().citations.length, 0);
    gate.resolve(); await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(h.trace.models, 0);
    assert.equal(h.ui.snapshot().citations.length, 0);
  } finally { await h.ui.stop(); }
});
test('knowledge cancel during retrieval suppresses a completion that arrives while cancel is pending', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness({ searchGate: gate }); await h.start();
  const originalCancel = h.ui.knowledge.cancel.bind(h.ui.knowledge);
  let releaseCancel; let cancelStarted = false;
  h.ui.knowledge.cancel = async (taskId) => {
    cancelStarted = true; gate.resolve();
    await new Promise(resolve => { releaseCancel = resolve; });
    return originalCancel(taskId);
  };
  try {
    await h.ui.send('same query');
    for (let i = 0; i < 200 && h.trace.searches === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
    const pending = h.ui.cancelCurrent();
    for (let i = 0; i < 200 && !cancelStarted; i++) await new Promise(resolve => setTimeout(resolve, 2));
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
    assert.equal(h.trace.models, 0);
    if (releaseCancel) releaseCancel();
    await pending;
    assert.equal(h.trace.models, 0);
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
  } finally { if (releaseCancel) releaseCancel(); await h.ui.stop(); }
});
test('knowledge submit failure after acceptance cancels the orphan task', async () => {
  const h = liveKnowledgeHarness(); await h.start();
  const originalCancel = h.ui.knowledge.cancel.bind(h.ui.knowledge);
  let cancelled = ''; h.ui.knowledge.cancel = async (taskId) => { cancelled = taskId; return originalCancel(taskId); };
  h.ui.knowledge.subscribe = async () => { throw Error('injected subscribe failure'); };
  try {
    await h.ui.send('same query'); await waitKnowledge(h.ui);
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
    assert(cancelled.length > 0);
    assert.equal(h.trace.models, 0);
  } finally { await h.ui.stop(); }
});
test('knowledge answer stops after ten model calls and never reports success', async () => {
  const h = liveKnowledgeHarness(); await h.start();
  try {
    for (let i = 0; i < 11; i++) { await h.ui.send('same query'); await waitKnowledge(h.ui); }
    assert.equal(h.trace.searches, 11);
    assert.equal(h.trace.models, 10);
    assert.equal(h.ui.snapshot().stage, 'answerFailed');
    assert.equal(h.ui.snapshot().citations.length, 1);
  } finally { await h.ui.stop(); }
});
test('knowledge answer blocks unconsented use and enable never calls the model', async () => {
  const denied = liveKnowledgeHarness(); await denied.start(false);
  assert.notEqual(denied.ui.snapshot().lifecycle, ShuviRuntimeState.READY);
  assert.equal(denied.ui.snapshot().consent, false);
  assert.equal(denied.trace.searches, 0); assert.equal(denied.trace.models, 0);
  assert.equal(await denied.ui.send('same query'), false);
  const h = liveKnowledgeHarness(); await h.start();
  try {
    assert.equal(h.ui.snapshot().consent, true);
    assert.equal(h.trace.searches, 0); assert.equal(h.trace.models, 0);
    assert.equal(h.trace.answerOpened, 1);
  } finally { await h.ui.stop(); }
});
test('knowledge retrieval precedes the model and empty results never call it', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness({ searchGate: gate }); await h.start();
  try {
    const first = h.ui.send('same query');
    assert.equal(await h.ui.send('duplicate query'), false);
    await first;
    for (let i = 0; i < 200 && h.trace.searches === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 0);
    gate.resolve(); await waitKnowledge(h.ui);
    assert.equal(h.trace.models, 1); assert.equal(h.ui.snapshot().stage, 'complete');
  } finally { await h.ui.stop(); }
  const empty = liveKnowledgeHarness({ empty: true }); await empty.start();
  try {
    await empty.ui.send('same query'); await waitKnowledge(empty.ui);
    assert.equal(empty.trace.searches, 1); assert.equal(empty.trace.models, 0);
    assert.equal(empty.ui.snapshot().stage, 'empty'); assert.equal(empty.ui.snapshot().citations.length, 0);
  } finally { await empty.ui.stop(); }
});
test('knowledge tag-only, invalid evidence and retrieval failure never call the model', async () => {
  for (const options of [{tagOnly:true},{badEvidence:true},{searchFail:true}]) {
    const h = liveKnowledgeHarness(options); await h.start();
    try {
      await h.ui.send('same query'); await waitKnowledge(h.ui);
      assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 0);
      assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
      assert.equal(h.ui.snapshot().answer, '');
    } finally { await h.ui.stop(); }
  }
});
test('knowledge answer sends only the question, short titles and excerpts under PERSONAL', async () => {
  const h = liveKnowledgeHarness({ twoCitations: true }); await h.start();
  try {
    await h.ui.send('本机问题'); await waitKnowledge(h.ui);
    assert.equal(h.trace.models, 1);
    const body = h.trace.bodies[0]; assert.equal(body.messages.length, 2);
    const user = body.messages[1].content;
    assert.match(user, /本机问题/); assert.match(user, /\[1\]/); assert.match(user, /\[2\]/);
    assert.match(user, /本机笔记/); assert.match(user, /第二条本机片段/);
    for (const forbidden of ['internal-evidence-1','internal-evidence-2','upd-internal-document',
      'generation-internal','sourceHash','documentId','evidenceId','/data/','shuvi_','native://']) {
      assert(!user.includes(forbidden), 'prompt leaked ' + forbidden);
    }
    assert.equal(body.response_format.type, 'json_object');
    const payload = JSON.parse(h.answerBackend.value.payloadJson);
    assert.equal(payload.records[0].checkpoint.envelope.privacyClass, contracts.PrivacyClass.PERSONAL);
  } finally { await h.ui.stop(); }
});
test('ordinary chat remains PUBLIC while knowledge answer planning requires PERSONAL', async () => {
  assert.equal(chatAssembly.chatFrontendConfig().privacyClass, contracts.PrivacyClass.PUBLIC);
  const chatPlanner = new chatAssembly.ChatPlanner();
  const personal = new runtime.PlanningRequest();
  personal.envelope.taskId = 'task-personal'; personal.envelope.userIntent = 'question';
  personal.envelope.privacyClass = contracts.PrivacyClass.PERSONAL;
  assert.equal((await chatPlanner.plan(personal)).status, runtime.PlanningStatus.REJECTED);
  const publicRequest = new runtime.PlanningRequest();
  publicRequest.envelope.taskId = 'task-public'; publicRequest.envelope.userIntent = 'question';
  publicRequest.envelope.privacyClass = contracts.PrivacyClass.PUBLIC;
  assert.equal((await chatPlanner.plan(publicRequest)).status, runtime.PlanningStatus.READY);
  const answerPlanner = new knowledgeAnswerSupport.KnowledgeAnswerPlanner();
  assert.equal((await answerPlanner.plan(personal)).status, runtime.PlanningStatus.READY);
  assert.equal((await answerPlanner.plan(publicRequest)).status, runtime.PlanningStatus.REJECTED);
});
test('knowledge answer rejects missing, out-of-range or duplicate citations', async () => {
  const cases = [
    '{"answer":"回答 [2]","citations":[2]}',
    '{"answer":"回答 [0] [1]","citations":[1]}',
    '{"answer":"回答 [-1] [1]","citations":[1]}',
    '{"answer":"回答 [1.5] [1]","citations":[1]}',
    '{"answer":"回答 [1]","citations":[]}',
    '{"answer":"没有引用","citations":[1]}',
    '{"answer":"回答 [1]","citations":[1,1]}',
    '{"answer":"回答 [1]","citations":[1,2]}'
  ];
  for (const modelText of cases) {
    const h = liveKnowledgeHarness({ modelText }); await h.start();
    try {
      await h.ui.send('same query'); await waitKnowledge(h.ui);
      assert.equal(h.trace.models, 1); assert.equal(h.ui.snapshot().stage, 'answerFailed');
      assert.equal(h.ui.snapshot().answer, ''); assert.equal(h.ui.snapshot().citations.length, 1);
    } finally { await h.ui.stop(); }
  }
  const valid = liveKnowledgeHarness(); await valid.start();
  try {
    await valid.ui.send('same query'); await waitKnowledge(valid.ui);
    assert.equal(valid.ui.snapshot().stage, 'complete');
  } finally { await valid.ui.stop(); }
});
test('knowledge answer treats a no-citation insufficiency as a non-success state', async () => {
  const h = liveKnowledgeHarness({ modelText: '{"answer":"资料中没有足够依据","citations":[]}' }); await h.start();
  try {
    await h.ui.send('same query'); await waitKnowledge(h.ui);
    assert.equal(h.trace.models, 1);
    assert.equal(h.ui.snapshot().stage, 'insufficient');
    assert.equal(h.ui.snapshot().answer, '');
    assert.equal(h.ui.snapshot().citations.length, 1);
    assert.match(h.ui.snapshot().message, /资料中没有足够依据/);
  } finally { await h.ui.stop(); }
});
test('knowledge model failure keeps citations and retry answers without another retrieval', async () => {
  const h = liveKnowledgeHarness({ failFirst: true }); await h.start();
  try {
    await h.ui.send('same query'); await waitKnowledge(h.ui);
    assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 1);
    assert.equal(h.ui.snapshot().stage, 'answerFailed');
    assert.equal(h.ui.snapshot().answer, ''); assert.equal(h.ui.snapshot().citations.length, 1);
    await h.ui.retryAnswer(); await waitKnowledge(h.ui);
    assert.equal(h.trace.searches, 1); assert.equal(h.trace.models, 2);
    assert.equal(h.ui.snapshot().stage, 'complete'); assert.match(h.ui.snapshot().answer, /\[1\]/);
  } finally { await h.ui.stop(); }
});
test('knowledge background stops the model, clears consent and ignores late results', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness({ modelGate: gate }); await h.start();
  try {
    await h.ui.send('same query'); await waitKnowledgeModel(h.ui);
    assert.equal(h.trace.models, 1);
    await h.ui.onBackground();
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.STOPPED);
    assert.equal(h.ui.snapshot().consent, false); assert.equal(h.ui.snapshot().answer, '');
    assert.equal(h.ui.snapshot().citations.length, 1);
    assert(h.trace.modelCancelled >= 1);
    gate.resolve(knowledgeModelResponse('{"answer":"迟到 [1]","citations":[1]}'));
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(h.ui.snapshot().answer, ''); assert.equal(h.trace.models, 1);
    assert.equal(h.trace.answerClosed, 1); assert.equal(h.trace.released, 1);
  } finally { await h.ui.stop(); }
});
test('knowledge cancel during the model keeps citations and never re-searches', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness({ modelGate: gate }); await h.start();
  try {
    await h.ui.send('same query'); await waitKnowledgeModel(h.ui);
    await h.ui.cancelCurrent();
    assert.equal(h.ui.snapshot().stage, 'answerFailed');
    assert.equal(h.ui.snapshot().citations.length, 1); assert.equal(h.ui.snapshot().answer, '');
    assert.equal(h.trace.searches, 1);
    gate.resolve(knowledgeModelResponse('{"answer":"迟到 [1]","citations":[1]}'));
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(h.ui.snapshot().answer, '');
  } finally { await h.ui.stop(); }
});
test('knowledge answer persistence failure never displays success', async () => {
  const before = liveKnowledgeHarness(); await before.start();
  try {
    before.answerBackend.fail = true;
    await before.ui.send('same query');
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(before.ui.snapshot().answer, '');
    assert.notEqual(before.ui.snapshot().stage, 'complete');
    assert.equal(before.trace.models, 0);
  } finally { await before.ui.stop(); }
  const after = liveKnowledgeHarness({ failAnswerWriteAfterModel: true }); await after.start();
  try {
    await after.ui.send('same query');
    for (let i = 0; i < 200 && after.ui.snapshot().busy; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(after.ui.snapshot().busy, false);
    assert.equal(after.ui.snapshot().stage, 'answerFailed');
    assert.match(after.ui.snapshot().message, /未能可靠保存/);
    assert.equal(after.ui.snapshot().answer, '');
    assert.equal(after.ui.snapshot().citations.length, 1);
    assert.equal(after.trace.models, 1);
  } finally { await after.ui.stop(); }
});
test('knowledge tool outcome persistence rejection ends retrieval immediately without a model call', async () => {
  const h = liveKnowledgeHarness({ failToolOutcome: true }); await h.start();
  try {
    await h.ui.send('same query');
    for (let i = 0; i < 200 && h.ui.snapshot().busy; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(h.ui.snapshot().busy, false);
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
    assert.match(h.ui.snapshot().message, /未能可靠保存/);
    assert.equal(h.trace.models, 0);
  } finally { await h.ui.stop(); }
});
test('knowledge stop failure enters BLOCKED and cannot restart', async () => {
  const h = liveKnowledgeHarness(); await h.start();
  h.assemblyPort.release = async () => { throw Error('private close failure'); };
  await h.ui.stop();
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.BLOCKED);
  const key = new TextEncoder().encode('test-only-key');
  await h.ui.start(h.toolFactory, h.answerFactory, key, true);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.BLOCKED);
  assert(key.every(value => value === 0));
});
test('knowledge session consumes the key, clears consent on stop and cannot be reused', async () => {
  const h = liveKnowledgeHarness(); const key = new TextEncoder().encode('test-only-key');
  await h.ui.start(h.toolFactory, h.answerFactory, key, true);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY, h.ui.snapshot().message);
  assert(key.every(value => value === 0));
  assert.equal(h.ui.snapshot().consent, true);
  assert(!JSON.stringify(h.ui.snapshot()).includes('test-only-key'));
  await h.ui.send('same query'); await waitKnowledge(h.ui);
  await h.ui.stop();
  assert.equal(h.ui.snapshot().consent, false);
  assert.equal(h.trace.answerClosed, 1); assert.equal(h.trace.released, 1);
  const before = h.trace.models;
  assert.equal(await h.ui.send('another query'), false); assert.equal(h.trace.models, before);
});
test('knowledge stop after retrieval but before model submission prevents the model call', async () => {
  const h = liveKnowledgeHarness(); await h.start();
  let submitStarted = false; let release;
  const original = h.ui.answer.submit.bind(h.ui.answer);
  h.ui.answer.submit = async (request) => {
    submitStarted = true;
    await new Promise(resolve => { release = resolve; });
    return original(request);
  };
  try {
    await h.ui.send('same query');
    for (let i = 0; i < 200 && !submitStarted; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(submitStarted, true);
    await h.ui.stop();
    if (release) release();
    await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(h.trace.models, 0);
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.STOPPED);
  } finally { if (release) release(); await h.ui.stop(); }
});
test('knowledge answer resource uses its own encrypted database and reopens retained evidence', async () => {
  nativeModules['@ohos.data.relationalStore'].RdbPredicates = class {
    equalTo(key, value) { this[key] = value; return this; } and() { return this; }
  };
  nativeModules['@ohos.data.relationalStore'].ConflictResolution = { ON_CONFLICT_IGNORE: 1 };
  const h = rdbHarness();
  h.handle.update = async (values, predicate) => {
    if (!h.envelope || h.envelope.revision !== predicate.revision) return 0;
    h.envelope = { revision: values.revision, schemaVersion: values.schema_version,
      payloadJson: values.payload_json, payloadDigest: values.payload_digest }; return 1;
  };
  h.handle.insert = async (_table, values) => {
    if (h.envelope) return -1;
    h.envelope = { revision: values.revision, schemaVersion: values.schema_version,
      payloadJson: values.payload_json, payloadDigest: values.payload_digest }; return 1;
  };
  const resource = new KnowledgeAnswerExecutionResource(h.opener, new AgentHostDigest()); await resource.open();
  assert.equal(h.opens[0].name, 'shuvi_knowledge_answer_v1.db'); assert.equal(h.opens[0].encrypt, true);
  const source = liveKnowledgeHarness(); await source.start();
  try {
    await source.ui.send('same query'); await waitKnowledge(source.ui);
    h.envelope = structuredClone(source.answerBackend.value);
    await resource.close(); await resource.open();
    const row = JSON.parse(h.envelope.payloadJson).records[0];
    const reopened = await resource.loadCheckpoint(row.checkpoint.snapshot.taskId);
    assert.equal(reopened.snapshot.status, contracts.AgentTaskStatus.COMPLETED);
    assert.equal(reopened.envelope.privacyClass, contracts.PrivacyClass.PERSONAL);
  } finally { await source.ui.stop(); await resource.close(); }
});
test('knowledge prompt excludes internal identifiers and fails closed on invalid evidence', () => {
  const base = knowledgeCitation();
  const prompt = knowledgeAnswerSupport.buildKnowledgePrompt('问题', [base]);
  assert(prompt); assert.match(prompt, /问题/); assert.match(prompt, /\[1\]/); assert.match(prompt, /个人知识库片段/);
  for (const forbidden of ['internal-evidence-1','upd-internal-document','generation-internal','sourceHash',
    'documentId','evidenceId']) { assert(!prompt.includes(forbidden)); }
  assert.equal(knowledgeAnswerSupport.buildKnowledgePrompt('问题', [{...base, excerpt:'x'.repeat(801)}]), undefined);
  assert.equal(knowledgeAnswerSupport.buildKnowledgePrompt('问题', [{...base, evidence:'Tag'}]), undefined);
  const five = [1,2,3,4,5].map(id => ({...base, citationId:id, evidenceId:'e'+id, excerpt:'x'.repeat(800)}));
  assert.equal(knowledgeAnswerSupport.buildKnowledgePrompt('问题', five), undefined);
  const bounded = [1,2,3,4,5].map(id => ({...base, citationId:id, evidenceId:'e'+id, excerpt:'x'.repeat(640)}));
  assert(knowledgeAnswerSupport.buildKnowledgePrompt('问题', bounded));
});
test('knowledge answer parser enforces schema, citation bounds and markers', () => {
  const valid = { schemaVersion:'1.0', kind:'knowledgeAnswer', text:'回答 [1]', citationIds:[1], inputTokens:100, outputTokens:20 };
  assert(knowledgeAnswerSupport.parseKnowledgeAnswer(JSON.stringify(valid),1));
  for (const bad of [
    {...valid, schemaVersion:'2.0'}, {...valid, kind:'other'}, {...valid, text:''}, {...valid, text:'没有引用'},
    {...valid, citationIds:[]}, {...valid, citationIds:[2]}, {...valid, citationIds:[1,1]},
    {...valid, inputTokens:8193}, {...valid, outputTokens:1025}, {...valid, text:'回答 [2]'},
    {...valid, text:'回答 [0] [1]'}, {...valid, text:'回答 [-1] [1]'}, {...valid, text:'回答 [1.5] [1]'}
  ]) assert.equal(knowledgeAnswerSupport.parseKnowledgeAnswer(JSON.stringify(bad),1), undefined);
  assert.equal(knowledgeAnswerSupport.parseKnowledgeAnswer(JSON.stringify(valid),0), undefined);
  assert(knowledgeAnswerSupport.parseKnowledgeModelOutput('{"answer":"回答 [1]","citations":[1]}',1));
  assert.equal(knowledgeAnswerSupport.parseKnowledgeModelOutput('```json\n{"answer":"回答 [1]","citations":[1]}\n```',1), undefined);
  const context = new knowledgeAnswerSupport.KnowledgeAnswerContext();
  assert.match(context.systemPrompt(), /不要用方括号/);
  const insufficient = { schemaVersion:'1.0', kind:'knowledgeInsufficient', text:'资料中没有足够依据', citationIds:[], inputTokens:10, outputTokens:5 };
  assert(knowledgeAnswerSupport.parseKnowledgeInsufficient(JSON.stringify(insufficient)));
  assert.equal(knowledgeAnswerSupport.parseKnowledgeInsufficient(JSON.stringify({...insufficient, citationIds:[1]})), undefined);
  assert.equal(knowledgeAnswerSupport.parseKnowledgeInsufficient(JSON.stringify({...insufficient, text:'其他'})), undefined);
  assert(knowledgeAnswerSupport.parseKnowledgeModelInsufficient('{"answer":"资料中没有足够依据","citations":[]}'));
  assert.equal(knowledgeAnswerSupport.parseKnowledgeModelInsufficient('{"answer":"资料中没有足够依据","citations":[1]}'), undefined);
});

const semanticRagAdapterModule = load(path.join(root,
  'entry/src/main/ets/knowledge/application/KnowledgeSemanticRuntimeSearchAdapter.ets'), {
  './KnowledgeQuerySession': { KnowledgeQuerySession: class {} }
});
function runtimeRagResult() {
  return { schemaVersion:'1.0', provider:'shuvi-local-knowledge', query:'same query', route:'local-rag',
    citations:[knowledgeCitation()] };
}
function runtimeRagPort(options = {}) {
  const trace = { opened:0, closed:0, searched:0, cancel:undefined };
  return { trace, async open() { trace.opened++; }, async close() { trace.closed++; },
    async readiness() { return { ready:!options.notReady, code:options.notReady?'EmbeddingSettingsRequired':'Ready',
      message:options.notReady?'Embedding 未就绪':'知识库 RAG 已就绪。' }; },
    async search(request, cancel) {
      trace.searched++; trace.cancel = cancel;
      if (options.gate) await options.gate.promise;
      cancel.check(); const result = runtimeRagResult(); result.query = request.query; return result;
    } };
}
test('prepared RAG enables only after readiness, retrieves before one PERSONAL answer and keeps the key private', async () => {
  const h = liveKnowledgeHarness(); const rag = runtimeRagPort();
  const key = new TextEncoder().encode('test-only-key');
  await h.ui.prepareRag(rag, h.answerFactory, key);
  try {
    assert(key.every(value => value === 0)); assert.equal(rag.trace.opened, 1);
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY); assert.equal(h.ui.snapshot().consent, false);
    assert.equal(await h.ui.send('same query'), false); assert.equal(rag.trace.searched, 0); assert.equal(h.trace.models, 0);
    const readiness = await h.ui.activateRag(); assert.equal(readiness.ready, true); assert.equal(h.ui.snapshot().consent, true);
    assert.equal(await h.ui.send('same query'), true); await waitKnowledge(h.ui);
    assert.equal(rag.trace.searched, 1); assert.equal(h.trace.models, 1); assert.equal(h.ui.snapshot().stage, 'complete');
    const prompt = h.trace.bodies[0].messages[1].content;
    for (const forbidden of ['internal-evidence-1','upd-internal-document','generation-internal']) assert(!prompt.includes(forbidden));
  } finally { await h.ui.stop(); }
  assert.equal(rag.trace.closed, 1); assert.equal(h.trace.answerClosed, 1);
});
test('RAG readiness fails closed without disabling the prepared ordinary-chat peer session', async () => {
  const h = liveKnowledgeHarness(); const rag = runtimeRagPort({ notReady:true });
  await h.ui.prepareRag(rag, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    const readiness = await h.ui.activateRag(); assert.equal(readiness.ready, false);
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY); assert.equal(h.ui.snapshot().consent, false);
    assert.equal(await h.ui.send('same query'), false); assert.equal(rag.trace.searched, 0); assert.equal(h.trace.models, 0);
  } finally { await h.ui.stop(); }
});
test('turning RAG off preserves its prepared answer session while blocking further knowledge queries', async () => {
  const h = liveKnowledgeHarness(); const rag = runtimeRagPort();
  await h.ui.prepareRag(rag, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    await h.ui.activateRag(); await h.ui.deactivateRag();
    assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY); assert.equal(h.ui.snapshot().consent, false);
    assert.equal(rag.trace.closed, 0); assert.equal(await h.ui.send('same query'), false);
    await h.ui.activateRag(); assert.equal(h.ui.snapshot().consent, true);
  } finally { await h.ui.stop(); }
});
test('late RAG readiness cannot re-enable consent after the session is stopped', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness(); const rag = runtimeRagPort();
  rag.readiness = async () => { await gate.promise; return {ready:true,code:'Ready',message:'知识库 RAG 已就绪。'}; };
  await h.ui.prepareRag(rag, h.answerFactory, new TextEncoder().encode('test-only-key'));
  const enabling = h.ui.activateRag(); const stopping = h.ui.stop(); gate.resolve();
  const readiness = await enabling; await stopping;
  assert.equal(readiness.ready, false); assert.equal(h.ui.snapshot().consent, false);
  assert.notEqual(h.ui.snapshot().lifecycle, ShuviRuntimeState.READY);
});
test('cancelling retrieval invalidates the exact RAG query and never dispatches DeepSeek', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness(); const rag = runtimeRagPort({ gate });
  await h.ui.prepareRag(rag, h.answerFactory, new TextEncoder().encode('test-only-key')); await h.ui.activateRag();
  try {
    assert.equal(await h.ui.send('same query'), true);
    for (let i = 0; i < 200 && rag.trace.searched === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
    await h.ui.cancelCurrent(); assert.equal(rag.trace.cancel.invalid, true); assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
    gate.resolve(); await new Promise(resolve => setTimeout(resolve, 20)); assert.equal(h.trace.models, 0);
  } finally { gate.resolve(); await h.ui.stop(); }
});
test('semantic Runtime adapter executes local then review then embedding, filters tag-only cards and bounds evidence', async () => {
  const order = []; let receivedCancel;
  const direct = { key:'direct-1', kind:'Text', title:'Direct', text:'direct body', documentKey:'doc-1', generation:'gen-1',
    current:true, reasons:[{route:'BodyDirect'}] };
  const tagOnly = { key:'tag-1', kind:'Image', title:'Tag', text:'tag text', documentKey:'doc-2', generation:'gen-2',
    current:true, reasons:[{route:'Tag'}] };
  const vector = { key:'vector-1', kind:'Text', title:'Vector', text:'vector body', documentKey:'doc-3', generation:'gen-3',
    current:true, reasons:[{route:'Tag'},{route:'Vector'}] };
  const session = { state:{ direct:{cards:[direct],error:''}, related:{cards:[tagOnly,vector],error:''}, semanticState:'Complete' },
    async start(query, archived, cancel) { order.push('local'); assert.equal(query,'same query'); assert.equal(archived,false); receivedCancel=cancel; },
    async review() { order.push('review'); }, async allowSemantic(consent,cost) { order.push('embedding'); assert(consent && cost); },
    async close() { order.push('close'); } };
  const adapter = new semanticRagAdapterModule.KnowledgeSemanticRuntimeSearchAdapter(() => session);
  const cancel = { invalid:false, check() { if (this.invalid) throw Error('cancelled'); } };
  const result = await adapter.search({query:'same query',maxResults:5}, cancel);
  assert.equal(receivedCancel, cancel); assert.deepEqual(order, ['local','review','embedding','close']);
  assert.equal(result.route, 'local-rag'); assert.equal(result.citations.length, 2);
  assert.equal(result.citations[0].evidence, 'BodyDirect'); assert.equal(result.citations[1].evidence, 'Vector');
  assert(!result.citations.some(citation => citation.evidence === 'Tag'));
});
test('semantic Runtime adapter fails closed when the exact-query embedding step is unavailable', async () => {
  const session = { state:{ direct:{cards:[],error:''}, related:{cards:[],error:''}, semanticState:'NoRequest' },
    async start() {}, async review() {}, async allowSemantic() {}, async close() {} };
  const adapter = new semanticRagAdapterModule.KnowledgeSemanticRuntimeSearchAdapter(() => session);
  const cancel = { invalid:false, check() {} };
  await assert.rejects(adapter.search({query:'same query',maxResults:5}, cancel), /RuntimeRagSemanticUnavailable/);
});
// Real composition: page session -> RAG session adapter -> semantic adapter -> KnowledgeQuerySession.
const realRagQueryModule = load(path.join(root, 'entry/src/main/ets/knowledge/application/KnowledgeQuerySession.ets'));
const realRagAdapterModule = load(path.join(root, 'entry/src/main/ets/knowledge/infra/KnowledgeRagSessionAdapter.ets'), {
  './KnowledgeAssembly': { KnowledgeAssembly: class {} }
});
const realRagModels = load(path.join(root, 'entry/src/main/ets/knowledge/domain/UnifiedQueryModels.ets'));
const realRagParsed = load(path.join(root, 'entry/src/main/ets/knowledge/domain/ParsedDocumentModels.ets'));
function realRagVectorCard() {
  const card = new realRagModels.UnifiedSearchCard(); card.key = 'text:upd-vector-doc:gen-vector-1:chunk-vector-1';
  card.title = '向量笔记'; card.text = '向量片段说明回答必须先固定本机证据。';
  card.documentKey = 'upd-vector-doc'; card.generation = 'gen-vector-1';
  const reason = new realRagModels.UnifiedSearchReason(); reason.route = 'Vector'; card.reasons = [reason];
  return card;
}
function realRagStack(options = {}) {
  const trace = { acquired:0, released:0, reviews:0, embeddings:0 };
  function createQuerySession() {
    const scope = new realRagModels.UnifiedQueryScope(); scope.complete = true;
    if (options.directText) {
      const source = new realRagModels.UnifiedQueryTextSource();
      source.document.id = 'upd-direct-doc'; source.document.title = '本机设计笔记';
      const chunk = new realRagParsed.ParsedTextChunk(); chunk.id = 'chunk-direct-1'; chunk.documentKey = 'upd-direct-doc';
      chunk.generation = 'gen-direct-1'; chunk.text = options.directText; chunk.evidence = 'Body';
      source.chunks = [chunk]; scope.texts = [source];
    }
    const scopePort = { async capture() { return scope; }, async visible() { return true; } };
    const engine = {
      async review(question, session, epoch) {
        trace.reviews++; const approval = new realRagModels.UnifiedQueryApproval();
        approval.session = session; approval.epoch = epoch; approval.actual = question; return approval;
      },
      async approve() {}, async revoke() {},
      async semantic(_approval, cancel) {
        trace.embeddings++; if (options.semanticGate) await options.semanticGate.promise;
        cancel.check(); return options.vector ? [realRagVectorCard()] : [];
      }
    };
    const history = { async append() {}, async list() { return []; } };
    const identity = { id() { return crypto.randomUUID(); }, async hash() { return 'host-hash'; } };
    return new realRagQueryModule.KnowledgeQuerySession(scopePort, engine, { currentConfig() { return {}; } }, history, identity);
  }
  const assembly = { async acquire() { trace.acquired++; }, async release() { trace.released++; },
    async ragReadiness() { return { ready:true, code:'Ready', message:'知识库 RAG 已就绪。' }; }, createQuerySession };
  return { trace, port: new realRagAdapterModule.KnowledgeRagSessionAdapter(assembly) };
}
test('real RAG composition keeps a successful retrieval and dispatches one grounded DeepSeek answer', async () => {
  const h = liveKnowledgeHarness(); const stack = realRagStack({ directText:'休比 Runtime 设计 采用持久化执行记录。', vector:true });
  await h.ui.prepareRag(stack.port, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    assert.equal((await h.ui.activateRag()).ready, true);
    assert.equal(await h.ui.send('Runtime 设计'), true); await waitKnowledge(h.ui);
    const view = h.ui.snapshot();
    assert.equal(view.stage, 'complete', view.message); assert.equal(stack.trace.embeddings, 1); assert.equal(h.trace.models, 1);
    assert.deepEqual(view.citations.map(citation => citation.evidence), ['BodyDirect', 'Vector']);
    const prompt = h.trace.bodies[0].messages[1].content;
    assert(prompt.includes('采用持久化执行记录') && prompt.includes('必须先固定本机证据'));
    for (const internal of ['upd-direct-doc','gen-direct-1','chunk-direct-1','upd-vector-doc','gen-vector-1']) assert(!prompt.includes(internal));
  } finally { await h.ui.stop(); }
  assert.equal(stack.trace.acquired, 1); assert.equal(stack.trace.released, 1);
});
test('real RAG composition finishes empty without DeepSeek when nothing is citable', async () => {
  const h = liveKnowledgeHarness(); const stack = realRagStack();
  await h.ui.prepareRag(stack.port, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    await h.ui.activateRag(); assert.equal(await h.ui.send('Runtime 设计'), true); await waitKnowledge(h.ui);
    assert.equal(h.ui.snapshot().stage, 'empty', h.ui.snapshot().message);
    assert.equal(stack.trace.embeddings, 1); assert.equal(h.trace.models, 0);
  } finally { await h.ui.stop(); }
});
test('real RAG composition still discards retrieval cancelled during the query embedding', async () => {
  const gate = deferred(); const h = liveKnowledgeHarness(); const stack = realRagStack({ vector:true, semanticGate:gate });
  await h.ui.prepareRag(stack.port, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    await h.ui.activateRag(); assert.equal(await h.ui.send('Runtime 设计'), true);
    for (let i = 0; i < 200 && stack.trace.embeddings === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
    assert.equal(stack.trace.embeddings, 1); await h.ui.cancelCurrent();
    assert.equal(h.ui.snapshot().stage, 'retrievalFailed'); assert.equal(h.ui.snapshot().busy, false);
    gate.resolve(); await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(h.trace.models, 0); assert.equal(h.ui.snapshot().stage, 'retrievalFailed');
  } finally { gate.resolve(); await h.ui.stop(); }
});
const knowledgePresentation = load(path.join(services, 'RuntimeKnowledgePresentation.ets'));
test('knowledge panel wording covers both RAG phases and only offers retry when the session would accept it', () => {
  const { RuntimeKnowledgeView } = load(path.join(services, 'RuntimeKnowledgeSession.ets'));
  const view = (fields) => Object.assign(new RuntimeKnowledgeView(), fields);
  const two = [knowledgeCitation(1), knowledgeCitation(2)];
  const cases = [
    [{ stage:'idle' }, '未开始', '未开始'],
    [{ stage:'retrieving', busy:true }, '检索中', '等待本机检索完成'],
    [{ stage:'answering', busy:true, citations:two }, '已完成 · 2 条本机片段', 'DeepSeek 整理中'],
    [{ stage:'complete', citations:two, answer:'回答 [1]', answerSource:'deepseek' }, '已完成 · 2 条本机片段', '已完成'],
    [{ stage:'complete', citations:two, answer:'已找到 2 条', answerSource:'local' }, '已完成 · 2 条本机片段', '未调用 DeepSeek'],
    [{ stage:'answerFailed', citations:two }, '已完成 · 2 条本机片段', '未完成，可仅重试回答'],
    [{ stage:'insufficient', citations:two }, '已完成 · 2 条本机片段', '资料中没有足够依据'],
    [{ stage:'empty' }, '没有可引用的片段', '未调用 DeepSeek'],
    [{ stage:'retrievalFailed' }, '未完成', '未调用 DeepSeek'],
    [{ stage:'stopped', citations:two, answer:'回答 [1]', answerSource:'deepseek' }, '已完成 · 2 条本机片段', '已完成'],
    [{ stage:'stopped' }, '已停止', '已停止']
  ];
  for (const [fields, retrieval, answer] of cases) {
    assert.equal(knowledgePresentation.knowledgeRetrievalStage(view(fields)), retrieval, fields.stage);
    assert.equal(knowledgePresentation.knowledgeAnswerStage(view(fields)), answer, fields.stage);
  }
  const retryable = { stage:'answerFailed', lifecycle:ShuviRuntimeState.READY, consent:true, citations:two };
  assert.equal(knowledgePresentation.knowledgeRetryAvailable(view(retryable)), true);
  for (const blocked of [{ busy:true }, { consent:false }, { citations:[] }, { stage:'insufficient' },
    { lifecycle:ShuviRuntimeState.STOPPED }]) {
    assert.equal(knowledgePresentation.knowledgeRetryAvailable(view({ ...retryable, ...blocked })), false, JSON.stringify(blocked));
  }
  assert.equal(knowledgePresentation.knowledgeAnswerIsModel(view({ answer:'回答 [1]', answerSource:'deepseek' })), true);
  assert.equal(knowledgePresentation.knowledgeAnswerIsModel(view({ answer:'已找到 1 条', answerSource:'local' })), false);
  assert.equal(knowledgePresentation.knowledgeAnswerIsModel(view({ answer:'', answerSource:'deepseek' })), false);
});
test('real RAG composition offers answer-only retry after a model failure and never re-runs retrieval', async () => {
  const h = liveKnowledgeHarness({ failFirst:true }); const stack = realRagStack({ vector:true });
  await h.ui.prepareRag(stack.port, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    await h.ui.activateRag(); assert.equal(await h.ui.send('Runtime 设计'), true); await waitKnowledge(h.ui);
    let view = h.ui.snapshot();
    assert.equal(view.stage, 'answerFailed', view.message); assert.equal(view.citations.length, 1);
    assert.equal(knowledgePresentation.knowledgeRetryAvailable(view), true);
    assert.equal(knowledgePresentation.knowledgeAnswerIsModel(view), false);
    await h.ui.retryAnswer(); await waitKnowledge(h.ui); view = h.ui.snapshot();
    assert.equal(view.stage, 'complete', view.message); assert.equal(view.answerSource, 'deepseek');
    assert.equal(knowledgePresentation.knowledgeAnswerIsModel(view), true);
    assert.equal(knowledgePresentation.knowledgeRetryAvailable(view), false);
    assert.equal(h.trace.models, 2); assert.equal(stack.trace.embeddings, 1);
    assert.equal(await h.ui.send('Runtime 设计'), true); await waitKnowledge(h.ui);
    assert.equal(h.ui.snapshot().answerSource, 'deepseek'); assert.equal(stack.trace.embeddings, 2);
    h.ui.clearConversation(); assert.equal(h.ui.snapshot().answerSource, ''); assert.equal(h.ui.snapshot().answer, '');
  } finally { await h.ui.stop(); }
});
test('real RAG composition shows insufficient evidence as a non-success without retry or model label', async () => {
  const h = liveKnowledgeHarness({ modelText:'{"answer":"资料中没有足够依据","citations":[]}' });
  const stack = realRagStack({ vector:true });
  await h.ui.prepareRag(stack.port, h.answerFactory, new TextEncoder().encode('test-only-key'));
  try {
    await h.ui.activateRag(); assert.equal(await h.ui.send('Runtime 设计'), true); await waitKnowledge(h.ui);
    const view = h.ui.snapshot();
    assert.equal(view.stage, 'insufficient', view.message); assert.equal(view.answer, ''); assert.equal(view.answerSource, '');
    assert.equal(view.citations.length, 1); assert.equal(knowledgePresentation.knowledgeRetryAvailable(view), false);
    assert.equal(knowledgePresentation.knowledgeAnswerStage(view), '资料中没有足够依据');
  } finally { await h.ui.stop(); }
});
test('assistant coordinator consumes one caller key and gives isolated copies to PUBLIC chat and PERSONAL RAG', async () => {
  const trace = { chatKey:undefined, ragKey:undefined, chatStopped:0, ragStopped:0 }; let chatState = ShuviRuntimeState.IDLE;
  const fakeKnowledgeSession = { answerContext:{},
    async prepareRag(_search, _factory, key) { trace.ragKey = key.slice(); key.fill(0); },
    answerOutcomeRejected() {}, async activateRag() { return {ready:true}; }, async deactivateRag() {},
    snapshot() { return {lifecycle:ShuviRuntimeState.IDLE}; }, async stop() { trace.ragStopped++; } };
  const coordinator = load(path.join(services, 'RuntimeAssistantCoordinator.ets'), {
    './ChatRuntimeAssembly': { chatRuntimeFactory() { return {kind:'chat'}; } },
    './KnowledgeAnswerRuntimeAssembly': { knowledgeAnswerRuntimeFactory() { return {kind:'answer'}; } },
    './RuntimeChatService': { RuntimeChatService:{session:{
      async start(_factory, key) { trace.chatKey = key.slice(); key.fill(0); chatState=ShuviRuntimeState.READY; },
      snapshot() { return {lifecycle:chatState}; }, async stop() { trace.chatStopped++; }
    }}},
    './RuntimeKnowledgeService': { RuntimeKnowledgeService:{session:fakeKnowledgeSession} },
    '../../knowledge/infra/KnowledgeAssembly': { KnowledgeAssembly:{forContext() { return {}; }} },
    '../../knowledge/infra/KnowledgeRagSessionAdapter': { KnowledgeRagSessionAdapter:class { constructor(assembly) { this.assembly=assembly; } } }
  });
  const key = new TextEncoder().encode('one-session-key');
  await coordinator.RuntimeAssistantCoordinator.start({}, true, key);
  assert(key.every(value => value === 0)); assert.deepEqual(trace.chatKey, trace.ragKey);
  assert.notEqual(trace.chatKey, trace.ragKey); assert.equal(new TextDecoder().decode(trace.chatKey), 'one-session-key');
  await coordinator.RuntimeAssistantCoordinator.stop(); assert.equal(trace.chatStopped,1); assert.equal(trace.ragStopped,1);
});
test('assistant coordinator does not retain or prepare a RAG key when PUBLIC chat startup fails', async () => {
  let prepared = 0; const fakeKnowledgeSession = { answerContext:{}, snapshot() { return {lifecycle:ShuviRuntimeState.IDLE}; },
    async prepareRag() { prepared++; }, answerOutcomeRejected() {}, async stop() {} };
  const coordinator = load(path.join(services, 'RuntimeAssistantCoordinator.ets'), {
    './ChatRuntimeAssembly': { chatRuntimeFactory() { return {}; } },
    './KnowledgeAnswerRuntimeAssembly': { knowledgeAnswerRuntimeFactory() { return {}; } },
    './RuntimeChatService': { RuntimeChatService:{session:{ async start(_factory,key) { key.fill(0); },
      snapshot() { return {lifecycle:ShuviRuntimeState.FAILED}; }, async stop() {} }}},
    './RuntimeKnowledgeService': { RuntimeKnowledgeService:{session:fakeKnowledgeSession} },
    '../../knowledge/infra/KnowledgeAssembly': { KnowledgeAssembly:{forContext() { return {}; }} },
    '../../knowledge/infra/KnowledgeRagSessionAdapter': { KnowledgeRagSessionAdapter:class {} }
  });
  const key = new TextEncoder().encode('rejected-session-key');
  await coordinator.RuntimeAssistantCoordinator.start({}, true, key);
  assert(key.every(value => value === 0)); assert.equal(prepared, 0);
});
test('assistant coordinator rejects duplicate start without rotating the prepared RAG key', async () => {
  let chatStarts = 0; let ragPrepares = 0; let ragStops = 0;
  const coordinator = load(path.join(services, 'RuntimeAssistantCoordinator.ets'), {
    './RuntimeChatService': { RuntimeChatService:{session:{ snapshot() { return {lifecycle:ShuviRuntimeState.READY}; },
      async start() { chatStarts++; }, async stop() {} }}},
    './RuntimeKnowledgeService': { RuntimeKnowledgeService:{session:{ answerContext:{},
      snapshot() { return {lifecycle:ShuviRuntimeState.READY}; }, async prepareRag() { ragPrepares++; },
      answerOutcomeRejected() {}, async stop() { ragStops++; } }}},
    './ChatRuntimeAssembly': { chatRuntimeFactory() { return {}; } },
    './KnowledgeAnswerRuntimeAssembly': { knowledgeAnswerRuntimeFactory() { return {}; } },
    '../../knowledge/infra/KnowledgeAssembly': { KnowledgeAssembly:{forContext() { return {}; }} },
    '../../knowledge/infra/KnowledgeRagSessionAdapter': { KnowledgeRagSessionAdapter:class {} }
  });
  const key = new TextEncoder().encode('duplicate-key');
  await coordinator.RuntimeAssistantCoordinator.start({}, true, key);
  assert(key.every(value => value === 0)); assert.equal(chatStarts,0); assert.equal(ragPrepares,0); assert.equal(ragStops,0);
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

// Route 2: session-key direct vision answer. Real protocol/validation; network and image decode are injected.
const visionProtocol = load(path.join(services, 'VisionChatProtocol.ets'));
const visionSupport = load(path.join(services, 'VisionAnswerTaskSupport.ets'));
const visionPorts = load(path.join(services, 'VisionImagePorts.ets'));
const visionStore = load(path.join(services, 'KnowledgeAnswerExecutionStore.ets'));
const visionAssembly = load(path.join(services, 'VisionAnswerRuntimeAssembly.ets'));
const { RuntimeVisionSession } = load(path.join(services, 'RuntimeVisionSession.ets'));

function visionImage(overrides = {}) {
  return Object.assign(new visionProtocol.VisionChatImage(), {
    mime: 'image/jpeg', width: 1024, height: 768, sha256: 'a'.repeat(64), bytes: new Uint8Array([1, 2, 3, 4])
  }, overrides);
}
function visionRequest(overrides = {}) {
  return Object.assign(new visionProtocol.VisionChatRequest(), {
    modelId: 'test-model', systemPrompt: '只依据图片回答并输出 JSON。', question: '图里是什么？', image: visionImage()
  }, overrides);
}
function visionResponse(text, overrides = {}) {
  return { statusCode: 200, body: JSON.stringify({ object: 'chat.completion', model: 'test-model',
    choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 }, ...overrides }) };
}
function visionResult(text, overrides = {}) {
  return Object.assign(new visionProtocol.VisionChatResult(), {
    outputText: text, inputTokens: 100, outputTokens: 20, finishReason: 'stop', modelId: 'test-model'
  }, overrides);
}
function visionPolicy() {
  const policy = new visionStore.AnswerExecutionPolicy();
  policy.schema = 'shuvi-vision-answer-1.0'; policy.storeName = 'shuvi_vision_answer_v1.db';
  policy.memoryStoreName = 'shuvi_vision_answer_unused_memory_v1.db'; policy.stepId = visionSupport.VISION_ANSWER_STEP_ID;
  return policy;
}

test('vision payload sends only the question and sanitized image with strict JSON mode', () => {
  const body = visionProtocol.buildVisionChatBody(visionRequest({
    systemPrompt: new visionSupport.VisionAnswerContext().systemPrompt()
  }), 'AQID');
  assert(body); const parsed = JSON.parse(body);
  assert.equal(parsed.model, 'test-model'); assert.deepEqual(parsed.thinking, { type: 'disabled' });
  assert.equal(parsed.stream, false); assert.deepEqual(parsed.response_format, { type: 'json_object' });
  assert.equal(parsed.max_tokens, visionProtocol.VISION_CHAT_MAX_OUTPUT_TOKENS);
  assert.equal(parsed.messages[0].role, 'system'); assert.match(parsed.messages[0].content, /不可信数据/);
  const parts = parsed.messages[1].content;
  assert.equal(parts.length, 2); assert.equal(parts[0].type, 'text'); assert.match(parts[0].text, /图里是什么/);
  assert.equal(parts[1].type, 'image_url'); assert.equal(parts[1].image_url.url, 'data:image/jpeg;base64,AQID');
  assert(!body.includes('screen.jpg')); assert(!body.includes('file://')); assert(!body.includes('evidenceId'));
  for (const bad of [
    visionRequest({ modelId: 'https://other' }), visionRequest({ question: '' }), visionRequest({ question: 'x'.repeat(501) }),
    visionRequest({ image: visionImage({ mime: 'image/gif' }) }), visionRequest({ image: visionImage({ bytes: new Uint8Array(0) }) }),
    visionRequest({ maxOutputTokens: 0 }), visionRequest({ timeoutMs: 0 })
  ]) assert.equal(visionProtocol.buildVisionChatBody(bad, 'AQID'), undefined);
  assert.equal(visionProtocol.buildVisionChatBody(visionRequest(), 'not base64!'), undefined);
});

test('vision response parser enforces model, finish, usage and no tools', () => {
  const ok = visionProtocol.parseVisionChatResponse(200, visionResponse('{"answer":"图中有文字 [1]","citations":[1]}').body, 'test-model');
  assert.equal(ok.outputText, '{"answer":"图中有文字 [1]","citations":[1]}');
  assert.equal(ok.inputTokens, 100); assert.equal(ok.outputTokens, 20);
  const normal = JSON.parse(visionResponse('{}').body);
  for (const body of ['{', 'null', '[]',
    JSON.stringify({ ...normal, model: 'other' }), JSON.stringify({ ...normal, object: 'chat.completion.chunk' }),
    JSON.stringify({ ...normal, choices: [] }), JSON.stringify({ ...normal, choices: [{ index: 0, message: { role: 'assistant', content: '' }, finish_reason: 'stop' }] }),
    JSON.stringify({ ...normal, choices: [{ index: 0, message: { role: 'assistant', content: '{}' }, finish_reason: 'length' }] }),
    JSON.stringify({ ...normal, choices: [{ index: 0, message: { role: 'assistant', content: '{}', tool_calls: [] }, finish_reason: 'stop' }] }),
    JSON.stringify({ ...normal, usage: null }), JSON.stringify({ ...normal, usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 99 } })
  ]) assert.throws(() => visionProtocol.parseVisionChatResponse(200, body, 'test-model'));
  assert.throws(() => visionProtocol.parseVisionChatResponse(401, 'private body', 'test-model'),
    error => error.code === 'AUTHENTICATION' && !error.message.includes('private'));
});

test('vision context freezes only bounded sanitized image evidence and fails closed', () => {
  const context = new visionSupport.VisionAnswerContext();
  assert(context.freeze('图里有什么？', visionImage()));
  const snapshot = context.snapshotFor('图里有什么？');
  assert(snapshot); assert.equal(snapshot.image.mime, 'image/jpeg'); assert.equal(snapshot.image.bytes.length, 4);
  assert.equal(context.snapshotFor('另一个问题'), undefined);
  context.clear(); assert.equal(context.snapshotFor('图里有什么？'), undefined);
  const bad = new visionSupport.VisionAnswerContext();
  for (const image of [visionImage({ mime: 'image/gif' }), visionImage({ bytes: new Uint8Array(0) }),
    visionImage({ sha256: 'bad' }), visionImage({ width: 0 }), visionImage({ width: 8193 })]) {
    assert.equal(bad.freeze('问题', image), false);
  }
  assert.match(context.systemPrompt(), /不可信数据/); assert.match(context.systemPrompt(), /资料中没有足够依据/);
});

function visionJournalBackend() {
  const h = { value: undefined, fail: false };
  h.port = { async initialize() {}, async load() { return h.value; }, async compareAndSet(rev, next) {
    if (h.fail || rev !== (h.value?.revision || 0)) return false;
    h.value = structuredClone(next); return true;
  } }; return h;
}
function liveVisionHarness(options = {}) {
  const backend = visionJournalBackend(); const trace = { requests: [], prepares: 0, cancels: 0,
    opened: 0, closed: 0, rejected: 0 };
  let journal;
  const prepared = new visionPorts.VisionPreparedImage();
  prepared.displayName = 'screen.jpg'; prepared.image = visionImage();
  const preparer = { async prepare(uri, displayName) {
    trace.prepares++;
    if (options.prepareFail) throw new visionPorts.VisionImageFailure('IMAGE_HEADER_INVALID');
    assert.equal(uri, 'file:///user/screen.jpg'); assert.equal(displayName, 'screen.jpg');
    return prepared;
  } };
  class Resource {
    closed = false;
    async open() {
      trace.opened++; journal = new visionStore.KnowledgeAnswerExecutionStore(backend.port, new AgentHostDigest(), visionPolicy());
      await journal.open();
    }
    async close() { if (!this.closed) trace.closed++; this.closed = true; }
    saveCheckpoint(...args) { return journal.saveCheckpoint(...args); }
    loadCheckpoint(...args) { return journal.loadCheckpoint(...args); }
    beforeDispatch(...args) { return journal.beforeDispatch(...args); }
    async recordOutcome(...args) {
      try {
        if (options.failOutcome) { backend.fail = true; }
        const result = await journal.recordOutcome(...args);
        if (!result.accepted && !result.duplicate) { trace.rejected++; this.onOutcomeRejected(args[0]); }
        return result;
      } catch (error) { this.onOutcomeRejected(args[0]); throw error; }
    }
    recordDispatchRejected(...args) { return journal.recordDispatchRejected(...args); }
    normalizeRecoveredOperation(...args) { return journal.normalizeRecoveredOperation(...args); }
    recordReconciliation(...args) { return journal.recordReconciliation(...args); }
  }
  const transport = {
    start(request, cancellation) {
      trace.requests.push(request);
      if (options.gate) return { result: options.gate.promise, cancel() { trace.cancels++; } };
      const text = options.texts ? options.texts[Math.min(trace.requests.length - 1, options.texts.length - 1)] :
        (options.text || '{"answer":"图中写着 Runtime [1]","citations":[1]}');
      const result = options.fail ? Promise.reject(new Error('private provider failure')) : Promise.resolve(visionResult(text));
      return { result, cancel() { trace.cancels++; } };
    }
  };
  const assembly = load(path.join(services, 'VisionAnswerRuntimeAssembly.ets'), {
    './KnowledgeAnswerExecutionStore': { ...visionStore, KnowledgeAnswerExecutionResource: Resource }
  });
  const ui = new RuntimeVisionSession(preparer); ui.onForeground();
  const factory = new assembly.VisionAnswerRuntimeFactory({}, true, ui.answerContext, 'test-model',
    (taskId) => ui.answerOutcomeRejected(taskId), transport);
  return { ui, factory, trace, prepared, backend, gate: options.gate, async start(consent = true) {
    const key = new TextEncoder().encode('test-only-key');
    await ui.start(factory, key, consent);
    if (consent) assert.equal(ui.snapshot().lifecycle, ShuviRuntimeState.READY, ui.snapshot().message);
    assert(key.every(value => value === 0), 'vision session must consume the key');
  }, async attach() {
    assert.equal(await ui.attachImage('file:///user/screen.jpg', 'screen.jpg'), true);
    assert.equal(ui.snapshot().imageReady, true);
  } };
}
async function waitVision(ui, predicate = view => !view.busy) {
  for (let i = 0; i < 300; i++) { if (predicate(ui.snapshot())) return; await new Promise(resolve => setTimeout(resolve, 2)); }
  assert.fail('Vision state did not arrive: ' + JSON.stringify(ui.snapshot()));
}
test('vision session sends one image question only after consent and attachment', async () => {
  const h = liveVisionHarness(); assert.equal(await h.ui.start(h.factory, new TextEncoder().encode('key'), false), undefined);
  assert.equal(h.ui.snapshot().lifecycle, ShuviRuntimeState.IDLE); assert.equal(h.trace.requests.length, 0);
  await h.start(); await h.attach();
  assert.equal(h.ui.snapshot().imageName, 'screen.jpg'); assert.equal(h.ui.snapshot().imageBytes, 4);
  assert.equal(h.ui.snapshot().pricingState, 'unverified'); assert.equal(h.ui.snapshot().maxRequests, 10);
  assert.equal(await h.ui.send('图里写着什么？'), true); await waitVision(h.ui);
  const view = h.ui.snapshot();
  assert.equal(view.stage, 'complete', JSON.stringify(view)); assert.equal(view.answer, '图中写着 Runtime [1]');
  assert.equal(h.trace.requests.length, 1); assert.equal(h.trace.requests[0].image.bytes.length, 4);
  assert.equal(h.trace.requests[0].question, '图里写着什么？');
  assert(!JSON.stringify(h.trace.requests[0]).includes('screen.jpg'));
  await h.ui.stop();
  assert.equal(h.ui.snapshot().imageReady, false); assert.equal(h.ui.snapshot().answer, '图中写着 Runtime [1]');
  assert.equal(h.prepared.image.bytes.every(value => value === 0), true);
});

test('vision session keeps the image for retry and maps insufficient/invalid output to non-success', async () => {
  const invalid = liveVisionHarness({ text: '{"answer":"没有引用","citations":[1]}' }); await invalid.start(); await invalid.attach();
  await invalid.ui.send('问题'); await waitVision(invalid.ui);
  assert.equal(invalid.ui.snapshot().stage, 'answerFailed'); assert.equal(invalid.ui.snapshot().imageReady, true);
  assert.equal(invalid.trace.prepares, 1);
  await invalid.ui.stop();

  const insufficient = liveVisionHarness({ text: '{"answer":"资料中没有足够依据","citations":[]}' });
  await insufficient.start(); await insufficient.attach();
  await insufficient.ui.send('问题'); await waitVision(insufficient.ui);
  assert.equal(insufficient.ui.snapshot().stage, 'insufficient'); assert.equal(insufficient.ui.snapshot().answer, '');
  assert.equal(insufficient.ui.snapshot().imageReady, true);
  await insufficient.ui.stop();

  const retry = liveVisionHarness({ texts: ['{"answer":"没有引用","citations":[1]}',
    '{"answer":"重试后依据图片回答 [1]","citations":[1]}'] });
  await retry.start(); await retry.attach();
  await retry.ui.send('问题'); await waitVision(retry.ui);
  assert.equal(retry.ui.snapshot().stage, 'answerFailed');
  await retry.ui.retryAnswer(); await waitVision(retry.ui);
  assert.equal(retry.ui.snapshot().stage, 'complete'); assert.match(retry.ui.snapshot().answer, /重试后/);
  assert.equal(retry.trace.prepares, 1); assert.equal(retry.trace.requests.length, 2);
  await retry.ui.stop();
});

test('vision session failure, persistence rejection and image failure never become success', async () => {
  const failed = liveVisionHarness({ fail: true }); await failed.start(); await failed.attach();
  await failed.ui.send('问题'); await waitVision(failed.ui);
  assert.equal(failed.ui.snapshot().stage, 'answerFailed'); assert.equal(failed.ui.snapshot().answer, '');
  await failed.ui.stop();

  const rejected = liveVisionHarness({ failOutcome: true }); await rejected.start(); await rejected.attach();
  await rejected.ui.send('问题'); await waitVision(rejected.ui);
  assert.equal(rejected.ui.snapshot().stage, 'answerFailed'); assert.equal(rejected.trace.rejected, 1);
  await rejected.ui.stop();

  const badImage = liveVisionHarness({ prepareFail: true }); await badImage.start();
  assert.equal(await badImage.ui.attachImage('file:///user/bad.png', 'bad.png'), false);
  assert.equal(badImage.ui.snapshot().stage, 'imageFailed'); assert.equal(badImage.trace.requests.length, 0);
  await badImage.ui.stop();
});

test('vision answer execution resource uses its own encrypted database and step', async () => {
  const h = rdbHarness();
  const resource = new visionStore.KnowledgeAnswerExecutionResource(h.opener, new AgentHostDigest(), visionPolicy());
  await resource.open();
  assert.equal(h.opens[0].name, 'shuvi_vision_answer_v1.db'); assert.equal(h.opens[0].encrypt, true);
  await resource.close();
});

const { ArkTsVisionChatTransport } = load(path.join(services, 'VisionChatTransport.ets'));
function visionTransportHarness(options = {}) {
  const sent = []; let cancelled = 0; let resolves = 0;
  const http = { start(request) {
    sent.push(request);
    if (options.gate) return { result: options.gate.promise, cancel() { cancelled++; } };
    return { result: Promise.resolve(options.response || visionResponse('{"answer":"图中有文字 [1]","citations":[1]}')),
      cancel() { cancelled++; } };
  } };
  const credentials = { async resolve(provider, scope) {
    resolves++; assert.equal(provider, 'deepseek-direct'); assert.equal(scope, 'deepseek.invoke');
    if (options.credentialError) throw new Error('private credential detail');
    if (options.headers) return { headers: options.headers };
    return { headers: { Authorization: 'Bearer test-only-key' } };
  } };
  return { sent, http, credentials, get cancelled() { return cancelled; }, get resolves() { return resolves; },
    transport: new ArkTsVisionChatTransport(http, credentials) };
}
test('vision transport sends sanitized image bytes through the session HTTP boundary', async () => {
  const h = visionTransportHarness(); const cancellation = new connectors.ProviderCancellationSource();
  const result = await h.transport.start(visionRequest(), cancellation).result;
  assert.equal(result.outputText, '{"answer":"图中有文字 [1]","citations":[1]}');
  assert.equal(h.sent.length, 1); assert.equal(h.sent[0].authorization, 'Bearer test-only-key');
  assert(h.sent[0].body.includes('data:image/jpeg;base64,AQID'));
  assert(!h.sent[0].body.includes('screen.jpg'));
  assert.equal(h.sent[0].maxResponseBytes, visionProtocol.VISION_CHAT_MAX_RESPONSE_BYTES);
});
test('vision transport rejects bad credentials and malformed responses before success', async () => {
  for (const headers of [{}, { authorization: 'Bearer test' }, { Authorization: 'Bearer a b' },
    { Authorization: 'Bearer test', Other: 'x' }]) {
    const h = visionTransportHarness({ headers });
    await assert.rejects(h.transport.start(visionRequest(), new connectors.ProviderCancellationSource()).result,
      error => error.code === 'AUTHENTICATION');
    assert.equal(h.sent.length, 0);
  }
  const bad = visionTransportHarness({ response: { statusCode: 200, body: '{"object":"other"}' } });
  await assert.rejects(bad.transport.start(visionRequest(), new connectors.ProviderCancellationSource()).result,
    error => error.code === 'PROVIDER');
});
test('vision transport cancellation is idempotent and discards a late result', async () => {
  const gate = deferred(); const h = visionTransportHarness({ gate });
  const cancellation = new connectors.ProviderCancellationSource();
  const operation = h.transport.start(visionRequest(), cancellation);
  for (let i = 0; i < 50 && h.sent.length === 0; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.sent.length, 1);
  operation.cancel(); operation.cancel();
  gate.resolve(visionResponse('{"answer":"late [1]","citations":[1]}'));
  await assert.rejects(operation.result, error => error.code === 'CANCELLED');
  assert.equal(h.cancelled, 1);
});

test('vision answer config is PERSONAL with no tools, retries or replans', () => {
  const config = visionAssembly.visionAnswerFrontendConfig();
  assert.equal(config.privacyClass, contracts.PrivacyClass.PERSONAL);
  assert.equal(config.requestedBudget.maxToolCalls, 0);
  assert.equal(config.requestedBudget.maxRetries, 0);
  assert.equal(config.requestedBudget.maxReplans, 0);
  assert.equal(config.requestedBudget.maxMonetaryCostMicros, 10000);
});

test('vision cancel while the transport is pending discards the late result', async () => {
  const gate = deferred(); const h = liveVisionHarness({ gate }); await h.start(); await h.attach();
  const sending = h.ui.send('问题');
  for (let i = 0; i < 100 && h.trace.requests.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
  assert.equal(h.trace.requests.length, 1);
  await h.ui.cancelCurrent();
  gate.resolve(visionResult('{"answer":"迟到回答 [1]","citations":[1]}'));
  await sending; await waitVision(h.ui);
  assert.equal(h.ui.snapshot().stage, 'answerFailed'); assert.equal(h.ui.snapshot().answer, '');
  assert(h.trace.cancels >= 1); await h.ui.stop();
});

test('vision stop while the transport is pending clears the image and ignores the late result', async () => {
  const gate = deferred(); const h = liveVisionHarness({ gate }); await h.start(); await h.attach();
  const sending = h.ui.send('问题');
  for (let i = 0; i < 100 && h.trace.requests.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 2));
  assert.equal(h.trace.requests.length, 1);
  await h.ui.stop();
  gate.resolve(visionResult('{"answer":"迟到回答 [1]","citations":[1]}'));
  await sending;
  const view = h.ui.snapshot();
  assert.equal(view.lifecycle, ShuviRuntimeState.STOPPED); assert.equal(view.imageReady, false);
  assert.equal(view.answer, '');
});

test('vision session stops after ten model requests without reporting an eleventh success', async () => {
  const h = liveVisionHarness(); await h.start(); await h.attach();
  for (let i = 0; i < 10; i++) {
    assert.equal(await h.ui.send('问题 ' + i), true); await waitVision(h.ui);
    assert.equal(h.ui.snapshot().stage, 'complete', JSON.stringify(h.ui.snapshot()));
  }
  assert.equal(h.trace.requests.length, 10);
  assert.equal(await h.ui.send('第十一次'), false);
  assert.match(h.ui.snapshot().message, /请求上限/);
  assert.equal(h.ui.snapshot().requestCount, 10); assert.equal(h.ui.snapshot().maxRequests, 10);
  assert.equal(h.trace.requests.length, 10);
  await h.ui.stop();
});

test('vision start failure clears consent but preserves the selected image', async () => {
  const prepared = new visionPorts.VisionPreparedImage();
  prepared.displayName = 'screen.jpg'; prepared.image = visionImage();
  const preparer = { async prepare() { return prepared; } };
  const ui = new RuntimeVisionSession(preparer); ui.onForeground();
  assert.equal(await ui.attachImage('file:///user/screen.jpg', 'screen.jpg'), true);
  const key = new TextEncoder().encode('test-only-key');
  await ui.start({ create() { throw new Error('injected-configuration-failure'); } }, key, true);
  const view = ui.snapshot();
  assert.equal(view.lifecycle, ShuviRuntimeState.FAILED);
  assert.equal(view.consent, false); assert.equal(view.imageReady, true);
  assert.equal(view.imageName, 'screen.jpg'); assert(key.every(value => value === 0));
  await ui.stop(); assert.equal(ui.snapshot().imageReady, false);
});
