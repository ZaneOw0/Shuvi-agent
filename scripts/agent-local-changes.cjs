// Local modifications are reviewed separately; UPSTREAM.json remains the source baseline.
const assert = require('node:assert/strict');
const path = require('node:path');
function localChanges(manifest, local) {
  if (!local) return new Map();
  assert.equal(local.schemaVersion, 1);
  assert.equal(local.upstreamCommit, manifest.commit);
  const baseline = new Map(manifest.files.map(file => [file.path, file.sha256]));
  const result = new Map();
  for (const file of local.files) {
    assert(typeof file.path === 'string' && file.path.length > 0 && !file.path.includes('\\') &&
      !path.posix.isAbsolute(file.path) && !file.path.includes(':') &&
      !file.path.split('/').some(part => part === '..' || part === '.' || part === ''), 'Unsafe local path');
    assert(manifest.modules.some(module => file.path.startsWith(module.directory + '/')), 'Local file outside modules');
    assert(!result.has(file.path), 'Duplicate local path');
    assert.equal(file.originalSha256, baseline.get(file.path) ?? null, 'Original hash must match upstream');
    assert.match(file.sha256, /^[0-9a-f]{64}$/);
    assert.notEqual(file.sha256, file.originalSha256, 'Unchanged file in local changes');
    for (const key of ['reason', 'contractImpact', 'validation']) {
      assert(typeof file[key] === 'string' && file[key].trim().length > 0, `Missing ${key}`);
    }
    result.set(file.path, file);
  }
  return result;
}
module.exports = { localChanges };
