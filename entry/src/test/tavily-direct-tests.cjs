'use strict';
// Phone-direct Tavily search: the in-app web_search manager, its HTTPS client and the Tavily key record.
// Fake HTTPS and fake keys only; no real credentials or network requests.
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { test } = require('node:test');

module.exports = function ({ load, root, services, digest, deferred, liveSearchHarness, waitSearch, authorizeSearch,
  setNativeFactory, loadDeepSeekKeyStore, ShuviRuntimeState }) {
  const direct = load(path.join(services, 'DirectTavilySearch.ets'));
  const tavilyHttp = load(path.join(services, 'TavilyHttpClient.ets'));
  const { readSearchUsage } = load(path.join(services, 'SearchUsageReceipts.ets'));
  const searchSupport = load(path.join(services, 'SearchTaskSupport.ets'));
  const connectors = load(path.join(root, 'modules/harmony_agent/agent_connectors/Index.ets'));
  const mcp = load(path.join(root, 'modules/harmony_agent/mcp_client/Index.ets'));
  const KEY = 'tvly-test-only-not-a-real-key';
  const ref = { serverId: 'shuvi-web-search', kind: mcp.McpCapabilityKind.TOOL, name: 'web_search' };

  function keys(text = KEY) {
    const h = { text, loads: 0, copies: [] };
    h.port = {
      async status() { return h.text == null ? 'Missing' : 'Saved'; },
      async load() {
        h.loads++; if (h.text == null) return undefined;
        const copy = new TextEncoder().encode(h.text); h.copies.push(copy); return copy;
      }
    };
    return h;
  }
  function item(title, url, content) { return { title, url, content, score: 0.9, raw_content: null }; }
  function body(results, extra = {}) {
    return JSON.stringify(Object.assign({ query: 'ignored', answer: null, images: [], results,
      response_time: 0.4, usage: { credits: 1 }, request_id: 'req-123_abc' }, extra));
  }
  const ok = () => ({ statusCode: 200, body: body([item('Official documentation',
    'https://developer.huawei.com/consumer/cn/arkui', 'Declarative UI documentation.')]) });
  function http(respond = ok) {
    const h = { requests: [], cancelled: 0 };
    h.port = { start(request) {
      h.requests.push(Object.assign({}, request));
      let fail;
      const result = new Promise((resolve, reject) => { fail = reject; Promise.resolve(respond(request)).then(resolve, reject); });
      return { result, cancel() { h.cancelled++; fail(new tavilyHttp.TavilyTransportError('CANCELLED')); } };
    } };
    return h;
  }
  function allowAll(seen) { return { async authorize(context) { seen.push(structuredClone(context)); return { allowed: true }; } }; }
  async function connected(options = {}) {
    const seen = []; const k = options.keys || keys(); const h = options.http || http();
    const manager = new direct.DirectTavilySearchManager({ invocationPolicy: options.policy || allowAll(seen) }, h.port, k.port);
    const config = new connectors.ShuviWebSearchMcpConfig();
    config.endpoint = 'https://api.tavily.com/search'; config.allowInsecureHttp = false;
    const providers = new connectors.McpProviderRegistry(digest); const policies = new connectors.McpReadOnlyToolPolicyRegistry();
    if (options.connect !== false) await connectors.connectShuviWebSearchMcp(manager, providers, policies, config);
    // The production adapter wraps the manager in the contract-validating port; tests use the same wrapper.
    const port = new connectors.ShuviWebSearchMcpClientToolPort(new connectors.McpClientManagerToolPort(manager));
    return { manager, port, keys: k, http: h, seen, config, providers, policies };
  }
  const neverCancelled = { isCancellationRequested() { return false; }, subscribe() { return { dispose() {} }; } };

  test('in-app web_search passes the connection contract only when a Tavily key is saved', async () => {
    const missing = await connected({ keys: keys(null), connect: false });
    await assert.rejects(connectors.connectShuviWebSearchMcp(missing.manager, missing.providers, missing.policies, missing.config),
      error => error.code === 'CONFIGURATION' && error.requestDispatched === false);
    assert.equal(missing.manager.getConnections().length, 0, 'a failed connect unregisters the server');
    assert.equal(missing.http.requests.length, 0);
    const h = await connected();
    assert.deepEqual(h.manager.getConnections().map(item => item.state), ['ready']);
    const tools = await h.manager.listTools();
    assert.equal(tools.items.length, 1); assert.equal(tools.items[0].name, 'web_search');
    assert.equal(h.keys.loads, 0, 'connecting checks status only and never reads the secret');
    assert.throws(() => h.manager.registerServer({ id: 'other', endpoint: 'https://example.com/mcp' }), /Only web search/);
  });

  test('one consented call sends one bounded HTTPS request with the phone key and returns the validated envelope', async () => {
    const h = await connected();
    const result = await h.port.callTool(ref, { query: '  ArkUI 官方文档  ', maxResults: 3 }, neverCancelled);
    assert.equal(h.http.requests.length, 1);
    const sent = h.http.requests[0];
    assert.equal(sent.authorization, 'Bearer ' + KEY);
    assert.deepEqual(JSON.parse(sent.body), { query: 'ArkUI 官方文档', max_results: 3, search_depth: 'basic', topic: 'general',
      auto_parameters: false, include_answer: false, include_raw_content: false, include_images: false, include_usage: true });
    assert.equal(sent.timeoutMs, 15000); assert.equal(sent.maxResponseBytes, 1048576);
    assert(h.keys.copies.every(copy => copy.every(byte => byte === 0)), 'the loaded key copy is cleared after use');
    assert.equal(result.isError, false);
    assert.equal(result.structuredContent.query, 'ArkUI 官方文档'); assert.equal(result.structuredContent.provider, 'tavily');
    assert.deepEqual(result.structuredContent.results, [{ title: 'Official documentation',
      url: 'https://developer.huawei.com/consumer/cn/arkui', snippet: 'Declarative UI documentation.' }]);
    assert.doesNotMatch(JSON.stringify(result), new RegExp(KEY));
    const usage = readSearchUsage(result);
    assert.equal(usage.state, 'known'); assert.equal(usage.credits, 1); assert.equal(usage.providerRequestId, 'req-123_abc');
    assert.equal(h.seen.length, 1, 'every call asks the invocation policy first');
    assert.equal(h.seen[0].profile.endpoint, 'https://api.tavily.com/search');
    assert.deepEqual(h.seen[0].arguments, { query: '  ArkUI 官方文档  ', maxResults: 3 });
  });

  test('only safe sources survive: titles trimmed, snippets bounded, count capped', async () => {
    const response = { statusCode: 200, body: body([
      item('  Title A  ', 'https://a.example.com/x', 'a'), item('Local', 'http://127.0.0.1/', 'b'),
      item('File', 'file:///etc/passwd', 'c'), item('   ', 'https://b.example.com/', 'd'),
      item('Credential', 'https://user:pass@c.example.com/', 'e'), item('At query', 'https://c.example.com?ref=a@b', 'e'),
      item('At fragment', 'https://c.example.com#@x', 'e'),
      item('T'.repeat(600), 'https://d.example.com/', '长'.repeat(9000)), item('Extra', 'https://e.example.com/', 'f')]) };
    const result = direct.tavilySearchResult({ query: 'q', maxResults: 2 }, response, crypto.randomUUID(), new Date().toISOString());
    assert.equal(result.isError, false);
    assert.deepEqual(result.structuredContent.results.map(source => source.title), ['Title A', 'T'.repeat(200)]);
    assert.equal(result.structuredContent.results[1].snippet.length, 300);
    assert.notEqual(searchSupport.parseLiveSearch(JSON.stringify(result.structuredContent), 'q'), undefined);
    // The same result also passes the contract-validating port (it rejects any '@' before the first '/').
    const port = new connectors.ShuviWebSearchMcpClientToolPort({ async listTools() { return { items: [], errors: [] }; },
      async callTool() { return result; } });
    await port.callTool(ref, { query: 'q', maxResults: 2 }, neverCancelled);
    const oddId = direct.tavilySearchResult({ query: 'q', maxResults: 3 }, { statusCode: 200,
      body: body([], { request_id: 'bad id with spaces' }) }, crypto.randomUUID(), new Date().toISOString());
    assert.equal(readSearchUsage(oddId).state, 'unknown', 'an odd provider request id makes usage untrusted');
    const empty = direct.tavilySearchResult({ query: 'q', maxResults: 3 }, { statusCode: 200, body: body([], { usage: undefined }) },
      crypto.randomUUID(), new Date().toISOString());
    assert.deepEqual(empty.structuredContent.results, []); assert.equal(readSearchUsage(empty).state, 'unknown');
  });

  test('provider failures become tool errors without forwarding provider bodies', async () => {
    const cases = [[401, 'AUTHENTICATION'], [403, 'AUTHENTICATION'], [429, 'RATE_LIMITED'], [432, 'QUOTA_EXCEEDED'],
      [433, 'QUOTA_EXCEEDED'], [500, 'UPSTREAM'], [302, 'UPSTREAM']];
    for (const [statusCode, code] of cases) {
      const result = direct.tavilySearchResult({ query: 'q', maxResults: 3 }, { statusCode, body: 'private provider body' },
        crypto.randomUUID(), new Date().toISOString());
      assert.equal(result.isError, true); assert.equal(result.structuredContent.error.code, code, String(statusCode));
      assert.doesNotMatch(JSON.stringify(result), /private provider body/);
    }
    for (const text of ['not json', '{"results":"x"}', '[]']) {
      const result = direct.tavilySearchResult({ query: 'q', maxResults: 3 }, { statusCode: 200, body: text },
        crypto.randomUUID(), new Date().toISOString());
      assert.equal(result.structuredContent.error.code, 'INVALID_RESPONSE', text);
    }
    for (const code of ['TIMEOUT', 'NETWORK', 'RESPONSE_TOO_LARGE', 'INVALID_RESPONSE']) {
      const h = await connected({ http: http(() => Promise.reject(new tavilyHttp.TavilyTransportError(code))) });
      const result = await h.port.callTool(ref, { query: 'q', maxResults: 3 }, neverCancelled);
      assert.equal(result.isError, true); assert.equal(result.structuredContent.error.code, code);
      assert.equal(h.http.requests.length, 1, 'no automatic retry');
    }
  });

  test('nothing is sent without a policy ticket, a saved key, valid arguments or a live connection', async () => {
    const denied = await connected({ policy: { async authorize() { return { allowed: false, reason: 'no ticket' }; } } });
    await assert.rejects(denied.port.callTool(ref, { query: 'q' }, neverCancelled),
      error => error.code === 'POLICY_DENIED' && error.requestDispatched === false);
    const failing = await connected({ policy: { async authorize() { throw new Error('policy down'); } } });
    await assert.rejects(failing.port.callTool(ref, { query: 'q' }, neverCancelled), error => error.code === 'POLICY_DENIED');
    const unkeyed = await connected(); unkeyed.keys.text = undefined;
    await assert.rejects(unkeyed.port.callTool(ref, { query: 'q' }, neverCancelled),
      error => error.code === 'CONFIGURATION' && error.requestDispatched === false);
    const h = await connected();
    await assert.rejects(h.manager.callTool(ref, { query: 'q', extra: 1 }, neverCancelled), error => error.code === 'INVALID_ARGUMENT');
    await assert.rejects(h.manager.callTool(Object.assign({}, ref, { name: 'other' }), { query: 'q' }, neverCancelled),
      error => error.code === 'CONFIGURATION' && error.requestDispatched === false);
    const early = { isCancellationRequested() { return true; }, subscribe() { return { dispose() {} }; } };
    await assert.rejects(h.manager.callTool(ref, { query: 'q' }, early), error => error.code === 'CANCELLED' && error.requestDispatched === false);
    await h.manager.disconnectAll();
    await assert.rejects(h.manager.callTool(ref, { query: 'q' }, neverCancelled), error => error.code === 'CONFIGURATION');
    for (const value of [denied, failing, unkeyed, h]) assert.equal(value.http.requests.length, 0);
  });

  test('unregistering while the key is being read stops the send', async () => {
    const gate = deferred(); const k = keys(); const load = k.port.load;
    k.port.load = async () => { await gate.promise; return load(); };
    const h = await connected({ keys: k });
    const pending = h.manager.callTool(ref, { query: 'q' }, neverCancelled);
    await new Promise(resolve => setTimeout(resolve, 2));
    await h.manager.unregisterServer('shuvi-web-search'); gate.resolve();
    await assert.rejects(pending, error => error.code === 'CANCELLED' && error.requestDispatched === false);
    assert.equal(h.http.requests.length, 0);
  });

  test('cancelling or disconnecting aborts the in-flight request without a retry', async () => {
    const gate = deferred();
    const h = await connected({ http: http(() => gate.promise) });
    const source = new mcp.McpCancellationSource();
    const pending = h.manager.callTool(ref, { query: 'q' }, source);
    for (let i = 0; i < 50 && h.http.requests.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 1));
    source.cancel();
    const cancelled = await pending;
    assert.equal(cancelled.structuredContent.error.code, 'CANCELLED'); assert.equal(h.http.cancelled, 1);
    const second = h.manager.callTool(ref, { query: 'q' }, neverCancelled);
    for (let i = 0; i < 50 && h.http.requests.length < 2; i++) await new Promise(resolve => setTimeout(resolve, 1));
    await h.manager.disconnectAll();
    assert.equal((await second).structuredContent.error.code, 'CANCELLED');
    gate.resolve(ok()); assert.equal(h.http.requests.length, 2);
  });

  test('native Tavily HTTPS: fixed origin, no redirects or cache, bounded, error bodies dropped', async () => {
    function harness() {
      const status = deferred(); const handlers = {}; let destroyed = 0; let sent;
      setNativeFactory(() => ({ on(event, callback) { handlers[event] = callback; }, destroy() { destroyed++; },
        requestInStream(endpoint, options) { sent = { endpoint, options }; return status.promise; } }));
      const input = Object.assign(new tavilyHttp.TavilyHttpRequest(), { authorization: 'Bearer ' + KEY, body: '{}',
        connectTimeoutMs: 5, timeoutMs: 100, maxResponseBytes: 16 });
      const data = text => handlers.dataReceive(new TextEncoder().encode(text).buffer);
      return { input, handlers, data, status, get sent() { return sent; }, get destroyed() { return destroyed; } };
    }
    let h = harness(); let op = new tavilyHttp.ArkTsTavilyHttpClient().start(h.input);
    assert.equal(h.sent.endpoint, 'https://api.tavily.com/search');
    assert.equal(h.sent.options.maxRedirects, 0); assert.equal(h.sent.options.usingCache, false);
    assert.equal(h.sent.options.header.Authorization, 'Bearer ' + KEY);
    h.data('{"results":[]}'); h.handlers.dataEnd(); h.status.resolve(200);
    assert.equal((await op.result).body, '{"results":[]}'); assert.equal(h.destroyed, 1);
    h = harness(); op = new tavilyHttp.ArkTsTavilyHttpClient().start(h.input);
    h.status.resolve(401); await Promise.resolve(); h.data('private body'); h.handlers.dataEnd();
    const failed = await op.result; assert.equal(failed.statusCode, 401); assert.equal(failed.body, '');
    h = harness(); op = new tavilyHttp.ArkTsTavilyHttpClient().start(h.input); h.data('x'.repeat(17));
    await assert.rejects(op.result, error => error.code === 'RESPONSE_TOO_LARGE');
    h = harness(); op = new tavilyHttp.ArkTsTavilyHttpClient().start(h.input); op.cancel();
    await assert.rejects(op.result, error => error.code === 'CANCELLED'); assert.equal(h.destroyed, 1);
    h = harness(); op = new tavilyHttp.ArkTsTavilyHttpClient().start(h.input); h.status.reject({ code: 2300028, message: 'private' });
    await assert.rejects(op.result, error => error.code === 'TIMEOUT' && !error.message.includes('private'));
    h = harness(); h.input.authorization = 'Bearer bad key';
    assert.throws(() => new tavilyHttp.ArkTsTavilyHttpClient().start(h.input), error => error.code === 'CONFIGURATION');
    setNativeFactory(() => { throw new Error('Network is not available in host tests'); });
  });

  test('the Tavily key is its own device-only record and never touches the DeepSeek key', async () => {
    const { asset, backend, DeepSeekCredentialStore, DeepSeekKeyStatus, TAVILY_KEY_ALIAS, DEEPSEEK_KEY_ALIAS } = loadDeepSeekKeyStore();
    const tavily = new DeepSeekCredentialStore(backend, TAVILY_KEY_ALIAS); const deepSeek = new DeepSeekCredentialStore(backend);
    await tavily.save(new TextEncoder().encode(KEY));
    assert.equal(await tavily.status(), DeepSeekKeyStatus.Saved); assert.equal(await deepSeek.status(), DeepSeekKeyStatus.Missing);
    const row = backend.rows.get(TAVILY_KEY_ALIAS);
    assert.equal(row.get(asset.Tag.SYNC_TYPE), asset.SyncType.NEVER);
    assert.equal(row.get(asset.Tag.ACCESSIBILITY), asset.Accessibility.DEVICE_UNLOCKED);
    assert.equal(backend.rows.has(DEEPSEEK_KEY_ALIAS), false);
    assert.equal(new TextDecoder().decode(await tavily.load()), KEY);
    await tavily.remove(); assert.equal(await tavily.status(), DeepSeekKeyStatus.Missing);
  });

  test('phone-direct search runs through the real grant, policy ticket and durable record, and can search again', async () => {
    const k = keys(); const h = http();
    const harness = liveSearchHarness({ direct: { http: h.port, keys: k.port } }); await harness.start();
    try {
      await authorizeSearch(harness); await waitSearch(harness.ui, view => !view.busy);
      assert.equal(harness.ui.snapshot().stage, 'complete', harness.ui.snapshot().message);
      assert.equal(h.requests.length, 1); assert.equal(harness.trace.models, 1);
      assert.equal(harness.ui.snapshot().sources[0].url, 'https://developer.huawei.com/consumer/cn/arkui');
      assert.match(harness.ui.snapshot().answer, /\[1\]/);
      const stored = harness.dbs.search.envelope.payloadJson;
      assert.doesNotMatch(stored, new RegExp(KEY), 'the key never reaches the execution record');
      const operation = JSON.parse(stored).operations[0];
      assert.equal(operation.pendingInvoice.usageState, 'known'); assert.equal(operation.pendingInvoice.credits, 1);
      assert.equal(harness.ui.snapshot().allowance, true);
      assert.equal(await harness.ui.send('next query'), true); await waitSearch(harness.ui, view => view.preview !== undefined);
      assert.equal(h.requests.length, 1, 'the next search waits for its own consent'); await harness.ui.decide(true);
      await waitSearch(harness.ui, view => !view.busy); assert.equal(h.requests.length, 2);
      assert.equal(JSON.parse(h.requests[1].body).query, 'next query');
    } finally { await harness.ui.stop(); }
  });

  test('without a saved Tavily key the search session does not start and says where to save it', async () => {
    const h = http(); const harness = liveSearchHarness({ direct: { http: h.port, keys: keys(null).port } });
    await harness.ui.start(harness.factory, harness.answerFactory, new TextEncoder().encode('test-only-key'));
    assert.equal(harness.ui.snapshot().lifecycle, ShuviRuntimeState.FAILED);
    assert.match(harness.ui.snapshot().message, /Tavily Key/);
    assert.equal(await harness.ui.send('q'), false); assert.equal(h.requests.length, 0);
    await harness.ui.stop();
  });

  test('the single-row record stays readable: new searches stop near the size limit and no write passes it', async () => {
    const resource = load(path.join(services, 'SearchExecutionResource.ets'));
    assert.equal(resource.utf8Length('a长😀'), 1 + 3 + 4);
    const harness = liveSearchHarness(); await harness.start();
    try {
      const measured = harness.factory.execution.measured;
      assert(measured.bytes < 100000, 'a fresh store is small');
      await authorizeSearch(harness); await waitSearch(harness.ui, view => !view.busy);
      assert.equal(measured.bytes, Buffer.byteLength(harness.dbs.search.envelope.payloadJson));
      measured.bytes = resource.SEARCH_STORE_SOFT_LIMIT_BYTES;
      assert.equal(harness.factory.available(), false);
      const envelope = harness.dbs.search.envelope;
      await assert.rejects(measured.compareAndSet(envelope.revision, Object.assign({}, envelope,
        { revision: envelope.revision + 1, payloadJson: '长'.repeat(resource.SEARCH_STORE_HARD_LIMIT_BYTES / 3 + 1) })),
        /SEARCH_STORE_TOO_LARGE/);
      assert.equal(harness.dbs.search.envelope, envelope, 'the oversized row was never written');
      await harness.ui.send('same query'); await waitSearch(harness.ui, view => !view.busy);
      assert.equal(harness.ui.snapshot().stage, 'failed'); assert.match(harness.ui.snapshot().message, /搜索记录已满/);
      assert.equal(harness.trace.tools, 1);
    } finally { await harness.ui.stop(); }
  });

  test('a full search record store refuses a new search before anything is sent', async () => {
    const harness = liveSearchHarness(); await harness.start();
    try {
      const { SEARCH_HISTORY_LIMIT } = load(path.join(services, 'SearchExecutionResource.ets'));
      assert.equal(SEARCH_HISTORY_LIMIT, 128);
      harness.factory.execution.durable.listTaskIds = () => new Array(SEARCH_HISTORY_LIMIT).fill('task');
      assert.equal(harness.factory.available(), false);
      await harness.ui.send('same query'); await waitSearch(harness.ui, view => !view.busy);
      assert.equal(harness.ui.snapshot().stage, 'failed'); assert.equal(harness.ui.snapshot().allowance, false);
      assert.equal(harness.trace.tools, 0);
    } finally { await harness.ui.stop(); }
  });
};
