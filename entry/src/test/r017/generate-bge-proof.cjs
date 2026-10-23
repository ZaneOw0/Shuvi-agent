// Offline derivation. Reads only reviewed public artifacts in .cache/r017-tokenizer.
// Writes only R017 cache and resource files; never downloads or executes artifact code.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const project = path.resolve(__dirname, '../../../..');
const cache = path.join(project, '.cache/r017-tokenizer');
const resource = path.join(project, 'entry/src/main/resources/rawfile/embedding/bge_m3');
const revision = 'a46a13810c9d7f876fccd8d7017512ebc265d2c1';
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const artifacts = [
  ['sentencepiece.bpe.model', 5069051, 'cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865'],
  ['tokenizer.json', 17098108, '21106b6d7dab2952c1d496fb21d5dc9db75c28ed361a05f5020bbba27810dd08'],
  ['tokenizer_config.json', 444, 'a62b2b6784f990259fddef5f16388693a8043be4f69179e6a5257eeb3f9abac4'],
  ['special_tokens_map.json', 964, '8c785abebea9ae3257b61681b4e6fd8365ceafde980c21970d001e834cf10835'],
  ['config.json', 687, '26159e7ad065073448460117eb24b7a4572f6f4e78eadff65dc0a11c052449fa'],
  ['README.md', 15822, '0b81ccf9134e5874d620a86e6905062ea999e779c34eb1a7e65eaeb7fe00e450']
];
for (const [name, size, digest] of artifacts) {
  const bytes = fs.readFileSync(path.join(cache, name));
  if (bytes.length !== size || sha(bytes) !== digest) throw new Error(`Public artifact mismatch: ${name}`);
}
function protobuf(bytes) {
  let pos = 0;
  const fields = new Map();
  function varint() {
    let value = 0, shift = 0;
    for (let i = 0; i < 10; i++) {
      if (pos >= bytes.length) throw new Error('Truncated protobuf');
      const b = bytes[pos++]; value += (b & 127) * 2 ** shift;
      if (!(b & 128)) return value;
      shift += 7;
    }
    throw new Error('Invalid protobuf varint');
  }
  while (pos < bytes.length) {
    const key = varint(), field = Math.floor(key / 8), wire = key % 8;
    let value;
    if (wire === 0) value = varint();
    else if (wire === 2) { const length = varint(); value = bytes.subarray(pos, pos + length); pos += length; }
    else if (wire === 5) { value = bytes.subarray(pos, pos + 4); pos += 4; }
    else if (wire === 1) { value = bytes.subarray(pos, pos + 8); pos += 8; }
    else throw new Error('Unsupported protobuf wire type');
    if (pos > bytes.length) throw new Error('Truncated protobuf field');
    if (!fields.has(field)) fields.set(field, []);
    fields.get(field).push(value);
  }
  return fields;
}
function one(fields, key, fallback) { return fields.get(key)?.[0] ?? fallback; }
function charsmapRules(blob) {
  const trieBytes = blob.readUInt32LE(0);
  if (trieBytes < 1024 || trieBytes % 1024 || trieBytes + 4 >= blob.length) throw new Error('Invalid charsmap');
  const units = Array.from({ length: trieBytes / 4 }, (_, i) => blob.readUInt32LE(4 + i * 4));
  const output = blob.subarray(4 + trieBytes);
  const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
  const offset = unit => ((unit >>> 10) << ((unit & 512) >>> 6)) >>> 0;
  const rules = [];
  function walk(index, prefix, ancestors) {
    if (ancestors.has(index) || prefix.length > 64 || rules.length > 1000000) throw new Error('Unbounded charsmap');
    const unit = units[index], base = (index ^ offset(unit)) >>> 0;
    if (unit & 256) {
      const pointer = units[base] & 0x7fffffff;
      const end = output.indexOf(0, pointer);
      if (end < pointer) throw new Error('Unterminated charsmap output');
      rules.push([decoder.decode(Buffer.from(prefix)), decoder.decode(output.subarray(pointer, end))]);
    }
    const nextAncestors = new Set(ancestors); nextAncestors.add(index);
    for (let b = 1; b <= 255; b++) {
      const child = (base ^ b) >>> 0;
      if (child < units.length && ((units[child] & 0x800000ff) >>> 0) === b) walk(child, [...prefix, b], nextAncestors);
    }
  }
  walk(0, [], new Set());
  return { rules, trieBytes, outputBytes: output.length };
}
function derive() {
  const model = protobuf(fs.readFileSync(path.join(cache, artifacts[0][0])));
  const trainer = protobuf(one(model, 2));
  const normalizer = protobuf(one(model, 3));
  const blob = one(normalizer, 2);
  const parsed = charsmapRules(blob);
  const fast = JSON.parse(fs.readFileSync(path.join(cache, 'tokenizer.json'), 'utf8'));
  const config = JSON.parse(fs.readFileSync(path.join(cache, 'tokenizer_config.json'), 'utf8'));
  const special = JSON.parse(fs.readFileSync(path.join(cache, 'special_tokens_map.json'), 'utf8'));
  const modelConfig = JSON.parse(fs.readFileSync(path.join(cache, 'config.json'), 'utf8'));
  if (!fs.readFileSync(path.join(cache, 'README.md'), 'utf8').startsWith('---\npipeline_tag: sentence-similarity\n') ||
    !fs.readFileSync(path.join(cache, 'README.md'), 'utf8').includes('\nlicense: mit\n')) throw new Error('Model license evidence changed');
  const pieceTypes = new Map();
  for (const entry of model.get(1)) {
    const piece = protobuf(entry), type = one(piece, 3, 1), text = one(piece, 1).toString('utf8');
    if (!text) throw new Error('Empty SentencePiece piece');
    pieceTypes.set(type, (pieceTypes.get(type) || 0) + 1);
  }
  const weights = new Map();
  for (const [source, target] of parsed.rules) {
    const first = source.codePointAt(0), length = Array.from(target).length;
    if (length > (weights.get(first) || 1)) weights.set(first, length);
  }
  const ranges = [];
  for (const [cp, weight] of [...weights].sort((a, b) => a[0] - b[0])) {
    const prev = ranges[ranges.length - 1];
    if (prev && prev[1] + 1 === cp && prev[2] === weight) prev[1] = cp;
    else ranges.push([cp, cp, weight]);
  }
  const fastBlob = Buffer.from(fast.normalizer.normalizers.find(n => n.type === 'Precompiled').precompiled_charsmap, 'base64');
  if (!blob.equals(fastBlob)) throw new Error('Slow/fast charsmap mismatch');
  const profile = {
    schema: 'BGE-M3-SCALAR-BOUND-1', modelId: 'BAAI/bge-m3', source: 'https://modelscope.cn/BAAI/bge-m3', revision,
    upstreamHuggingFaceRevision: 'NotIndependentlyResolved', providerRevision: 'NotReported',
    baseModelType: modelConfig.model_type,
    license: { identifier: 'MIT', declaration: 'README.md frontmatter at pinned revision',
      noticeSource: 'Official FlagEmbedding 1.4.2 distribution LICENSE; copyright (c) 2022 staoxiao',
      noticeSourceArchiveSha256: 'c9dfd0faac52ae7f87a7ac47bd58fdacdd0ce3ef48a097b8255ddc86df88bb1b' },
    referenceImplementation: { fast: 'huggingface/tokenizers 0.22.1', slowNormalizer: 'google/sentencepiece 0.2.1',
      fastSourceArchiveSha256: '61de6522785310a309b3407bac22d99c4db5dba349935e99e4d15ea2226af2d9',
      scope: 'Official public host reference only; no runtime dependency; provider equivalence not established' },
    artifacts: artifacts.map(([file, bytes, sha256]) => ({ file, bytes, sha256,
      url: `https://modelscope.cn/api/v1/models/BAAI/bge-m3/repo?Revision=${revision}&FilePath=${file}` })),
    sentencepiece: { modelType: one(trainer, 3, 1), byteFallback: !!one(trainer, 35, 0),
      byteFallbackFieldPresent: trainer.has(35), modelTypeFieldPresent: trainer.has(3),
      treatWhitespaceAsSuffix: !!one(trainer, 24, 0), pieceTypes: Object.fromEntries(pieceTypes),
      userDefinedSymbols: (trainer.get(31) || []).map(b => b.toString('utf8')),
      normalizer: { name: one(normalizer, 1).toString('utf8'), addDummyPrefix: !!one(normalizer, 3, 1),
        removeExtraWhitespaces: !!one(normalizer, 4, 1), escapeWhitespaces: !!one(normalizer, 5, 1),
        charsmapBytes: blob.length, charsmapSha256: sha(blob), trieBytes: parsed.trieBytes, outputBytes: parsed.outputBytes } },
    fast: { version: fast.version, truncation: fast.truncation, padding: fast.padding, addedTokens: fast.added_tokens,
      normalizer: { type: fast.normalizer.type, normalizers: fast.normalizer.normalizers.map(n => n.type === 'Precompiled'
        ? { type: n.type, charsmapSha256: sha(fastBlob) } : n) }, preTokenizer: fast.pre_tokenizer,
      postProcessor: fast.post_processor, modelType: fast.model.type, unkId: fast.model.unk_id,
      byteFallback: fast.model.byte_fallback ?? false, byteFallbackFieldPresent: Object.hasOwn(fast.model, 'byte_fallback'),
      byteFallbackDefaultEvidence: 'tokenizers 0.22.1 tokenizers/src/models/unigram/serialization.rs:51', vocabularySize: fast.model.vocab.length,
      emptyPieces: fast.model.vocab.filter(v => !v[0]).length },
    tokenizerConfig: config, specialTokensMap: special,
    derivation: { ruleCount: parsed.rules.length, expandingFirstScalars: weights.size, rangeCount: ranges.length,
      maximumWeight: Math.max(...weights.values()), defaultWeight: 1,
      ruleSha256: sha(Buffer.from(JSON.stringify(parsed.rules))),
      weightsSha256: sha(Buffer.from(JSON.stringify(ranges))), ranges }
  };
  fs.writeFileSync(path.join(cache, 'charsmap-rules.json'), JSON.stringify(parsed.rules) + '\n');
  fs.writeFileSync(path.join(cache, 'derived-profile.json'), JSON.stringify(profile, null, 2) + '\n');
  if (process.argv.includes('--resources')) {
    if (profile.sentencepiece.modelType !== 1 || profile.sentencepiece.byteFallback || profile.fast.modelType !== 'Unigram' ||
      profile.fast.byteFallback || profile.fast.emptyPieces || profile.sentencepiece.userDefinedSymbols.length || pieceTypes.has(4) || pieceTypes.has(6)) {
      throw new Error('Unsupported proof premises');
    }
    fs.mkdirSync(resource, { recursive: true });
    fs.writeFileSync(path.join(resource, 'proof-metadata.json'), JSON.stringify(profile, null, 2) + '\n');
    fs.writeFileSync(path.join(resource, 'scalar-weights.txt'), ranges.map(r => r.join(':')).join('\n') + '\n');
  }
  console.log(JSON.stringify({ sentencepiece: profile.sentencepiece, fast: profile.fast,
    derivation: { ...profile.derivation, ranges: undefined } }, null, 2));
}
if (require.main === module) derive();
module.exports = { protobuf, charsmapRules, derive };
