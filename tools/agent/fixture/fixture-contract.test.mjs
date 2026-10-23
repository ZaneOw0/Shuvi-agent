import assert from 'node:assert/strict';
import test from 'node:test';

const baseUrl = process.env.MCP_FIXTURE_URL;
const protocol = process.env.MCP_PROTOCOL ?? 'Both';
if (!baseUrl) throw new Error('MCP_FIXTURE_URL is required');

const MODERN_VERSION = '2026-07-28';
const LEGACY_VERSION = '2025-11-25';
let requestId = 0;

function body(method, params, modern = false) {
  requestId += 1;
  const wireParams = { ...params };
  if (modern) {
    wireParams._meta = {
      'io.modelcontextprotocol/protocolVersion': MODERN_VERSION,
      'io.modelcontextprotocol/clientInfo': { name: 'harmony_agent-fixture-contract', version: '0.1.0' },
      'io.modelcontextprotocol/clientCapabilities': {}
    };
  }
  return { jsonrpc: '2.0', id: requestId, method, params: wireParams };
}

function modernHeaders(message, name, additional = {}) {
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
    'mcp-protocol-version': MODERN_VERSION,
    'mcp-method': message.method,
    ...additional
  };
  if (name !== undefined) headers['mcp-name'] = name;
  return headers;
}

async function post(path, message, headers = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(message)
  });
  const text = await response.text();
  let payload;
  if (text.length > 0 && !response.headers.get('content-type')?.includes('text/event-stream')) {
    payload = JSON.parse(text);
  }
  return { response, text, payload };
}

async function modernDiscover(path = '/modern') {
  const message = body('server/discover', {}, true);
  const result = await post(path, message, modernHeaders(message));
  assert.equal(result.response.status, 200);
  assert.deepEqual(result.payload.result.supportedVersions, [MODERN_VERSION]);
  return result.payload.result;
}

async function legacyConnect() {
  const probe = body('server/discover', {}, true);
  const probeResult = await post('/legacy', probe, modernHeaders(probe));
  assert.equal(probeResult.response.status, 404);
  assert.equal(probeResult.payload.error.code, -32601);

  const initialize = body('initialize', {
    protocolVersion: LEGACY_VERSION,
    capabilities: {},
    clientInfo: { name: 'harmony_agent-fixture-contract', version: '0.1.0' }
  });
  const initialized = await post('/legacy', initialize);
  assert.equal(initialized.response.status, 200);
  assert.equal(initialized.payload.result.protocolVersion, LEGACY_VERSION);
  const session = initialized.response.headers.get('mcp-session-id');
  assert.equal(session, 'fixture-session');

  const notification = {
    jsonrpc: '2.0',
    method: 'notifications/initialized',
    params: {}
  };
  const notificationResult = await post('/legacy', notification, {
    'mcp-protocol-version': LEGACY_VERSION,
    'mcp-session-id': session
  });
  assert.equal(notificationResult.response.status, 202);
  return session;
}

if (protocol === 'Modern' || protocol === 'Both') {
  test('modern discovery, pagination, tools, resources, templates and prompts', async () => {
    await modernDiscover();

    const list1 = body('tools/list', {}, true);
    const page1 = await post('/modern', list1, modernHeaders(list1));
    assert.equal(page1.response.status, 200);
    assert.equal(page1.payload.result.nextCursor, 'tools-2');
    assert.equal(page1.payload.result.tools.length, 3);

    const list2 = body('tools/list', { cursor: 'tools-2' }, true);
    const page2 = await post('/modern', list2, modernHeaders(list2));
    assert.equal(page2.payload.result.tools[0].name, 'same-name');

    const route = body('tools/call', {
      name: 'route',
      arguments: { region: '华北', scope: { tenant: 42 } }
    }, true);
    const region = `=?base64?${Buffer.from('华北', 'utf8').toString('base64')}?=`;
    const called = await post('/modern', route, modernHeaders(route, 'route', {
      'mcp-param-region': region,
      'mcp-param-tenant': '42'
    }));
    assert.equal(called.response.status, 200);
    assert.equal(called.payload.result.structuredContent.echoed.scope.tenant, 42);
    assert.equal(called.payload.result.content[2].type, 'audio');
    assert.equal(called.payload.result.content[3].type, 'future-extension');

    const resources = body('resources/list', {}, true);
    const resourcePage = await post('/modern', resources, modernHeaders(resources));
    assert.equal(resourcePage.payload.result.nextCursor, 'resources-2');

    const templates = body('resources/templates/list', {}, true);
    const templatePage = await post('/modern', templates, modernHeaders(templates));
    assert.equal(templatePage.payload.result.resourceTemplates[0].uriTemplate, 'fixture://documents/{id}');

    const read = body('resources/read', { uri: 'fixture://welcome' }, true);
    const readResult = await post('/modern', read, modernHeaders(read, 'fixture://welcome'));
    assert.equal(readResult.payload.result.contents[1].type, 'resource_link');

    const prompts = body('prompts/list', {}, true);
    const promptPage = await post('/modern', prompts, modernHeaders(prompts));
    assert.equal(promptPage.payload.result.prompts[0].name, 'summarize');

    const getPrompt = body('prompts/get', { name: 'summarize', arguments: { topic: 'MCP' } }, true);
    const promptResult = await post('/modern', getPrompt, modernHeaders(getPrompt, 'summarize'));
    assert.equal(promptResult.payload.result.messages[0].content.text, 'Summarize MCP');
  });

  test('modern SSE carries notification and matching response', async () => {
    const message = body('tools/list', {}, true);
    const result = await post('/modern?format=sse', message, modernHeaders(message));
    assert.equal(result.response.status, 200);
    const events = result.text.split('\n\n').filter(Boolean).map((event) => {
      const data = event.split('\n').find((line) => line.startsWith('data: '));
      return JSON.parse(data.substring(6));
    });
    assert.equal(events[0].method, 'notifications/progress');
    assert.equal(events[1].id, message.id);
  });

  test('modern header mismatch is a structured protocol error', async () => {
    const message = body('tools/call', { name: 'route', arguments: { region: 'eu-west' } }, true);
    const result = await post('/modern', message, modernHeaders(message, 'wrong-name', {
      'mcp-param-region': 'eu-west'
    }));
    assert.equal(result.response.status, 400);
    assert.equal(result.payload.error.code, -32020);
  });

  test('modern fixture exposes an oversized discovery response', async () => {
    const message = body('server/discover', {}, true);
    const result = await post('/modern?large=1', message, modernHeaders(message));
    assert.equal(result.response.status, 200);
    assert.equal(result.text.length > 4096, true);
  });
}

if (protocol === 'Legacy' || protocol === 'Both') {
  test('legacy initialization, session and catalogs', async () => {
    const session = await legacyConnect();
    const list = body('tools/list', {});
    const listed = await post('/legacy', list, {
      'mcp-protocol-version': LEGACY_VERSION,
      'mcp-session-id': session
    });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.payload.result.tools[0].name, 'echo');

    const call = body('tools/call', { name: 'echo', arguments: { text: 'legacy' } });
    const called = await post('/legacy', call, {
      'mcp-protocol-version': LEGACY_VERSION,
      'mcp-session-id': session
    });
    assert.equal(called.payload.result.content[0].text, 'legacy');
  });
}

if (protocol === 'Both') {
  test('two protocol eras operate concurrently and isolate failure', async () => {
    const modern = modernDiscover();
    const legacy = legacyConnect();
    const broken = fetch(`${baseUrl}/status/500`, { method: 'POST' });
    const results = await Promise.allSettled([modern, legacy, broken]);
    assert.equal(results[0].status, 'fulfilled');
    assert.equal(results[1].status, 'fulfilled');
    assert.equal(results[2].status, 'fulfilled');
    assert.equal(results[2].value.status, 500);
  });

  test('401, 403 and 5xx are not legacy discovery signals', async () => {
    for (const status of [401, 403, 500]) {
      const message = body('server/discover', {}, true);
      const result = await post(`/status/${status}`, message, modernHeaders(message));
      assert.equal(result.response.status, status);
      assert.equal(result.payload.error, undefined);
    }
  });

  test('fixture redacts authorization values from observable stats', async () => {
    const secret = 'fixture-secret-must-not-leak';
    const message = body('server/discover', {}, true);
    await post('/modern', message, modernHeaders(message, undefined, { authorization: `Bearer ${secret}` }));
    const stats = await (await fetch(`${baseUrl}/__fixture/stats`)).json();
    assert.equal(stats.lastAuthorization, '[REDACTED]');
    assert.equal(JSON.stringify(stats).includes(secret), false);
  });

  test('malformed SSE is available for negative client tests', async () => {
    const response = await fetch(`${baseUrl}/malformed-sse`, { method: 'POST' });
    assert.equal(response.headers.get('content-type'), 'text/event-stream');
    assert.equal((await response.text()).includes('{not-json}'), true);
  });

  test('dropped connection is exposed as a network failure', async () => {
    let rejected = false;
    try {
      await fetch(`${baseUrl}/drop`, { method: 'POST' });
    } catch {
      rejected = true;
    }
    assert.equal(rejected, true);
  });
}
