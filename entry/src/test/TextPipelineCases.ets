import { chunkText } from '../main/ets/knowledge/pipeline/Chunker';
import { normalizeText, encodeTextUtf8, sourceRange } from '../main/ets/knowledge/pipeline/TextNormalizer';
import { processText, encodeSnapshot, decodeSnapshot } from '../main/ets/knowledge/pipeline/StructuredChunker';
import { TextDocument, TextFormat, TextNodeKind, TextNode, TextRangeRole, TextSourceRange } from '../main/ets/knowledge/domain/TextKnowledgeModels';
import { prepareTextQuery, textLikePattern, textFtsInput } from '../main/ets/knowledge/pipeline/QueryPreparation';

export interface TextPipelineTest { name: string; run: () => Promise<void>; }
function pipelineCheck(ok: boolean, message: string): void { if (!ok) { throw new Error(message); } }

export function textPipelineCases(): TextPipelineTest[] {
  return [
    { name: '严格 UTF8 拒绝非最短/代理/截断/二进制/空白', run: async (): Promise<void> => {
      const bad: number[][] = [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE4, 0xB8], [0], [32, 10]];
      for (const bytes of bad) {
        let refused: boolean = false;
        try { normalizeText(new Uint8Array(bytes)); } catch { refused = true; }
        pipelineCheck(refused, '非法原件必须拒绝，不替换');
      }
    } },
    { name: 'BOM CRLF 原文 UTF16 和行号映射', run: async (): Promise<void> => {
      const normalized = normalizeText(encodeTextUtf8('\uFEFF甲\r\n😀乙\r丙'));
      pipelineCheck(normalized.text === '甲\n😀乙\n丙', '规范化错误');
      const range = sourceRange(normalized, 2, 5, 'n', []);
      pipelineCheck(range.originalStart === 4 && range.originalEnd === 7 && range.startLine === 2 && range.endLine === 2, 'BOM/CRLF 定位错误');
    } },
    { name: '结构表格转义管道代码管道/标题列表围栏图片保留且不加载', run: async (): Promise<void> => {
      const source: string = '# 主标题\n\n子标题\n---\n\n- 父项\n  - 子项\n\n| 名 | 值 |\n|---|---|\n| a\\|b | `c|d` |\n\n~~~sh\ncommand-only-text\n~~~\n\n![图](unselected.png)\n\n<div>未知结构</div>\n';
      const document: TextDocument = new TextDocument(); document.id = 'd'; document.format = TextFormat.Markdown;
      const output = processText(encodeTextUtf8(source), document, 'g');
      const table = output.snapshot.nodes.find((node: TextNode): boolean => node.kind === TextNodeKind.Table);
      pipelineCheck(table !== undefined && table.cells.length === 4 && table.cells[2].text === 'a\\|b' && table.cells[3].text === '`c|d`', '表格关系被平铺或错列');
      pipelineCheck(output.snapshot.nodes.some((node: TextNode): boolean => node.kind === TextNodeKind.Image), '图片引用节点缺失');
      pipelineCheck(output.snapshot.nodes.some((node: TextNode): boolean => node.kind === TextNodeKind.Code), '围栏缺失');
      pipelineCheck(output.snapshot.warnings.length >= 2, '未知/图片限制警告缺失');
      for (const chunk of output.chunks) {
        pipelineCheck(chunk.retrievalText.length <= 512 && chunk.prefix.includes('主标题'), '完整输入预算/标题关联');
        pipelineCheck(chunk.kind !== TextNodeKind.Heading, '不得独立标题证据');
        pipelineCheck(chunk.ranges.some((range: TextSourceRange): boolean => range.role === TextRangeRole.Heading), '附加标题无来源');
      }
      const restored = decodeSnapshot(encodeSnapshot(output.snapshot));
      pipelineCheck(restored.normalized.originalText === source && restored.nodes.length === output.snapshot.nodes.length, '完整快照不保真');
    } },
    { name: '长列表代码表格完整快照与全部块原文覆盖', run: async (): Promise<void> => {
      const source: string = '# H\n\n~~~\n' + '😀'.repeat(1000) + '\n~~~\n\n- ' + '条目'.repeat(1000) + '\n';
      const doc: TextDocument = new TextDocument(); doc.id = 'long'; doc.format = TextFormat.Markdown;
      const result = processText(encodeTextUtf8(source), doc, 'g');
      pipelineCheck(result.chunks.length > 5 && result.snapshot.normalized.originalText === source, '超长结构被截断');
      for (const chunk of result.chunks) {
        pipelineCheck(chunk.retrievalText.length <= 512, '标题计入后超限');
        for (const range of chunk.ranges) {
          if (range.role === TextRangeRole.Evidence) { pipelineCheck(source.slice(range.originalStart, range.originalEnd) === chunk.evidenceText, '原文映射不一致'); }
        }
      }
    } },
    { name: '旧切片严格代理对边界', run: async (): Promise<void> => {
      const source: string = '甲'.repeat(511) + '😀' + '乙'.repeat(600);
      const slices = chunkText(source, 512, 0.1);
      for (const slice of slices) {
        const first: number = slice.text.charCodeAt(0);
        const last: number = slice.text.charCodeAt(slice.text.length - 1);
        pipelineCheck(!(first >= 0xDC00 && first <= 0xDFFF), '拆分低代理');
        pipelineCheck(!(last >= 0xD800 && last <= 0xDBFF), '拆分高代理');
      }
    } },
    { name: '旧切片所有 trim 空白偏移', run: async (): Promise<void> => {
      const source: string = '\uFEFF\u00A0\u3000正文';
      const slices = chunkText(source, 512, 0.1);
      pipelineCheck(slices[0].charOffset === 3, 'trim 后位置应为原文偏移 3');
      pipelineCheck(source.slice(slices[0].charOffset) === slices[0].text, '偏移原文不一致');
    } },
    { name: '英文/中文/emoji 超长问题双预算与条件保留', run: async (): Promise<void> => {
      const questions: string[] = ['a'.repeat(2000), '汉'.repeat(2000), '😀'.repeat(700),
        '普通文字'.repeat(700) + '。仅2026年之后，不包含归档资料。'];
      for (const question of questions) {
        const prepared = prepareTextQuery(question);
        pipelineCheck(prepared.fullQuestion === question && prepared.notice.length > 0 && prepared.droppedRanges.length > 0, '完整问题/丢弃提示缺失');
        pipelineCheck(Array.from(prepared.actualInput).length <= 512 && encodeTextUtf8(prepared.actualInput).length <= 1000, '双单位超限');
      }
      pipelineCheck(prepareTextQuery(questions[3]).actualInput.startsWith('仅2026年之后'), '时间/范围/否定分句未优先');
      pipelineCheck(textLikePattern('%_\\') === '%\\%\\_\\\\%', 'LIKE 元字符未按字面转义');
      pipelineCheck(textFtsInput(['a"b', 'x OR y']) === '"a""b" OR "x OR y"', 'FTS 语法注入未隔离');
    } },
    { name: '类型伪装与快照未知版本必须拒绝', run: async (): Promise<void> => {
      for (const text of ['%PDF-1.7', 'PK\u0003\u0004binary', 'GIF89aabcdef']) {
        let refused: boolean = false; try { normalizeText(encodeTextUtf8(text)); } catch { refused = true; }
        pipelineCheck(refused, '伪装二进制文本进入索引');
      }
      let refused: boolean = false; try { decodeSnapshot('TEXT-SNAPSHOT-999'); } catch { refused = true; }
      pipelineCheck(refused, '未知快照猜测为可用');
    } },
    { name: '1 MiB 恰好与超限/高节点预算边界', run: async (): Promise<void> => {
      pipelineCheck(normalizeText(new Uint8Array(1048576).fill(65)).text.length === 1048576, '恰好上限被截断');
      let refused: boolean = false; try { normalizeText(new Uint8Array(1048577).fill(65)); } catch { refused = true; }
      pipelineCheck(refused, '超限未拒绝');
      const doc: TextDocument = new TextDocument(); doc.id = 'node-budget'; doc.format = TextFormat.Markdown;
      refused = false; try { processText(encodeTextUtf8('- x\n'.repeat(20001)), doc, 'g'); } catch { refused = true; }
      pipelineCheck(refused, '节点/块超限未拒绝');
    } }
  ];
}
