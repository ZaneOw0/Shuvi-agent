'use strict';
const path = require('node:path');
const assert = require('node:assert/strict');
const { test } = require('node:test');

module.exports = function ({ load, root }) {
  const { chatKnowledgeReply, chatKnowledgeStoredReply } = load(path.join(root, 'entry/src/main/ets/components/ChatKnowledgeSources.ets'));
  const { ChatKnowledgeSnapshot } = load(path.join(root, 'entry/src/main/ets/model/ChatKnowledgeModels.ets'));
  const citations = [1, 2].map(citationId => ({ citationId, documentId: 'doc-1', generation: 'gen-1',
    title: '营业安排.pdf', kind: 'Pdf' }));
  const body = '资料中的安排 [1]，补充说明 [2]，网络信息 [W1]。';
  const footer = '\n\n个人知识库来源：[1] [2]';
  const tails = ['', '\n\n网页来源：\n[W1] 官方页面\nhttps://example.com',
    '\n\n本轮搜索到的网页（回答未直接引用）：\n[W1] 官方页面\nhttps://example.com'];

  for (const [index, tail] of tails.entries()) {
    test(`chat knowledge sources: live and restored cards with tail ${index}`, () => {
      const text = body + footer + tail;
      const reply = chatKnowledgeReply(text, citations);
      assert.equal(reply.sources.length, 1);
      assert.deepEqual(reply.sources[0].citationIds, [1, 2]);
      assert.equal(reply.text, body + tail, 'keep the answer and complete web section');
      const saved = Object.assign(new ChatKnowledgeSnapshot(), { sources: reply.sources });
      const restored = chatKnowledgeStoredReply(text, JSON.parse(JSON.stringify(saved)));
      assert.deepEqual(restored, reply, 'restore without the current retrieval session');
    });
  }

  test('chat knowledge sources: missing bindings and mismatched history retain original text', () => {
    const text = body + footer + tails[1];
    const live = chatKnowledgeReply(text, citations.slice(0, 1));
    assert.equal(live.text, text); assert.deepEqual(live.sources, []);
    const saved = Object.assign(new ChatKnowledgeSnapshot(), { sources: chatKnowledgeReply(body + footer, citations).sources });
    for (const snapshot of [undefined, saved]) {
      const changed = text.replace('[1] [2]', '[1] [3]');
      const reply = chatKnowledgeStoredReply(changed, snapshot);
      assert.equal(reply.text, changed); assert.deepEqual(reply.sources, []);
    }
  });

  test('chat knowledge sources: ordinary prose after source numbers stays unchanged', () => {
    const text = body + footer + '\n\n继续说明。';
    const reply = chatKnowledgeReply(text, citations);
    assert.equal(reply.text, text); assert.deepEqual(reply.sources, []);
  });
};
