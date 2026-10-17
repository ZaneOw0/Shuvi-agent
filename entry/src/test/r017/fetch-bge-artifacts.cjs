// Optional explicit public download, never invoked by the offline test runner.
// Fixed model snapshot and tokenizer-only allowlist. No cookies or environment credentials.
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../../../..');
const cache = path.join(root, '.cache/r017-tokenizer');
const metadataFile = path.join(root, 'entry/src/main/resources/rawfile/embedding/bge_m3/proof-metadata.json');
const metadata = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
fs.mkdirSync(cache, { recursive: true });
for (const entry of metadata.artifacts) {
  if (!['tokenizer.json', 'sentencepiece.bpe.model', 'tokenizer_config.json', 'special_tokens_map.json', 'config.json', 'README.md'].includes(entry.file) ||
    entry.bytes > 18000000 || !/^[a-f0-9]{64}$/.test(entry.sha256) ||
    entry.url !== `https://modelscope.cn/api/v1/models/BAAI/bge-m3/repo?Revision=a46a13810c9d7f876fccd8d7017512ebc265d2c1&FilePath=${entry.file}`) {
    throw new Error('Unreviewed public artifact');
  }
  const file = path.join(cache, entry.file);
  if (!fs.existsSync(file) || crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== entry.sha256) {
    const result = cp.spawnSync('curl', ['--disable', '--fail', '--silent', '--show-error', '--location', '--max-time', '90',
      '--max-filesize', String(entry.bytes), '--proto', '=https', '--proto-redir', '=https', '--output', file, entry.url], { encoding: 'utf8' });
    if (result.status !== 0) throw new Error(`Public artifact download failed: ${entry.file} RC=${result.status}`);
  }
  const bytes = fs.readFileSync(file);
  if (bytes.length !== entry.bytes || crypto.createHash('sha256').update(bytes).digest('hex') !== entry.sha256) throw new Error('Artifact integrity failure');
  console.log(`PUBLIC_ARTIFACT ${entry.file} ${bytes.length} ${entry.sha256}`);
}
