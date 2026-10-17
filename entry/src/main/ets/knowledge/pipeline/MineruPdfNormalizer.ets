import { PdfArchivePort, PdfNormalizationPort } from '../domain/KnowledgePorts';
import { PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfNormalizedDocument, PdfContentNode, PdfNodeKind, PdfInlineRun, PdfBox, PdfLocator, PdfCoverageIssue, PdfBudget, KnowledgeCancellation, KnowledgeFailure, PdfTableCell } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson, PdfJsonNode } from './BoundedDocumentJson';
import { PdfTableDecoder } from './PdfTableDecoder';

function pdfUniqueMember(manifest: PdfZipManifest, suffix: string): PdfZipMember {
  const matches: PdfZipMember[] = manifest.members.filter((member: PdfZipMember): boolean => member.logicalName.endsWith(suffix));
  if (matches.length !== 1 || !matches[0].verified) { throw new KnowledgeFailure('ProtocolMemberMissingOrAmbiguous','normalize'); } return matches[0];
}
function pdfSourceBox(node: PdfJsonNode): PdfBox {
  const values: PdfJsonNode[] = node.array(); if (values.length !== 4) { throw new KnowledgeFailure('BoxShape','normalize'); }
  const numbers: number[] = values.map((value: PdfJsonNode): number => value.integer());
  if (numbers.some((value: number): boolean => value < 0 || value > 1000) || numbers[0] >= numbers[2] || numbers[1] >= numbers[3]) { throw new KnowledgeFailure('BoxRange','normalize'); }
  const box: PdfBox = new PdfBox(); box.left = numbers[0]; box.top = numbers[1]; box.right = numbers[2]; box.bottom = numbers[3]; return box;
}
function pdfInline(node: PdfJsonNode): PdfInlineRun[] {
  const runs: PdfInlineRun[] = [];
  for (const item of node.array()) {
    const run: PdfInlineRun = new PdfInlineRun(); run.kind = item.required('type').string(); run.text = item.required('content').string();
    if (run.kind !== 'text' && run.kind !== 'equation_inline') { throw new KnowledgeFailure('InlineTypeUnsupported','normalize'); } runs.push(run);
  } return runs;
}
function pdfAuxFlags(node: PdfJsonNode, flag: string): number {
  let count: number = 0;
  if (node.kind === 'object') { for (const field of node.fields) { if (field.key === flag && field.node.kind === 'true') { count++; } count += pdfAuxFlags(field.node,flag); } }
  else if (node.kind === 'array') { for (const item of node.items) { count += pdfAuxFlags(item,flag); } } return count;
}
class PdfAuditProjection { boxes: PdfBox[] = []; pages: number[] = []; }
function pdfAuditProjection(bytes: Uint8Array, cancel: KnowledgeCancellation): PdfAuditProjection {
  const audit: PdfJsonNode[] = new BoundedDocumentJson(bytes,cancel).read().array();
  if (audit.length > PdfBudget.nodes) { throw new KnowledgeFailure('NodeBudgetOrAudit','normalize'); }
  const result: PdfAuditProjection = new PdfAuditProjection();
  for (const node of audit) { cancel.check(); result.boxes.push(pdfSourceBox(node.required('bbox'))); result.pages.push(node.required('page_idx').integer()); }
  return result;
}
class PdfLayoutProjection { pages: number[] = []; cross: number = 0; deleted: number = 0; }
function pdfLayoutProjection(bytes: Uint8Array, cancel: KnowledgeCancellation): PdfLayoutProjection {
  const layout: PdfJsonNode = new BoundedDocumentJson(bytes,cancel).read();
  if (layout.required('_version_name').string() !== '3.4.4' || layout.required('_backend').string() !== 'hybrid' || layout.required('_effort').string() !== 'medium' || layout.required('_ocr_enable').kind !== 'true') { throw new KnowledgeFailure('ProtocolProfileUnrecognized','normalize'); }
  const result: PdfLayoutProjection = new PdfLayoutProjection(); result.pages = layout.required('pdf_info').array().map((node: PdfJsonNode): number => node.required('page_idx').integer());
  result.cross = pdfAuxFlags(layout,'cross_page'); result.deleted = pdfAuxFlags(layout,'lines_deleted'); return result;
}
function pdfIssue(document: PdfNormalizedDocument, code: string, nodeId: string = '', page: number = -1): void {
  const issue: PdfCoverageIssue = new PdfCoverageIssue(); issue.code = code; issue.nodeId = nodeId; issue.pageIndex0 = page; document.coverage.issues.push(issue);
}
function pdfCaptionRuns(content: PdfJsonNode, field: string): PdfInlineRun[] {
  const node: PdfJsonNode | undefined = content.optional(field); if (node === undefined) { return []; }
  const result: PdfInlineRun[] = [];
  for (const caption of node.array()) {
    if (caption.kind === 'array') { result.push(...pdfInline(caption)); }
    else if (caption.kind === 'object' && caption.optional('type') !== undefined && caption.optional('content') !== undefined) {
      const run: PdfInlineRun = new PdfInlineRun(); run.kind = caption.required('type').string(); run.text = caption.required('content').string();
      if (run.kind !== 'text' && run.kind !== 'equation_inline') { throw new KnowledgeFailure('CaptionUnsupported','normalize'); } result.push(run);
    } else { throw new KnowledgeFailure('CaptionShapeUnsupported','normalize'); }
  } return result;
}
export class MineruPdfNormalizer implements PdfNormalizationPort {
  async normalize(binding: PdfSourceBinding, manifest: PdfZipManifest, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument> {
    if (!manifest.hardPassed || manifest.zipHash !== binding.zipHash || binding.originalPages < 1 || binding.originalPages > PdfBudget.pages) { throw new KnowledgeFailure('UnvalidatedBinding','normalize'); }
    const v2Member: PdfZipMember = pdfUniqueMember(manifest,'_content_list_v2.json');
    const v1Member: PdfZipMember = pdfUniqueMember(manifest,'_content_list.json');
    const layoutMember: PdfZipMember = pdfUniqueMember(manifest,'layout.json');
    const stem: string = v2Member.logicalName.slice(0,-'_content_list_v2.json'.length);
    if (v1Member.logicalName !== stem+'_content_list.json') { throw new KnowledgeFailure('ProtocolRootIdentity','normalize'); }
    const audit: PdfAuditProjection = pdfAuditProjection(await archive.readMember(manifest,v1Member,cancel),cancel);
    const layout: PdfLayoutProjection = pdfLayoutProjection(await archive.readMember(manifest,layoutMember,cancel),cancel);
    const pages: PdfJsonNode[] = new BoundedDocumentJson(await archive.readMember(manifest,v2Member,cancel),cancel).read().array();
    if (pages.length !== binding.originalPages || pages.length !== layout.pages.length || pages.length > PdfBudget.pages) { throw new KnowledgeFailure('PageAuditMismatch','normalize'); }
    const document: PdfNormalizedDocument = new PdfNormalizedDocument(); document.binding = binding; document.manifest = manifest;
    document.coverage.hardPassed = true; let order: number = 0; let sourceCells: number = 0; let occupancy: number = 0;
    for (let page: number = 0; page < pages.length; page++) {
      cancel.check(); if (layout.pages[page] !== page) { throw new KnowledgeFailure('LayoutPageOrder','normalize'); }
      if (pages[page].array().length === 0) { document.coverage.unknownPages.push(page); pdfIssue(document,'NoBlocksNotProvenBlank','',page); }
      for (const raw of pages[page].array()) {
        if (order >= PdfBudget.nodes || order >= audit.boxes.length) { throw new KnowledgeFailure('NodeBudgetOrAudit','normalize'); }
        const node: PdfContentNode = new PdfContentNode(); node.id = `node-${order}`; node.order = order; node.sourceRecord = order; node.sourceMemberId = v2Member.id; node.pageIndex0 = page;
        node.providerType = raw.required('type').string(); const content: PdfJsonNode = raw.required('content');
        const box: PdfBox = pdfSourceBox(raw.required('bbox')); const auditBox: PdfBox = audit.boxes[order];
        if (audit.pages[order] !== page || box.left !== auditBox.left || box.top !== auditBox.top || box.right !== auditBox.right || box.bottom !== auditBox.bottom) { throw new KnowledgeFailure('V1V2OrderAuditMismatch','normalize'); }
        const locator: PdfLocator = new PdfLocator(); locator.originalHash = binding.originalHash; locator.originalVersion = binding.originalVersion;
        locator.providerPageIndex0 = page; locator.candidatePhysicalPageIndex0 = page; locator.providerBoxes = [box]; node.locators = [locator];
        try {
          if (node.providerType === 'paragraph') { node.kind = PdfNodeKind.Text; node.runs = pdfInline(content.required('paragraph_content')); }
          else if (node.providerType === 'title') { node.kind = PdfNodeKind.Title; content.required('level').integer(); node.runs = pdfInline(content.required('title_content')); }
          else if (node.providerType === 'equation_interline') { node.kind = PdfNodeKind.Formula; if (content.required('math_type').string() !== 'latex') { throw new KnowledgeFailure('MathTypeUnsupported','normalize'); } node.rawLatex = content.required('math_content').string(); node.text = node.rawLatex; }
          else if (node.providerType === 'table') {
            node.kind = PdfNodeKind.Table; node.table = new PdfTableDecoder(content.required('html').string()).decode(node.id+'-table');
            sourceCells += node.table.cells.length; occupancy += node.table.occupancy;
            if (sourceCells > PdfBudget.cells || occupancy > PdfBudget.cells) { throw new KnowledgeFailure('GlobalTableBudget','normalize'); }
            node.text = node.table.cells.map((cell: PdfTableCell): string => cell.text).join('\n');
          } else if (node.providerType === 'list') {
            if (content.required('list_type').string() !== 'reference_list') { throw new KnowledgeFailure('ListTypeUnsupported','normalize'); }
            node.kind = PdfNodeKind.Reference;
            for (const item of content.required('list_items').array()) { item.required('item_type').string(); node.runs.push(...pdfInline(item.required('item_content'))); const separator: PdfInlineRun = new PdfInlineRun(); separator.text = '\n'; node.runs.push(separator); }
          } else if (node.providerType === 'page_header') { node.kind = PdfNodeKind.Header; node.runs = pdfInline(content.required('page_header_content')); }
          else if (node.providerType === 'page_number') { node.kind = PdfNodeKind.PageNumber; node.runs = pdfInline(content.required('page_number_content')); }
          else if (node.providerType === 'page_aside_text') { node.kind = PdfNodeKind.Aside; node.runs = pdfInline(content.required('page_aside_text_content')); }
          else if (node.providerType === 'image' || node.providerType === 'chart') { node.kind = PdfNodeKind.Image; if (content.required('content').string().length > 0) { pdfIssue(document,'VisualContentUnverified',node.id,page); } }
          else { throw new KnowledgeFailure('NodeTypeUnsupported','normalize'); }
          if (node.runs.length > 0) { node.text = node.runs.map((run: PdfInlineRun): string => run.text).join(''); }
          const imageSource: PdfJsonNode | undefined = content.optional('image_source');
          if (imageSource !== undefined) {
            const logical: string = imageSource.required('path').string(); const assets: PdfZipMember[] = manifest.members.filter((member: PdfZipMember): boolean => member.logicalName === logical);
            if (assets.length !== 1 || !assets[0].verified) { throw new KnowledgeFailure('ImageRelationshipMissing','normalize'); } node.assetIds.push(assets[0].id);
          }
          const captionFields: string[] = ['table_caption','table_footnote','chart_caption','chart_footnote','image_caption','image_footnote','caption','footnote'];
          for (const field of captionFields) {
            const runs: PdfInlineRun[] = pdfCaptionRuns(content,field);
            if (runs.length > 0) {
              const caption: PdfContentNode = new PdfContentNode(); caption.id = `${node.id}-${field}`; caption.parentId = node.id; caption.kind = PdfNodeKind.Caption;
              caption.runs = runs; caption.text = runs.map((run: PdfInlineRun): string => run.text).join(''); caption.locators = node.locators;
              caption.assetIds = node.assetIds.slice(); caption.pageIndex0 = page; caption.verified = true; caption.sourceMemberId = v2Member.id; caption.sourceRecord = order;
              node.captionIds.push(caption.id); document.nodes.push(caption);
            }
          }
          node.verified = true;
          if (node.text.trim().length === 0 && node.kind !== PdfNodeKind.Image) { node.verified = false; node.excludedReason = 'EmptyText'; pdfIssue(document,'EmptyText',node.id,page); }
        } catch (error) {
          if (error instanceof KnowledgeFailure && (error.category.includes('Budget') || error.category === 'TableRows' || error.category === 'TableBytes')) { throw error; }
          node.verified = false; node.excludedReason = error instanceof KnowledgeFailure ? error.category : 'NodeInvalid'; pdfIssue(document,node.excludedReason,node.id,page);
        }
        document.nodes.push(node); if (document.nodes.length > PdfBudget.nodes) { throw new KnowledgeFailure('NodeBudget','normalize'); } order++;
      }
    }
    if (order !== audit.boxes.length) { throw new KnowledgeFailure('V1V2CountAuditMismatch','normalize'); }
    const cross: number = layout.cross; const deleted: number = layout.deleted;
    if (cross > 0) { pdfIssue(document,`CrossPageUnverified:${cross}`); } if (deleted > 0) { pdfIssue(document,`LinesDeleted:${deleted}`); }
    pdfIssue(document,'OriginalPageAndRegionMappingUnverified'); pdfIssue(document,'ServicePdfIsDerivativeNotOriginal');
    document.coverage.validatedNodes = document.nodes.filter((node: PdfContentNode): boolean => node.verified).length;
    document.coverage.excludedNodes = document.nodes.filter((node: PdfContentNode): boolean => !node.verified).length;
    document.coverage.unresolvedNodes = document.coverage.excludedNodes; return document;
  }
}
