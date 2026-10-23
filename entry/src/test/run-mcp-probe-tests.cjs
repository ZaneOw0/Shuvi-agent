// Pure host checks with injected transports. No device, credentials or real network.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const sdk = process.env.DEVECO_SDK_HOME;
if (!sdk) throw new Error('Set DEVECO_SDK_HOME.');
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const services = path.resolve(__dirname, '../main/ets/services');
function load(name, imports = {}) {
  const source = fs.readFileSync(path.join(services, `${name}.ets`), 'utf8');
  const compiled = ts.transpileModule(source, {
    fileName: `${name}.ts`,
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', compiled)(id => {
    assert(Object.hasOwn(imports, id), `Unexpected import ${id}`);
    return imports[id];
  }, module, module.exports);
  return module.exports;
}
const sessionModule = load('McpProbeSession');
const { McpProbeSession, McpProbeState } = sessionModule;
const contractModule = load('McpProbeContract');
const { validSearchProbeSchema } = contractModule;
const input = {
  type: 'object', additionalProperties: false,
  properties: { query: { type: 'string' }, maxResults: { type: 'integer', minimum: 1, maximum: 10, default: 5 } },
  required: ['query']
};
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function harness(overrides = {}, enabled = true, timeoutMs = 15000) {
  const calls = [];
  const transport = {
    connect: async () => { calls.push('connect'); return '2025-11-25'; },
    discover: async () => { calls.push('discover'); },
    interrupt: async () => { calls.push('interrupt'); },
    close: async () => { calls.push('close'); },
    ...overrides
  };
  const session = new McpProbeSession({ create() { calls.push('create'); return transport; } }, enabled, timeoutMs);
  const states = [];
  session.attach(value => states.push(value));
  return { session, calls, states };
}

test('valid schema; malformed or incompatible discovery is rejected', () => {
  assert(validSearchProbeSchema(JSON.stringify(input)));
  for (const invalid of ['{', 'null', '[]', '"schema"', '{}',
    JSON.stringify({ ...input, required: ['query', 'maxResults'] }),
    JSON.stringify({ ...input, properties: { query: null, maxResults: {} } }),
    JSON.stringify({ ...input, additionalProperties: true }),
    JSON.stringify({ ...input, properties: { ...input.properties, extra: {} } })]) {
    assert.equal(validSearchProbeSchema(invalid), false, invalid);
  }
});
test('success is published after discovery and cleanup', async () => {
  const h = harness();
  await h.session.run();
  assert.deepEqual(h.calls, ['create', 'connect', 'discover', 'close']);
  assert.equal(h.states.at(-1).state, McpProbeState.Connected);
  assert.equal(h.states.at(-1).protocolVersion, '2025-11-25');
});
test('release guard does not construct a transport', async () => {
  const h = harness({}, false);
  await h.session.run();
  assert.deepEqual(h.calls, []);
  assert.equal(h.states.at(-1).state, McpProbeState.Failed);
});
test('connection failure cleans up and permits manual retry', async () => {
  let attempts = 0;
  const h = harness({ connect: async () => {
    if (++attempts === 1) throw new Error('NETWORK');
    return '2025-11-25';
  } });
  await h.session.run();
  assert.equal(h.states.at(-1).state, McpProbeState.Failed);
  await h.session.run();
  assert.equal(h.states.at(-1).state, McpProbeState.Connected);
  assert.equal(h.calls.filter(x => x === 'close').length, 2);
});
test('double click shares the existing operation', async () => {
  const gate = deferred();
  const h = harness({ connect: () => gate.promise });
  const first = h.session.run();
  await h.session.run();
  assert.equal(h.calls.filter(x => x === 'create').length, 1);
  gate.resolve('2025-11-25');
  await first;
});
test('cancellation during handshake suppresses discovery and closes late session', async () => {
  const gate = deferred();
  const h = harness({ connect: () => gate.promise });
  const running = h.session.run();
  h.session.cancel();
  gate.resolve('2025-11-25');
  await running;
  assert.deepEqual(h.calls, ['create', 'interrupt', 'close']);
  assert.equal(h.states.at(-1).state, McpProbeState.Cancelled);
});
test('leaving page detaches observer; reattaching sees cancelled state', async () => {
  const gate = deferred();
  const h = harness({ discover: () => gate.promise });
  const running = h.session.run();
  await Promise.resolve();
  const previous = h.states.length;
  h.session.detach();
  gate.resolve();
  await running;
  assert.equal(h.states.length, previous);
  h.session.attach(value => h.states.push(value));
  assert.equal(h.states.at(-1).state, McpProbeState.Cancelled);
});
test('timeout interrupts transport and reports timeout rather than success', async () => {
  const gate = deferred();
  const h = harness({
    connect: () => gate.promise,
    interrupt: async () => gate.reject(new Error('aborted'))
  }, true, 5);
  await h.session.run();
  assert.equal(h.states.at(-1).state, McpProbeState.Failed);
  assert.match(h.states.at(-1).message, /TIMEOUT/);
  assert(h.calls.includes('close'));
});
test('discovery or cleanup failure never reports success', async () => {
  for (const overrides of [
    { discover: async () => { throw new Error('SCHEMA_MISMATCH'); } },
    { close: async () => { throw new Error('close failed'); } }
  ]) {
    const h = harness(overrides);
    await h.session.run();
    assert.equal(h.states.at(-1).state, McpProbeState.Failed);
  }
});
test('cancelling during final cleanup does not start concurrent disconnect', async () => {
  const gate = deferred();
  const h = harness({ close: () => gate.promise });
  const running = h.session.run();
  await Promise.resolve();
  await Promise.resolve();
  h.session.cancel();
  gate.resolve();
  await running;
  assert(!h.calls.includes('interrupt'));
  assert.equal(h.states.at(-1).state, McpProbeState.Cancelled);
});

// Run the real adapter with a fake manager; assert the complete allowed call sequence.
function adapterHarness(debug, catalogError = false) {
  const calls = [];
  class FakeManager {
    constructor(options) { calls.push(['options', options]); }
    registerServer(profile) { calls.push(['register', profile]); }
    async connect() { calls.push(['connect']); return { state: 'ready', protocolVersion: '2025-11-25' }; }
    async listTools() {
      calls.push(['list']);
      return {
        errors: catalogError ? [{ code: 'NETWORK' }] : [],
        items: [{ name: 'web_search', ref: { serverId: 'shuvi-web-search', name: 'web_search', kind: 'tool' },
          inputSchema: input, outputSchema: { type: 'object' } }]
      };
    }
    async disconnect() { calls.push(['disconnect']); }
    async unregisterServer() { calls.push(['unregister']); }
    async callTool() { assert.fail('The probe must never call tools'); }
  }
  class FakeError extends Error {
    constructor(code, message) { super(message); this.code = code; }
  }
  const { McpConnectionCheckService } = load('McpConnectionCheckService', {
    BuildProfile: { DEBUG: debug },
    './McpProbeSession': sessionModule,
    './McpProbeContract': contractModule,
    '@harmony_agent/mcp-client': {
      McpClientManager: FakeManager, McpClientError: FakeError,
      McpErrorCode: { NETWORK: 'NETWORK', TIMEOUT: 'TIMEOUT', SCHEMA_MISMATCH: 'SCHEMA_MISMATCH' },
      McpProtocolMode: { LEGACY: 'legacy' }, McpConnectionState: { READY: 'ready' },
      McpCapabilityKind: { TOOL: 'tool' }
    }
  });
  const states = [];
  const session = McpConnectionCheckService.session;
  session.attach(value => states.push(value));
  return { session, calls, states };
}
test('device adapter uses fixed loopback and discovery-only calls', async () => {
  const h = adapterHarness(true);
  await h.session.run();
  assert.deepEqual(h.calls.map(x => x[0]), ['options', 'register', 'connect', 'list', 'unregister']);
  assert.equal(h.calls[1][1].endpoint, 'http://127.0.0.1:8787/mcp');
  assert.equal(h.calls[1][1].retryToolCallOnExpiredSession, false);
  assert.equal(h.states.at(-1).state, McpProbeState.Connected);
});
test('adapter release build cannot create a manager', async () => {
  const h = adapterHarness(false);
  await h.session.run();
  assert.deepEqual(h.calls, []);
});
test('partial directory failure is rejected and sanitized', async () => {
  const h = adapterHarness(true, true);
  await h.session.run();
  assert.equal(h.states.at(-1).state, McpProbeState.Failed);
  assert.match(h.states.at(-1).message, /SCHEMA_MISMATCH/);
  assert.equal(h.calls.at(-1)[0], 'unregister');
});
