// Import-baseline check: historical evidence must not silently become current evidence.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const archive = path.join(root, 'docs/archive/harmony-agent-f177176');
const manifest = JSON.parse(fs.readFileSync(path.join(archive, 'UPSTREAM.json'), 'utf8'));
if (manifest.schemaVersion !== 1 || manifest.commit !== 'f1771764f129193725a8bccb5da2be6c3604e998' || manifest.files.length !== 29) {
  throw new Error('Unexpected Agent document baseline');
}
const seen = new Set();
for (const entry of manifest.files) {
  const file = path.resolve(archive, entry.path);
  if (!file.startsWith(archive + path.sep) || seen.has(file)) throw new Error('Invalid archive path');
  seen.add(file);
  const content = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  if (!content.startsWith('> **历史归档，不是当前操作指南。**')) throw new Error(`Missing historical marker: ${entry.path}`);
  const hash = crypto.createHash('sha256').update(content).digest('hex');
  if (hash !== entry.importedSha256) throw new Error(`Archive changed: ${entry.path}`);
}
console.log(`Agent historical documents verified: ${seen.size}`);
