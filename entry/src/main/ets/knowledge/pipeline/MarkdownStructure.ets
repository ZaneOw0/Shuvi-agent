import {
  TextBudget, TextFailure, TextFormat, TextNode, TextNodeKind, TextCell, TextSnapshot, TextNormalized
} from '../domain/TextKnowledgeModels';
import { sourceRange } from './TextNormalizer';

class TextLine { start: number = 0; end: number = 0; body: string = ''; }
function textLines(text: string): TextLine[] {
  const lines: TextLine[] = [];
  let start: number = 0;
  while (start < text.length) {
    const next: number = text.indexOf('\n', start);
    const end: number = next < 0 ? text.length : next + 1;
    const line: TextLine = new TextLine();
    line.start = start; line.end = end; line.body = text.slice(start, end).trimEnd();
    lines.push(line); start = end;
  }
  if (lines.length > TextBudget.nodes * 4) { throw new TextFailure('BUDGET', 'structure', '原文行数超过保护预算'); }
  return lines;
}
function listLevel(body: string): number {
  const match: RegExpMatchArray | null = body.match(new RegExp('^(\\s*)(?:[-+*]|[0-9]+[.)])\\s+'));
  return match === null ? -1 : Math.floor(match[1].length / 2) + 1;
}
function tableDelimiter(body: string): boolean {
  return body.indexOf('|') >= 0 && new RegExp('^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)+\\|?\\s*$').test(body);
}
function tableCells(line: TextLine, normalized: TextNormalized, node: TextNode, row: number): TextCell[] {
  const cells: TextCell[] = [];
  let start: number = line.body.trimStart().startsWith('|') ? line.body.indexOf('|') + 1 : 0;
  let codeTicks: number = 0;
  for (let i: number = start; i <= line.body.length; i++) {
    if (line.body.charAt(i) === '\\') { i++; continue; }
    if (line.body.charAt(i) === '`') {
      let count: number = 1;
      while (line.body.charAt(i + count) === '`') { count++; }
      if (codeTicks === 0) { codeTicks = count; } else if (codeTicks === count) { codeTicks = 0; }
      i += count - 1; continue;
    }
    if (i === line.body.length || (line.body.charAt(i) === '|' && codeTicks === 0)) {
      const raw: string = line.body.slice(start, i);
      if (i === line.body.length && raw.trim().length === 0 && start > 0) { break; }
      const cell: TextCell = new TextCell();
      cell.row = row; cell.column = cells.length; cell.header = row === 0; cell.text = raw.trim();
      const left: number = raw.length - raw.trimStart().length;
      cell.range = sourceRange(normalized, line.start + start + left,
        line.start + i - (raw.length - raw.trimEnd().length), node.id, node.headingPath);
      cells.push(cell); start = i + 1;
    }
  }
  return cells;
}

export function parseTextStructure(snapshot: TextSnapshot, format: TextFormat): void {
  const normalized: TextNormalized = snapshot.normalized;
  const lines: TextLine[] = textLines(normalized.text);
  const headings: TextNode[] = [];
  let cells: number = 0;
  let lastList: TextNode | undefined = undefined;
  for (let i: number = 0; i < lines.length;) {
    if (lines[i].body.trim().length === 0) { i++; continue; }
    const first: TextLine = lines[i];
    let endIndex: number = i;
    const node: TextNode = new TextNode();
    node.id = `n${snapshot.nodes.length}`; node.order = snapshot.nodes.length;
    node.headingPath = headings.map((heading: TextNode): string => heading.text);
    node.parentId = headings.length > 0 ? headings[headings.length - 1].id : '';
    const atx: RegExpMatchArray | null = first.body.match(new RegExp('^ {0,3}(#{1,6})\\s+(.+?)\\s*#*\\s*$'));
    const fence: RegExpMatchArray | null = first.body.match(new RegExp('^ {0,3}(`{3,}|~{3,})(.*)$'));
    const setext: boolean = i + 1 < lines.length && new RegExp('^ {0,3}(=+|-+)\\s*$').test(lines[i + 1].body);
    if (format === TextFormat.Markdown && (atx !== null || setext)) {
      node.kind = TextNodeKind.Heading;
      node.level = atx !== null ? atx[1].length : (lines[i + 1].body.trim().startsWith('=') ? 1 : 2);
      node.text = atx !== null ? atx[2] : first.body.trim();
      if (atx === null) { endIndex++; }
      while (headings.length > 0 && headings[headings.length - 1].level >= node.level) { headings.pop(); }
      node.parentId = headings.length > 0 ? headings[headings.length - 1].id : '';
      node.headingPath = headings.map((heading: TextNode): string => heading.text);
      headings.push(node);
    } else if (format === TextFormat.Markdown && fence !== null) {
      node.kind = TextNodeKind.Code;
      const close: RegExp = new RegExp(`^ {0,3}${fence[1].charAt(0)}{${fence[1].length},}\\s*$`);
      while (endIndex + 1 < lines.length) {
        endIndex++; if (close.test(lines[endIndex].body)) { break; }
      }
      if (!close.test(lines[endIndex].body) || endIndex === i) { snapshot.warnings.push('围栏未闭合，原文完整保留'); }
    } else if (format === TextFormat.Markdown && i + 1 < lines.length && tableDelimiter(lines[i + 1].body)) {
      node.kind = TextNodeKind.Table;
      node.cells = tableCells(first, normalized, node, 0);
      endIndex = i + 1;
      let row: number = 1;
      while (endIndex + 1 < lines.length && lines[endIndex + 1].body.indexOf('|') >= 0 && lines[endIndex + 1].body.trim().length > 0) {
        endIndex++; node.cells = node.cells.concat(tableCells(lines[endIndex], normalized, node, row++));
      }
      cells += node.cells.length;
      if (cells > TextBudget.cells) { throw new TextFailure('BUDGET', 'structure', '表格单元格超过保护预算'); }
    } else if (format === TextFormat.Markdown && listLevel(first.body) >= 0) {
      node.kind = TextNodeKind.List; node.level = listLevel(first.body);
      if (lastList !== undefined && lastList.level < node.level) { node.parentId = lastList.id; }
      while (endIndex + 1 < lines.length && lines[endIndex + 1].body.trim().length > 0 &&
        listLevel(lines[endIndex + 1].body) < 0 && new RegExp('^\\s{2,}').test(lines[endIndex + 1].body)) { endIndex++; }
      lastList = node;
    } else {
      node.kind = TextNodeKind.Paragraph;
      while (endIndex + 1 < lines.length && lines[endIndex + 1].body.trim().length > 0) {
        const next: string = lines[endIndex + 1].body;
        if (format === TextFormat.Markdown && (new RegExp('^ {0,3}(#{1,6}\\s|`{3,}|~{3,})').test(next) ||
          listLevel(next) >= 0 || (endIndex + 2 < lines.length && tableDelimiter(lines[endIndex + 2].body)))) { break; }
        endIndex++;
      }
      if (format === TextFormat.Markdown && new RegExp('(^\\s*[<>]|\\$\\$|^\\s*\\[.+\\]:|^\\s{4}|^\\s*[-*_]{3,}\\s*$)', 'm').test(normalized.text.slice(first.start, lines[endIndex].end))) {
        node.kind = TextNodeKind.Raw; snapshot.warnings.push('特殊 Markdown/HTML/公式/引用定义未展开，原文保留');
      }
    }
    const end: number = lines[endIndex].end;
    node.range = sourceRange(normalized, first.start, end, node.id, node.headingPath);
    if (node.kind !== TextNodeKind.Heading) { node.text = normalized.text.slice(first.start, end); }
    snapshot.nodes.push(node);
    if (snapshot.nodes.length > TextBudget.nodes) { throw new TextFailure('BUDGET', 'structure', '结构节点超过保护预算'); }
    if (format === TextFormat.Markdown && node.kind !== TextNodeKind.Code) {
      const images: RegExp = new RegExp('!\\[[^\\]]*\\](?:\\([^\\n)]*\\)|\\[[^\\]]*\\])', 'g');
      const referenceSource: string = normalized.text.slice(first.start, end);
      let match: RegExpExecArray | null = images.exec(referenceSource);
      while (match !== null) {
        node.references.push(match[0]);
        const imageNode: TextNode = new TextNode();
        imageNode.id = `n${snapshot.nodes.length}`; imageNode.parentId = node.id;
        imageNode.order = snapshot.nodes.length; imageNode.kind = TextNodeKind.Image;
        imageNode.headingPath = node.headingPath.slice(); imageNode.text = match[0];
        imageNode.range = sourceRange(normalized, first.start + match.index, first.start + match.index + match[0].length,
          imageNode.id, imageNode.headingPath); imageNode.references.push(match[0]);
        snapshot.nodes.push(imageNode);
        snapshot.warnings.push('图片仅保留引用文字，未读取或下载资源');
        match = images.exec(referenceSource);
      }
    }
    i = endIndex + 1;
  }
}
