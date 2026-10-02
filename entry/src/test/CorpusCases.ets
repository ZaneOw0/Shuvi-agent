import { chunkText } from '../main/ets/knowledge/pipeline/Chunker';
import { ChunkSlice } from '../main/ets/knowledge/domain/KnowledgeTypes';

export interface CorpusDoc {
  name: string;
  kind: string;
  text: string;
}

export interface CorpusTestCase {
  name: string;
  run: () => Promise<void>;
}

const SIZES: number[] = [512, 2048, 4096];
const DEFAULT_RATIO: number = 0.1;

function check(condition: boolean, message: string): void {
  if (!condition) {
    throw new Error(message);
  }
}

function leadingWhitespace(value: string): number {
  let index: number = 0;
  while (index < value.length && isWhitespace(value.charCodeAt(index))) {
    index++;
  }
  return index;
}

function trailingWhitespace(value: string): number {
  let count: number = 0;
  while (count < value.length && isWhitespace(value.charCodeAt(value.length - 1 - count))) {
    count++;
  }
  return count;
}

function isWhitespace(code: number): boolean {
  return code === 32 || code === 9 || code === 10 || code === 13 || code === 0xA0 || code === 0x3000 ||
    code === 0x2028 || code === 0x2029 || code === 0xFEFF;
}

function rawEnd(source: string, slice: ChunkSlice): number {
  let index: number = slice.charOffset + slice.text.length;
  while (index < source.length && isWhitespace(source.charCodeAt(index))) {
    index++;
  }
  return index;
}

function countHardCuts(source: string, slices: ChunkSlice[]): number {
  let hardCuts: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const end: number = rawEnd(source, slices[i]);
    if (end >= source.length) {
      continue;
    }
    if (!isBoundaryChar(source, end - 1)) {
      hardCuts++;
    }
  }
  return hardCuts;
}

function isBoundaryChar(text: string, index: number): boolean {
  if (index < 0 || index >= text.length) {
    return false;
  }
  const ch: string = text.charAt(index);
  return ch === '。' || ch === '！' || ch === '？' || ch === '；' || ch === '.' || ch === '!' || ch === '?' ||
    ch === ';' || ch === '\n' || ch === '\r' || ch === '\u2028' || ch === '\u2029';
}

function verifyInvariants(doc: CorpusDoc, slices: ChunkSlice[], size: number): void {
  const source: string = doc.text;
  const label: string = `${doc.name} @${size}`;
  check(slices.length > 0, `${label}: 期望至少一块`);
  let covered: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const slice: ChunkSlice = slices[i];
    check(slice.text.length > 0, `${label}: 第 ${i} 块为空`);
    check(slice.text.length <= size, `${label}: 第 ${i} 块长度 ${slice.text.length} 超出上限 ${size}`);
    check(slice.charOffset >= 0 && slice.charOffset + slice.text.length <= source.length,
      `${label}: 第 ${i} 块越出原文范围`);
    check(source.substr(slice.charOffset, slice.text.length) === slice.text,
      `${label}: 第 ${i} 块文本与其偏移处原文不一致`);
    check(slice.text === slice.text.trim(), `${label}: 第 ${i} 块未去除首尾空白`);
    if (i === 0) {
      check(slice.charOffset === leadingWhitespace(source), `${label}: 首块偏移未跳过前导空白`);
    } else {
      const previous: ChunkSlice = slices[i - 1];
      check(slice.charOffset > previous.charOffset, `${label}: 第 ${i} 块偏移未递增`);
      check(slice.charOffset <= previous.charOffset + previous.text.length,
        `${label}: 第 ${i} 块与上一块之间出现空洞`);
    }
    const end: number = slice.charOffset + slice.text.length;
    if (end > covered) {
      covered = end;
    }
  }
  check(covered === source.length - trailingWhitespace(source),
    `${label}: 未覆盖到原文有效结尾（覆盖 ${covered} / 有效长度 ${source.length - trailingWhitespace(source)}）`);
}

function logMetrics(doc: CorpusDoc, slices: ChunkSlice[], size: number): void {
  let total: number = 0;
  let longest: number = 0;
  let boundaryEnds: number = 0;
  let numberSplits: number = 0;
  let urlFragments: number = 0;
  let unsafeStarts: number = 0;
  let unsafeEnds: number = 0;
  const source: string = doc.text;
  for (let i = 0; i < slices.length; i++) {
    const slice: ChunkSlice = slices[i];
    total = total + slice.text.length;
    if (slice.text.length > longest) {
      longest = slice.text.length;
    }
    const end: number = rawEnd(source, slice);
    if (end < source.length && isBoundaryChar(source, end - 1)) {
      boundaryEnds++;
    }
    if (end < source.length) {
      const before: string = source.charAt(end - 1);
      const after: string = source.charAt(end);
      if (before >= '0' && before <= '9' && after >= '0' && after <= '9') {
        numberSplits++;
      }
    }
    const head: string = slice.text.charAt(0);
    const tail: string = slice.text.charAt(slice.text.length - 1);
    const headCode: number = head.charCodeAt(0);
    const tailCode: number = tail.charCodeAt(0);
    const looksLikeUrlFragment: boolean = slice.text.indexOf('http') >= 0 &&
      slice.text.indexOf('https://') < 0 && slice.text.indexOf('http://') < 0;
    if (looksLikeUrlFragment) {
      urlFragments++;
    }
    if (headCode >= 0xDC00 && headCode <= 0xDFFF) {
      unsafeStarts++;
    }
    if (headCode >= 0x0300 && headCode <= 0x036F) {
      unsafeStarts++;
    }
    if (head === '\u200d' || head === '\ufe0f' || head === '\ufe0e') {
      unsafeStarts++;
    }
    if (tailCode >= 0xD800 && tailCode <= 0xDBFF) {
      unsafeEnds++;
    }
    if (tail === '\u200d') {
      unsafeEnds++;
    }
  }
  const average: number = slices.length === 0 ? 0 : Math.round(total / slices.length);
  console.log(`[语料] ${doc.name} (${doc.kind}) size=${size} 原文字符=${source.length} 块数=${slices.length}` +
    ` 平均块长=${average} 最长块=${longest} 标点/换行收尾块=${boundaryEnds}` +
    ` 数字被切开=${numberSplits} URL 碎片块=${urlFragments} 起始拆分字符=${unsafeStarts} 结尾拆分字符=${unsafeEnds}`);
}

function countUnsafeBoundaries(slices: ChunkSlice[]): number {
  let unsafe: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const text: string = slices[i].text;
    const headCode: number = text.charCodeAt(0);
    const tailCode: number = text.charCodeAt(text.length - 1);
    if (headCode >= 0xDC00 && headCode <= 0xDFFF) {
      unsafe++;
    }
    if (headCode >= 0x0300 && headCode <= 0x036F) {
      unsafe++;
    }
    if (headCode === 0x200d || headCode === 0xfe0f || headCode === 0xfe0e) {
      unsafe++;
    }
    if (tailCode >= 0xD800 && tailCode <= 0xDBFF) {
      unsafe++;
    }
    if (tailCode === 0x200d) {
      unsafe++;
    }
  }
  return unsafe;
}

function countNumberSplits(source: string, slices: ChunkSlice[]): number {
  let splits: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const end: number = slices[i].charOffset + slices[i].text.length;
    if (end >= source.length) {
      continue;
    }
    const before: string = source.charAt(end - 1);
    const after: string = source.charAt(end);
    const beforeDigit: boolean = (before >= '0' && before <= '9') || before === '.';
    const afterDigit: boolean = after >= '0' && after <= '9';
    if (beforeDigit && afterDigit) {
      splits++;
    }
  }
  return splits;
}

function countUrlFragments(slices: ChunkSlice[]): number {
  let fragments: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const text: string = slices[i].text;
    if (text.indexOf('http') >= 0 && text.indexOf('https://') < 0 && text.indexOf('http://') < 0) {
      fragments++;
    }
  }
  return fragments;
}

function findDoc(docs: CorpusDoc[], name: string): CorpusDoc {
  for (let i = 0; i < docs.length; i++) {
    if (docs[i].name === name) {
      return docs[i];
    }
  }
  throw new Error(`未找到语料：${name}`);
}

export function corpusCases(docs: CorpusDoc[]): CorpusTestCase[] {
  const cases: CorpusTestCase[] = [];
  for (let d = 0; d < docs.length; d++) {
    const doc: CorpusDoc = docs[d];
    for (let s = 0; s < SIZES.length; s++) {
      const size: number = SIZES[s];
      cases.push({
        name: `语料不变量 · ${doc.name} @${size}`,
        run: async () => {
          const slices: ChunkSlice[] = chunkText(doc.text, size, DEFAULT_RATIO);
          logMetrics(doc, slices, size);
          verifyInvariants(doc, slices, size);
        }
      });
    }
  }
  cases.push({
    name: '语料 · 超大块 4096 下长文档块数极少且不丢字符',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'project-design-zh.md');
      const slices: ChunkSlice[] = chunkText(doc.text, 4096, DEFAULT_RATIO);
      const lowerBound: number = Math.floor(doc.text.length / 4096);
      check(slices.length >= lowerBound, `块数 ${slices.length} 少于下限 ${lowerBound}`);
      verifyInvariants(doc, slices, 4096);
    }
  });
  cases.push({
    name: 'Unicode · 零宽字符与代理对不应被拆到两块',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'unicode-edge-cases.txt');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      const unsafe: number = countUnsafeBoundaries(slices);
      console.log(`[Unicode] ${doc.name} 起始/结尾被拆分的字符数=${unsafe}`);
      check(unsafe === 0, `存在 ${unsafe} 处把代理对、组合字符、零宽连接符或变体选择符拆到两块之间`);
    }
  });
  cases.push({
    name: 'Unicode · 数字与日期不应被切在中间',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'unicode-edge-cases.txt');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      const splits: number = countNumberSplits(doc.text, slices);
      console.log(`[Unicode] 数字被切开处数=${splits}`);
      check(splits === 0, `存在 ${splits} 处在数字或小数中间切开`);
    }
  });
  cases.push({
    name: 'Unicode · 组合字符的基字符与附加符号不应分离',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'unicode-edge-cases.txt');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      let separated: number = 0;
      for (let i = 0; i < slices.length; i++) {
        const head: string = slices[i].text.charAt(0);
        const code: number = head.charCodeAt(0);
        if (code >= 0x0300 && code <= 0x036F) {
          separated++;
        }
      }
      check(separated === 0, `有 ${separated} 块以组合附加符号开头，说明基字符被留在了上一块`);
    }
  });
  cases.push({
    name: '长链接 · 超长 URL 不应被切成无 scheme 的碎片',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'unicode-edge-cases.txt');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      const fragments: number = countUrlFragments(slices);
      console.log(`[长链接] 无 scheme 的 URL 碎片块=${fragments}`);
      check(fragments === 0, `有 ${fragments} 块只包含 URL 的一部分且丢失 scheme`);
    }
  });
  cases.push({
    name: '工程文档 · Markdown 标题不应落在块尾被截断',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'engineering-readme-mixed.md');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      let truncatedHeading: number = 0;
      for (let i = 0; i < slices.length; i++) {
        const text: string = slices[i].text;
        const lastLine: string = text.substring(text.lastIndexOf('\n') + 1);
        if (lastLine.startsWith('#') && !doc.text.startsWith(lastLine)) {
          truncatedHeading++;
        }
      }
      console.log(`[工程文档] 块尾被截断的标题数=${truncatedHeading}`);
      check(truncatedHeading === 0, `有 ${truncatedHeading} 块把标题行留在了块尾`);
    }
  });
  cases.push({
    name: '法律条款 · Apache 2.0 条款编号不应与正文分离到不同块',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'apache-license-2.0.txt');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      let orphanNumber: number = 0;
      for (let i = 0; i < slices.length; i++) {
        const text: string = slices[i].text;
        const lastLine: string = text.substring(text.lastIndexOf('\n') + 1).trim();
        const numeric: boolean = lastLine.length > 0 && lastLine.length <= 4 &&
          lastLine.charAt(0) >= '1' && lastLine.charAt(0) <= '9';
        if (numeric && lastLine.indexOf('.') === lastLine.length - 1) {
          orphanNumber++;
        }
      }
      console.log(`[法律条款] 块尾孤立的条款编号数=${orphanNumber}`);
      check(orphanNumber === 0, `有 ${orphanNumber} 块以孤立的条款编号结尾`);
    }
  });
  cases.push({
    name: '医学长文 · 中文段落切分点应落在标点或换行',
    run: async () => {
      const doc: CorpusDoc = findDoc(docs, 'who-hypertension-factsheet.md');
      const slices: ChunkSlice[] = chunkText(doc.text, 512, DEFAULT_RATIO);
      const hardCuts: number = countHardCuts(doc.text, slices);
      console.log(`[医学长文] 硬切块数=${hardCuts} / 总块数=${slices.length}`);
      check(hardCuts === 0, `有 ${hardCuts} 块在非标点非换行处硬切`);
    }
  });
  return cases;
}
