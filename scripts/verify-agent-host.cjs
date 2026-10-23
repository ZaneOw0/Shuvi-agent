// Verify test-only imports, reviewed relocations and isolation from the product.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
require('./verify-agent-import.cjs');
const project = path.resolve(__dirname, '..');
const host = path.join(project, 'tests/agent-host');
const modulesRoot = path.join(project, 'modules/harmony_agent');
const moduleManifest = JSON.parse(fs.readFileSync(path.join(modulesRoot, 'UPSTREAM.json'), 'utf8'));
const readJson = p => JSON.parse(fs.readFileSync(p, 'utf8'));
let total = 0;
for (const relative of ['tests/agent-host', 'tools/agent']) {
  const root = path.join(project, relative);
  const manifest = readJson(path.join(root, 'UPSTREAM.json'));
  assert.equal(manifest.commit, moduleManifest.commit);
  const seen = new Set();
  for (const file of manifest.files) {
    const target = path.resolve(root, file.path);
    assert(target.startsWith(root + path.sep));
    assert(!seen.has(file.path));
    seen.add(file.path);
    const data = fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n');
    const digest = crypto.createHash('sha256').update(data).digest('hex');
    assert.equal(digest, file.importedSha256, `Reviewed import changed: ${file.path}`);
    assert.match(file.sourceSha256, /^[0-9a-f]{64}$/);
    if (file.sourceSha256 !== file.importedSha256) assert(file.change, 'Unexplained source modification');
    total++;
  }
}
const profile = readJson(path.join(host, 'build-profile.json5'));
const product = readJson(path.join(project, 'build-profile.json5'));
assert.deepEqual(profile.app.signingConfigs, []);
assert.equal(profile.app.products[0].compatibleSdkVersion, product.app.products[0].compatibleSdkVersion);
assert.equal(profile.app.products[0].targetSdkVersion, product.app.products[0].targetSdkVersion);
assert.equal(profile.app.products[0].runtimeOS, product.app.products[0].runtimeOS);
assert.deepEqual(readJson(path.join(host, 'oh-package.json5')).devDependencies, readJson(path.join(project, 'oh-package.json5')).devDependencies);
const app = readJson(path.join(host, 'AppScope/app.json5'));
assert.equal(app.app.bundleName, 'com.example.shuvi.agenttest');
assert.notEqual(app.app.bundleName, readJson(path.join(project, 'AppScope/app.json5')).app.bundleName);
assert.equal(profile.modules.filter(m => m.name === 'test_host').length, 1);
const hostPackage = readJson(path.join(host, 'test_host/oh-package.json5'));
for (const [name, spec] of Object.entries(hostPackage.dependencies)) {
  assert(spec.startsWith('file:'));
  const target = path.resolve(host, 'test_host', spec.slice(5));
  assert(moduleManifest.modules.some(m => path.join(modulesRoot, m.directory) === target));
  assert.equal(readJson(path.join(target, 'oh-package.json5')).name, name);
}
assert(!product.modules.some(m => m.name === 'test_host'));
console.log(`Verified ${total} host/fixture imports, SDK baseline and isolated test bundle.`);
