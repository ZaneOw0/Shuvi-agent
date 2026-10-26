const { test } = require('node:test');
const assert = require('node:assert/strict');
const { localChanges } = require('../agent-local-changes.cjs');
const manifest = { commit: 'a'.repeat(40), modules: [{ directory: 'agent_storage' }],
  files: [{ path: 'agent_storage/Index.ets', sha256: 'a'.repeat(64) }] };
function fixture(change = {}) {
  return { schemaVersion: 1, upstreamCommit: manifest.commit, files: [{ path: 'agent_storage/Index.ets',
    originalSha256: 'a'.repeat(64), sha256: 'b'.repeat(64), reason: 'approved change',
    contractImpact: 'new explicit state', validation: 'spec reference', ...change }] };
}
test('local provenance requires original baseline hash and an explicit changed hash', () => {
  assert.equal(localChanges(manifest, fixture()).size, 1);
  assert.throws(() => localChanges(manifest, fixture({ originalSha256: 'c'.repeat(64) })));
  assert.throws(() => localChanges(manifest, fixture({ sha256: 'a'.repeat(64) })));
  assert.throws(() => localChanges(manifest, fixture({ validation: '' })));
  assert.throws(() => localChanges(manifest, { ...fixture(), upstreamCommit: 'b'.repeat(40) }));
});
test('new files must be declared; path escape and duplicate entries are rejected', () => {
  assert.equal(localChanges(manifest, fixture({ path: 'agent_storage/New.ets', originalSha256: null })).size, 1);
  for (const path of ['../escape', 'agent_storage/../escape', 'agent_storage\\bad', 'E:/file', '/etc/file', 'other/Index.ets']) {
    assert.throws(() => localChanges(manifest, fixture({ path, originalSha256: null })));
  }
  const duplicate = fixture(); duplicate.files.push(duplicate.files[0]);
  assert.throws(() => localChanges(manifest, duplicate));
});
