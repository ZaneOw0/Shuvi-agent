import { PdfTable, PdfTableCell, KnowledgeFailure, PdfBudget } from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';

export function pdfDecodeEntities(raw: string): string {
  let text: string = '';
  for (let at: number = 0; at < raw.length;) {
    if (raw.charAt(at) !== '&') { text += raw.charAt(at++); continue; }
    const end: number = raw.indexOf(';',at+1); if (end < 0 || end-at > 12) { throw new KnowledgeFailure('TableEntity','table'); }
    const entity: string = raw.slice(at+1,end); let decoded: string = '';
    if (entity === 'amp') { decoded = '&'; } else if (entity === 'lt') { decoded = '<'; } else if (entity === 'gt') { decoded = '>'; }
    else if (entity === 'quot') { decoded = '"'; } else if (entity === 'apos' || entity === '#39') { decoded = "'"; } else if (entity === 'nbsp') { decoded = '\u00a0'; }
    else if (new RegExp('^#(?:[0-9]{1,7}|x[0-9a-fA-F]{1,6})$').test(entity)) {
      const cp: number = entity.charAt(1) === 'x' ? Number.parseInt(entity.slice(2),16) : Number(entity.slice(1));
      if (cp <= 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff) || (cp < 32 && cp !== 9 && cp !== 10 && cp !== 13) || cp === 127) { throw new KnowledgeFailure('TableEntity','table'); } decoded = String.fromCodePoint(cp);
    } else { throw new KnowledgeFailure('TableEntityUnsupported','table'); }
    text += decoded; at = end+1;
  } return text;
}
class PdfTableTag { name: string = ''; closing: boolean = false; rowSpan: number = 1; columnSpan: number = 1; }
export class PdfTableDecoder {
  private raw: string; private at: number = 0;
  constructor(raw: string) { if (documentUtf8Bytes(raw) > 262144) { throw new KnowledgeFailure('TableBytes','table'); } this.raw = raw; }
  private space(): void { while (this.at < this.raw.length && ' \r\n\t'.indexOf(this.raw.charAt(this.at)) >= 0) { this.at++; } }
  private tag(): PdfTableTag {
    this.space(); if (this.raw.charAt(this.at++) !== '<') { throw new KnowledgeFailure('TableMarkup','table'); }
    const tag: PdfTableTag = new PdfTableTag(); if (this.raw.charAt(this.at) === '/') { tag.closing = true; this.at++; }
    const start: number = this.at; while (this.at < this.raw.length && /[a-z]/.test(this.raw.charAt(this.at))) { this.at++; }
    tag.name = this.raw.slice(start,this.at); if (['table','tr','td'].indexOf(tag.name) < 0) { throw new KnowledgeFailure('TableTagUnsupported','table'); }
    const seen: Set<string> = new Set<string>();
    while (this.at < this.raw.length) {
      const before: number = this.at; this.space(); if (this.raw.charAt(this.at) === '>') { this.at++; return tag; }
      if (tag.closing || tag.name !== 'td' || before === this.at) { throw new KnowledgeFailure('TableAttribute','table'); }
      const attributeStart: number = this.at; while (/[a-z]/.test(this.raw.charAt(this.at)) && this.at < this.raw.length) { this.at++; }
      const attribute: string = this.raw.slice(attributeStart,this.at); if ((attribute !== 'rowspan' && attribute !== 'colspan') || seen.has(attribute)) { throw new KnowledgeFailure('TableAttributeUnsupported','table'); } seen.add(attribute);
      this.space(); if (this.raw.charAt(this.at++) !== '=') { throw new KnowledgeFailure('TableAttribute','table'); } this.space();
      const quote: string = this.raw.charAt(this.at++); if (quote !== '"' && quote !== "'") { throw new KnowledgeFailure('TableAttribute','table'); }
      const valueStart: number = this.at; while (this.at < this.raw.length && this.raw.charAt(this.at) !== quote) { this.at++; }
      const value: string = this.raw.slice(valueStart,this.at++);
      if (!new RegExp('^[1-9][0-9]{0,3}$').test(value)) { throw new KnowledgeFailure('TableSpan','table'); }
      if (attribute === 'rowspan') { tag.rowSpan = Number(value); } else { tag.columnSpan = Number(value); }
    } throw new KnowledgeFailure('TableTruncated','table');
  }
  decode(id: string): PdfTable {
    const table: PdfTable = new PdfTable(); table.id = id; table.sourceHtml = this.raw;
    const root: PdfTableTag = this.tag(); if (root.name !== 'table' || root.closing) { throw new KnowledgeFailure('TableRoot','table'); }
    const occupied: Set<number> = new Set<number>(); let row: number = -1; let inRow: boolean = false; let column: number = 0;
    while (this.at < this.raw.length) {
      const tag: PdfTableTag = this.tag();
      if (tag.name === 'table' && tag.closing && !inRow) {
        this.space(); if (this.at !== this.raw.length || table.cells.length === 0 || table.rows === 0 || Array.from(occupied).some((slot: number): boolean => Math.floor(slot/256) >= table.rows)) { throw new KnowledgeFailure('TableIncomplete','table'); }
        table.occupancy = occupied.size; return table;
      }
      if (tag.name === 'tr' && !tag.closing && !inRow) { if (++row >= 1000) { throw new KnowledgeFailure('TableRows','table'); } inRow = true; column = 0; table.rows++; continue; }
      if (tag.name === 'tr' && tag.closing && inRow) { inRow = false; continue; }
      if (tag.name !== 'td' || tag.closing || !inRow) { throw new KnowledgeFailure('TableNesting','table'); }
      while (occupied.has(row*256+column) && column < 256) { column++; }
      if (tag.rowSpan > 1000-row || tag.columnSpan > 256-column || table.cells.length >= PdfBudget.cells || tag.rowSpan*tag.columnSpan > PdfBudget.cells-occupied.size) { throw new KnowledgeFailure('TableGridBudget','table'); }
      const cell: PdfTableCell = new PdfTableCell(); cell.id = `${id}-cell-${table.cells.length}`; cell.row = row; cell.column = column; cell.rowSpan = tag.rowSpan; cell.columnSpan = tag.columnSpan;
      const textStart: number = this.at; const next: number = this.raw.indexOf('<',textStart); if (next < 0) { throw new KnowledgeFailure('TableCellTruncated','table'); }
      cell.text = pdfDecodeEntities(this.raw.slice(textStart,next)); this.at = next;
      const close: PdfTableTag = this.tag(); if (!close.closing || close.name !== 'td') { throw new KnowledgeFailure('TableActiveOrNestedContent','table'); }
      for (let r: number = row; r < row+tag.rowSpan; r++) { for (let c: number = column; c < column+tag.columnSpan; c++) { const slot: number = r*256+c; if (occupied.has(slot)) { throw new KnowledgeFailure('TableSpanCollision','table'); } occupied.add(slot); } }
      table.cells.push(cell); column += tag.columnSpan; table.columns = Math.max(table.columns,column);
    } throw new KnowledgeFailure('TableTruncated','table');
  }
}
