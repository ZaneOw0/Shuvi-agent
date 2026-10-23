// Optional host-only official reference implementations. No application dependency changes.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const cache = path.resolve(__dirname, '../../../../.cache/r017-tokenizer');
function download(url, name, expected) {
  if (!/^https:\/\/(?:pypi\.org\/pypi\/|files\.pythonhosted\.org\/packages\/)/.test(url)) throw new Error('Non-public source');
  const file = path.join(cache, name);
  const result = cp.spawnSync('curl', ['--disable', '--fail', '--location', '--silent', '--show-error', '--max-time', '90',
    '--max-filesize', '6000000', '--proto', '=https', '--proto-redir', '=https', '--output', file, url], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`Public reference download failed: ${result.status}`);
  const bytes = fs.readFileSync(file), sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  if (expected && sha256 !== expected) throw new Error('Reference wheel hash mismatch');
  return { file: name, bytes: bytes.length, sha256, url };
}
const evidence = [];
for (const [name, version] of [['tokenizers', '0.22.1'], ['sentencepiece', '0.2.1']]) {
  evidence.push(download(`https://pypi.org/pypi/${name}/${version}/json`, name + '-pypi.json'));
  const metadata = JSON.parse(fs.readFileSync(path.join(cache, name + '-pypi.json'), 'utf8'));
  const wheel = metadata.urls.find(f => f.filename.includes('cp39-') && /macosx_.*arm64.whl$/.test(f.filename));
  const expected = name === 'tokenizers' ? '8d4e484f7b0827021ac5f9f71d4794aaef62b979ab7608593da22b1d2e3c4edc'
    : '814978ac05130dd5812b4b03215c766bc6abaef13e7bd72bc534e4d1e12e9a4c';
  if (!wheel || wheel.size > 6000000 || wheel.digests.sha256 !== expected) throw new Error('No reviewed compatible reference wheel');
  evidence.push(download(wheel.url, wheel.filename, wheel.digests.sha256));
  const target = path.join(cache, 'oracle'); fs.mkdirSync(target, { recursive: true });
  const extract = cp.spawnSync('python3', ['-m', 'zipfile', '-e', path.join(cache, wheel.filename), target], { encoding: 'utf8' });
  if (extract.status !== 0) throw new Error('Reference extraction failed');
  if (name === 'tokenizers') {
    const source = metadata.urls.find(f => f.packagetype === 'sdist');
    if (source.digests.sha256 !== '61de6522785310a309b3407bac22d99c4db5dba349935e99e4d15ea2226af2d9') throw new Error('Unreviewed reference source');
    evidence.push(download(source.url, source.filename, source.digests.sha256));
    const unpack = cp.spawnSync('tar', ['-xzf', path.join(cache, source.filename), '-C', cache], { encoding: 'utf8' });
    if (unpack.status !== 0) throw new Error('Reference source extraction failed');
  }
}
fs.writeFileSync(path.join(cache, 'oracle-evidence.json'), JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify(evidence));
