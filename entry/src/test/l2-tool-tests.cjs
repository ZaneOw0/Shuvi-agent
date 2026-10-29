'use strict';
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

module.exports = function ({ load, root, services, writableRdb, assistantHarness, toolCall, waitChat, assertValidToolHistory }) {
  const domain = path.join(root, 'entry/src/main/ets/knowledge/domain');
  const { KnowledgeAgentQuery, KnowledgeAgentResult, parseKnowledgeAgentQuery } = load(path.join(domain, 'KnowledgeAgentPorts.ets'));
  const { ParsedCancellation } = load(path.join(domain, 'ParsedDocumentModels.ets'));
  const { KnowledgeAgentRuntime, knowledgeAgentEntry } = load(path.join(services, 'KnowledgeAgentRuntime.ets'));
  const { ModelKnowledgeTools } = load(path.join(services, 'ModelKnowledgeTools.ets'));
  const { AgentHostDigest } = load(path.join(services, 'AgentHostDigest.ets'));
  const { ShuviRuntimeState } = load(path.join(services, 'ShuviRuntimeController.ets'));
  const { KnowledgeQueryAuthorization } = load(path.join(root, 'entry/src/main/ets/knowledge/application/KnowledgeQueryAuthorization.ets'));
  const { KnowledgeAgentSearchAdapter } = load(path.join(root, 'entry/src/main/ets/knowledge/application/KnowledgeAgentSearchAdapter.ets'));
  const query = () => Object.assign(new KnowledgeAgentQuery(), { query: '营业日', keywords: ['营业'], topK: 5, mode: 'auto' });
  const hit = (id = 'evidence-1', count = 30) => ({ citationId: 1, evidenceId: id, documentId: 'document-1', generation: 'generation-1',
    title: '合成资料', excerpt: '营业安排。'.repeat(count), kind: 'Text', evidence: 'Vector' });
  function searchPort(options = {}) {
    return { opened: 0, closed: 0, calls: [], valid: true,
      async open() { this.opened++; if (options.openGate) await options.openGate; },
      async close() { this.closed++; },
      async capabilities() { return { directReady: true, semanticReady: true, reasonCode: 'Ready' }; },
      async validate() { return this.valid; },
      async search(q, host, cancel) {
        this.calls.push({ q, host }); if (options.fail) throw Error('private error body');
        if (options.gate) await options.gate;
        cancel.check(); const result = new KnowledgeAgentResult(); result.status = 'ok'; result.route = 'semantic'; result.complete = true;
        result.hits = options.hits ? options.hits(this.calls.length) : [hit()]; return result;
      }
    };
  }
  async function setup(options = {}) {
    const port = options.port || searchPort(options); const db = writableRdb(); const tools = new ModelKnowledgeTools();
    const runtime = new KnowledgeAgentRuntime(db.opener, port, () => tools.snapshot().consent);
    tools.prepare(port, runtime, async () => {}, async () => {});
    if (options.enabled !== false) assert.equal((await tools.activateRag(options.queryEgress !== false)).ready, true);
    return { port, db, tools, runtime };
  }
  const final = (kind = 'grounded', citations = [1]) => ({ content: JSON.stringify({ kind, answer: '合成资料中的营业安排。', citations }) });
  test('L2 direct production executor smoke', async () => {
    const s = await setup();
    const trace = [];
    for (const name of ['saveCheckpoint', 'beforeDispatch', 'recordOutcome']) {
      const original = s.runtime.resource[name].bind(s.runtime.resource);
      s.runtime.resource[name] = async (...args) => {
        try { const r = await original(...args); trace.push([name, r]); return r; }
        catch (e) { trace.push([name, e.message]); throw e; }
      };
    }
    const record = s.runtime.resource.recordOutcome.bind(s.runtime.resource);
    s.runtime.resource.recordOutcome = async (...args) => {
      const result = await record(...args);
      assert(result.accepted || result.duplicate, JSON.stringify(result)); return result;
    };
    try {
      const result = await s.runtime.execute(query(), { originalQuestion: '查询', turnId: 'turn', toolCallId: 'call',
        consentRevision: 1, queryEgressAllowed: true, excerptEgressAllowed: true, deadline: Date.now() + 10000 }, new ParsedCancellation());
      assert.equal(result.status, 'ok');
    } catch (e) { throw Error(e.message + ' ' + JSON.stringify(trace)); }
    finally { await s.tools.close().catch(() => {}); }
  });

  test('L2 strict tool schema rejects unknown fields, paths, malformed keywords and invalid bounds', () => {
    assert.equal(parseKnowledgeAgentQuery(JSON.stringify(query())).query, '营业日');
    for (const change of [{ sql: 'SELECT *' }, { keywords: ['a', 'a'] }, { keywords: [3] }, { keywords: [] },
      { topK: 6 }, { topK: 1.5 }, { query: ' ' }, { mode: 'shell' }, { query: 'x'.repeat(501) }]) {
      assert.throws(() => parseKnowledgeAgentQuery(JSON.stringify({ ...query(), ...change })));
    }
  });
  test('L2 Registry descriptor declares optional network and metered cost, preserving the old local identity', () => {
    const entry = knowledgeAgentEntry(new AgentHostDigest());
    assert.equal(entry.descriptor.toolId, 'native://shuvi/knowledge.search');
    assert.equal(entry.requiresNetwork, true); assert(entry.estimatedCostMicros > 0);
    assert.equal(entry.descriptor.costClass, 'metered-embedding'); assert.equal(entry.descriptor.dataBoundary, 'remoteAllowed');
  });
  test('L2 authorization opening sends no search/model requests; general answer makes no retrieval', async () => {
    const s = await setup(); const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [final('general', [])] });
    await h.start(); try {
      await h.ui.send('你好'); await waitChat(h.ui);
      assert.equal(h.ui.snapshot().succeeded, true); assert.equal(s.port.calls.length, 0);
      assert(h.requests[0].tools.some(t => t.function.name === 'knowledge_search'));
      assert.equal(h.requests[0].tool_choice, 'auto'); assert.match(h.ui.snapshot().reply, /未查询个人知识库/);
    } finally { await h.ui.stop(); }
  });
  test('L2 real Registry authorization, durable Runtime and matching tool message feed the SAME model loop', async () => {
    const s = await setup(); const h = assistantHarness({ tools: {}, extraTools: s.tools,
      rounds: [{ tool_calls: [toolCall('kb1', 'knowledge_search', query())] }, final()] });
    await h.start(); try {
      await h.ui.send('帮我查个人资料里的营业日'); await waitChat(h.ui);
      assert.equal(h.ui.snapshot().succeeded, true); assert.equal(s.port.calls.length, 1);
      assert.equal(h.requests.length, 2); assertValidToolHistory(h.requests[1].messages);
      const wire = JSON.parse(h.requests[1].messages.find(m => m.role === 'tool').content);
      assert.equal(wire.status, 'ok'); assert.equal(wire.hits[0].citation, 1);
      const outgoing = JSON.stringify(wire);
      for (const secret of ['document-1', 'generation-1', 'evidence-1']) assert(!outgoing.includes(secret));
      assert.match(h.ui.snapshot().reply, /个人知识库来源：\[1\]/);
      assert(s.db.envelope, 'real encrypted snapshot backend has durable authority/outcome evidence');
      assert.match(s.db.envelope.payloadJson, /"usageState":"unknown"/);
      assert.equal(s.port.calls[0].host.toolCallId, 'kb1'); assert(s.port.calls[0].host.consentRevision > 0);
    } finally { await h.ui.stop(); }
  });
  test('L2 disabled authorization does not declare tools and a forged call never reaches search', async () => {
    const s = await setup({ enabled: false });
    const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [{ tool_calls: [toolCall('forged', 'knowledge_search', query())] }] });
    await h.start(); try {
      await h.ui.send('查资料'); await waitChat(h.ui);
      assert(!h.requests[0].tools.some(t => t.function.name === 'knowledge_search'));
      assert.equal(s.port.calls.length, 0); assert.equal(h.ui.snapshot().succeeded, false);
    } finally { await h.ui.stop(); }
  });
  test('L2 failed durable writes prevent execution and cannot fabricate knowledge success', async () => {
    const s = await setup(); s.db.failWrites = true;
    s.tools.begin('查询', 'turn', Date.now() + 10000);
    const reply = JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'call'));
    assert.equal(reply.status, 'failed'); assert.equal(s.port.calls.length, 0);
    const result = await s.tools.finish(final().content); assert.match(result, /校验失败/);
    await assert.rejects(s.tools.close(), /CLOSE_UNCONFIRMED/); assert.equal(s.tools.snapshot().lifecycle, ShuviRuntimeState.BLOCKED);
  });
  test('L2 at most two searches and cumulative five/3200 evidence chars, stable IDs and no internal IDs', async () => {
    const s = await setup({ hits: n => Array.from({ length: 3 }, (_, i) => hit('hit-' + (n * 3 + i), 200)) });
    s.tools.begin('查询', 'turn', Date.now() + 10000);
    const first = JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c1'));
    const second = JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c2'));
    assert.equal(first.hits.length, 3); assert(second.hits.length <= 5);
    assert(second.hits.reduce((n, h) => n + h.excerpt.length, 0) <= 3200);
    assert.deepEqual(second.hits.slice(0, 3).map(h => h.citation), [1, 2, 3]);
    assert.equal(JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c3')).status, 'budget_exceeded');
    assert.equal(s.port.calls.length, 2); await s.tools.close();
  });
  test('L2 citation revalidation rejects deleted or changed evidence and preserves original source snapshot', async () => {
    const s = await setup(); s.tools.begin('查询', 'turn', Date.now() + 10000);
    await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'call'); s.port.valid = false;
    assert.match(await s.tools.finish(final().content), /校验失败/);
    assert.equal(s.tools.snapshot().citations.length, 1); await s.tools.close();
  });
  test('L2 closing authorization purges tool history before the next model request', async () => {
    const s = await setup(); const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [
      { tool_calls: [toolCall('kb1', 'knowledge_search', query())] }, final(), { content: '普通回答' }] });
    await h.start(); try {
      await h.ui.send('查我的资料'); await waitChat(h.ui); await s.tools.deactivateRag();
      await h.ui.send('你好'); await waitChat(h.ui);
      const last = h.requests[2]; assert.equal(last.messages.length, 2);
      assert(!JSON.stringify(last.messages).includes('合成资料')); assert.equal(s.tools.snapshot().consent, false);
    } finally { await h.ui.stop(); }
  });
  test('L2 local-only authorization is injected by host, never chosen by model', async () => {
    const s = await setup({ queryEgress: false }); s.tools.begin('查询', 'turn', Date.now() + 10000);
    await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'call');
    assert.equal(s.port.calls[0].host.queryEgressAllowed, false); assert.equal(s.port.calls[0].host.excerptEgressAllowed, true);
    await s.tools.close();
  });
  test('L2 query-only grants bind session, epoch and live cancellation and never survive a fresh authority', () => {
    const authority = new KnowledgeQueryAuthorization(), cancel = new ParsedCancellation();
    authority.allow('q1', 2, 8, cancel);
    assert.equal(authority.revision('q1', 2), 8); assert.equal(authority.revision('q1', 3), 0);
    assert.equal(new KnowledgeQueryAuthorization().revision('q1', 2), 0);
    cancel.invalid = true; assert.equal(authority.revision('q1', 2), 0);
  });
  test('L2 malformed arguments never execute a tool and do not consume a retrieval slot', async () => {
    const s = await setup(); s.tools.begin('查询', 'turn', Date.now() + 10000);
    await assert.rejects(s.tools.invoke('knowledge_search', '{"query":"x"}', 'bad'));
    assert.equal(s.port.calls.length, 0);
    assert.equal(JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'good')).status, 'ok');
    await s.tools.close();
  });
  test('L2 retrieval failure closes the tool result without poisoning the next authorized query', async () => {
    const s = await setup({ fail: true }); s.tools.begin('查询', 'turn', Date.now() + 10000);
    const errors = []; const execute = s.runtime.execute.bind(s.runtime);
    s.runtime.execute = async (...args) => { try { return await execute(...args); } catch (e) { errors.push(e.message); throw e; } };
    assert.equal(JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'failed1')).status, 'failed');
    assert.equal(JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'failed2')).status, 'failed');
    assert.equal(s.port.calls.length, 2, JSON.stringify(errors)); await s.tools.close();
  });
  test('L2 duplicate searches retain one stable citation and do not replenish excerpt budget', async () => {
    const s = await setup(); s.tools.begin('查询', 'turn', Date.now() + 10000);
    await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c1');
    const wire = JSON.parse(await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c2'));
    assert.equal(wire.hits.length, 1); assert.equal(wire.hits[0].citation, 1); await s.tools.close();
  });
  test('L2 fabricated citations in a general answer are rejected without grounding', async () => {
    const s = await setup(); s.tools.begin('你好', 'turn', Date.now() + 10000);
    assert.match(await s.tools.finish(final('general', [1]).content), /校验失败/);
    assert.equal(s.tools.snapshot().citations.length, 0); await s.tools.close();
  });
  test('L2 revocation rejects late search output and retains no leaked excerpts', async () => {
    let release; const gate = new Promise(resolve => { release = resolve; }); const s = await setup({ gate });
    s.tools.begin('查询', 'turn', Date.now() + 10000);
    const pending = s.tools.invoke('knowledge_search', JSON.stringify(query()), 'late');
    while (s.port.calls.length === 0) await new Promise(resolve => setTimeout(resolve, 2));
    const closing = s.tools.deactivateRag(); release(); await closing; await pending;
    assert.equal(s.tools.snapshot().consent, false); assert.equal(s.tools.snapshot().citations.length, 0); await s.tools.close();
  });
  test('L2 answer-only retry reuses frozen evidence and never declares retrieval tools', async () => {
    const s = await setup(); s.tools.begin('查询', 'turn', Date.now() + 10000);
    await s.tools.invoke('knowledge_search', JSON.stringify(query()), 'c1'); await s.tools.finish('{invalid');
    let retries = 0;
    s.tools.retryChat = async () => {
      retries++; assert.deepEqual(s.tools.names(), []); s.tools.begin('重试回答', 'retry-turn', Date.now() + 10000);
      assert.match(await s.tools.finish(final().content), /个人知识库来源/);
    };
    await s.tools.retryAnswer(); assert.equal(retries, 1); assert.equal(s.port.calls.length, 1); await s.tools.close();
  });
  test('L2 new conversation revokes the grant without restoring it from the old model history', async () => {
    const s = await setup(); s.tools.clearConversation();
    assert.deepEqual(s.tools.names(), []); assert.equal(s.tools.snapshot().consent, false); await s.tools.close();
  });
  test('L2 semantic failure falls back to real shared literal policy without canceling the parent turn', async () => {
    const { UnifiedQueryScope } = load(path.join(domain, 'UnifiedQueryModels.ets'));
    const { ParsedDocumentRecord, ParsedTextChunk } = load(path.join(domain, 'ParsedDocumentModels.ets'));
    const scope = new UnifiedQueryScope(); scope.complete = true; scope.localHash = 'stable-scope';
    const doc = Object.assign(new ParsedDocumentRecord(), { id: 'd1', activeGeneration: 'g1', title: '营业通知' });
    const chunk = Object.assign(new ParsedTextChunk(), { id: 'e1', documentId: 'd1', generation: 'g1', text: '营业时间为周一至周五。' });
    scope.texts = [{ document: doc, chunks: [chunk] }];
    let semanticCalls = 0; let child;
    const fakeSession = { state: { session: 's1', epoch: 1 }, async start(_q, _a, c) { child = c; },
      async review() { semanticCalls++; throw Error('embedding unavailable'); }, async close() { if (child) child.invalid = true; } };
    const adapter = new KnowledgeAgentSearchAdapter({ async captureLocal() { return scope; }, async visible() { return true; } },
      { currentConfig() { return {}; } }, () => fakeSession, async () => {}, async () => {});
    await adapter.open(); const cancel = new ParsedCancellation();
    const host = { excerptEgressAllowed: true, queryEgressAllowed: true, consentRevision: 1 };
    const result = await adapter.search(query(), host, cancel);
    assert.equal(semanticCalls, 1); assert.equal(cancel.invalid, false); assert.equal(result.route, 'direct');
    assert.equal(result.engine, 'literal-scan'); assert.equal(result.status, 'ok'); assert.equal(result.hits.length, 1);
    assert.equal(await adapter.validate(result.hits, cancel), true); await adapter.close();
  });
  test('L2 durable memory and compaction exclude retrieved evidence and later derived answers after revocation', async () => {
    const marker = 'PRIVATE_RAG_SOURCE_26';
    const s = await setup({ enabled: false, hits: () => [hit('sensitive-evidence', 1)] });
    const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [
      { content: '普通对话记忆保留' },
      { tool_calls: [toolCall('private1', 'knowledge_search', query())] },
      { content: JSON.stringify({ kind: 'grounded', answer: marker, citations: [1] }) },
      { content: JSON.stringify({ kind: 'general', answer: '沿用来源的派生回答' + marker, citations: [] }) },
      body => {
        const wire = JSON.stringify(body.messages);
        assert.match(wire, /普通对话记忆保留/);
        assert.doesNotMatch(wire, /PRIVATE_RAG_SOURCE_26|sensitive-evidence|营业安排|私有问题|派生回答/);
        assert(!body.tools.some(t => t.function.name === 'knowledge_search'));
        return { content: '授权已撤销，普通记忆仍然可用' };
      }
    ] });
    await h.start();
    try {
      await h.ui.send('普通问题'); await waitChat(h.ui);
      await s.tools.activateRag(false);
      await h.ui.send('私有问题'); await waitChat(h.ui); assert.match(h.ui.snapshot().reply, /PRIVATE_RAG_SOURCE_26/);
      await h.ui.send('继续解释'); await waitChat(h.ui);
      const persisted = JSON.stringify(h.ui.context.memory.snapshot());
      assert.match(persisted, /普通对话记忆保留/);
      assert.doesNotMatch(persisted, /PRIVATE_RAG_SOURCE_26|营业安排|私有问题|派生回答|knowledge_search/);
      await s.tools.deactivateRag();
      // Simulate restoring the serializable model memory before the next request.
      h.ui.context.memory.restore(JSON.parse(persisted));
      await h.ui.send('撤销后继续'); await waitChat(h.ui);
      assert.equal(h.calls(), 5); assert.match(h.ui.snapshot().reply, /普通记忆仍然可用/);
    } finally { await h.ui.stop(); }
  });
  test('L2 tool authorization revisions purge transient knowledge context on conversation change', async () => {
    const s = await setup();
    const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [
      { tool_calls: [toolCall('old1', 'knowledge_search', query())] }, final(),
      body => { assert.equal(body.messages.length, 2); assert.doesNotMatch(JSON.stringify(body), /合成资料|营业安排/); return { content: '新对话' }; }
    ] });
    await h.start();
    try {
      await h.ui.send('旧对话查资料'); await waitChat(h.ui);
      s.tools.clearConversation(); h.ui.clearConversation();
      await h.ui.send('新对话'); await waitChat(h.ui);
      assert.equal(h.calls(), 3); assert.equal(s.tools.snapshot().consent, false);
    } finally { await h.ui.stop(); }
  });
  test('L2 keeps the authorized session model-request cap while ordinary conversations remain unlimited', async () => {
    const s = await setup();
    const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: Array.from({ length: 10 }, () => final('general', [])) });
    await h.start();
    try {
      for (let i = 0; i < 10; i++) { await h.ui.send('普通询问' + i); await waitChat(h.ui); assert.equal(h.ui.snapshot().succeeded, true); }
      await h.ui.send('第十一次'); await waitChat(h.ui);
      assert.equal(h.calls(), 10); assert.equal(h.ui.snapshot().succeeded, false);
      assert(h.requests.every(r => r.max_tokens === 2048)); assert.equal(s.port.calls.length, 0);
    } finally { await h.ui.stop(); }
  });
  test('PR26 image memory works with the production optional knowledge port while knowledge is disabled', async () => {
    const s = await setup({ enabled: false });
    const { VisionChatImage } = load(path.join(services, 'VisionChatProtocol.ets'));
    const image = Object.assign(new VisionChatImage(), { mime: 'image/jpeg', width: 10, height: 10, bytes: new Uint8Array([1, 2, 3]) });
    const h = assistantHarness({ tools: {}, extraTools: s.tools, rounds: [
      body => { assert(Array.isArray(body.messages[1].content)); assert(!body.tools.some(t => t.function.name === 'knowledge_search')); return { content: '图片文字' }; },
      body => { assert.doesNotMatch(JSON.stringify(body), /image_url|base64/); assert.match(JSON.stringify(body), /图片文字/); return { content: '普通追问' }; }
    ] });
    await h.start();
    try {
      await h.ui.send('识图', image); await waitChat(h.ui);
      assert(image.bytes.every(b => b === 0));
      await h.ui.send('继续'); await waitChat(h.ui);
      assert.equal(h.calls(), 2); assert.equal(h.ui.context.memory.turns().length, 2); assert.equal(s.port.calls.length, 0);
    } finally { await h.ui.stop(); }
  });

};
