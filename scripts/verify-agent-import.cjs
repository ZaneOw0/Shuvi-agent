// Verify the imported source snapshot without an upstream checkout or network.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../modules/harmony_agent');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'UPSTREAM.json'), 'utf8'));
assert.equal(manifest.schemaVersion, 1);
assert.match(manifest.commit, /^[0-9a-f]{40}$/);
const seen = new Set();
for (const file of manifest.files) {
  const absolute = path.resolve(root, file.path);
  assert(absolute.startsWith(root + path.sep), `Path outside snapshot: ${file.path}`);
  assert(!seen.has(file.path), `Duplicate manifest entry: ${file.path}`);
  seen.add(file.path);
  // Git checkouts may use CRLF; the upstream source blobs use LF.
  const contents = fs.readFileSync(absolute, 'utf8').replace(/\r\n/g, '\n');
  const digest = crypto.createHash('sha256').update(contents).digest('hex');
  assert.equal(digest, file.sha256, `Imported baseline changed; review and record the local change: ${file.path}`);
}
const modulePaths = new Set(manifest.modules.map(module => path.join(root, module.directory)));
const projectRoot = path.resolve(root, '../..');
const entryPackage = JSON.parse(fs.readFileSync(path.join(projectRoot, 'entry/oh-package.json5'), 'utf8'));
const buildProfile = JSON.parse(fs.readFileSync(path.join(projectRoot, 'build-profile.json5'), 'utf8'));
const hostRoot = path.join(projectRoot, 'tests/agent-host');
const hostProfile = JSON.parse(fs.readFileSync(path.join(hostRoot, 'build-profile.json5'), 'utf8'));
for (const module of manifest.modules) {
  const folder = path.join(root, module.directory);
  const pkg = JSON.parse(fs.readFileSync(path.join(folder, 'oh-package.json5'), 'utf8'));
  assert.equal(pkg.name, module.name);
  assert.equal(pkg.version, module.version);
  assert.equal(pkg.license, manifest.licenseDeclaredByUpstreamPackages);
  assert(['product', 'test-host-only'].includes(module.usage), `Unknown usage: ${module.directory}`);
  const registered = buildProfile.modules.find(item => item.name === module.directory);
  if (module.usage === 'product') {
    assert.equal(entryPackage.dependencies[module.name], `file:../modules/harmony_agent/${module.directory}`);
    assert(registered, `Module not registered in product: ${module.directory}`);
    assert.equal(path.resolve(projectRoot, registered.srcPath), folder);
  } else {
    assert.equal(entryPackage.dependencies[module.name], undefined, 'Test-only module entered product dependencies');
    assert.equal(registered, undefined, 'Test-only module entered product build');
  }
  const hostRegistered = hostProfile.modules.find(item => item.name === module.directory);
  assert(hostRegistered, `Module not registered in test host: ${module.directory}`);
  assert.equal(path.resolve(hostRoot, hostRegistered.srcPath), folder);
  for (const [name, spec] of Object.entries(pkg.dependencies ?? {})) {
    assert(spec.startsWith('file:'), `Unexpected external dependency: ${name}`);
    const target = path.resolve(folder, spec.slice(5));
    assert(modulePaths.has(target), `Dependency outside imported modules: ${name}`);
    const dependency = JSON.parse(fs.readFileSync(path.join(target, 'oh-package.json5'), 'utf8'));
    assert.equal(dependency.name, name);
  }
}
function checkSourceTree(folder) {
  for (const item of fs.readdirSync(folder, { withFileTypes: true })) {
    if (['build', 'oh_modules', '.hvigor', '.cxx', '.test'].includes(item.name)) continue;
    const absolute = path.join(folder, item.name);
    assert(!item.isSymbolicLink(), `Unexpected symlink: ${absolute}`);
    if (item.isDirectory()) {
      checkSourceTree(absolute);
    } else {
      const relative = path.relative(root, absolute).split(path.sep).join('/');
      const generated = manifest.modules.some(module =>
        relative === `${module.directory}/BuildProfile.ets` ||
        relative === `${module.directory}/oh-package-lock.json5`);
      assert(generated || seen.has(relative), `Unlisted upstream file: ${relative}`);
    }
  }
}
for (const module of manifest.modules) checkSourceTree(path.join(root, module.directory));
console.log(`Verified ${manifest.files.length} upstream files and ${manifest.modules.length} local modules (${manifest.commit}).`);
