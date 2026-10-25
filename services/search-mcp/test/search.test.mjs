import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createSearch, inputSchema } from '../dist/search.js';

const fixture = { results: [{ title: '测试文档', url: 'https://example.com/docs', content: '仅用于测试的摘要' }] };
const input = { query: '测试关键词', maxResults: 5 };
const signal = () => new AbortController().signal;
const options = fetcher => ({ apiKey: 'test-only-placeholder', fetcher });

test('供应商用量独立返回且绑定结果；合法零值和小数不被替换', async () => {
  for (const credits of [0, 0.5, 1, 2]) {
    const { output, usage } = await createSearch(options(async () => Response.json({ ...fixture,
      usage: { credits }, request_id: 'provider-test-1' })))(input, signal());
    assert.deepEqual(usage, { schemaVersion: '1.0', requestId: output.requestId, provider: 'tavily',
      state: 'known', unit: 'credits', credits, providerRequestId: 'provider-test-1' });
    assert.equal(output.usage, undefined);
  }
});

test('缺失或非法用量保持未知，不丢来源、不猜零、不透传供应商正文', async () => {
  for (const change of [{}, { usage: null }, { usage: {} }, { usage: { credits: '1' } },
    { usage: { credits: -1 } }, { usage: { credits: 1e100 } },
    { usage: { credits: 1 }, request_id: 'private\ninvalid' }]) {
    const { output, usage } = await createSearch(options(async () => Response.json({ ...fixture, ...change })))(input, signal());
    assert.equal(output.results.length, 1);
    assert.deepEqual(usage, { schemaVersion: '1.0', requestId: output.requestId, provider: 'tavily', state: 'unknown' });
  }
});

test('参数默认值、首尾空白和 Unicode 字符数边界', () => {
  assert.deepEqual(inputSchema.parse({ query: ' 鸿蒙 ' }), { query: '鸿蒙', maxResults: 5 });
  assert.equal(inputSchema.safeParse({ query: '🌟'.repeat(500) }).success, true);
  assert.equal(inputSchema.safeParse({ query: '🌟'.repeat(501) }).success, false);
  for (const value of [{ query: ' ' }, { query: 1 }, { query: 'a', maxResults: 0 },
    { query: 'a', maxResults: 11 }, { query: 'a', maxResults: 1.5 }, { query: 'a', endpoint: 'evil' }]) {
    assert.equal(inputSchema.safeParse(value).success, false);
  }
});

test('真实 HTTP 请求格式与返回字段转换（测试 transport）', async () => {
  let calls = 0;
  const search = createSearch(options(async (url, init) => {
    calls++;
    assert.equal(url, 'https://api.tavily.com/search');
    assert.equal(init.method, 'POST');
    assert.equal(init.redirect, 'error');
    assert.equal(init.headers.Authorization, 'Bearer test-only-placeholder');
    assert.deepEqual(JSON.parse(init.body), { query: '测试关键词', max_results: 5,
      search_depth: 'basic', topic: 'general', auto_parameters: false,
      include_answer: false, include_raw_content: false, include_images: false, include_usage: true });
    return Response.json(fixture);
  }));
  const { output: result } = await search(input, signal());
  assert.equal(calls, 1);
  assert.deepEqual(result.results, [{ title: '测试文档', url: 'https://example.com/docs', snippet: '仅用于测试的摘要' }]);
  assert.equal(result.provider, 'tavily');
  assert.equal(result.schemaVersion, '1.0');
  assert.ok(result.requestId);
  assert.ok(Number.isFinite(Date.parse(result.searchedAt)));
});

test('参数或配置无效时不发请求；预先取消不发请求', async () => {
  let calls = 0;
  const fetcher = async () => { calls++; return Response.json(fixture); };
  await assert.rejects(createSearch(options(fetcher))({ query: '' }, signal()), { code: 'INVALID_ARGUMENT' });
  await assert.rejects(createSearch({ apiKey: '', fetcher })(input, signal()), { code: 'CONFIGURATION' });
  await assert.rejects(createSearch({ apiKey: 'line\nbreak', fetcher })(input, signal()), { code: 'CONFIGURATION' });
  await assert.rejects(createSearch(options(fetcher))(input, AbortSignal.abort()), { code: 'CANCELLED' });
  assert.equal(calls, 0);
});

test('合法空结果保持成功；数量不超过请求上限', async () => {
  assert.deepEqual((await createSearch(options(async () => Response.json({ results: [] })))(input, signal())).output.results, []);
  const { output: result } = await createSearch(options(async () => Response.json({ results: Array(4).fill(fixture.results[0]) })))({ ...input, maxResults: 2 }, signal());
  assert.equal(result.results.length, 2);
});

for (const [status, code] of [[401, 'AUTHENTICATION'], [403, 'AUTHENTICATION'],
  [429, 'RATE_LIMITED'], [432, 'QUOTA_EXCEEDED'], [433, 'QUOTA_EXCEEDED'], [500, 'UPSTREAM']]) {
  test(`HTTP ${status} 正确映射，不泄露上游响应、不自动重试`, async () => {
    let calls = 0;
    const search = createSearch(options(async () => { calls++; return new Response('sensitive-test-text', { status }); }));
    await assert.rejects(search(input, signal()), error => error.code === code && !error.message.includes('sensitive-test-text'));
    assert.equal(calls, 1);
  });
}

test('网络错误被脱敏，不伪造空结果', async () => {
  await assert.rejects(createSearch(options(async () => { throw new Error('sensitive-test-text'); }))(input, signal()),
    error => error.code === 'NETWORK' && !error.message.includes('sensitive-test-text'));
});

test('损坏 JSON、缺字段及危险 URL 均拒绝', async () => {
  for (const body of ['not-json', '{}', '{"results":[{}]}', JSON.stringify({ results: [
    { ...fixture.results[0], url: 'javascript:alert(1)' }
  ] }), JSON.stringify({ results: [{ ...fixture.results[0], url: 'https://user:password@example.com' }] })]) {
    await assert.rejects(createSearch(options(async () => new Response(body)))(input, signal()), { code: 'INVALID_RESPONSE' });
  }
});

test('响应体大小受限并取消读取', async () => {
  let cancelled = false;
  const search = createSearch(options(async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(1_048_577)); },
    cancel() { cancelled = true; }
  }))));
  await assert.rejects(search(input, signal()), { code: 'RESPONSE_TOO_LARGE' });
  assert.equal(cancelled, true);
});

async function slowUpstream(t) {
  const upstream = createServer((req, res) => {
    req.resume();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.write('{"results":'); // Headers arrive, body deliberately never completes.
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const port = upstream.address().port;
  t.after(async () => {
    const done = new Promise(resolve => upstream.close(resolve));
    upstream.closeAllConnections();
    await done;
  });
  return (url, init) => fetch(`http://127.0.0.1:${port}`, init);
}

test('超时覆盖收到响应头后的读取阶段（本机真实 HTTP）', async t => {
  const fetcher = await slowUpstream(t);
  await assert.rejects(createSearch({ ...options(fetcher), timeoutMs: 100 })(input, signal()), { code: 'TIMEOUT' });
});

test('取消会中止正在读取的 HTTP 响应', async t => {
  const fetcher = await slowUpstream(t);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 100);
  t.after(() => clearTimeout(timer));
  await assert.rejects(createSearch(options(fetcher))(input, controller.signal), { code: 'CANCELLED' });
});
