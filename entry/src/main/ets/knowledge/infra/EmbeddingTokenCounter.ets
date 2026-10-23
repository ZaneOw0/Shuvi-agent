// R017 is independent of shared embedding models, ports and authorization policy.
export enum BgeM3CountState {
  SafeUnderPinnedProfile = 'SafeUnderPinnedProfile',
  BoundUnproven = 'BoundUnproven',
  InvalidInput = 'InvalidInput',
  UnsupportedProfile = 'UnsupportedProfile'
}

export enum BgeM3InputRole { Document = 'Document', Query = 'Query', Probe = 'Probe' }

export class BgeM3TokenProfile {
  static readonly id: string = 'BGE-M3-MS-a46a138-fast-scalar-v1';
  static readonly modelId: string = 'BAAI/bge-m3';
  static readonly revision: string = 'a46a13810c9d7f876fccd8d7017512ebc265d2c1';
  static readonly evidenceVersion: string = 'BGE-M3-SCALAR-BOUND-1';
  static readonly tokenizerSha256: string = '21106b6d7dab2952c1d496fb21d5dc9db75c28ed361a05f5020bbba27810dd08';
  static readonly weightsSha256: string = 'd05d0175a046b03c786c08ef8d5f396ddc9330516c76067cfae6a3f0ad19ff41';
  static readonly metadataSha256: string = '4f0e7a8a26e481c9c2dade315528e60630d2075aa5801363b93f9bfbd224603e';
  static readonly contextLimit: number = 8192;
  static readonly maxUtf16Units: number = 131072;
  static readonly weightsResource: string = 'embedding/bge_m3/scalar-weights.txt';
  static readonly metadataResource: string = 'embedding/bge_m3/proof-metadata.json';
}

export class BgeM3CountInput {
  // Already-final input string, including all caller prefixes. Not a JSON request body.
  fullInput: string = '';
  modelId: string = BgeM3TokenProfile.modelId;
  profileId: string = BgeM3TokenProfile.id;
  profileRevision: string = BgeM3TokenProfile.revision;
  role: BgeM3InputRole = BgeM3InputRole.Document;
  policyVersion: string = '';
  tokenBudget: number = BgeM3TokenProfile.contextLimit;
}

export class BgeM3CountEvidence {
  state: BgeM3CountState = BgeM3CountState.InvalidInput;
  reason: string = 'NotCounted';
  profileBoundProven: boolean = false;
  upperBound: number = -1;
  contextLimit: number = BgeM3TokenProfile.contextLimit;
  tokenBudget: number = -1;
  textHash: string = '';
  bindingHash: string = '';
  modelId: string = '';
  profileId: string = BgeM3TokenProfile.id;
  profileRevision: string = BgeM3TokenProfile.revision;
  evidenceVersion: string = BgeM3TokenProfile.evidenceVersion;
  evidenceProvenance: string = 'ModelScopePublicSnapshot;FixedTokenizerJson;EnumeratedCharsmap';
  tokenizerSha256: string = BgeM3TokenProfile.tokenizerSha256;
  role: string = '';
  policyVersion: string = '';
  inputScalars: number = 0;
  ordinaryWeight: number = 0;
  ordinarySegments: number = 0;
  literalSpecialTokens: number = 0;
  providerRevision: string = 'NotReported';
  providerConsistency: string = 'UnverifiedRevisionAndHiddenProcessing';
  applicableScope: string = 'PinnedFastSingleSequence;NoPadding;NoTruncation;NoHiddenPrefix;NotProviderUsageOrGrant';
}

class BgeM3ScalarWeight {
  first: number = 0;
  last: number = 0;
  weight: number = 1;
}

function bgeM3ScalarAt(text: string, offset: number): number {
  const first: number = text.charCodeAt(offset);
  if (first >= 0xD800 && first <= 0xDBFF) {
    const second: number = text.charCodeAt(offset + 1);
    if (!(second >= 0xDC00 && second <= 0xDFFF)) { return -1; }
    return 0x10000 + (first - 0xD800) * 1024 + second - 0xDC00;
  }
  if (first >= 0xDC00 && first <= 0xDFFF) { return -1; }
  return first;
}

function bgeM3Utf8(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let at: number = 0; at < text.length;) {
    const scalar: number = bgeM3ScalarAt(text, at);
    if (scalar < 0) { throw new Error('R017:InvalidUtf16'); }
    at += scalar > 0xFFFF ? 2 : 1;
    if (scalar < 0x80) { bytes.push(scalar); }
    else if (scalar < 0x800) { bytes.push(0xC0 | (scalar >> 6), 0x80 | (scalar & 63)); }
    else if (scalar < 0x10000) { bytes.push(0xE0 | (scalar >> 12), 0x80 | ((scalar >> 6) & 63), 0x80 | (scalar & 63)); }
    else { bytes.push(0xF0 | (scalar >> 18), 0x80 | ((scalar >> 12) & 63), 0x80 | ((scalar >> 6) & 63), 0x80 | (scalar & 63)); }
  }
  return new Uint8Array(bytes);
}

function bgeM3Rotate(word: number, bits: number): number { return (word >>> bits) | (word << (32 - bits)); }

// FIPS 180-4 SHA-256, over strict UTF-8. No platform APIs or shared adapter needed.
function bgeM3Sha256(text: string): string {
  const input: Uint8Array = bgeM3Utf8(text);
  const padded: Uint8Array = new Uint8Array(Math.ceil((input.length + 9) / 64) * 64);
  padded.set(input); padded[input.length] = 128;
  const bitLength: number = input.length * 8;
  for (let at: number = 0; at < 8; at++) { padded[padded.length - 1 - at] = Math.floor(bitLength / Math.pow(256, at)) & 255; }
  const constants: number[] = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ];
  const hash: number[] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  const words: number[] = new Array<number>(64).fill(0);
  for (let block: number = 0; block < padded.length; block += 64) {
    for (let at: number = 0; at < 16; at++) {
      const start: number = block + at * 4;
      words[at] = (padded[start] << 24) | (padded[start + 1] << 16) | (padded[start + 2] << 8) | padded[start + 3];
    }
    for (let at: number = 16; at < 64; at++) {
      const left: number = words[at - 15]; const right: number = words[at - 2];
      const s0: number = bgeM3Rotate(left, 7) ^ bgeM3Rotate(left, 18) ^ (left >>> 3);
      const s1: number = bgeM3Rotate(right, 17) ^ bgeM3Rotate(right, 19) ^ (right >>> 10);
      words[at] = (words[at - 16] + s0 + words[at - 7] + s1) | 0;
    }
    let a: number = hash[0]; let b: number = hash[1]; let c: number = hash[2]; let d: number = hash[3];
    let e: number = hash[4]; let f: number = hash[5]; let g: number = hash[6]; let h: number = hash[7];
    for (let at: number = 0; at < 64; at++) {
      const sum1: number = bgeM3Rotate(e, 6) ^ bgeM3Rotate(e, 11) ^ bgeM3Rotate(e, 25);
      const choice: number = (e & f) ^ (~e & g);
      const temp1: number = (h + sum1 + choice + constants[at] + words[at]) | 0;
      const sum0: number = bgeM3Rotate(a, 2) ^ bgeM3Rotate(a, 13) ^ bgeM3Rotate(a, 22);
      const majority: number = (a & b) ^ (a & c) ^ (b & c);
      const temp2: number = (sum0 + majority) | 0;
      h = g; g = f; f = e; e = (d + temp1) | 0; d = c; c = b; b = a; a = (temp1 + temp2) | 0;
    }
    hash[0] = (hash[0] + a) | 0; hash[1] = (hash[1] + b) | 0; hash[2] = (hash[2] + c) | 0; hash[3] = (hash[3] + d) | 0;
    hash[4] = (hash[4] + e) | 0; hash[5] = (hash[5] + f) | 0; hash[6] = (hash[6] + g) | 0; hash[7] = (hash[7] + h) | 0;
  }
  return hash.map((word: number): string => (word >>> 0).toString(16).padStart(8, '0')).join('');
}

export class BgeM3TokenCounter {
  private weights: BgeM3ScalarWeight[] = [];

  // Integration loads only weightsResource as UTF-8. The digest pins exact bytes including LF.
  constructor(weightsText: string) {
    if (weightsText.length !== 3663 || bgeM3Sha256(weightsText) !== BgeM3TokenProfile.weightsSha256) {
      throw new Error('R017:WeightResourceIntegrity');
    }
    const rows: string[] = weightsText.trimEnd().split('\n');
    let previous: number = -1;
    for (const row of rows) {
      const fields: string[] = row.split(':');
      const entry: BgeM3ScalarWeight = new BgeM3ScalarWeight();
      entry.first = Number(fields[0]); entry.last = Number(fields[1]); entry.weight = Number(fields[2]);
      if (fields.length !== 3 || !Number.isInteger(entry.first) || !Number.isInteger(entry.last) ||
        !Number.isInteger(entry.weight) || entry.first <= previous || entry.first > entry.last ||
        entry.last > 0x10FFFF || entry.weight < 2 || entry.weight > 18) { throw new Error('R017:WeightResourceFormat'); }
      this.weights.push(entry); previous = entry.last;
    }
    if (this.weights.length !== 277) { throw new Error('R017:WeightResourceCount'); }
  }

  private weight(scalar: number): number {
    let first: number = 0; let last: number = this.weights.length - 1;
    while (first <= last) {
      const middle: number = Math.floor((first + last) / 2); const entry: BgeM3ScalarWeight = this.weights[middle];
      if (scalar < entry.first) { last = middle - 1; }
      else if (scalar > entry.last) { first = middle + 1; }
      else { return entry.weight; }
    }
    return 1;
  }

  count(input: BgeM3CountInput): BgeM3CountEvidence {
    const result: BgeM3CountEvidence = new BgeM3CountEvidence();
    result.modelId = input.modelId; result.role = input.role; result.policyVersion = input.policyVersion;
    result.tokenBudget = input.tokenBudget;
    if (input.modelId !== BgeM3TokenProfile.modelId || input.profileId !== BgeM3TokenProfile.id ||
      input.profileRevision !== BgeM3TokenProfile.revision) {
      result.state = BgeM3CountState.UnsupportedProfile; result.reason = 'PinnedProfileMismatch'; return result;
    }
    if (input.fullInput.length === 0 || input.fullInput.length > BgeM3TokenProfile.maxUtf16Units ||
      input.policyVersion.length === 0 || input.policyVersion.length > 256 ||
      !Number.isInteger(input.tokenBudget) || input.tokenBudget < 2 || input.tokenBudget > result.contextLimit ||
      (input.role !== BgeM3InputRole.Document && input.role !== BgeM3InputRole.Query && input.role !== BgeM3InputRole.Probe)) {
      result.reason = 'InvalidInputOrLocalBudget'; return result;
    }
    for (let at: number = 0; at < input.policyVersion.length;) {
      const scalar: number = bgeM3ScalarAt(input.policyVersion, at);
      if (scalar < 0) { result.reason = 'InvalidPolicyUtf16'; return result; }
      at += scalar > 0xFFFF ? 2 : 1;
    }
    const specialTokens: string[] = ['<s>', '<pad>', '</s>', '<unk>', '<mask>'];
    let ordinary: boolean = false;
    for (let at: number = 0; at < input.fullInput.length;) {
      let literal: string = '';
      if (input.fullInput.charCodeAt(at) === 60) {
        for (const token of specialTokens) { if (input.fullInput.startsWith(token, at)) { literal = token; break; } }
      }
      if (literal.length > 0) {
        result.literalSpecialTokens++; result.inputScalars += literal.length;
        ordinary = false; at += literal.length; continue;
      }
      const scalar: number = bgeM3ScalarAt(input.fullInput, at);
      if (scalar < 0) { result.reason = 'InvalidInputUtf16'; return result; }
      if (!ordinary) { result.ordinarySegments++; ordinary = true; }
      result.inputScalars++; result.ordinaryWeight += this.weight(scalar);
      at += scalar > 0xFFFF ? 2 : 1;
    }
    result.textHash = bgeM3Sha256(input.fullInput);
    const binding: string[] = [result.evidenceVersion, result.modelId, result.profileId, result.profileRevision,
      result.tokenizerSha256, result.role, result.policyVersion, `${input.tokenBudget}`, result.textHash];
    result.bindingHash = bgeM3Sha256(binding.map((field: string): string => `${field.length}:${field}`).join(''));
    // Each rule consumes >=1 input scalar. Metaspace adds at most one scalar per plain fragment.
    // MASK lstrip deletes text; ignoring deletion remains an upper bound. Special literals emit once.
    result.upperBound = result.ordinaryWeight + result.ordinarySegments + result.literalSpecialTokens + 2;
    result.profileBoundProven = true;
    result.state = result.upperBound <= input.tokenBudget ? BgeM3CountState.SafeUnderPinnedProfile : BgeM3CountState.BoundUnproven;
    result.reason = result.state === BgeM3CountState.BoundUnproven ? 'UpperBoundExceedsBudgetNotActualTokenOverflow' : 'PinnedProfileUpperBoundWithinBudget';
    return result;
  }
}
