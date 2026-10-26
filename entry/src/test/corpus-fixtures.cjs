'use strict';
// Resolver for the committed, sanitized, hash-pinned offline corpora used by the host
// tests. Corpus fixtures are frozen evidence: this module refuses to run when an entry is
// not committed yet, is missing, or its bytes no longer match the pinned hash. It never
// repairs, copies or downloads anything at test time.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const corpusRoot = path.join(__dirname, 'fixtures/corpus');
const digestOf = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function readManifest(root = corpusRoot) {
  const file = path.join(root, 'manifest.json');
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    throw new Error(`Corpus manifest missing or unreadable: ${path.join(path.basename(root), 'manifest.json')}`);
  }
  if (!manifest || !Array.isArray(manifest.entries)) throw new Error('Corpus manifest must contain an entries array');
  return manifest;
}

function requireCorpus(id, root = corpusRoot) {
  const manifest = readManifest(root);
  const entry = manifest.entries.find(item => item && item.id === id);
  if (!entry) throw new Error(`Unknown corpus fixture: ${id}`);
  if (entry.status !== 'committed') {
    throw new Error(`Corpus fixture ${entry.id} is not committed yet (status: ${entry.status}); see entry/src/test/fixtures/corpus/README.md`);
  }
  if (!Number.isSafeInteger(entry.bytes) || entry.bytes <= 0) throw new Error(`Corpus manifest entry ${entry.id} has no pinned size`);
  if (typeof entry.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(entry.sha256)) throw new Error(`Corpus manifest entry ${entry.id} has no pinned sha256`);
  const file = path.join(root, entry.file);
  let bytes;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    throw new Error(`Missing committed corpus fixture: ${entry.file}`);
  }
  if (bytes.length !== entry.bytes) throw new Error(`Corpus fixture size changed: ${entry.file} (expected ${entry.bytes}, got ${bytes.length})`);
  if (digestOf(bytes) !== entry.sha256) throw new Error(`Corpus fixture hash changed: ${entry.file}`);
  return { entry, file, bytes, sha256: entry.sha256 };
}

module.exports = { requireCorpus, readManifest, digestOf, corpusRoot };
