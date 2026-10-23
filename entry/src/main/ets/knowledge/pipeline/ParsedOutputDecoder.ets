import { ParsedBlock, ParsedInline, ParsedKind, ParsedFailure, ParsedLimits, ParsedCancellation, ParsedPrecision } from '../domain/ParsedDocumentModels';
import { PdfJsonNode } from './BoundedDocumentJson';
import { parsedJson } from './ParsedDocumentCodec';
import { PdfTableDecoder } from './PdfTableDecoder';
import { PdfTable, PdfTableCell } from '../domain/PdfKnowledgeModels';

export class ParsedOutputImageLink { occurrenceId: string = ''; blockId: string = ''; inlineId: string = ''; member: string = ''; caption: string = ''; order: number = 0; }
export class ParsedOutputProjection { blocks: ParsedBlock[] = []; links: ParsedOutputImageLink[] = []; warnings: string[] = []; }
function decodedRecord(raw: PdfJsonNode, p: ParsedOutputProjection): void {
  const length: number = p.blocks.length; const links: number = p.links.length;
  try { record(raw,p); }
  catch (error) {
    p.blocks.splice(length); p.links.splice(links);
    if (error instanceof ParsedFailure && error.category.includes('Budget')) { throw error; }
    const b: ParsedBlock = new ParsedBlock(); b.id = `block-${p.blocks.length}`; b.order = p.blocks.length; b.kind = ParsedKind.Unknown; b.limitation = 'UnsupportedStructuredRecord'; p.blocks.push(b); p.warnings.push('PartialStructuredOutput');
  }
}
function imageLink(p: ParsedOutputProjection, block: ParsedBlock, member: string, caption: string, inlineId: string = ''): string {
  const l: ParsedOutputImageLink = new ParsedOutputImageLink(); l.occurrenceId = `occ-${p.links.length}`; l.blockId = block.id; l.inlineId = inlineId; l.member = member; l.caption = caption; l.order = p.links.length;
  if (p.links.length >= ParsedLimits.occurrences) { throw new ParsedFailure('ImageOccurrenceBudget','output'); } p.links.push(l); return l.occurrenceId;
}
export function parsedMarkdownProjection(markdown: string, cancel: ParsedCancellation): ParsedOutputProjection {
  const p: ParsedOutputProjection = new ParsedOutputProjection(); p.warnings.push('MarkdownProjectionStructureUnverified');
  const paragraphs: string[] = []; let current: string = ''; let fence: string = '';
  for (const line of markdown.split(/\r?\n/)) {
    const marker: RegExpExecArray | null = /^\s*(```+|~~~+)/.exec(line);
    if (marker !== null) { if (fence.length === 0) { fence = marker[1][0]; } else if (fence === marker[1][0]) { fence = ''; } }
    if (line.trim().length === 0 && fence.length === 0) { if (current.length > 0) { paragraphs.push(current); current = ''; } }
    else { current += (current.length > 0 ? '\n' : '')+line; }
  }
  if (current.length > 0) { paragraphs.push(current); }
  for (const paragraph of paragraphs) {
    cancel.check(); if (paragraph.trim().length === 0) { continue; }
    if (p.blocks.length >= ParsedLimits.blocks) { throw new ParsedFailure('BlockBudget','markdown'); }
    const b: ParsedBlock = new ParsedBlock(); b.id = `block-${p.blocks.length}`; b.order = p.blocks.length; b.text = paragraph; b.locator.precision = ParsedPrecision.Block;
    if (/^\s*(```|~~~)/.test(paragraph)) { p.blocks.push(b); continue; }
    if (paragraph.trim().startsWith('$$') && paragraph.trim().endsWith('$$') && paragraph.trim().length > 4) { b.kind = ParsedKind.Formula; b.formula.latex = paragraph.trim().slice(2,-2).trim(); b.text = ''; }
    else {
      const pattern: RegExp = /!\[([^\]]*)\]\(([^\s)]+)(?:\s+"[^"]*")?\)|\$([^$\n]+)\$/g; let at: number = 0; let match: RegExpExecArray | null = pattern.exec(paragraph);
      while (match !== null) {
        if (match.index > at) { const r: ParsedInline = new ParsedInline(); r.id = `${b.id}-r${b.inlines.length}`; r.order = b.inlines.length; r.text = paragraph.slice(at,match.index); b.inlines.push(r); }
        const r: ParsedInline = new ParsedInline(); r.id = `${b.id}-r${b.inlines.length}`; r.order = b.inlines.length;
        if (match[2] !== undefined) { r.kind = ParsedKind.Image; r.imageOccurrenceId = imageLink(p,b,match[2],match[1] ?? '',r.id); }
        else { r.kind = ParsedKind.Formula; r.formula.latex = match[3] ?? ''; }
        b.inlines.push(r); at = match.index+match[0].length; match = pattern.exec(paragraph);
      }
      if (at < paragraph.length) { const r: ParsedInline = new ParsedInline(); r.id = `${b.id}-r${b.inlines.length}`; r.order = b.inlines.length; r.text = paragraph.slice(at); b.inlines.push(r); }
      if (b.inlines.length === 1 && b.inlines[0].kind === ParsedKind.Image) { b.kind = ParsedKind.Image; b.imageOccurrenceId = b.inlines[0].imageOccurrenceId; b.inlines = []; b.text = ''; const link: ParsedOutputImageLink = p.links[p.links.length-1]; link.inlineId = ''; }
    }
    p.blocks.push(b);
  }
  return p;
}
function textField(n: PdfJsonNode, key: string): string { const v: PdfJsonNode | undefined = n.optional(key); return v === undefined ? '' : v.string(); }
function typedRuns(n: PdfJsonNode, b: ParsedBlock): void {
  const values: PdfJsonNode[] = n.array(); if (values.length > ParsedLimits.blocks) { throw new ParsedFailure('InlineBudget','output'); }
  for (const raw of values) {
    const r: ParsedInline = new ParsedInline(); r.id = `${b.id}-r${b.inlines.length}`; r.order = b.inlines.length;
    const type: string = raw.required('type').string();
    if (type === 'text') { r.text = raw.required('content').string(); }
    else if (type === 'equation_inline') { r.kind = ParsedKind.Formula; r.formula.latex = raw.required('content').string(); }
    else { r.kind = ParsedKind.Unknown; r.limitation = 'UnsupportedInline:'+type; }
    b.inlines.push(r);
  }
}
function record(raw: PdfJsonNode, p: ParsedOutputProjection): void {
  if (p.blocks.length >= ParsedLimits.blocks) { throw new ParsedFailure('BlockBudget','output'); }
  const b: ParsedBlock = new ParsedBlock(); b.id = `block-${p.blocks.length}`; b.order = p.blocks.length; b.locator.precision = ParsedPrecision.Block;
  const type: string = raw.required('type').string(); const nested: PdfJsonNode | undefined = raw.optional('content');
  if (nested !== undefined && nested.kind === 'object') {
    if (type === 'paragraph' || type === 'title') { b.kind = type === 'title' ? ParsedKind.Heading : ParsedKind.Text; typedRuns(nested.required(type === 'title' ? 'title_content' : 'paragraph_content'),b); }
    else if (type === 'equation_interline') { b.kind = ParsedKind.Formula; if (textField(nested,'math_type') === 'latex') { b.formula.latex = textField(nested,'math_content'); } else { b.formula.unsupportedReason = 'UnsupportedMathRepresentation'; } }
    else if (type === 'image' || type === 'chart') { b.kind = ParsedKind.Image; const source: PdfJsonNode | undefined = nested.optional('image_source'); const member: string = source === undefined ? '' : textField(source,'path'); b.imageOccurrenceId = imageLink(p,b,member,''); }
    else if (type === 'table') { b.kind = ParsedKind.Table; b.text = textField(nested,'html'); }
    else { b.kind = ParsedKind.Unknown; b.limitation = 'UnsupportedContentType:'+type; }
  } else {
    if (type === 'text' || type === 'title') { b.kind = type === 'title' ? ParsedKind.Heading : ParsedKind.Text; b.text = textField(raw,'text'); }
    else if (type === 'equation' || type === 'equation_interline') { b.kind = ParsedKind.Formula; b.formula.latex = textField(raw,'text'); if (b.formula.latex.length === 0) { b.formula.unsupportedReason = 'FormulaTextNotReported'; } }
    else if (type === 'image') { b.kind = ParsedKind.Image; b.imageOccurrenceId = imageLink(p,b,textField(raw,'img_path'),''); }
    else if (type === 'table') { b.kind = ParsedKind.Table; b.text = textField(raw,'table_body'); }
    else { b.kind = ParsedKind.Unknown; b.limitation = 'UnsupportedContentType:'+type; }
  }
  if (b.kind === ParsedKind.Formula && b.formula.text.length+b.formula.latex.length+b.formula.unsupportedReason.length === 0) { b.formula.unsupportedReason = 'FormulaTextNotReported'; }
  p.blocks.push(b);
  if (b.kind === ParsedKind.Table) {
    try {
      const table: PdfTable = new PdfTableDecoder(b.text).decode(b.id+'-table'); b.text = '';
      if (p.blocks.filter((r: ParsedBlock): boolean => r.kind === ParsedKind.Cell).length+table.cells.length > ParsedLimits.cells) { throw new ParsedFailure('CellBudget','output'); }
      for (const cell of table.cells) { const c: ParsedBlock = new ParsedBlock(); c.id = `${b.id}-cell-${p.blocks.length}`; c.parentId = b.id; c.order = p.blocks.length; c.kind = ParsedKind.Cell; c.row = cell.row; c.column = cell.column; c.rowSpan = cell.rowSpan; c.columnSpan = cell.columnSpan; c.text = cell.text; c.locator.precision = ParsedPrecision.Block; p.blocks.push(c); }
    } catch (error) { b.kind = ParsedKind.Unknown; b.limitation = 'TableConversionUnsupported'; }
  }
  const source: PdfJsonNode = nested !== undefined && nested.kind === 'object' ? nested : raw;
  for (const key of ['image_caption','image_footnote','table_caption','table_footnote','chart_caption','chart_footnote','caption','footnote']) {
    const caption: PdfJsonNode | undefined = source.optional(key); if (caption === undefined) { continue; }
    const c: ParsedBlock = new ParsedBlock(); c.id = `${b.id}-${key}`; c.order = p.blocks.length; c.parentId = b.id; c.locator.precision = ParsedPrecision.Block;
    if (caption.kind === 'string') { c.text = caption.string(); }
    else if (caption.kind === 'array') {
      for (const value of caption.array()) {
        if (value.kind === 'string') { c.text += (c.text.length>0 ? '\n' : '')+value.string(); }
        else if (value.kind === 'array') { typedRuns(value,c); }
        else if (value.kind === 'object') { const run: ParsedInline = new ParsedInline(); run.id = `${c.id}-r${c.inlines.length}`; run.order = c.inlines.length;
          if (textField(value,'type') === 'equation_inline') { run.kind = ParsedKind.Formula; run.formula.latex = textField(value,'content'); } else if (textField(value,'type') === 'text') { run.text = textField(value,'content'); } else { run.kind = ParsedKind.Unknown; run.limitation = 'UnsupportedCaptionInline'; } c.inlines.push(run); }
      }
    } else { c.kind = ParsedKind.Unknown; c.limitation = 'UnsupportedCaptionRepresentation'; }
    if (c.text.length>0 || c.inlines.length>0 || c.limitation.length>0) {
      if (c.text.length>0 && c.inlines.length>0) { const text: ParsedInline = new ParsedInline(); text.id = `${c.id}-text`; text.text = c.text; text.order = 0; for (const run of c.inlines) { run.order++; } c.inlines.unshift(text); c.text = ''; }
      p.blocks.push(c);
    }
  }
}
export function parsedContentProjection(bytes: Uint8Array, cancel: ParsedCancellation): ParsedOutputProjection {
  const root: PdfJsonNode = parsedJson(bytes,cancel); const projection: ParsedOutputProjection = new ParsedOutputProjection();
  for (const raw of root.array()) { cancel.check(); if (raw.kind === 'array') { for (const child of raw.array()) { cancel.check(); decodedRecord(child,projection); } } else { decodedRecord(raw,projection); } }
  return projection;
}
