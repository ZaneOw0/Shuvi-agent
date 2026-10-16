import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { CallToolResultSchema } from '@modelcontextprotocol/sdk/types.js';
import { createSearch } from '../dist/search.js';
import { startServer } from '../dist/server.js';

async function connected(t, search) {
  const app = await startServer(search, 0);
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  const transport = new StreamableHTTPClientTransport(new URL(app.url));
  t.after(async () => {
    await transport.terminateSession().catch(() => {});
    await client.close();
    await app.close();
  });
  await client.connect(transport);
  return { app, client, transport };
}

test('完整 MCP 握手、工具发现、调用与结构化/文本结果一致（上游替身）', async t => {
  const { client } = await connected(t, createSearch({ apiKey: 'test-placeholder', fetcher: async () =>
    Response.json({ results: [{ title: '测试', url: 'https://example.com', content: '模拟响应' }] }) }));
  const listed = await client.listTools();
  assert.deepEqual(listed.tools.map(tool => tool.name), ['web_search']);
  assert.equal(listed.tools[0].inputSchema.additionalProperties, false);
  const result = await client.callTool({ name: 'web_search', arguments: { query: '测试' } });
  assert.equal(result.isError, undefined);
  assert.equal(result.structuredContent.results[0].snippet, '模拟响应');
  assert.deepEqual(JSON.parse(result.content[0].text), result.structuredContent);
});

test('MCP 参数拒绝与未知工具不会调用上游', async t => {
  let calls = 0;
  const { client } = await connected(t, async () => { calls++; throw new Error('Should not run'); });
  const result = await client.callTool({ name: 'web_search', arguments: { query: 'test', extra: true } });
  assert.equal(result.isError, true);
  assert.equal(result.structuredContent.error.code, 'INVALID_ARGUMENT');
  await assert.rejects(client.callTool({ name: 'other', arguments: {} }));
  assert.equal(calls, 0);
});

test('没有凭据仍能发现工具，搜索明确失败', async t => {
  const { client } = await connected(t, createSearch({ apiKey: '' }));
  assert.equal((await client.listTools()).tools.length, 1);
  const result = await client.callTool({ name: 'web_search', arguments: { query: 'test' } });
  assert.equal(result.isError, true);
  assert.equal(result.structuredContent.error.code, 'CONFIGURATION');
});

test('拒绝错误 Host、浏览器 Origin、未知会话、无会话调用和超大请求', async t => {
  const { app } = await connected(t, createSearch({ apiKey: '' }));
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };
  // Node fetch may normalize Host; use the HTTP API to send the exact hostile header.
  const hostStatus = await new Promise((resolve, reject) => {
    const request = httpRequest(app.url, { method: 'POST', headers: { ...headers, Host: 'evil.example' } }, response => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('error', reject);
    request.end('{}');
  });
  assert.equal(hostStatus, 403);
  for (const extra of [{ Origin: 'https://evil.example' }]) {
    const response = await fetch(app.url, { method: 'POST', headers: { ...headers, ...extra }, body: '{}' });
    assert.equal(response.status, 403);
    await response.body.cancel();
  }
  const expired = await fetch(app.url, { method: 'POST', headers: { ...headers, 'mcp-session-id': 'missing' }, body: '{}' });
  assert.equal(expired.status, 404);
  await expired.body.cancel();
  const noSession = await fetch(app.url, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
  assert.equal(noSession.status, 400);
  await noSession.body.cancel();
  const large = await fetch(app.url, { method: 'POST', headers, body: 'x'.repeat(17000) });
  assert.equal(large.status, 413);
  await large.body.cancel();
});

test('协议协商可回退到 2025-11-25（不代表 ArkTS 客户端已通过）', async t => {
  const app = await startServer(createSearch({ apiKey: '' }), 0);
  t.after(() => app.close());
  const response = await fetch(app.url, { method: 'POST', headers: {
    'Content-Type': 'application/json', Accept: 'application/json, text/event-stream'
  }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {
    protocolVersion: '2026-07-28', capabilities: {}, clientInfo: { name: 'protocol-test', version: '1' }
  } }) });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).result.protocolVersion, '2025-11-25');
});

test('MCP 取消通知传到执行中的搜索', async t => {
  let startedResolve;
  let cancelledResolve;
  const started = new Promise(resolve => { startedResolve = resolve; });
  const cancelled = new Promise(resolve => { cancelledResolve = resolve; });
  const { client } = await connected(t, (input, signal) => new Promise((resolve, reject) => {
    startedResolve();
    signal.addEventListener('abort', () => { cancelledResolve(); reject(new Error('cancelled-test')); }, { once: true });
  }));
  const controller = new AbortController();
  const call = client.callTool({ name: 'web_search', arguments: { query: 'cancel' } },
    CallToolResultSchema, { signal: controller.signal });
  const rejected = assert.rejects(call);
  await started;
  controller.abort();
  await rejected;
  await Promise.race([cancelled, new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Cancellation not delivered')), 1500);
    timer.unref();
    cancelled.then(() => { clearTimeout(timer); resolve(); });
  })]);
});
