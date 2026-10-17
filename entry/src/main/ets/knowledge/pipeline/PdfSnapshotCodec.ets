import { BoundedDocumentJson, PdfJsonNode } from './BoundedDocumentJson';
import {
  PdfNormalizedDocument, PdfSourceBinding, PdfZipMember, PdfContentNode, PdfNodeKind, PdfInlineRun,
  PdfLocator, PdfBox, PdfMappingTier, PdfTable, PdfTableCell, PdfDerivedImage, PdfCoverageIssue,
  KnowledgeCancellation, KnowledgeFailure, PdfBudget
} from '../domain/PdfKnowledgeModels';
import { documentUtf8Bytes } from '../domain/DocumentParseModels';

export function pdfCodecUtf8(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(documentUtf8Bytes(text)); let offset: number = 0;
  for (const char of text) {
    const cp: number = char.codePointAt(0) ?? 0;
    if (cp < 128) { bytes[offset++] = cp; }
    else if (cp < 2048) { bytes[offset++] = 0xc0|(cp>>6); bytes[offset++] = 0x80|(cp&63); }
    else if (cp < 65536) { bytes[offset++] = 0xe0|(cp>>12); bytes[offset++] = 0x80|((cp>>6)&63); bytes[offset++] = 0x80|(cp&63); }
    else { bytes[offset++] = 0xf0|(cp>>18); bytes[offset++] = 0x80|((cp>>12)&63); bytes[offset++] = 0x80|((cp>>6)&63); bytes[offset++] = 0x80|(cp&63); }
  } return bytes;
}
function codecString(node: PdfJsonNode, key: string): string { return node.required(key).string(); }
function codecInteger(node: PdfJsonNode, key: string): number { return node.required(key).integer(); }
function codecBoolean(node: PdfJsonNode, key: string): boolean {
  const value: PdfJsonNode = node.required(key); if (value.kind !== 'true' && value.kind !== 'false') { throw new KnowledgeFailure('SnapshotBoolean','codec'); } return value.kind === 'true';
}
function codecStrings(node: PdfJsonNode, key: string, limit: number): string[] {
  const values: PdfJsonNode[] = node.required(key).array(); if (values.length > limit) { throw new KnowledgeFailure('SnapshotArrayBudget','codec'); }
  return values.map((value: PdfJsonNode): string => value.string());
}
function codecBox(node: PdfJsonNode): PdfBox {
  const box: PdfBox = new PdfBox(); box.left = codecInteger(node,'left'); box.top = codecInteger(node,'top'); box.right = codecInteger(node,'right'); box.bottom = codecInteger(node,'bottom');
  if (box.left < 0 || box.top < 0 || box.right > 1000 || box.bottom > 1000 || box.right <= box.left || box.bottom <= box.top) { throw new KnowledgeFailure('SnapshotBox','codec'); } return box;
}
export function pdfDecodeLocators(root: PdfJsonNode): PdfLocator[] {
  const locators: PdfLocator[] = []; if (root.array().length > 1000) { throw new KnowledgeFailure('SnapshotLocatorBudget','codec'); }
  for (const raw of root.array()) {
    const locator: PdfLocator = new PdfLocator(); locator.originalHash = codecString(raw,'originalHash'); locator.originalVersion = codecInteger(raw,'originalVersion');
    locator.providerPageIndex0 = codecInteger(raw,'providerPageIndex0'); locator.candidatePhysicalPageIndex0 = codecInteger(raw,'candidatePhysicalPageIndex0');
    locator.printedLabel = codecString(raw,'printedLabel'); locator.coordinateSpace = codecString(raw,'coordinateSpace');
    locator.pageEvidenceId = codecString(raw,'pageEvidenceId'); locator.regionEvidenceIds = codecStrings(raw,'regionEvidenceIds',1000);
    const tier: PdfMappingTier | undefined = [PdfMappingTier.Unknown,PdfMappingTier.Package,PdfMappingTier.Page,PdfMappingTier.Region].find((value: PdfMappingTier): boolean => value === codecString(raw,'tier'));
    if (tier === undefined || locator.providerPageIndex0 < 0 || locator.providerPageIndex0 >= PdfBudget.pages) { throw new KnowledgeFailure('SnapshotLocator','codec'); }
    locator.tier = tier; locator.providerBoxes = raw.required('providerBoxes').array().map((value: PdfJsonNode): PdfBox => codecBox(value)); locators.push(locator);
  } return locators;
}
function codecRuns(raw: PdfJsonNode): PdfInlineRun[] {
  if (raw.array().length > PdfBudget.nodes) { throw new KnowledgeFailure('SnapshotRunBudget','codec'); }
  return raw.array().map((value: PdfJsonNode): PdfInlineRun => {
    const run: PdfInlineRun = new PdfInlineRun(); run.kind = codecString(value,'kind'); run.text = codecString(value,'text'); run.assetIds = codecStrings(value,'assetIds',1000);
    if (run.kind !== 'text' && run.kind !== 'equation_inline') { throw new KnowledgeFailure('SnapshotRun','codec'); } return run;
  });
}
export function pdfDecodeSnapshotNode(raw: PdfJsonNode): PdfContentNode {
  const node: PdfContentNode = new PdfContentNode(); node.id = codecString(raw,'id'); node.parentId = codecString(raw,'parentId'); node.order = codecInteger(raw,'order');
  node.sourceMemberId = codecString(raw,'sourceMemberId'); node.sourceRecord = codecInteger(raw,'sourceRecord'); node.pageIndex0 = codecInteger(raw,'pageIndex0');
  const kind: PdfNodeKind | undefined = [PdfNodeKind.Text,PdfNodeKind.Title,PdfNodeKind.Formula,PdfNodeKind.Table,PdfNodeKind.Caption,PdfNodeKind.Image,PdfNodeKind.Header,PdfNodeKind.PageNumber,PdfNodeKind.Reference,PdfNodeKind.Aside,PdfNodeKind.Unsupported].find((value: PdfNodeKind): boolean => value === codecString(raw,'kind'));
  if (kind === undefined) { throw new KnowledgeFailure('SnapshotNodeKind','codec'); } node.kind = kind;
  node.providerType = codecString(raw,'providerType'); node.text = codecString(raw,'text'); node.rawLatex = codecString(raw,'rawLatex'); node.runs = codecRuns(raw.required('runs'));
  node.headingPath = codecStrings(raw,'headingPath',64); node.assetIds = codecStrings(raw,'assetIds',1000); node.captionIds = codecStrings(raw,'captionIds',PdfBudget.nodes);
  node.locators = pdfDecodeLocators(raw.required('locators')); node.verified = codecBoolean(raw,'verified'); node.excludedReason = codecString(raw,'excludedReason');
  const tableRaw: PdfJsonNode | undefined = raw.optional('table');
  if (tableRaw !== undefined) {
    const table: PdfTable = new PdfTable(); table.id = codecString(tableRaw,'id'); table.rows = codecInteger(tableRaw,'rows'); table.columns = codecInteger(tableRaw,'columns'); table.occupancy = codecInteger(tableRaw,'occupancy');
    table.headerEvidence = codecString(tableRaw,'headerEvidence'); table.sourceHtml = codecString(tableRaw,'sourceHtml'); table.locators = pdfDecodeLocators(tableRaw.required('locators'));
    if (table.rows < 1 || table.rows > 1000 || table.columns < 1 || table.columns > 256 || table.occupancy > PdfBudget.cells || tableRaw.required('cells').array().length > PdfBudget.cells) { throw new KnowledgeFailure('SnapshotTableBudget','codec'); }
    for (const cellRaw of tableRaw.required('cells').array()) {
      const cell: PdfTableCell = new PdfTableCell(); cell.id = codecString(cellRaw,'id'); cell.row = codecInteger(cellRaw,'row'); cell.column = codecInteger(cellRaw,'column');
      cell.rowSpan = codecInteger(cellRaw,'rowSpan'); cell.columnSpan = codecInteger(cellRaw,'columnSpan'); cell.text = codecString(cellRaw,'text'); cell.runs = codecRuns(cellRaw.required('runs'));
      if (cell.row < 0 || cell.column < 0 || cell.rowSpan < 1 || cell.columnSpan < 1 || cell.row+cell.rowSpan > table.rows || cell.column+cell.columnSpan > table.columns) { throw new KnowledgeFailure('SnapshotCell','codec'); } table.cells.push(cell);
    } node.table = table;
  } return node;
}
export function pdfDecodeSnapshotHeader(bytes: Uint8Array, cancel: KnowledgeCancellation): PdfNormalizedDocument {
  const raw: PdfJsonNode = new BoundedDocumentJson(bytes,cancel).read(); const snapshot: PdfNormalizedDocument = new PdfNormalizedDocument();
  if (codecString(raw,'wire') !== 'PDF-NORMALIZED-1' || raw.required('nodes').array().length !== 0) { throw new KnowledgeFailure('SnapshotWire','codec'); }
  snapshot.id = codecString(raw,'id'); snapshot.hash = codecString(raw,'hash'); snapshot.documentId = codecString(raw,'documentId');
  snapshot.generation = codecString(raw,'generation');
  snapshot.profile = codecString(raw,'profile'); snapshot.adapterVersion = codecString(raw,'adapterVersion'); snapshot.normalizationVersion = codecString(raw,'normalizationVersion'); snapshot.filterVersion = codecString(raw,'filterVersion');
  snapshot.binding = pdfDecodeSourceBinding(raw.required('binding'));
  const manifest: PdfJsonNode = raw.required('manifest'); snapshot.manifest.id = codecString(manifest,'id'); snapshot.manifest.policy = codecString(manifest,'policy'); snapshot.manifest.zipHash = codecString(manifest,'zipHash');
  snapshot.manifest.zipBytes = codecInteger(manifest,'zipBytes'); snapshot.manifest.expandedBytes = codecInteger(manifest,'expandedBytes'); snapshot.manifest.hardPassed = codecBoolean(manifest,'hardPassed');
  if (manifest.required('members').array().length > PdfBudget.members) { throw new KnowledgeFailure('SnapshotMemberBudget','codec'); }
  for (const entry of manifest.required('members').array()) {
    const member: PdfZipMember = new PdfZipMember(); member.id = codecString(entry,'id'); member.logicalName = codecString(entry,'logicalName'); member.method = codecInteger(entry,'method'); member.flags = codecInteger(entry,'flags');
    member.localOffset = codecInteger(entry,'localOffset'); member.payloadOffset = codecInteger(entry,'payloadOffset'); member.compressedBytes = codecInteger(entry,'compressedBytes'); member.declaredBytes = codecInteger(entry,'declaredBytes');
    member.actualBytes = codecInteger(entry,'actualBytes'); member.crc32 = codecInteger(entry,'crc32'); member.actualCrc32 = codecInteger(entry,'actualCrc32'); member.sha256 = codecString(entry,'sha256'); member.directory = codecBoolean(entry,'directory'); member.verified = codecBoolean(entry,'verified');
    if (!member.verified || member.actualBytes !== member.declaredBytes || member.crc32 !== member.actualCrc32) { throw new KnowledgeFailure('SnapshotMemberIntegrity','codec'); } snapshot.manifest.members.push(member);
  }
  for (const value of raw.required('images').array()) {
    const image: PdfDerivedImage = new PdfDerivedImage(); image.id = codecString(value,'id'); image.memberId = codecString(value,'memberId'); image.parentNodeId = codecString(value,'parentNodeId'); image.relationship = codecString(value,'relationship');
    image.sha256 = codecString(value,'sha256'); image.bytes = codecInteger(value,'bytes'); image.mime = codecString(value,'mime'); image.pixelWidth = codecInteger(value,'pixelWidth'); image.pixelHeight = codecInteger(value,'pixelHeight'); image.provenance = codecString(value,'provenance');
    if (image.pixelWidth < 1 || image.pixelHeight < 1 || image.pixelWidth*image.pixelHeight > PdfBudget.pixels || snapshot.images.length >= PdfBudget.members) { throw new KnowledgeFailure('SnapshotImageBudget','codec'); } snapshot.images.push(image);
  }
  const report: PdfJsonNode = raw.required('coverage'); snapshot.coverage.id = codecString(report,'id'); snapshot.coverage.hash = codecString(report,'hash'); snapshot.coverage.snapshotHash = codecString(report,'snapshotHash');
  snapshot.coverage.hardPassed = codecBoolean(report,'hardPassed'); snapshot.coverage.validatedNodes = codecInteger(report,'validatedNodes'); snapshot.coverage.excludedNodes = codecInteger(report,'excludedNodes'); snapshot.coverage.unresolvedNodes = codecInteger(report,'unresolvedNodes'); snapshot.coverage.filterVersion = codecString(report,'filterVersion');
  snapshot.coverage.unknownPages = report.required('unknownPages').array().map((value: PdfJsonNode): number => value.integer());
  for (const value of report.required('issues').array()) {
    const issue: PdfCoverageIssue = new PdfCoverageIssue(); issue.code = codecString(value,'code'); issue.nodeId = codecString(value,'nodeId'); issue.pageIndex0 = codecInteger(value,'pageIndex0'); issue.hard = codecBoolean(value,'hard'); issue.detail = codecString(value,'detail');
    if (snapshot.coverage.issues.length >= PdfBudget.nodes+100) { throw new KnowledgeFailure('SnapshotIssueBudget','codec'); } snapshot.coverage.issues.push(issue);
  } return snapshot;
}
export function pdfDecodeSourceBinding(b: PdfJsonNode): PdfSourceBinding {
  const binding: PdfSourceBinding = new PdfSourceBinding();
  binding.originalId = codecString(b,'originalId'); binding.originalAssetId = codecString(b,'originalAssetId'); binding.originalHash = codecString(b,'originalHash'); binding.originalVersion = codecInteger(b,'originalVersion');
  binding.originalBytes = codecInteger(b,'originalBytes'); binding.originalPages = codecInteger(b,'originalPages'); binding.taskId = codecString(b,'taskId'); binding.dataId = codecString(b,'dataId');
  binding.resultAssetId = codecString(b,'resultAssetId'); binding.zipHash = codecString(b,'zipHash'); binding.zipBytes = codecInteger(b,'zipBytes'); binding.requestMode = codecString(b,'requestMode'); binding.backend = codecString(b,'backend'); binding.producerVersion = codecString(b,'producerVersion'); return binding;
}
