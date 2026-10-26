'use strict';
// Offline checker for a candidate corpus ZIP before it is imported.
// Prints ONLY aggregate counts (never member names, never document text), so it is safe to
// paste into a chat or a log.
//
// Usage: node scripts/verify-corpus-zip.cjs --zip <path> [--expect-members N] [--expect-expanded N]
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const args = process.argv.slice(2);
const option = name => { const at = args.indexOf(name); return at >= 0 ? args[at + 1] : undefined; };
const zipPath = option('--zip');
const expectMembers = Number(option('--expect-members') || 0);
const expectExpanded = Number(option('--expect-expanded') || 0);
if (!zipPath) {
  console.error('Usage: node scripts/verify-corpus-zip.cjs --zip <path> [--expect-members N] [--expect-expanded N]');
  process.exit(2);
}

const required = ['_content_list_v2.json', '_content_list.json', 'layout.json'];
const zip = fs.readFileSync(zipPath);

let eocd = -1;
for (let i = zip.length - 22; i >= Math.max(0, zip.length - 65557); i--) {
  if (zip.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
}
if (eocd < 0) { console.error('FAIL: no ZIP end-of-central-directory record'); process.exit(1); }

const count = zip.readUInt16LE(eocd + 10);
let offset = zip.readUInt32LE(eocd + 16);
let expanded = 0;
let crcPassed = 0;
let storedMembers = 0;
let imageMembers = 0;
const suffixes = new Set();
const crc32 = bytes => {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc & 1) ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
};

for (let index = 0; index < count; index++) {
  if (offset + 46 > zip.length || zip.readUInt32LE(offset) !== 0x02014b50) { console.error('FAIL: malformed central directory'); process.exit(1); }
  const method = zip.readUInt16LE(offset + 10);
  const crc = zip.readUInt32LE(offset + 16);
  const compressed = zip.readUInt32LE(offset + 20);
  const declared = zip.readUInt32LE(offset + 24);
  const nameLength = zip.readUInt16LE(offset + 28);
  const extraLength = zip.readUInt16LE(offset + 30);
  const commentLength = zip.readUInt16LE(offset + 32);
  const localOffset = zip.readUInt32LE(offset + 42);
  const name = zip.subarray(offset + 46, offset + 46 + nameLength).toString('utf8');
  if (method === 0) storedMembers++;
  if (/\.(?:png|jpe?g|webp|gif)$/i.test(name)) imageMembers++;
  for (const suffix of required) if (name.endsWith(suffix)) suffixes.add(suffix);
  expanded += declared;
  if (localOffset + 30 <= zip.length) {
    const localName = zip.readUInt16LE(localOffset + 26);
    const localExtra = zip.readUInt16LE(localOffset + 28);
    const start = localOffset + 30 + localName + localExtra;
    const payload = zip.subarray(start, start + compressed);
    try {
      const body = method === 0 ? payload : zlib.inflateRawSync(payload, { maxOutputLength: Math.max(declared, 1) * 2 });
      if (body.length === declared && crc32(body) === crc) crcPassed++;
    } catch { /* counted as failed below */ }
  }
  offset += 46 + nameLength + extraLength + commentLength;
}

const missing = required.filter(suffix => !suffixes.has(suffix));
const problems = [];
if (missing.length) problems.push(`missing required member suffix(es): ${missing.join(', ')}`);
if (crcPassed !== count) problems.push(`CRC mismatch on ${count - crcPassed} member(s)`);
if (storedMembers) problems.push(`${storedMembers} member(s) are stored, expected deflate`);
if (expectMembers && count !== expectMembers) problems.push(`members=${count}, expected ${expectMembers}`);
if (expectExpanded && expanded !== expectExpanded) problems.push(`expanded=${expanded}, expected ${expectExpanded}`);

console.log(JSON.stringify({
  bytes: zip.length,
  members: count,
  crcPassed,
  expandedBytes: expanded,
  imageMembers,
  storedMembers,
  requiredPresent: required.filter(suffix => suffixes.has(suffix)).length,
  verdict: problems.length ? 'FAIL' : 'OK',
  problems
}, null, 2));
process.exit(problems.length ? 1 : 0);
