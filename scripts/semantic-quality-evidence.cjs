'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const source = '.cache/test-logs/2026-10-17-quality-provider-receipt-9f5992c/host.log';
const lines = fs.readFileSync(path.join(root, source), 'utf8').split('\n');
const guard = JSON.parse(fs.readFileSync(path.join(root, '.cache/r025-quality-a220261017240001-one-attempt.guard'), 'utf8'));
assert.equal(guard.documentCap, 8); assert.equal(guard.queryCap, 16); assert.equal(guard.retry, false);
assert.equal(guard.model, 'BAAI/bge-m3'); assert.equal(guard.provider, 'SiliconFlow');
const manifest = fs.readFileSync(path.join(root, 'entry/src/test/fixtures/round2-semantic-manual-v1.md'), 'utf8');
const gold = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/test/eval/round2-semantic-gold-v1.json'), 'utf8'));
const inputs = manifest.split('\n## ').slice(1).map(section => { const [id, ...body] = section.split('\n'); return { id, text: body.join('\n').trim(), role: 'document' }; })
  .concat(gold.cases.map(row => ({ id: row.id, text: row.question, role: 'query' })));
const attempts = new Map(); const rpc = new Map(); const receipts = new Map(); const reviewed = new Map(); const cases = new Map();
for (const line of lines) {
  let match = line.match(/^R2_QUALITY_INPUT id=(\w+) role=(document|query) hash=([a-f0-9]{64}) binding=([a-f0-9]{64}) bound=(\d+)$/);
  if (match) { assert(!reviewed.has(match[1])); reviewed.set(match[1], { role: match[2], hash: match[3], binding: match[4], bound: +match[5] }); }
  match = line.match(/^R2_QUALITY_ATTEMPT id=(\w+) role=(document|query) ordinal=(\d+) grant=(kb-[a-f0-9]{32}) count=(\d+)$/);
  if (match) { assert(!attempts.has(match[1])); attempts.set(match[1], { role: match[2], ordinal: +match[3], grant: match[4], count: +match[5] }); }
  match = line.match(/^R2_EMBED_REQUEST attempt=([a-f0-9]+) purpose=(PdfCorpus|Query|ModelList|Probe) stage=(Start|Http|Failed) http=(\d+) sdk=(-?\d+) category=([A-Za-z]+)$/);
  if (match) { const row = rpc.get(match[1]) || { purpose: match[2], starts: 0, http: 0, failed: false }; assert.equal(row.purpose, match[2]); if (match[3] === 'Start') row.starts++; if (match[3] === 'Http') row.http = +match[4]; if (match[3] === 'Failed') row.failed = true; rpc.set(match[1], row); }
  match = line.match(/^R2_QUALITY_RECEIPT id=(\w+) dimension=(\d+) elapsed=(\d+) total=(-?\d+) prompt=(-?\d+) readback=([a-f0-9]{64})$/);
  if (match) { assert(!receipts.has(match[1])); receipts.set(match[1], { dimension: +match[2], elapsed: +match[3], total: +match[4], prompt: +match[5], readback: match[6] }); }
  if (line.startsWith('R2_QUALITY_CASE ')) { const fields = Object.fromEntries(line.split(' ').slice(1).map(item => item.split('='))); assert(!cases.has(fields.id)); cases.set(fields.id, fields); }
}
assert.equal(reviewed.size, 24); assert.equal(attempts.size, 24); assert.equal(receipts.size, 24); assert.equal(rpc.size, 24); assert.equal(cases.size, 16);
for (const [ordinal, input] of inputs.entries()) { const review = reviewed.get(input.id); assert.equal(review.hash, crypto.createHash('sha256').update(input.text).digest('hex')); assert.equal(review.role, input.role); assert(review.bound > 0 && review.bound <= 8192); assert.equal(attempts.get(input.id).ordinal, ordinal); assert.equal(attempts.get(input.id).count, ordinal + 1); assert.equal(receipts.get(input.id).dimension, 1024); }
for (const row of rpc.values()) { assert.equal(row.starts, 1); assert.equal(row.http, 200); assert.equal(row.failed, false); }
assert.equal([...rpc.values()].filter(row => row.purpose === 'PdfCorpus').length, 8); assert.equal([...rpc.values()].filter(row => row.purpose === 'Query').length, 16);
const laterScopes = ['quality-cache-reopen', 'quality-process-reopen', 'quality-final-readback-production', 'quality-delivery-native-local', 'quality-delivery-vector-basis-flow', 'quality-delivery-protection'];
for (const scope of laterScopes) {
  const later = fs.readFileSync(path.join(root, `.cache/test-logs/2026-10-17-${scope}-9f5992c/host.log`), 'utf8');
  for (const line of later.split('\n')) { const match = line.match(/^R2_EMBED_REQUEST attempt=([a-f0-9]+) purpose=(\w+) stage=Start /); if (match) { assert(rpc.has(match[1]), 'Unexpected request after authorized run'); assert.equal(rpc.get(match[1]).purpose, match[2]); } }
}
assert.equal(new Set([...attempts.values()].filter(row => row.role === 'document').map(row => row.grant)).size, 1);
assert.equal(new Set([...attempts.values()].filter(row => row.role === 'query').map(row => row.grant)).size, 1);
assert.notEqual(attempts.get('F01').grant, attempts.get('P01').grant);
let recalled = 0; let reciprocal = 0; let recovered = 0; let negation = 0; let noanswer = 0;
for (const item of gold.cases) {
  const row = cases.get(item.id); assert.equal(row.kind, item.kind); assert.equal(row.gold, item.sources.join(',') || 'None'); assert.equal(row.answer_generated, '0');
  const hybrid = row.hybrid.split(','); const vector = row.vector.split(','); assert.equal(vector.length, 5); assert.equal(hybrid.length, 5); assert.equal(new Set(hybrid).size, 5); assert(hybrid.every(id => inputs.slice(0, 8).some(input => input.id === id)));
  const rank = hybrid.findIndex(id => item.sources.includes(id)) + 1; assert.equal(+row.hr, rank); assert.equal(+row.vr, vector.findIndex(id => item.sources.includes(id)) + 1);
  if (item.sources.length) { if (rank) recalled++; reciprocal += rank ? 1 / rank : 0; if (item.kind === 'paraphrase' && +row.kr === 0 && +row.vr > 0) recovered++; if (item.kind === 'negation' && rank && (!(+row.forbidden_rank) || rank < +row.forbidden_rank)) negation++; }
  else { assert.equal(row.noanswer, '1'); assert.equal(rank, 0); noanswer++; }
}
const usage = role => inputs.filter(input => input.role === role).reduce((total, input) => total + receipts.get(input.id).total, 0);
const summary = { run: guard.run, documents: 8, queries: 16, http200: rpc.size, failed: 0, recall: recalled / 12, mrr: reciprocal / 12, recovered, negation, noanswer, documentTokens: usage('document'), queryTokens: usage('query'), source, evidenceHash: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, source))).digest('hex') };
assert(summary.recall >= 0.8 && summary.mrr >= 0.6 && recovered >= 2 && negation === 4);
const receipt = path.join(root, '.cache/r025-quality-a220261017240001-actual-receipt.json');
try { fs.writeFileSync(receipt, JSON.stringify(summary) + '\n', { flag: 'wx', mode: 0o600 }); }
catch (error) { if (error.code !== 'EEXIST') throw error; assert.deepEqual(JSON.parse(fs.readFileSync(receipt, 'utf8')), summary); }
console.log(`R2_QUALITY_RPC documents=8 queries=16 http200=${rpc.size} failed=0 models=0 probe=0 guard_preserved=1`);
console.log(`R2_QUALITY_POST scopes=${laterScopes.length} unexpected_requests=0`);
console.log(`R2_QUALITY_SCORE recall=${summary.recall} mrr=${summary.mrr} recovered=${recovered} negation=${negation} noanswer=${noanswer} document_usage=${summary.documentTokens} query_usage=${summary.queryTokens} source_sha256=${summary.evidenceHash}`);
