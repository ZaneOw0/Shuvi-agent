// Checks the first-import baseline without accessing the source repository or credentials.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../services/local-ai-gateway');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'UPSTREAM.json'), 'utf8'));
assert.equal(manifest.schemaVersion, 1);
assert.match(manifest.commit, /^[0-9a-f]{40}$/);
const seen = new Set();
for (const item of manifest.files) {
  const filename = path.resolve(root, item.path);
  assert(filename.startsWith(root + path.sep), 'Manifest path outside gateway');
  assert(!seen.has(item.path), 'Duplicate manifest path');
  seen.add(item.path);
  assert(!fs.lstatSync(filename).isSymbolicLink(), `Unexpected symlink: ${item.path}`);
  const bytes = fs.readFileSync(filename);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),
    item.importedSha256, `Imported baseline changed: ${item.path}`);
}
console.log(`Verified ${seen.size} gateway baseline files (${manifest.commit}).`);
