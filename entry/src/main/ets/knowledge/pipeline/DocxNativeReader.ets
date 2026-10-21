import { DocxOriginal, DocxSnapshot, DocxNativeNode, DocxNodeKind, DocxLocator, DocxTextFragment, DocxHeadingIdentity,
  DocxListIdentity, DocxTable, DocxCellAddress, DocxMedia, DocxRelationship, DocxCoverageIssue, DocxCoverageKind, DocxFailure, DocxLimits } from '../domain/DocxKnowledgeModels';
import { DocxXmlNode, docxXmlAttr, docxXmlChild, docxXmlChildren } from '../domain/DocxXmlModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { ParsedBlock, ParsedInline, ParsedKind, ParsedPrecision, ParsedLimits } from '../domain/ParsedDocumentModels';
import { ParsedOutputProjection, ParsedOutputImageLink } from './ParsedOutputDecoder';

const DOCX_WORD: string = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const DOCX_STRICT_WORD: string = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
function docxWord(node: DocxXmlNode): boolean { return node.namespace === DOCX_WORD || node.namespace === DOCX_STRICT_WORD; }
function docxChild(node: DocxXmlNode | undefined, name: string): DocxXmlNode | undefined { return node?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === name); }
function docxVal(node: DocxXmlNode | undefined): string | undefined { return node === undefined ? undefined : docxXmlAttr(node,node.namespace,'val'); }
function docxToggle(node: DocxXmlNode | undefined): boolean | undefined { if (node === undefined) { return undefined; } return ['0','false','off'].indexOf(docxVal(node) ?? '') < 0; }
function docxInteger(raw: string | undefined, fallback: number, maximum: number): number {
  if (raw === undefined) { return fallback; } if (!new RegExp('^[0-9]+$').test(raw) || Number(raw) > maximum) { throw new DocxFailure('NativePropertyInvalid','native'); } return Number(raw);
}
class DocxStyleResolved { hidden: boolean = false; outline: number = -1; numId: string = ''; level: number = 0; }
class DocxNativeReducer {
  snapshot: DocxSnapshot = new DocxSnapshot(); private styles: DocxXmlNode | undefined; private numbering: DocxXmlNode | undefined;
  private cancel: KnowledgeCancellation; private headings: DocxHeadingIdentity[] = []; private paragraph: number = 0;
  private counters: Map<string,number[]> = new Map<string,number[]>(); private occupied: number = 0;
  private joinNext: boolean = false;
  constructor(original: DocxOriginal, styles: DocxXmlNode | undefined, numbering: DocxXmlNode | undefined, relationships: DocxRelationship[], cancel: KnowledgeCancellation) {
    this.snapshot.original = original; this.snapshot.documentId = original.documentId; this.styles = styles; this.numbering = numbering; this.snapshot.relationships = relationships; this.cancel = cancel;
  }
  private issue(kind: DocxCoverageKind, code: string, node: DocxXmlNode, parent: string = ''): void {
    const issue: DocxCoverageIssue = new DocxCoverageIssue(); issue.kind = kind; issue.code = code; issue.part = this.snapshot.original.mainPart; issue.nodeId = parent; issue.path = node.path.slice();
    this.snapshot.coverage.issues.push(issue); if (kind === DocxCoverageKind.Excluded) { this.snapshot.coverage.excluded++; } else { this.snapshot.coverage.unsupported++; }
  }
  private resolveStyle(id: string, resolved: DocxStyleResolved, visited: string[]): void {
    if (id.length === 0) { return; }
    if (visited.indexOf(id) >= 0 || visited.length >= 64) { throw new DocxFailure('StyleInheritanceCycleOrDepth','native'); }
    const style: DocxXmlNode | undefined = this.styles?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'style' && docxXmlAttr(n,n.namespace,'styleId') === id);
    if (style === undefined) { return; }
    this.resolveStyle(docxVal(docxChild(style,'basedOn')) ?? '',resolved,visited.concat([id]));
    const run: DocxXmlNode | undefined = docxChild(style,'rPr'); const hidden: boolean | undefined = docxToggle(docxChild(run,'vanish'));
    if (hidden !== undefined) { resolved.hidden = hidden; }
    this.paragraphProperties(docxChild(style,'pPr'),resolved);
  }
  private paragraphProperties(properties: DocxXmlNode | undefined, resolved: DocxStyleResolved): void {
    const outline: string | undefined = docxVal(docxChild(properties,'outlineLvl')); if (outline !== undefined) { resolved.outline = docxInteger(outline,9,9); }
    const num: DocxXmlNode | undefined = docxChild(properties,'numPr');
    const id: string | undefined = docxVal(docxChild(num,'numId')); if (id !== undefined) { resolved.numId = id === '0' ? '' : id; }
    const level: string | undefined = docxVal(docxChild(num,'ilvl')); if (level !== undefined) { resolved.level = docxInteger(level,0,8); }
  }
  private properties(p: DocxXmlNode): DocxStyleResolved {
    const resolved: DocxStyleResolved = new DocxStyleResolved();
    const defaults: DocxXmlNode | undefined = docxChild(this.styles,'docDefaults');
    resolved.hidden = docxToggle(docxChild(docxChild(docxChild(defaults,'rPrDefault'),'rPr'),'vanish')) ?? false;
    this.paragraphProperties(docxChild(docxChild(defaults,'pPrDefault'),'pPr'),resolved);
    const properties: DocxXmlNode | undefined = docxChild(p,'pPr');
    const defaultStyle: DocxXmlNode | undefined = this.styles?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'style' && docxXmlAttr(n,n.namespace,'type') === 'paragraph' && ['1','true','on'].indexOf(docxXmlAttr(n,n.namespace,'default') ?? '') >= 0);
    this.resolveStyle(docxVal(docxChild(properties,'pStyle')) ?? (defaultStyle === undefined ? '' : docxXmlAttr(defaultStyle,defaultStyle.namespace,'styleId') ?? ''),resolved,[]);
    this.paragraphProperties(properties,resolved); return resolved;
  }
  private addText(target: DocxNativeNode, run: DocxXmlNode, node: DocxXmlNode, text: string, kind: string): void {
    const fragment: DocxTextFragment = new DocxTextFragment(); fragment.runPath = run.path.slice(); fragment.textPath = node.path.slice();
    fragment.start = target.text.length; fragment.end = fragment.start+text.length; fragment.rawEnd = text.length; fragment.kind = kind;
    target.text += text; target.locator.fragments.push(fragment);
  }
  private runContents(node: DocxXmlNode, run: DocxXmlNode, target: DocxNativeNode, hidden: boolean): void {
    this.cancel.check();
    if (docxWord(node)) {
      if (['rPr','pPr','rPrChange','pPrChange','tblPrChange','trPrChange','tcPrChange','sectPr'].indexOf(node.localName) >= 0) { return; }
      if (node.localName === 'del' || node.localName === 'moveFrom') { this.issue(DocxCoverageKind.Excluded,node.localName,node,target.id); return; }
      if (node.localName === 'txbxContent') { this.issue(DocxCoverageKind.Unsupported,'TextBox',node,target.id); return; }
      if (['footnoteReference','endnoteReference','object','altChunk'].indexOf(node.localName) >= 0) { this.issue(DocxCoverageKind.Unsupported,node.localName === 'footnoteReference' ? 'FootnoteReference' : node.localName === 'endnoteReference' ? 'EndnoteReference' : node.localName,node,target.id); return; }
      if (node.localName === 'instrText' || node.localName === 'delText') { this.issue(DocxCoverageKind.Excluded,node.localName,node,target.id); return; }
      if (node.localName === 'r') {
        const rp: DocxXmlNode | undefined = docxChild(node,'rPr'); const resolved: DocxStyleResolved = new DocxStyleResolved(); resolved.hidden = hidden;
        const defaultStyle: DocxXmlNode | undefined = this.styles?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'style' && docxXmlAttr(n,n.namespace,'type') === 'character' && ['1','true','on'].indexOf(docxXmlAttr(n,n.namespace,'default') ?? '') >= 0);
        this.resolveStyle(docxVal(docxChild(rp,'rStyle')) ?? (defaultStyle === undefined ? '' : docxXmlAttr(defaultStyle,defaultStyle.namespace,'styleId') ?? ''),resolved,[]);
        const direct: boolean | undefined = docxToggle(docxChild(rp,'vanish')); if (direct !== undefined) { resolved.hidden = direct; }
        for (const child of node.children) { this.runContents(child,node,target,resolved.hidden); } return;
      }
      if (['t','tab','br','cr','noBreakHyphen','softHyphen'].indexOf(node.localName) >= 0) {
        if (hidden) { this.issue(DocxCoverageKind.Excluded,'EffectiveHidden',node,target.id); return; }
        this.addText(target,run,node,node.localName === 't' ? node.text : node.localName === 'tab' ? '\t' : node.localName === 'noBreakHyphen' ? '\u2011' : node.localName === 'softHyphen' ? '\u00ad' : '\n',node.localName); return;
      }
      if (node.localName === 'tbl') { this.issue(DocxCoverageKind.Unsupported,'NestedTable',node,target.id); return; }
    }
    if (['http://schemas.openxmlformats.org/officeDocument/2006/math','http://purl.oclc.org/ooxml/officeDocument/math'].indexOf(node.namespace) >= 0) { this.issue(DocxCoverageKind.Unsupported,'Formula',node,target.id); return; }
    if (node.localName === 'chart') { this.issue(DocxCoverageKind.Unsupported,'Chart',node,target.id); return; }
    if (node.localName === 'blip' && ['http://schemas.openxmlformats.org/drawingml/2006/main','http://purl.oclc.org/ooxml/drawingml/main'].indexOf(node.namespace) >= 0) {
      if (hidden) { this.issue(DocxCoverageKind.Excluded,'HiddenMedia',node,target.id); return; }
      const relationship: string = docxXmlAttr(node,'http://schemas.openxmlformats.org/officeDocument/2006/relationships','embed') ?? docxXmlAttr(node,'http://purl.oclc.org/ooxml/officeDocument/relationships','embed') ?? '';
      if (relationship.length > 0) {
        if (this.snapshot.media.length >= DocxLimits.media) { throw new DocxFailure('MediaReferenceBudget','native'); }
        const media: DocxMedia = new DocxMedia(); media.id = 'media-'+node.order; media.relationshipId = relationship; media.sourcePart = this.snapshot.original.mainPart; media.parentId = target.id; media.parentPath = node.path.slice();
        const rel: DocxRelationship | undefined = this.snapshot.relationships.find((r: DocxRelationship): boolean => r.sourcePart === media.sourcePart && r.id === relationship); media.targetPart = rel?.target ?? ''; media.external = rel?.external ?? false; this.snapshot.media.push(media);
      }
    }
    if (node.namespace === 'http://schemas.openxmlformats.org/markup-compatibility/2006' && node.localName === 'AlternateContent') { this.issue(DocxCoverageKind.Unsupported,'AlternateContent',node,target.id); return; }
    for (const child of node.children) { this.runContents(child,run,target,hidden); }
  }
  private list(resolved: DocxStyleResolved): DocxListIdentity | undefined {
    if (resolved.numId.length === 0) { return undefined; }
    const list: DocxListIdentity = new DocxListIdentity(); list.numId = resolved.numId; list.level = resolved.level;
    const num: DocxXmlNode | undefined = this.numbering?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'num' && docxXmlAttr(n,n.namespace,'numId') === resolved.numId);
    list.abstractId = docxVal(docxChild(num,'abstractNumId')) ?? '';
    const abstract: DocxXmlNode | undefined = this.numbering?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'abstractNum' && docxXmlAttr(n,n.namespace,'abstractNumId') === list.abstractId);
    const level: DocxXmlNode | undefined = abstract?.children.find((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'lvl' && docxXmlAttr(n,n.namespace,'ilvl') === `${list.level}`);
    list.format = docxVal(docxChild(level,'numFmt')) ?? ''; list.pattern = docxVal(docxChild(level,'lvlText')) ?? '';
    const counters: number[] = this.counters.get(list.numId) ?? [];
    counters[list.level] = counters[list.level] === undefined ? docxInteger(docxVal(docxChild(level,'start')),1,1000000) : counters[list.level]+1;
    for (let i: number = list.level+1; i < counters.length; i++) { counters[i] = 0; } this.counters.set(list.numId,counters);
    if (num !== undefined && !num.children.some((n: DocxXmlNode): boolean => n.localName === 'lvlOverride') && (list.format === 'decimal' && list.pattern === `%${list.level+1}.` || list.format === 'bullet' && list.pattern.indexOf('%') < 0)) {
      list.display = list.format === 'bullet' ? list.pattern : `${counters[list.level]}.`; list.displayEvidence = 'NumberingDefinition';
    } return list;
  }
  private paragraphNode(p: DocxXmlNode, cell: DocxCellAddress | undefined): void {
    const resolved: DocxStyleResolved = this.properties(p); const node: DocxNativeNode = new DocxNativeNode();
    node.id = 'node-'+p.order; node.order = p.order; node.outline = resolved.outline; node.list = this.list(resolved);
    node.kind = cell !== undefined ? DocxNodeKind.Cell : resolved.outline >= 0 && resolved.outline < 9 ? DocxNodeKind.Heading : node.list === undefined ? DocxNodeKind.Paragraph : DocxNodeKind.List;
    const locator: DocxLocator = node.locator; locator.originalAssetId = this.snapshot.original.assetId; locator.originalHash = this.snapshot.original.hash; locator.originalVersion = this.snapshot.original.version;
    locator.part = this.snapshot.original.mainPart; locator.nodeId = node.id; locator.path = p.path.slice(); locator.paragraph = this.paragraph++; locator.cell = cell;
    for (const child of p.children) { this.runContents(child,p,node,resolved.hidden); }
    locator.end = node.text.length;
    if (node.kind === DocxNodeKind.Heading) {
      this.headings = this.headings.filter((h: DocxHeadingIdentity): boolean => h.level < resolved.outline);
      const h: DocxHeadingIdentity = new DocxHeadingIdentity(); h.nodeId = node.id; h.text = node.text; h.level = resolved.outline; this.headings.push(h);
    }
    locator.headings = this.headings.slice();
    const previous: DocxNativeNode | undefined = this.snapshot.nodes[this.snapshot.nodes.length-1];
    if (this.joinNext && previous !== undefined && previous.locator.cell?.anchorId === cell?.anchorId) {
      const offset: number = previous.text.length; previous.text += node.text;
      for (const fragment of node.locator.fragments) { fragment.start += offset; fragment.end += offset; previous.locator.fragments.push(fragment); }
      previous.locator.end = previous.text.length;
    } else if (node.text.length > 0) { if (this.snapshot.nodes.length >= DocxLimits.nodes) { throw new DocxFailure('NativeNodeBudget','native'); } this.snapshot.nodes.push(node); }
    const marker: DocxXmlNode | undefined = docxChild(docxChild(p,'pPr'),'rPr');
    this.joinNext = docxChild(marker,'del') !== undefined || docxChild(marker,'moveFrom') !== undefined;
  }
  private table(t: DocxXmlNode): void {
    this.joinNext = false;
    const table: DocxTable = new DocxTable(); table.id = 'table-'+t.order; table.part = this.snapshot.original.mainPart; table.path = t.path.slice();
    const grid: DocxXmlNode | undefined = docxChild(t,'tblGrid'); table.columns = grid?.children.filter((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'gridCol').length ?? 0;
    const vertical: Map<number,DocxCellAddress> = new Map<number,DocxCellAddress>();
    const rows: DocxXmlNode[] = t.children.filter((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'tr');
    for (let physicalRow: number = 0; physicalRow < rows.length; physicalRow++) {
      const row: DocxXmlNode = rows[physicalRow]; const rp: DocxXmlNode | undefined = docxChild(row,'trPr');
      if (docxChild(rp,'del') !== undefined) { this.issue(DocxCoverageKind.Excluded,'DeletedRow',row,table.id); continue; }
      let column: number = docxInteger(docxVal(docxChild(rp,'gridBefore')),0,DocxLimits.cells); const currentColumns: number[] = [];
      const cells: DocxXmlNode[] = row.children.filter((n: DocxXmlNode): boolean => docxWord(n) && n.localName === 'tc'); let horizontal: DocxCellAddress | undefined = undefined;
      for (let physicalCell: number = 0; physicalCell < cells.length; physicalCell++) {
        const source: DocxXmlNode = cells[physicalCell]; const cp: DocxXmlNode | undefined = docxChild(source,'tcPr');
        if (docxChild(cp,'cellMerge') !== undefined) { this.issue(DocxCoverageKind.Unsupported,'TrackedCellMergeNotResolved',source,table.id); }
        if (docxChild(cp,'cellDel') !== undefined) { this.issue(DocxCoverageKind.Excluded,'DeletedCell',source,table.id); continue; }
        const cell: DocxCellAddress = new DocxCellAddress(); cell.tableId = table.id; cell.physicalRow = physicalRow; cell.physicalCell = physicalCell; cell.row = table.rows; cell.column = column;
        cell.columnSpan = Math.max(1,docxInteger(docxVal(docxChild(cp,'gridSpan')),1,DocxLimits.cells)); cell.anchorId = 'cell-'+source.order;
        const vm: DocxXmlNode | undefined = docxChild(cp,'vMerge'); const hm: DocxXmlNode | undefined = docxChild(cp,'hMerge');
        if (vm !== undefined && docxVal(vm) !== 'restart') {
          const anchor: DocxCellAddress | undefined = vertical.get(column);
          if (anchor !== undefined && anchor.columnSpan === cell.columnSpan && anchor.row+anchor.rowSpan === cell.row) { cell.anchorId = anchor.anchorId; cell.continuation = true; anchor.rowSpan++; }
          else { this.issue(DocxCoverageKind.Unsupported,'MergeAnchorUnproven',source,table.id); cell.continuation = true; }
        } else if (hm !== undefined && docxVal(hm) !== 'restart') {
          if (horizontal !== undefined) { horizontal.columnSpan += cell.columnSpan; cell.anchorId = horizontal.anchorId; cell.continuation = true; }
          else { this.issue(DocxCoverageKind.Unsupported,'MergeAnchorUnproven',source,table.id); cell.continuation = true; }
        }
        if (hm !== undefined && docxVal(hm) === 'restart') { horizontal = cell; } else if (hm === undefined) { horizontal = undefined; }
        if (vm !== undefined) { const anchor: DocxCellAddress | undefined = cell.continuation ? vertical.get(column) : cell; if (anchor !== undefined) { for (let i: number = column; i < column+cell.columnSpan; i++) { vertical.set(i,anchor); currentColumns.push(i); } } }
        this.occupied += cell.columnSpan; if (this.occupied > DocxLimits.cells || table.cells.length >= DocxLimits.cells) { throw new DocxFailure('TableCellBudget','native'); }
        table.cells.push(cell); column += cell.columnSpan;
        this.joinNext = false;
        const contentCell: DocxCellAddress | undefined = cell.continuation ? table.cells.find((a: DocxCellAddress): boolean => !a.continuation && a.anchorId === cell.anchorId) : cell;
        if (contentCell !== undefined) {
          for (const child of source.children) {
            if (docxWord(child) && child.localName === 'p') { this.paragraphNode(child,contentCell); }
            else if (docxWord(child) && child.localName === 'tbl') { this.issue(DocxCoverageKind.Unsupported,'NestedTable',child,table.id); }
          }
        }
      }
      for (const key of Array.from(vertical.keys())) { if (currentColumns.indexOf(key) < 0) { vertical.delete(key); } }
      table.columns = Math.max(table.columns,column); table.rows++;
      if (table.rows*table.columns > DocxLimits.cells) { throw new DocxFailure('TableOccupiedCellBudget','native'); }
    }
    this.snapshot.tables.push(table);
    this.joinNext = false;
  }
  read(root: DocxXmlNode): DocxSnapshot {
    if (!docxWord(root) || root.localName !== 'document') { throw new DocxFailure('WordDocumentRootRequired','native'); }
    if (this.styles !== undefined && (!docxWord(this.styles) || this.styles.localName !== 'styles') || this.numbering !== undefined && (!docxWord(this.numbering) || this.numbering.localName !== 'numbering')) { throw new DocxFailure('ReferencedStyleOrNumberingRootInvalid','native'); }
    const body: DocxXmlNode | undefined = docxChild(root,'body'); if (body === undefined) { throw new DocxFailure('WordBodyMissing','native'); }
    this.body(body); this.snapshot.coverage.supported = this.snapshot.nodes.length; this.snapshot.coverage.empty = this.snapshot.nodes.length === 0;
    this.snapshot.coverage.partial = this.snapshot.coverage.unsupported > 0; return this.snapshot;
  }
  private body(root: DocxXmlNode): void {
    for (const node of root.children) {
      this.cancel.check(); if (!docxWord(node)) { if (node.localName === 'AlternateContent') { this.issue(DocxCoverageKind.Unsupported,'AlternateContent',node); } continue; }
      if (node.localName === 'p') { this.paragraphNode(node,undefined); }
      else if (node.localName === 'tbl') { this.table(node); }
      else if (node.localName === 'del' || node.localName === 'moveFrom') { this.issue(DocxCoverageKind.Excluded,node.localName,node); }
      else if (['ins','moveTo','sdt','sdtContent','customXml'].indexOf(node.localName) >= 0) { this.body(node); }
      else if (node.localName === 'altChunk') { this.issue(DocxCoverageKind.Unsupported,'altChunk',node); }
    }
  }
}
export function docxReadNative(original: DocxOriginal, root: DocxXmlNode, styles: DocxXmlNode | undefined, numbering: DocxXmlNode | undefined, relationships: DocxRelationship[], cancel: KnowledgeCancellation): DocxSnapshot {
  return new DocxNativeReducer(original,styles,numbering,relationships,cancel).read(root);
}

// Separate additive projection: legacy snapshot/codec fields and digests are unchanged.
class DocxUnifiedObjectReader {
  private out: ParsedOutputProjection = new ParsedOutputProjection(); private relationships: DocxRelationship[]; private cancel: KnowledgeCancellation;
  constructor(relationships: DocxRelationship[], cancel: KnowledgeCancellation) { this.relationships = relationships; this.cancel = cancel; }
  private run(node: DocxXmlNode, block: ParsedBlock): void {
    this.cancel.check();
    if (docxWord(node) && ['pPr','rPr','del','moveFrom','instrText','delText'].indexOf(node.localName) >= 0) { return; }
    if (docxWord(node) && node.localName === 'r' && docxToggle(docxChild(docxChild(node,'rPr'),'vanish')) === true) { this.out.warnings.push('HiddenNativeRunExcluded'); return; }
    const r: ParsedInline = new ParsedInline(); r.id = `${block.id}-r${block.inlines.length}`; r.order = block.inlines.length;
    if (docxWord(node) && ['t','tab','br','cr'].indexOf(node.localName) >= 0) { r.text = node.localName === 't' ? node.text : node.localName === 'tab' ? '\t' : '\n'; block.inlines.push(r); return; }
    if (['http://schemas.openxmlformats.org/officeDocument/2006/math','http://purl.oclc.org/ooxml/officeDocument/math'].indexOf(node.namespace) >= 0) {
      r.kind = ParsedKind.Formula; r.formula.unsupportedReason = 'OmmlPreservedAsUnsupportedNoLatexConversion'; block.inlines.push(r); return;
    }
    const blip: boolean = node.localName === 'blip' && ['http://schemas.openxmlformats.org/drawingml/2006/main','http://purl.oclc.org/ooxml/drawingml/main'].indexOf(node.namespace) >= 0;
    const vml: boolean = node.localName === 'imagedata' && node.namespace === 'urn:schemas-microsoft-com:vml';
    if (blip || vml) {
      const id: string = docxXmlAttr(node,'http://schemas.openxmlformats.org/officeDocument/2006/relationships',vml ? 'id' : 'embed') ?? docxXmlAttr(node,'http://purl.oclc.org/ooxml/officeDocument/relationships',vml ? 'id' : 'embed') ?? '';
      const rel: DocxRelationship | undefined = this.relationships.find((row: DocxRelationship): boolean => row.id === id);
      const link: ParsedOutputImageLink = new ParsedOutputImageLink(); link.occurrenceId = `native-occ-${this.out.links.length}`; link.member = rel?.external ? '' : rel?.target ?? ''; link.blockId = block.id; link.inlineId = r.id; link.order = this.out.links.length;
      if (this.out.links.length >= ParsedLimits.occurrences) { throw new DocxFailure('UnifiedMediaBudget','native'); } this.out.links.push(link);
      r.kind = ParsedKind.Image; r.imageOccurrenceId = link.occurrenceId; if (rel === undefined || rel.external) { r.limitation = 'ExternalOrMissingMediaNotRead'; } block.inlines.push(r); return;
    }
    if (node.localName === 'object' || node.localName === 'chart' || node.localName === 'altChunk' || node.localName === 'AlternateContent' || node.localName === 'txbxContent') {
      r.kind = ParsedKind.Unknown; r.limitation = 'NativeObjectNotConverted:'+node.localName; block.inlines.push(r); return;
    }
    for (const child of node.children) { this.run(child,block); }
  }
  private body(node: DocxXmlNode, parent: string = '', row: number = -1, column: number = -1): void {
    this.cancel.check(); if (docxWord(node) && ['del','moveFrom','sectPr','tblPr','trPr','tcPr','tblGrid'].indexOf(node.localName) >= 0) { return; }
    if (docxWord(node) && node.localName === 'p') {
      const b: ParsedBlock = new ParsedBlock(); b.id = 'native-'+node.order; b.order = this.out.blocks.length; b.parentId = parent; b.locator.precision = ParsedPrecision.Block;
      b.evidenceType = 'SourceContextOnly'; b.locator.limitations.push('NativeObjectSequenceOnly');
      for (const child of node.children) { this.run(child,b); }
      if (b.inlines.length === 0) { return; }
      if (row >= 0) { b.kind = ParsedKind.Cell; b.row = row; b.column = column; }
      if (this.out.blocks.length >= ParsedLimits.blocks) { throw new DocxFailure('UnifiedNodeBudget','native'); } this.out.blocks.push(b); return;
    }
    if (docxWord(node) && node.localName === 'tbl') {
      const t: ParsedBlock = new ParsedBlock(); t.id = 'native-table-'+node.order; t.kind = ParsedKind.Table; t.order = this.out.blocks.length; t.parentId = parent; this.out.blocks.push(t);
      let r: number = 0;
      for (const tr of node.children) { if (!docxWord(tr) || tr.localName !== 'tr') { continue; } let c: number = 0; for (const tc of tr.children) { if (!docxWord(tc) || tc.localName !== 'tc') { continue; } for (const child of tc.children) { this.body(child,t.id,r,c); } c++; } r++; }
      return;
    }
    for (const child of node.children) { this.body(child,parent,row,column); }
  }
  read(root: DocxXmlNode): ParsedOutputProjection {
    if (!docxWord(root) || root.localName !== 'document') { throw new DocxFailure('WordDocumentRootRequired','unified-native'); }
    const body: DocxXmlNode | undefined = docxChild(root,'body'); if (body === undefined) { throw new DocxFailure('WordBodyMissing','unified-native'); }
    this.body(body); this.out.warnings.push('NativeObjectsNotAlignedToServiceText'); return this.out;
  }
}
export function docxReadUnifiedNative(root: DocxXmlNode, relationships: DocxRelationship[], cancel: KnowledgeCancellation): ParsedOutputProjection {
  return new DocxUnifiedObjectReader(relationships,cancel).read(root);
}
