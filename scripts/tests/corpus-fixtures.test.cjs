'use strict';
// Guards the corpus-fixture resolver: corpus fixtures are frozen evidence, so a pending,
// missing, resized or hash-mismatched entry must fail loudly instead of silently skipping.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { requireCorpus } = require('../../entry/src/test/corpus-fixtures.cjs');

const root = path.resolve(__dirname, '../../.local/corpus-fixture-tests');
fs.mkdirSync(root, { recursive: true });

function fixture(t, overrides = {}) {
  const dir = fs.mkdtempSync(path.join(root, 'corpus-'));
  const bytes = Buffer.from('frozen corpus bytes\n', 'utf8');
  fs.writeFileSync(path.join(dir, 'sample.bin'), bytes);
  const entry = {
    id: 'sample',
    file: 'sample.bin',
    status: 'committed',
    bytes: bytes.length,
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    ...overrides
  };
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify({ version: 'test', entries: [entry] }, null, 2));
  t.after(() => {
    if (path.dirname(dir) !== root || !path.basename(dir).startsWith('corpus-')) throw new Error('Unsafe cleanup path');
    fs.rmSync(dir, { recursive: true });
  });
  return { dir, bytes };
}

test('committed fixture with matching bytes resolves', t => {
  const { dir, bytes } = fixture(t);
  const corpus = requireCorpus('sample', dir);
  assert.equal(corpus.bytes.length, bytes.length);
  assert.equal(corpus.file, path.join(dir, 'sample.bin'));
});

test('pending entry refuses to resolve', t => {
  const { dir } = fixture(t, { status: 'pending', bytes: null, sha256: null });
  assert.throws(() => requireCorpus('sample', dir), /not committed yet/);
});

for (const [name, overrides, pattern] of [
  ['size drift', { bytes: 1 }, /size changed/],
  ['hash drift', { sha256: 'a'.repeat(64) }, /hash changed/],
  ['missing pin', { sha256: null }, /no pinned sha256/]
]) {
  test(`${name} refuses to resolve`, t => {
    const { dir } = fixture(t, overrides);
    assert.throws(() => requireCorpus('sample', dir), pattern);
  });
}

test('unknown id and missing file fail loudly', t => {
  const { dir } = fixture(t);
  assert.throws(() => requireCorpus('other', dir), /Unknown corpus fixture/);
  fs.unlinkSync(path.join(dir, 'sample.bin'));
  assert.throws(() => requireCorpus('sample', dir), /Missing committed corpus fixture/);
});

test('committed manifest entries must match the pinned bytes on disk', () => {
  // Guards the real manifest: a committed entry that lost its file or drifted fails here,
  // while pending entries are allowed (they fail only when a test needs them).
  const manifestPath = path.resolve(__dirname, '../../entry/src/test/fixtures/corpus/manifest.json');
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  assert.ok(Array.isArray(manifest.entries) && manifest.entries.length > 0);
  for (const entry of manifest.entries) {
    assert.ok(['pending', 'committed'].includes(entry.status), `unexpected status for ${entry.id}`);
    if (entry.status !== 'committed') continue;
    const bytes = fs.readFileSync(path.join(path.dirname(manifestPath), entry.file));
    assert.equal(bytes.length, entry.bytes, `${entry.id}: pinned size mismatch`);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), entry.sha256, `${entry.id}: pinned hash mismatch`);
  }
});
