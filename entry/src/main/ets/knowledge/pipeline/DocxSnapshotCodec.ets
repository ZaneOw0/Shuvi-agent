import { DocxSnapshot, DocxOriginal, DocxLocator, DocxPathStep, DocxTextFragment, DocxHeadingIdentity, DocxCellAddress,
  DocxNativeNode, DocxNodeKind, DocxListIdentity, DocxTable, DocxMedia, DocxPartEvidence, DocxRelationship,
  DocxCoverage, DocxCoverageIssue, DocxCoverageKind, DocxProjection, DocxProjectionRange, DocxCorrespondence,
  DocxResultBinding, DocxFailure, DocxLimits, docxId, docxHash } from '../domain/DocxKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { BoundedDocumentJson, PdfJsonNode, PdfJsonField } from './BoundedDocumentJson';
import { pdfCodecUtf8 } from './PdfSnapshotCodec';
import { docxPartName } from './DocxPackagePolicy';

function docxFields(n: PdfJsonNode, keys: string[]): void {
  if (n.kind !== 'object' || n.fields.length !== keys.length || n.fields.some((f: PdfJsonField): boolean => keys.indexOf(f.key) < 0)) { throw new DocxFailure('SnapshotFields','codec'); }
}
function docxNumber(n: PdfJsonNode): number { const number: number = n.integer(); if (number < 0) { throw new DocxFailure('SnapshotNegative','codec'); } return number; }
function docxBoolean(n: PdfJsonNode): boolean { if (n.kind !== 'true' && n.kind !== 'false') { throw new DocxFailure('SnapshotBoolean','codec'); } return n.kind === 'true'; }
function docxPaths(raw: PdfJsonNode): DocxPathStep[] {
  const path: DocxPathStep[] = []; for (const n of raw.array()) {
    docxFields(n,['namespace','localName','ordinal']); const step: DocxPathStep = new DocxPathStep(); step.namespace = n.required('namespace').string(); step.localName = n.required('localName').string(); step.ordinal = docxNumber(n.required('ordinal'));
    if (step.localName.length === 0 || path.length >= DocxLimits.depth) { throw new DocxFailure('LocatorPathBudget','codec'); } path.push(step);
  } return path;
}
function docxCell(raw: PdfJsonNode): DocxCellAddress {
  docxFields(raw,['tableId','physicalRow','physicalCell','row','column','rowSpan','columnSpan','anchorId','continuation']); const c: DocxCellAddress = new DocxCellAddress();
  c.tableId = raw.required('tableId').string(); c.physicalRow = docxNumber(raw.required('physicalRow')); c.physicalCell = docxNumber(raw.required('physicalCell')); c.row = docxNumber(raw.required('row')); c.column = docxNumber(raw.required('column')); c.rowSpan = docxNumber(raw.required('rowSpan')); c.columnSpan = docxNumber(raw.required('columnSpan')); c.anchorId = raw.required('anchorId').string(); c.continuation = docxBoolean(raw.required('continuation'));
  if (!docxId(c.tableId) || !docxId(c.anchorId) || c.rowSpan < 1 || c.columnSpan < 1 || c.row*c.columnSpan > DocxLimits.cells) { throw new DocxFailure('CellAddressInvalid','codec'); } return c;
}
export function docxReadLocator(raw: PdfJsonNode): DocxLocator {
  const withCell: boolean = raw.optional('cell') !== undefined;
  docxFields(raw,withCell ? ['policy','originalAssetId','originalHash','originalVersion','part','nodeId','path','headings','paragraph','cell','start','end','fragments'] : ['policy','originalAssetId','originalHash','originalVersion','part','nodeId','path','headings','paragraph','start','end','fragments']);
  const l: DocxLocator = new DocxLocator(); l.policy = raw.required('policy').string(); l.originalAssetId = raw.required('originalAssetId').string(); l.originalHash = raw.required('originalHash').string(); l.originalVersion = docxNumber(raw.required('originalVersion')); l.part = raw.required('part').string(); l.nodeId = raw.required('nodeId').string(); l.path = docxPaths(raw.required('path')); l.paragraph = docxNumber(raw.required('paragraph')); l.start = docxNumber(raw.required('start')); l.end = docxNumber(raw.required('end'));
  if (withCell) { l.cell = docxCell(raw.required('cell')); }
  for (const n of raw.required('headings').array()) {
    docxFields(n,['nodeId','text','level']); const h: DocxHeadingIdentity = new DocxHeadingIdentity(); h.nodeId = n.required('nodeId').string(); h.text = n.required('text').string(); h.level = docxNumber(n.required('level'));
    if (!docxId(h.nodeId) || h.level > 8 || l.headings.length >= 9) { throw new DocxFailure('HeadingIdentityInvalid','codec'); } l.headings.push(h);
  }
  for (const n of raw.required('fragments').array()) {
    docxFields(n,['runPath','textPath','start','end','rawStart','rawEnd','kind']); const f: DocxTextFragment = new DocxTextFragment(); f.runPath = docxPaths(n.required('runPath')); f.textPath = docxPaths(n.required('textPath')); f.start = docxNumber(n.required('start')); f.end = docxNumber(n.required('end')); f.rawStart = docxNumber(n.required('rawStart')); f.rawEnd = docxNumber(n.required('rawEnd')); f.kind = n.required('kind').string();
    if (f.start > f.end || f.rawStart > f.rawEnd || f.end-f.start !== f.rawEnd-f.rawStart || f.end > l.end || l.fragments.length >= DocxLimits.events) { throw new DocxFailure('FragmentRangeInvalid','codec'); } l.fragments.push(f);
  }
  if (l.policy !== 'DOCX-LOCATOR-1' || !docxId(l.originalAssetId) || !docxHash(l.originalHash) || l.originalVersion < 1 || !docxPartName(l.part) || !docxId(l.nodeId) || l.path.length === 0 || l.start > l.end) { throw new DocxFailure('LocatorIdentityInvalid','codec'); } return l;
}
function docxReadOriginal(raw: PdfJsonNode): DocxOriginal {
  docxFields(raw,['documentId','sourceId','assetId','hash','version','bytes','title','mainPart','savedAt']); const o: DocxOriginal = new DocxOriginal();
  o.documentId = raw.required('documentId').string(); o.sourceId = raw.required('sourceId').string(); o.assetId = raw.required('assetId').string(); o.hash = raw.required('hash').string(); o.version = docxNumber(raw.required('version')); o.bytes = docxNumber(raw.required('bytes')); o.title = raw.required('title').string(); o.mainPart = raw.required('mainPart').string(); o.savedAt = docxNumber(raw.required('savedAt'));
  if (!docxId(o.documentId) || !docxId(o.sourceId) || !docxId(o.assetId) || !docxHash(o.hash) || o.version < 1 || o.bytes < 1 || o.bytes > 20*1024*1024 || !docxPartName(o.mainPart)) { throw new DocxFailure('OriginalIdentityInvalid','codec'); } return o;
}
export function docxReadResult(raw: PdfJsonNode): DocxResultBinding {
  docxFields(raw,['taskId','dataId','assetId','hash','bytes','originalHash','originalVersion']); const r: DocxResultBinding = new DocxResultBinding();
  r.taskId = raw.required('taskId').string(); r.dataId = raw.required('dataId').string(); r.assetId = raw.required('assetId').string(); r.hash = raw.required('hash').string(); r.bytes = docxNumber(raw.required('bytes')); r.originalHash = raw.required('originalHash').string(); r.originalVersion = docxNumber(raw.required('originalVersion'));
  if (!docxId(r.taskId) || !docxId(r.dataId) || !docxId(r.assetId) || !docxHash(r.hash) || !docxHash(r.originalHash) || r.bytes < 22 || r.bytes > 30*1024*1024 || r.originalVersion < 1) { throw new DocxFailure('ResultIdentityInvalid','codec'); } return r;
}
function docxProjectionRanges(raw: PdfJsonNode): DocxProjectionRange[] {
  const ranges: DocxProjectionRange[] = []; for (const n of raw.array()) {
    docxFields(n,['start','end','artifactStart','artifactEnd']); const r: DocxProjectionRange = new DocxProjectionRange(); r.start = docxNumber(n.required('start')); r.end = docxNumber(n.required('end')); r.artifactStart = docxNumber(n.required('artifactStart')); r.artifactEnd = docxNumber(n.required('artifactEnd'));
    if (r.start > r.end || r.artifactStart > r.artifactEnd) { throw new DocxFailure('ProjectionRangeInvalid','codec'); } ranges.push(r);
  } return ranges;
}
export function docxDecodeSnapshot(bytes: Uint8Array, cancel: KnowledgeCancellation): DocxSnapshot {
  if (bytes.length > DocxLimits.snapshot) { throw new DocxFailure('SnapshotBytesBudget','codec'); }
  const raw: PdfJsonNode = new BoundedDocumentJson(bytes,cancel,DocxLimits.snapshot).read();
  docxFields(raw,['wire','normalization','filter','documentId','generation','original','result','parts','relationships','nodes','tables','media','projection','correspondence','coverage','nativeHash','correspondenceHash','hash']);
  const s: DocxSnapshot = new DocxSnapshot(); s.wire = raw.required('wire').string(); s.normalization = raw.required('normalization').string(); s.filter = raw.required('filter').string(); s.documentId = raw.required('documentId').string(); s.generation = raw.required('generation').string(); s.original = docxReadOriginal(raw.required('original')); s.result = docxReadResult(raw.required('result')); s.nativeHash = raw.required('nativeHash').string(); s.correspondenceHash = raw.required('correspondenceHash').string(); s.hash = raw.required('hash').string();
  for (const n of raw.required('parts').array()) {
    docxFields(n,['part','hash','bytes','crcVerified']); const p: DocxPartEvidence = new DocxPartEvidence(); p.part = n.required('part').string(); p.hash = n.required('hash').string(); p.bytes = docxNumber(n.required('bytes')); p.crcVerified = docxBoolean(n.required('crcVerified'));
    if (!docxPartName(p.part) || !docxHash(p.hash) || !p.crcVerified || p.bytes > 32*1024*1024) { throw new DocxFailure('SelectedPartEvidenceInvalid','codec'); } s.parts.push(p);
  }
  for (const n of raw.required('relationships').array()) {
    docxFields(n,['sourcePart','id','type','target','external']); const r: DocxRelationship = new DocxRelationship(); r.sourcePart = n.required('sourcePart').string(); r.id = n.required('id').string(); r.type = n.required('type').string(); r.target = n.required('target').string(); r.external = docxBoolean(n.required('external')); s.relationships.push(r);
  }
  for (const n of raw.required('nodes').array()) {
    const hasList: boolean = n.optional('list') !== undefined; docxFields(n,hasList ? ['id','kind','order','text','locator','list','outline'] : ['id','kind','order','text','locator','outline']);
    const node: DocxNativeNode = new DocxNativeNode(); node.id = n.required('id').string(); node.order = docxNumber(n.required('order')); node.text = n.required('text').string(); node.outline = n.required('outline').integer(); node.locator = docxReadLocator(n.required('locator'));
    const kind: DocxNodeKind | undefined = [DocxNodeKind.Heading,DocxNodeKind.Paragraph,DocxNodeKind.List,DocxNodeKind.Cell].find((k: DocxNodeKind): boolean => k === n.required('kind').string());
    if (kind === undefined || node.outline < -1 || node.outline > 9 || node.locator.nodeId !== node.id || node.locator.end !== node.text.length || node.locator.start !== 0 || node.locator.originalAssetId !== s.original.assetId || node.locator.originalHash !== s.original.hash || node.locator.originalVersion !== s.original.version || node.locator.part !== s.original.mainPart || s.nodes.some((old: DocxNativeNode): boolean => old.id === node.id || old.order >= node.order)) { throw new DocxFailure('NativeNodeBindingInvalid','codec'); } node.kind = kind;
    if (hasList) {
      const q: PdfJsonNode = n.required('list'); docxFields(q,['numId','level','abstractId','format','pattern','display','displayEvidence']); const l: DocxListIdentity = new DocxListIdentity(); l.numId = q.required('numId').string(); l.level = docxNumber(q.required('level')); l.abstractId = q.required('abstractId').string(); l.format = q.required('format').string(); l.pattern = q.required('pattern').string(); l.display = q.required('display').string(); l.displayEvidence = q.required('displayEvidence').string(); if (l.level > 8) { throw new DocxFailure('ListLevelInvalid','codec'); } node.list = l;
    } s.nodes.push(node); if (s.nodes.length > DocxLimits.nodes) { throw new DocxFailure('NativeNodeBudget','codec'); }
  }
  for (const n of raw.required('tables').array()) {
    docxFields(n,['id','part','path','rows','columns','cells']); const t: DocxTable = new DocxTable(); t.id = n.required('id').string(); t.part = n.required('part').string(); t.path = docxPaths(n.required('path')); t.rows = docxNumber(n.required('rows')); t.columns = docxNumber(n.required('columns')); for (const c of n.required('cells').array()) { t.cells.push(docxCell(c)); } if (t.cells.length > DocxLimits.cells) { throw new DocxFailure('TableCellBudget','codec'); } s.tables.push(t);
  }
  for (const n of raw.required('media').array()) {
    docxFields(n,['id','sourcePart','relationshipId','targetPart','hash','parentId','parentPath','external','captionNodeId','captionEvidence']); const m: DocxMedia = new DocxMedia(); m.id = n.required('id').string(); m.sourcePart = n.required('sourcePart').string(); m.relationshipId = n.required('relationshipId').string(); m.targetPart = n.required('targetPart').string(); m.hash = n.required('hash').string(); m.parentId = n.required('parentId').string(); m.parentPath = docxPaths(n.required('parentPath')); m.external = docxBoolean(n.required('external')); m.captionNodeId = n.required('captionNodeId').string(); m.captionEvidence = n.required('captionEvidence').string(); s.media.push(m); if (s.media.length > DocxLimits.media) { throw new DocxFailure('MediaBudget','codec'); }
  }
  const p: PdfJsonNode = raw.required('projection'); docxFields(p,['version','member','memberHash','text','ranges','producer']); s.projection.version = p.required('version').string(); s.projection.member = p.required('member').string(); s.projection.memberHash = p.required('memberHash').string(); s.projection.text = p.required('text').string(); s.projection.ranges = docxProjectionRanges(p.required('ranges')); s.projection.producer = p.required('producer').string();
  for (const n of raw.required('correspondence').array()) {
    docxFields(n,['nodeId','nativeStart','nativeEnd','projectedStart','projectedEnd','method','artifactRanges']); const c: DocxCorrespondence = new DocxCorrespondence(); c.nodeId = n.required('nodeId').string(); c.nativeStart = docxNumber(n.required('nativeStart')); c.nativeEnd = docxNumber(n.required('nativeEnd')); c.projectedStart = docxNumber(n.required('projectedStart')); c.projectedEnd = docxNumber(n.required('projectedEnd')); c.method = n.required('method').string(); c.artifactRanges = docxProjectionRanges(n.required('artifactRanges'));
    const node: DocxNativeNode | undefined = s.nodes.find((b: DocxNativeNode): boolean => b.id === c.nodeId);
    if (node === undefined || c.nativeStart !== 0 || c.nativeEnd !== node.text.length || s.projection.text.slice(c.projectedStart,c.projectedEnd) !== node.text || ['LiteralUniqueMonotonic','LiteralUniqueRowContext','LiteralUniqueNeighbors','LiteralContinuousMerge'].indexOf(c.method) < 0 || s.correspondence.some((old: DocxCorrespondence): boolean => old.nodeId === c.nodeId) || JSON.stringify(c.artifactRanges) !== JSON.stringify(s.projection.ranges.filter((r: DocxProjectionRange): boolean => r.end > c.projectedStart && r.start < c.projectedEnd))) { throw new DocxFailure('CorrespondenceBindingInvalid','codec'); } s.correspondence.push(c);
  }
  const cv: PdfJsonNode = raw.required('coverage'); docxFields(cv,['version','supported','excluded','unsupported','matched','ambiguous','unmatched','partial','empty','issues','hash']);
  const coverage: DocxCoverage = s.coverage; coverage.version = cv.required('version').string(); coverage.supported = docxNumber(cv.required('supported')); coverage.excluded = docxNumber(cv.required('excluded')); coverage.unsupported = docxNumber(cv.required('unsupported')); coverage.matched = docxNumber(cv.required('matched')); coverage.ambiguous = docxNumber(cv.required('ambiguous')); coverage.unmatched = docxNumber(cv.required('unmatched')); coverage.partial = docxBoolean(cv.required('partial')); coverage.empty = docxBoolean(cv.required('empty')); coverage.hash = cv.required('hash').string();
  for (const n of cv.required('issues').array()) {
    docxFields(n,['kind','code','part','nodeId','path','count']); const i: DocxCoverageIssue = new DocxCoverageIssue(); const kind: DocxCoverageKind | undefined = [DocxCoverageKind.Excluded,DocxCoverageKind.Unsupported,DocxCoverageKind.Ambiguous,DocxCoverageKind.Unmatched].find((k: DocxCoverageKind): boolean => k === n.required('kind').string()); if (kind === undefined) { throw new DocxFailure('CoverageKindUnknown','codec'); } i.kind = kind; i.code = n.required('code').string(); i.part = n.required('part').string(); i.nodeId = n.required('nodeId').string(); i.path = docxPaths(n.required('path')); i.count = docxNumber(n.required('count')); coverage.issues.push(i);
  }
  if (s.wire !== 'DOCX-NORMALIZED-1' || s.normalization !== 'DOCX-NATIVE-1' || s.filter !== 'DOCX-FINAL-VISIBLE-1' || s.documentId !== s.original.documentId || !docxId(s.generation) || !docxHash(s.hash) || !docxHash(s.nativeHash) || !docxHash(s.correspondenceHash) || !docxHash(coverage.hash) || s.result.originalHash !== s.original.hash || s.result.originalVersion !== s.original.version || coverage.supported !== s.nodes.length || coverage.matched !== s.correspondence.length || coverage.matched+coverage.ambiguous+coverage.unmatched !== s.nodes.length || coverage.empty !== (s.correspondence.length === 0) || coverage.partial !== (coverage.unsupported+coverage.ambiguous+coverage.unmatched > 0)) { throw new DocxFailure('SnapshotVersionOrCoverageBinding','codec'); }
  cancel.check(); return s;
}
function docxNativePayload(s: DocxSnapshot): string { return JSON.stringify(s.original)+'\n'+JSON.stringify(s.parts)+'\n'+JSON.stringify(s.relationships)+'\n'+JSON.stringify(s.nodes)+'\n'+JSON.stringify(s.tables)+'\n'+JSON.stringify(s.media); }
function docxCoveragePayload(c: DocxCoverage): string { const hash: string = c.hash; c.hash = ''; const text: string = JSON.stringify(c); c.hash = hash; return text; }
function docxSnapshotPayload(s: DocxSnapshot): string { const hash: string = s.hash; s.hash = ''; const text: string = JSON.stringify(s); s.hash = hash; return text; }
export async function docxSealSnapshot(s: DocxSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<void> {
  cancel.check(); s.nativeHash = await identity.hash(pdfCodecUtf8(docxNativePayload(s)));
  s.correspondenceHash = await identity.hash(pdfCodecUtf8(JSON.stringify(s.projection)+'\n'+JSON.stringify(s.correspondence)));
  s.coverage.hash = await identity.hash(pdfCodecUtf8(docxCoveragePayload(s.coverage)));
  s.hash = await identity.hash(pdfCodecUtf8(docxSnapshotPayload(s)));
  const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(s)); if (bytes.length > DocxLimits.snapshot) { throw new DocxFailure('SnapshotBytesBudget','codec'); } docxDecodeSnapshot(bytes,cancel);
}
export async function docxVerifySnapshot(s: DocxSnapshot, identity: KnowledgeIdentityPort, cancel: KnowledgeCancellation): Promise<void> {
  cancel.check();
  if (await identity.hash(pdfCodecUtf8(docxNativePayload(s))) !== s.nativeHash || await identity.hash(pdfCodecUtf8(JSON.stringify(s.projection)+'\n'+JSON.stringify(s.correspondence))) !== s.correspondenceHash || await identity.hash(pdfCodecUtf8(docxCoveragePayload(s.coverage))) !== s.coverage.hash || await identity.hash(pdfCodecUtf8(docxSnapshotPayload(s))) !== s.hash) { throw new DocxFailure('SnapshotDigestMismatch','codec'); }
}
