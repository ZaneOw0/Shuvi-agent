import { chunkText } from '../main/ets/knowledge/pipeline/Chunker';
import { ChunkSlice } from '../main/ets/knowledge/domain/KnowledgeTypes';

export interface ChunkerTestCase {
  name: string;
  run: () => Promise<void>;
}

const SIZE: number = 512;
const RATIO: number = 0.1;

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
  return code === 32 || code === 9 || code === 10 || code === 13;
}

function verifySlices(source: string, slices: ChunkSlice[], size: number, label: string): void {
  if (source.trim().length === 0) {
    check(slices.length === 0, `${label}: 空白输入不应产出块，实际 ${slices.length}`);
    return;
  }
  check(slices.length > 0, `${label}: 期望至少一块`);
  let covered: number = 0;
  for (let i = 0; i < slices.length; i++) {
    const slice: ChunkSlice = slices[i];
    check(slice.text.length > 0, `${label}: 第 ${i} 块为空`);
    check(slice.text.length <= size, `${label}: 第 ${i} 块长度 ${slice.text.length} 超过上限 ${size}`);
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
  check(covered === source.length - trailingWhitespace(source), `${label}: 未覆盖到原文有效结尾`);
}

function repeat(unit: string, times: number): string {
  let result: string = '';
  for (let i = 0; i < times; i++) {
    result = result + unit;
  }
  return result;
}

function paragraphText(paragraphs: number, charsPerParagraph: number): string {
  const parts: string[] = [];
  for (let i = 0; i < paragraphs; i++) {
    let body: string = '';
    while (body.length < charsPerParagraph - 1) {
      body = body + '内容';
    }
    parts.push(body + '。');
  }
  return parts.join('\n\n');
}

function paddedTo(length: number, prefix: string): string {
  let result: string = prefix;
  while (result.length < length) {
    result = result + '字';
  }
  return result;
}

export function chunkerCases(): ChunkerTestCase[] {
  return [
    {
      name: '空文本返回 0 块',
      run: async () => {
        check(chunkText('', SIZE, RATIO).length === 0, '空文本应无块');
      }
    },
    {
      name: '纯空白文本返回 0 块',
      run: async () => {
        const source: string = repeat(' ', 600) + '\n\n' + repeat('\t', 40);
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length === 0, `纯空白应无块，实际 ${slices.length}`);
      }
    },
    {
      name: '短文本单块且跳过前导空白',
      run: async () => {
        const source: string = '\n\n   短文本内容。';
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length === 1, '短文本应只有一块');
        check(slices[0].text === '短文本内容。', `块文本不符：${slices[0].text}`);
        check(slices[0].charOffset === 5, `偏移应跳过前导空白，实际 ${slices[0].charOffset}`);
        verifySlices(source, slices, SIZE, '短文本');
      }
    },
    {
      name: '恰好等于上限时单块、超一个字符时两块',
      run: async () => {
        const exact: string = repeat('甲', SIZE);
        check(chunkText(exact, SIZE, RATIO).length === 1, '恰好 512 字符应为一块');
        const over: string = repeat('甲', SIZE + 1);
        const slices: ChunkSlice[] = chunkText(over, SIZE, RATIO);
        check(slices.length === 2, `512+1 字符应为两块，实际 ${slices.length}`);
        check(slices[0].text.length === SIZE, '首块应为满长度');
        verifySlices(over, slices, SIZE, '超一字符');
      }
    },
    {
      name: '重叠比例决定下一块起点',
      run: async () => {
        const source: string = repeat('乙', SIZE + 1);
        const noOverlap: ChunkSlice[] = chunkText(source, SIZE, 0);
        check(noOverlap[1].charOffset === SIZE, `重叠为 0 时起点应为 ${SIZE}，实际 ${noOverlap[1].charOffset}`);
        const tenth: ChunkSlice[] = chunkText(source, SIZE, 0.1);
        check(tenth[1].charOffset === SIZE - 51, `重叠 10% 时起点应为 ${SIZE - 51}，实际 ${tenth[1].charOffset}`);
        const quarter: ChunkSlice[] = chunkText(source, SIZE, 0.25);
        check(quarter[1].charOffset === SIZE - 128, `重叠 25% 时起点应为 ${SIZE - 128}，实际 ${quarter[1].charOffset}`);
      }
    },
    {
      name: '无边界长文本按硬切且满足全部不变量',
      run: async () => {
        const source: string = repeat('丙', 3000);
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length === Math.ceil(3000 / (SIZE - 51)) || slices.length >= 7,
          `3000 字符块数异常：${slices.length}`);
        for (let i = 0; i < slices.length - 1; i++) {
          check(slices[i].text.length === SIZE, `硬切时第 ${i} 块应为满长度`);
        }
        verifySlices(source, slices, SIZE, '无边界长文本');
      }
    },
    {
      name: '段落边界优先于句号',
      run: async () => {
        const first: string = paddedTo(300, '第一段开始') + '。';
        const second: string = paddedTo(300, '第二段开始') + '。';
        const source: string = first + '\n\n' + second;
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 2, `多段落应至少两块，实际 ${slices.length}`);
        const firstEnd: number = slices[0].charOffset + slices[0].text.length;
        check(source.substr(firstEnd, 2) === '\n\n',
          `首块应在段落分隔处结束，实际切在 ${firstEnd}`);
        verifySlices(source, slices, SIZE, '段落边界');
      }
    },
    {
      name: '窗口内不足一半处的分隔符不采纳',
      run: async () => {
        const early: string = paddedTo(150, '开头') + '。';
        const source: string = early + paddedTo(SIZE * 3 - early.length, '');
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices[0].text.length === SIZE, `应走硬切取满长度，实际 ${slices[0].text.length}`);
        verifySlices(source, slices, SIZE, '早分隔符');
      }
    },
    {
      name: '中文句末标点作为切分边界',
      run: async () => {
        const source: string = paddedTo(300, '中文句子') + '。' + paddedTo(300, '后续中文') + '！' +
          paddedTo(300, '再后续') + '？' + paddedTo(300, '收尾') + '；';
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 3, `中文标点长文应至少三块，实际 ${slices.length}`);
        for (let i = 0; i < slices.length - 1; i++) {
          const end: number = slices[i].charOffset + slices[i].text.length;
          const boundary: string = source.charAt(end - 1);
          check(boundary === '。' || boundary === '！' || boundary === '？' || boundary === '；',
            `第 ${i} 块未切在中文标点处，实际边界字符「${boundary}」`);
        }
        verifySlices(source, slices, SIZE, '中文标点');
      }
    },
    {
      name: '英文句末标点作为切分边界',
      run: async () => {
        const source: string = paddedTo(300, 'alpha') + '.' + paddedTo(300, 'beta') + '!' +
          paddedTo(300, 'gamma') + '?' + paddedTo(300, 'delta') + ';';
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 3, `英文标点长文应至少三块，实际 ${slices.length}`);
        for (let i = 0; i < slices.length - 1; i++) {
          const end: number = slices[i].charOffset + slices[i].text.length;
          const boundary: string = source.charAt(end - 1);
          check(boundary === '.' || boundary === '!' || boundary === '?' || boundary === ';',
            `第 ${i} 块未切在英文标点处，实际边界字符「${boundary}」`);
        }
        verifySlices(source, slices, SIZE, '英文标点');
      }
    },
    {
      name: '中英混排与混合标点',
      run: async () => {
        const source: string = paddedTo(220, '混排 A1 中文') + '。' + paddedTo(220, 'mixed B2') + '.' +
          '\n' + paddedTo(220, '中英 mixed 3') + '!' + paddedTo(220, '结尾 end') + ';' + '\n\n' +
          paddedTo(220, '最后一段 last');
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 3, `混排长文应至少三块，实际 ${slices.length}`);
        verifySlices(source, slices, SIZE, '中英混排');
      }
    },
    {
      name: '单换行作为句边界（无空行时）',
      run: async () => {
        const source: string = paddedTo(300, '第一行') + '\n' + paddedTo(300, '第二行') +
          '\n' + paddedTo(300, '第三行');
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 2, `换行应提供切分机会，实际 ${slices.length} 块`);
        verifySlices(source, slices, SIZE, '单换行');
      }
    },
    {
      name: '连续空行不产生空块且覆盖完整',
      run: async () => {
        const source: string = paddedTo(300, '甲段') + '\n\n\n\n' + paddedTo(300, '乙段') +
          '\n\n\n\n\n\n' + paddedTo(300, '丙段') + '\n\n\n\n';
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        for (let i = 0; i < slices.length; i++) {
          check(slices[i].text.length > 0, `第 ${i} 块为空`);
        }
        verifySlices(source, slices, SIZE, '连续空行');
      }
    },
    {
      name: '超长多段落长文本满足全部不变量',
      run: async () => {
        const source: string = paragraphText(24, 240);
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(source.length > 5000, `语料长度不足：${source.length}`);
        check(slices.length >= 10, `长文块数偏少：${slices.length}`);
        verifySlices(source, slices, SIZE, '超长多段落');
        let overlapCount: number = 0;
        for (let i = 1; i < slices.length; i++) {
          const previousEnd: number = slices[i - 1].charOffset + slices[i - 1].text.length;
          if (slices[i].charOffset < previousEnd) {
            overlapCount++;
          }
        }
        check(overlapCount > 0, '长文本未出现任何重叠块');
      }
    },
    {
      name: '重叠比例递增时块数不减少',
      run: async () => {
        const source: string = paragraphText(12, 240);
        const none: number = chunkText(source, SIZE, 0).length;
        const tenth: number = chunkText(source, SIZE, 0.1).length;
        const quarter: number = chunkText(source, SIZE, 0.25).length;
        check(none <= tenth, `重叠 0 的块数 ${none} 应不大于重叠 10% 的 ${tenth}`);
        check(tenth <= quarter, `重叠 10% 的块数 ${tenth} 应不大于重叠 25% 的 ${quarter}`);
      }
    },
    {
      name: '含 emoji 与代理对的长文本不丢字符（已知限制：可能拆分代理对）',
      run: async () => {
        const emoji: string = repeat('😀', 400);
        const source: string = emoji + '。' + paddedTo(300, 'emoji 之后的文本') + '\n\n' + emoji;
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length >= 3, `含 emoji 长文应至少三块，实际 ${slices.length}`);
        verifySlices(source, slices, SIZE, 'emoji');
        let covered: number = 0;
        for (let i = 0; i < slices.length; i++) {
          const end: number = slices[i].charOffset + slices[i].text.length;
          if (end > covered) {
            covered = end;
          }
        }
        check(covered === source.length, `emoji 文本未完整覆盖：${covered} / ${source.length}`);
      }
    },
    {
      name: '尾部空白与换行不产生空块',
      run: async () => {
        const source: string = paddedTo(300, '正文内容') + '。' + repeat('\n', 6) + repeat(' ', 20);
        const slices: ChunkSlice[] = chunkText(source, SIZE, RATIO);
        check(slices.length === 1, `应只有一块，实际 ${slices.length}`);
        check(slices[0].text === paddedTo(300, '正文内容') + '。', '尾部空白应被去除');
        verifySlices(source, slices, SIZE, '尾部空白');
      }
    },
    {
      name: '极端小块参数下仍满足不变量',
      run: async () => {
        const source: string = paragraphText(6, 60);
        const sizes: number[] = [32, 64, 128];
        for (let i = 0; i < sizes.length; i++) {
          const size: number = sizes[i];
          const slices: ChunkSlice[] = chunkText(source, size, 0.2);
          verifySlices(source, slices, size, `小块 ${size}`);
        }
      }
    }
  ];
}
