import http from 'node:http';
import { writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';

const MODERN_VERSION = '2026-07-28';
const LEGACY_VERSION = '2025-11-25';
const MAX_REQUEST_BYTES = 1024 * 1024;

const { values } = parseArgs({
  options: {
    host: { type: 'string', default: '127.0.0.1' },
    port: { type: 'string', default: '0' },
    'ready-file': { type: 'string' }
  }
});

const host = values.host;
const requestedPort = Number.parseInt(values.port, 10);
if (!Number.isInteger(requestedPort) || requestedPort < 0 || requestedPort > 65535) {
  throw new Error(`Invalid port: ${values.port}`);
}

const stats = {
  requests: 0,
  toolCalls: 0,
  cancelledRequests: 0,
  expiredSessions: 0,
  deleteRequests: 0,
  byMethod: Object.create(null),
  lastAuthorization: undefined
};

let expiryInjected = false;

function jsonRpcResult(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function jsonRpcError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: '2.0', id, error };
}

function sendJson(response, statusCode, payload, extraHeaders = {}) {
  const body = payload === undefined ? '' : JSON.stringify(payload);
  response.writeHead(statusCode, {
    'content-type': 'application/json',
    'cache-control': 'no-store',
    ...extraHeaders
  });
  response.end(body);
}

function sendSse(response, messages) {
  response.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-store',
    connection: 'close'
  });
  for (const message of messages) {
    response.write(`event: message\ndata: ${JSON.stringify(message)}\n\n`);
  }
  response.end();
}

async function readJson(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > MAX_REQUEST_BYTES) throw new Error('request-too-large');
    chunks.push(chunk);
  }
  if (chunks.length === 0) return undefined;
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function toolsPage(cursor) {
  if (cursor === 'tools-2') {
    return {
      tools: [{
        name: 'same-name',
        description: 'Second page tool used for cross-server name collision tests.',
        inputSchema: { type: 'object', properties: {} }
      }]
    };
  }
  return {
    tools: [
      {
        name: 'echo',
        description: 'Echo structured input and content.',
        inputSchema: {
          type: 'object',
          properties: { text: { type: 'string' } },
          required: ['text']
        }
      },
      {
        name: 'route',
        description: 'Exercise 2026-07-28 parameter header mirroring.',
        inputSchema: {
          type: 'object',
          properties: {
            region: { type: 'string', 'x-mcp-header': 'Region' },
            scope: {
              type: 'object',
              properties: {
                tenant: { type: 'integer', 'x-mcp-header': 'Tenant' }
              }
            }
          },
          required: ['region']
        }
      },
      {
        name: 'invalid-header-tool',
        description: 'A conforming modern client must exclude this tool.',
        inputSchema: {
          type: 'object',
          properties: { ratio: { type: 'number', 'x-mcp-header': 'Ratio' } }
        }
      }
    ],
    nextCursor: 'tools-2'
  };
}

function resourcesPage(cursor) {
  if (cursor === 'resources-2') {
    return {
      resources: [{ uri: 'fixture://secondary', name: 'secondary', mimeType: 'text/plain' }]
    };
  }
  return {
    resources: [{ uri: 'fixture://welcome', name: 'welcome', mimeType: 'text/plain' }],
    nextCursor: 'resources-2'
  };
}

function promptsPage() {
  return {
    prompts: [{
      name: 'summarize',
      description: 'Create a deterministic summary prompt.',
      arguments: [{ name: 'topic', required: true }]
    }]
  };
}

function templatesPage() {
  return {
    resourceTemplates: [{
      uriTemplate: 'fixture://documents/{id}',
      name: 'document',
      mimeType: 'application/json'
    }]
  };
}

function decodeSentinel(value) {
  if (typeof value !== 'string') return value;
  const match = /^=\?base64\?([A-Za-z0-9+/]*={0,2})\?=$/.exec(value);
  return match ? Buffer.from(match[1], 'base64').toString('utf8') : value;
}

function validateModernHeaders(request, message) {
  if (request.headers['mcp-protocol-version'] !== MODERN_VERSION) {
    return 'MCP-Protocol-Version does not match the body';
  }
  if (request.headers['mcp-method'] !== message.method) {
    return 'Mcp-Method does not match the body';
  }
  const nameMethods = new Set(['tools/call', 'resources/read', 'prompts/get']);
  if (nameMethods.has(message.method)) {
    const expected = message.method === 'resources/read' ? message.params?.uri : message.params?.name;
    if (decodeSentinel(request.headers['mcp-name']) !== expected) {
      return 'Mcp-Name does not match the body';
    }
  }
  if (message.method === 'tools/call' && message.params?.name === 'route') {
    const args = message.params?.arguments ?? {};
    if (args.region != null && decodeSentinel(request.headers['mcp-param-region']) !== String(args.region)) {
      return 'Mcp-Param-Region does not match the body';
    }
    if (args.scope?.tenant != null && decodeSentinel(request.headers['mcp-param-tenant']) !== String(args.scope.tenant)) {
      return 'Mcp-Param-Tenant does not match the body';
    }
  }
  return undefined;
}

function methodResult(message) {
  const params = message.params ?? {};
  switch (message.method) {
    case 'tools/list':
      return toolsPage(params.cursor);
    case 'resources/list':
      return resourcesPage(params.cursor);
    case 'resources/templates/list':
      return templatesPage();
    case 'prompts/list':
      return promptsPage();
    case 'tools/call':
      stats.toolCalls += 1;
      return {
        content: [
          { type: 'text', text: String(params.arguments?.text ?? params.name) },
          { type: 'image', data: 'aW1hZ2U=', mimeType: 'image/png' },
          { type: 'audio', data: 'YXVkaW8=', mimeType: 'audio/mpeg' },
          { type: 'future-extension', fixture: true }
        ],
        structuredContent: { echoed: params.arguments ?? {}, server: 'fixture' },
        isError: false
      };
    case 'resources/read':
      if (params.uri === 'fixture://stats') {
        return {
          contents: [{
            type: 'resource',
            resource: { uri: params.uri, text: JSON.stringify({ toolCalls: stats.toolCalls }) }
          }]
        };
      }
      return {
        contents: [
          { type: 'resource', resource: { uri: params.uri, text: 'fixture resource' } },
          { type: 'resource_link', uri: 'fixture://linked', name: 'linked' }
        ]
      };
    case 'prompts/get':
      return {
        description: 'Fixture prompt',
        messages: [{ role: 'user', content: { type: 'text', text: `Summarize ${params.arguments?.topic ?? 'topic'}` } }]
      };
    default:
      return undefined;
  }
}

async function handleModern(request, response, url, message) {
  if (message.method === 'server/discover') {
    const result = {
      supportedVersions: [MODERN_VERSION],
      capabilities: { tools: { listChanged: true }, resources: {}, prompts: {} },
      instructions: url.searchParams.get('large') === '1' ? 'x'.repeat(4096) : 'harmony_agent fixture modern server',
      _meta: { 'io.modelcontextprotocol/serverInfo': { name: 'harmony_agent-fixture-modern', version: '0.1.0' } }
    };
    return sendJson(response, 200, jsonRpcResult(message.id, result));
  }
  const mismatch = validateModernHeaders(request, message);
  if (mismatch) {
    return sendJson(response, 400, jsonRpcError(message.id, -32020, mismatch));
  }
  if (message.method === 'tools/call' && message.params?.arguments?.text === 'device-cancel') {
    stats.toolCalls += 1;
    return await new Promise(resolve => {
      let completed = false;
      const finish = () => {
        if (completed) return;
        completed = true;
        resolve();
      };
      const timer = setTimeout(() => {
        if (!response.destroyed) {
          sendJson(response, 200, jsonRpcResult(message.id, {
            content: [{ type: 'text', text: 'late-response' }],
            structuredContent: { delayed: true },
            isError: false
          }));
        }
        finish();
      }, 5000);
      response.once('close', () => {
        if (!response.writableEnded) stats.cancelledRequests += 1;
        clearTimeout(timer);
        finish();
      });
    });
  }
  const result = methodResult(message);
  if (result === undefined) {
    return sendJson(response, 404, jsonRpcError(message.id, -32601, 'Method not found'));
  }
  if (url.searchParams.get('format') === 'sse') {
    return sendSse(response, [
      { jsonrpc: '2.0', method: 'notifications/progress', params: { progress: 0.5 } },
      jsonRpcResult(message.id, result)
    ]);
  }
  return sendJson(response, 200, jsonRpcResult(message.id, result));
}

async function handleLegacy(request, response, message) {
  if (message.method === 'server/discover') {
    return sendJson(response, 404, jsonRpcError(message.id, -32601, 'Method not found'));
  }
  if (message.method === 'initialize') {
    return sendJson(response, 200, jsonRpcResult(message.id, {
      protocolVersion: LEGACY_VERSION,
      capabilities: { tools: {}, resources: {}, prompts: {} },
      serverInfo: { name: 'harmony_agent-fixture-legacy', version: '0.1.0' },
      instructions: 'harmony_agent fixture legacy server'
    }), { 'mcp-session-id': 'fixture-session' });
  }
  if (message.method === 'notifications/initialized') {
    response.writeHead(202, { 'cache-control': 'no-store' });
    return response.end();
  }
  if (request.headers['mcp-session-id'] !== 'fixture-session') {
    return sendJson(response, 400, jsonRpcError(message.id, -32000, 'Missing session'));
  }
  if (request.url?.startsWith('/legacy-expire') && message.method === 'tools/call' && !expiryInjected) {
    expiryInjected = true;
    stats.expiredSessions += 1;
    return sendJson(response, 404, { error: 'Session expired' });
  }
  const result = methodResult(message);
  if (result === undefined) {
    return sendJson(response, 404, jsonRpcError(message.id, -32601, 'Method not found'));
  }
  return sendJson(response, 200, jsonRpcResult(message.id, result));
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  if (request.method === 'GET' && url.pathname === '/health') {
    return sendJson(response, 200, { ready: true, modern: MODERN_VERSION, legacy: LEGACY_VERSION });
  }
  if (request.method === 'GET' && url.pathname === '/__fixture/stats') {
    return sendJson(response, 200, stats);
  }
  if (request.method === 'POST' && url.pathname === '/__fixture/reset') {
    stats.requests = 0;
    stats.toolCalls = 0;
    stats.cancelledRequests = 0;
    stats.expiredSessions = 0;
    stats.deleteRequests = 0;
    stats.byMethod = Object.create(null);
    stats.lastAuthorization = undefined;
    expiryInjected = false;
    return sendJson(response, 200, { reset: true });
  }
  if (url.pathname.startsWith('/status/')) {
    const code = Number.parseInt(url.pathname.substring('/status/'.length), 10);
    return sendJson(response, code, { status: code });
  }
  if (url.pathname === '/slow') {
    return setTimeout(() => sendJson(response, 200, { delayed: true }), 1500);
  }
  if (url.pathname === '/drop') {
    return request.socket.destroy();
  }
  if (url.pathname === '/malformed-sse') {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    return response.end('data: {not-json}\n\n');
  }
  if (request.method === 'DELETE' && (url.pathname === '/legacy' || url.pathname === '/legacy-expire')) {
    stats.deleteRequests += 1;
    response.writeHead(204, { 'cache-control': 'no-store' });
    return response.end();
  }
  if (request.method !== 'POST') {
    return sendJson(response, 405, { error: 'method-not-allowed' });
  }

  try {
    const message = await readJson(request);
    if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') {
      return sendJson(response, 400, jsonRpcError(message?.id ?? null, -32600, 'Invalid Request'));
    }
    stats.requests += 1;
    stats.byMethod[message.method] = (stats.byMethod[message.method] ?? 0) + 1;
    stats.lastAuthorization = request.headers.authorization ? '[REDACTED]' : undefined;

    if (url.pathname === '/legacy' || url.pathname === '/legacy-expire') {
      return await handleLegacy(request, response, message);
    }
    if (url.pathname === '/modern') {
      return await handleModern(request, response, url, message);
    }
    return sendJson(response, 404, jsonRpcError(message.id, -32601, 'Unknown fixture endpoint'));
  } catch (error) {
    const status = error instanceof Error && error.message === 'request-too-large' ? 413 : 400;
    return sendJson(response, status, { error: 'invalid-request' });
  }
});

server.on('clientError', (_error, socket) => socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'));

server.listen(requestedPort, host, async () => {
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Fixture did not bind a TCP port');
  const ready = {
    pid: process.pid,
    host,
    port: address.port,
    baseUrl: `http://${host}:${address.port}`,
    modernVersion: MODERN_VERSION,
    legacyVersion: LEGACY_VERSION
  };
  if (values['ready-file']) {
    await writeFile(values['ready-file'], `${JSON.stringify(ready, null, 2)}\n`, 'utf8');
  }
  process.stdout.write(`${JSON.stringify(ready)}\n`);
});

function shutdown() {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 3000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
