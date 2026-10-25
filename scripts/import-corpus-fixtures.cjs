'use strict';
// Imports the three frozen offline corpora used by the host tests into
// entry/src/test/fixtures/corpus/, after scanning them for personal data and (optionally)
// scrubbing PDF metadata. This is the only writer of manifest.json.
//
// Privacy: reports only hit categories and counts. Never prints member names, document
// text, absolute paths of the inputs, or the input file names.
//
// Usage:
//   node scripts/import-corpus-fixtures.cjs --inbox <dir> [--scrub-pdf] [--commit] [--accept-scan-findings]
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');

const projectRoot = path.resolve(__dirname, '..');
const corpusRoot = path.join(projectRoot, 'entry/src/test/fixtures/corpus');
const manifestFile = path.join(corpusRoot, 'manifest.json');
const MAX_MEMBER_SCAN = 32 * 1024 * 1024;

function fail(message) {
  console.error(`[ERROR] ${message}`);
  process.exitCode = 1;
}

function parseArgs(argv) {
  const options = { inbox: path.join(projectRoot, '.local/corpus-inbox'), scrubPdf: false, commit: false, accept: false, only: null };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--only') { options.only = new Set((argv[++i] || '').split(',').map(id => id.trim()).filter(Boolean)); continue; }
    if (arg === '--inbox') { options.inbox = path.resolve(argv[++i] || ''); continue; }
    if (arg === '--scrub-pdf') { options.scrubPdf = true; continue; }
    if (arg === '--commit') { options.commit = true; continue; }
    if (arg === '--accept-scan-findings') { options.accept = true; continue; }
    throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const sensitive = [
  ['email', /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g],
  ['windows-user-path', /[A-Za-z]:\\\\?Users\\\\?[^\\/\s"']+/gi],
  ['posix-home-path', /\/home\/[A-Za-z0-9._-]+/g],
  ['bearer-token', /Bearer\s+[A-Za-z0-9._-]{12,}/gi],
  ['api-key', /\bsk-[A-Za-z0-9]{16,}\b/g],
  ['tenant-id', /\b(?:tenant|Tenant)[_-]?id\b/gi]
];

function scanText(text, hits) {
  for (const [name, pattern] of sensitive) {
    const found = text.match(pattern);
    if (found) hits.set(name, (hits.get(name) || 0) + found.length);
  }
}

// Reads the ZIP central directory to enumerate members, then inflates and scans text-like
// members. Returns category counts only.
function scanZip(buffer, hits) {
  let eocd = -1;
  for (let i = buffer.length - 22; i >= Math.max(0, buffer.length - 65557); i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) { hits.set('zip-unparsable', 1); return; }
  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  hits.set('zip-members', count);
  for (let index = 0; index < count; index++) {
    if (offset + 46 > buffer.length || buffer.readUInt32LE(offset) !== 0x02014b50) { hits.set('zip-unparsable', 1); return; }
    const method = buffer.readUInt16LE(offset + 10);
    const compressed = buffer.readUInt32LE(offset + 20);
    const declared = buffer.readUInt32LE(offset + 24);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
    scanText(name, hits);
    if (/^[A-Za-z]:|^\/(?:Users|home)\//.test(name)) hits.set('zip-member-absolute-path', (hits.get('zip-member-absolute-path') || 0) + 1);
    if (declared > 0 && declared <= MAX_MEMBER_SCAN && localOffset + 30 <= buffer.length) {
      const localNameLength = buffer.readUInt16LE(localOffset + 26);
      const localExtraLength = buffer.readUInt16LE(localOffset + 28);
      const dataStart = localOffset + 30 + localNameLength + localExtraLength;
      const payload = buffer.subarray(dataStart, dataStart + compressed);
      try {
        const body = method === 0 ? payload : zlib.inflateRawSync(payload, { maxOutputLength: declared });
        if (!/\.(?:png|jpe?g|gif|webp|zip|pdf|bin|woff2?|ttf|so|dll)$/i.test(name)) scanText(body.toString('utf8'), hits);
      } catch { hits.set('zip-member-unreadable', (hits.get('zip-member-unreadable') || 0) + 1); }
    }
    offset += 46 + nameLength + extraLength + commentLength;
  }
}

function scanPdf(buffer, hits) {
  const text = buffer.toString('latin1');
  for (const key of ['/Author', '/Creator', '/Producer', '/Title', '/Subject', '/Keywords', '/Metadata']) {
    const found = text.split(key).length - 1;
    if (found) hits.set(`pdf-metadata${key}`, found);
  }
  scanText(text, hits);
}

function scanFile(file) {
  const hits = new Map();
  const bytes = fs.readFileSync(file);
  if (/\.pdf$/i.test(file)) scanPdf(bytes, hits); else scanZip(bytes, hits);
  return { hits, bytes };
}

// Rewrites the PDF with empty metadata (keeps pages/content). Requires PyMuPDF ("fitz").
function scrubPdf(input, output) {
  const code = [
    'import sys, fitz',
    'doc = fitz.open(sys.argv[1])',
    'doc.set_metadata({})',
    'doc.del_xml_metadata()',
    'doc.save(sys.argv[2], garbage=4, deflate=True, clean=True)'
  ].join('\n');
  const result = spawnSync('python', ['-c', code, input, output], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`PDF scrub failed: ${(result.stderr || '').trim().split('\n').slice(-1)[0] || 'unknown error'}`);
}

function findInput(entry, inbox) {
  if (!fs.existsSync(inbox)) return null;
  const names = new Set(entry.acceptNames.map(name => name.toLowerCase()));
  const candidates = fs.readdirSync(inbox).filter(name => names.has(name.toLowerCase()));
  if (candidates.length === 0) return null;
  if (candidates.length > 1) throw new Error(`Multiple inputs match ${entry.id}; keep exactly one file in the inbox`);
  return path.join(inbox, candidates[0]);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  const staged = [];
  let findings = 0;

  for (const entry of manifest.entries) {
    if (options.only && !options.only.has(entry.id)) continue;
    const input = findInput(entry, options.inbox);
    if (!input) { fail(`missing input for ${entry.id} (accepted names: ${entry.acceptNames.join(', ')})`); continue; }
    const isPdf = /\.pdf$/i.test(input);
    let source = input;
    if (options.scrubPdf && isPdf) {
      source = path.join(options.inbox, `${entry.id}.scrubbed.pdf`);
      scrubPdf(input, source);
      console.log(`[脱敏] ${entry.id}: PDF 元数据已清空`);
    }
    const { hits, bytes } = scanFile(source);
    const categories = [...hits.keys()].filter(key => !['zip-members', 'pdf-metadata/Metadata'].includes(key) && hits.get(key) > 0);
    findings += categories.length;
    console.log(`[扫描] ${entry.id}: ${bytes.length} bytes, members=${hits.get('zip-members') ?? '-'}, 命中类别=${categories.length ? categories.join(',') : '无'}`);
    staged.push({ entry, source, bytes, hits });
  }

  if (process.exitCode) return;
  if (findings > 0 && !options.accept) {
    fail('scan findings present; review them, then re-run with --accept-scan-findings (or scrub the material)');
    return;
  }
  if (!options.commit) {
    console.log('[完成] 仅扫描（未写入仓库）。确认无敏感命中后加 --commit 入库。');
    return;
  }

  fs.mkdirSync(corpusRoot, { recursive: true });
  for (const item of staged) {
    const target = path.join(corpusRoot, item.entry.file);
    fs.copyFileSync(item.source, target);
    const bytes = fs.readFileSync(target);
    item.entry.status = 'committed';
    item.entry.bytes = bytes.length;
    item.entry.sha256 = sha256(bytes);
    console.log(`[入库] ${item.entry.file}: ${bytes.length} bytes, sha256=${item.entry.sha256}`);
  }
  fs.writeFileSync(manifestFile, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log('[完成] manifest.json 已更新；请提交 fixtures/corpus 下的文件与清单。');
}

try {
  main();
} catch (error) {
  fail(error.message);
}
