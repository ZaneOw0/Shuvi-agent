import { KnowledgeCancellation, KnowledgeFailure, PdfBudget, PdfNormalizedDocument, PdfContentNode, PdfChunk, PdfNodeKind, PdfTableCell } from '../domain/PdfKnowledgeModels';
import { PdfWorkerResult, PdfWorkerFailure } from '../domain/PdfWorkerModels';
import { pdfCodecUtf8, pdfDecodeSnapshotHeader, pdfDecodeSnapshotNode, pdfDecodeLocators } from './PdfSnapshotCodec';
import { BoundedDocumentJson, PdfJsonNode } from './BoundedDocumentJson';

const PDF_WORKER_OPERATIONS: string[] = ['normalize','chunks','seal','verify','encode-node','hydrate-node','hydrate-header'];
const PDF_WORKER_STAGES: string[] = ['normalize','pdf-json','zip-json','table','codec','worker','session','pdf-worker','pdf-chunk','readback','pdf-normalize','pdf-chunks','pdf-seal','pdf-verify','pdf-encode-node','pdf-hydrate-node','pdf-hydrate-header'];
const PDF_WORKER_CATEGORIES: string[] = [
  'WorkerOperationFailed','Canceled','Timeout','WorkerMemberMissing','WorkerInspectForbidden','WorkerInputBudget','WorkerOutputBudget','WorkerResultInvalid',
  'ProtocolMemberMissingOrAmbiguous','ProtocolProfileUnrecognized','UnvalidatedBinding','ProtocolRootIdentity','PageAuditMismatch','LayoutPageOrder','NodeBudgetOrAudit','V1V2OrderAuditMismatch','V1V2CountAuditMismatch','NodeBudget','GlobalTableBudget',
  'BoxShape','BoxRange','InlineTypeUnsupported','CaptionUnsupported','CaptionShapeUnsupported','MathTypeUnsupported','ListTypeUnsupported','NodeTypeUnsupported','ImageRelationshipMissing',
  'JsonObjectRequired','JsonFieldMissing','JsonStringRequired','JsonArrayRequired','JsonIntegerRequired','JsonUtf8Boundary','JsonBytes','JsonGrammarOrBudget','InvalidUtf8','TruncatedUtf8',
  'TableEntity','TableEntityUnsupported','TableBytes','TableMarkup','TableTagUnsupported','TableAttribute','TableAttributeUnsupported','TableSpan','TableTruncated','TableRoot','TableIncomplete','TableRows','TableNesting','TableGridBudget','TableCellTruncated','TableActiveOrNestedContent','TableSpanCollision',
  'SnapshotBoolean','SnapshotArrayBudget','SnapshotBox','SnapshotLocatorBudget','SnapshotLocator','SnapshotRunBudget','SnapshotRun','SnapshotNodeKind','SnapshotTableBudget','SnapshotCell','SnapshotWire','SnapshotMemberBudget','SnapshotMemberIntegrity','SnapshotImageBudget','SnapshotIssueBudget','SnapshotNodeBudget','SnapshotContentHashMismatch','CoverageContentHashMismatch',
  'PrefixNotBounded','HardIntegrityRequired','CannotLosslesslyChunk','DocumentChunkBudget','NoPublishableChunks'
];
export function pdfWorkerStage(operation: string): string {
  if (PDF_WORKER_OPERATIONS.indexOf(operation) < 0) { return 'pdf-worker'; }
  return 'pdf-'+operation;
}
function pdfWorkerCodeValid(code: number): boolean { return typeof code === 'number' && Number.isSafeInteger(code); }
function pdfWorkerFailureValid(failure: PdfWorkerFailure): boolean {
  return failure !== null && typeof failure === 'object' &&
    Object.keys(failure).every((key: string): boolean => ['category','stage','code'].indexOf(key) >= 0) &&
    typeof failure.category === 'string' && failure.category.length <= 64 && PDF_WORKER_CATEGORIES.indexOf(failure.category) >= 0 &&
    typeof failure.stage === 'string' && failure.stage.length <= 32 && PDF_WORKER_STAGES.indexOf(failure.stage) >= 0 &&
    (failure.code === undefined || pdfWorkerCodeValid(failure.code));
}
export function pdfWorkerSuccess(operation: string, payload: Uint8Array[]): PdfWorkerResult {
  const result: PdfWorkerResult = new PdfWorkerResult(); result.operation = operation; result.status = 'success'; result.payload = payload; return result;
}
export function pdfWorkerCaught(operation: string, error: Object, code?: number): PdfWorkerResult {
  const result: PdfWorkerResult = new PdfWorkerResult(); result.operation = operation; result.status = 'failure';
  const failure: PdfWorkerFailure = new PdfWorkerFailure(); failure.stage = pdfWorkerStage(operation);
  if (code !== undefined && pdfWorkerCodeValid(code)) { failure.code = code; }
  // This check is inside the worker that created the exception, never across threads.
  if (error instanceof KnowledgeFailure) {
    const candidate: PdfWorkerFailure = new PdfWorkerFailure(); candidate.category = error.category; candidate.stage = error.stage; candidate.code = error.code;
    if (pdfWorkerFailureValid(candidate)) { failure.category = candidate.category; failure.stage = candidate.stage; failure.code = candidate.code; } else { failure.code = undefined; }
  }
  result.failure = failure; return result;
}
export function pdfWorkerRejected(operation: string, cancel: KnowledgeCancellation, code?: number): KnowledgeFailure {
  try { cancel.check(); } catch (error) { if (error instanceof KnowledgeFailure) { return error; } }
  return new KnowledgeFailure('WorkerOperationFailed',pdfWorkerStage(operation),code !== undefined && pdfWorkerCodeValid(code) ? code : undefined);
}
export function pdfWorkerPayload(result: PdfWorkerResult, operation: string, cancel: KnowledgeCancellation): Uint8Array[] {
  cancel.check();
  if (result === undefined || result === null || typeof result !== 'object' || PDF_WORKER_OPERATIONS.indexOf(operation) < 0 ||
    Object.keys(result).some((key: string): boolean => ['wire','operation','status','payload','failure'].indexOf(key) < 0) ||
    result.wire !== 'PDF-WORKER-RESULT-1' || result.operation !== operation) { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  if (result.status === 'failure' && result.payload === undefined && result.failure !== undefined && pdfWorkerFailureValid(result.failure)) {
    throw new KnowledgeFailure(result.failure.category,result.failure.stage,result.failure.code);
  }
  if (result.status !== 'success' || result.failure !== undefined || !Array.isArray(result.payload) || result.payload.length > PdfBudget.nodes+1) { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  let total: number = 0;
  for (const bytes of result.payload) {
    if (!(bytes instanceof Uint8Array) || bytes.length > PdfBudget.jsonBytes || (total += bytes.length) > PdfBudget.expandedBytes) { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  }
  return result.payload;
}
export function pdfWorkerSnapshotParts(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Uint8Array[] {
  cancel.check(); if (snapshot.nodes.length > PdfBudget.nodes) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); }
  const header: PdfNormalizedDocument = new PdfNormalizedDocument();
  header.id = snapshot.id; header.hash = snapshot.hash; header.documentId = snapshot.documentId; header.generation = snapshot.generation;
  header.binding = snapshot.binding; header.manifest = snapshot.manifest; header.profile = snapshot.profile; header.adapterVersion = snapshot.adapterVersion;
  header.normalizationVersion = snapshot.normalizationVersion; header.filterVersion = snapshot.filterVersion; header.images = snapshot.images; header.coverage = snapshot.coverage;
  const first: Uint8Array = pdfCodecUtf8(JSON.stringify(header));
  if (first.length > PdfBudget.jsonBytes) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); }
  const parts: Uint8Array[] = [first]; let total: number = first.length;
  for (const node of snapshot.nodes) { cancel.check(); const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(node)); if (bytes.length > PdfBudget.jsonBytes || bytes.length > PdfBudget.expandedBytes-total) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); } total += bytes.length; parts.push(bytes); }
  // The same budget applies on both sides, including the header.
  return pdfWorkerPayload(pdfWorkerSuccess('normalize',parts),'normalize',cancel);
}
export function pdfWorkerReadNode(parts: Uint8Array[], cancel: KnowledgeCancellation, operation: string): PdfContentNode {
  if (parts.length !== 1) { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  return pdfDecodeSnapshotNode(new BoundedDocumentJson(parts[0],cancel).read());
}
export function pdfWorkerReadSnapshot(parts: Uint8Array[], cancel: KnowledgeCancellation, operation: string): PdfNormalizedDocument {
  if (parts.length < 1 || (operation === 'hydrate-header' && parts.length !== 1)) { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  const snapshot: PdfNormalizedDocument = pdfDecodeSnapshotHeader(parts[0],cancel);
  if (['MINERU-HOSTED-PDF-3.4.4-OBSERVED-1','MINERU-HOSTED-PDF-3.4.4-OCR-FALSE-1'].indexOf(snapshot.profile) < 0 || snapshot.adapterVersion !== 'MINERU-PDF-1' || snapshot.normalizationVersion !== 'PDF-NORMALIZE-1' || snapshot.filterVersion !== 'PDF-FILTER-1') { throw new KnowledgeFailure('WorkerResultInvalid',pdfWorkerStage(operation)); }
  for (let at: number = 1; at < parts.length; at++) { cancel.check(); snapshot.nodes.push(pdfDecodeSnapshotNode(new BoundedDocumentJson(parts[at],cancel).read())); }
  return snapshot;
}
function pdfWorkerStrings(raw: PdfJsonNode, key: string, maximum: number): string[] {
  const values: PdfJsonNode[] = raw.required(key).array();
  if (values.length > maximum) { throw new KnowledgeFailure('WorkerOutputBudget','worker'); }
  return values.map((value: PdfJsonNode): string => value.string());
}
export function pdfWorkerReadChunks(parts: Uint8Array[], snapshot: PdfNormalizedDocument, generation: string, cancel: KnowledgeCancellation): PdfChunk[] {
  if (parts.length < 1 || parts.length > PdfBudget.documentChunks) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
  const chunks: PdfChunk[] = [];
  for (const bytes of parts) {
    cancel.check(); const raw: PdfJsonNode = new BoundedDocumentJson(bytes,cancel).read(); const chunk: PdfChunk = new PdfChunk();
    chunk.id = raw.required('id').string(); chunk.documentId = raw.required('documentId').string(); chunk.generation = raw.required('generation').string();
    chunk.snapshotId = raw.required('snapshotId').string(); chunk.snapshotHash = raw.required('snapshotHash').string(); chunk.originalHash = raw.required('originalHash').string(); chunk.originalVersion = raw.required('originalVersion').integer();
    chunk.strategy = raw.required('strategy').string(); chunk.ordinal = raw.required('ordinal').integer();
    const kind: PdfNodeKind | undefined = [PdfNodeKind.Text,PdfNodeKind.Title,PdfNodeKind.Formula,PdfNodeKind.Table,PdfNodeKind.Caption,PdfNodeKind.Reference,PdfNodeKind.Aside,PdfNodeKind.Image].find((value: PdfNodeKind): boolean => value === raw.required('kind').string());
    const included: PdfJsonNode = raw.required('defaultIncluded');
    if (kind === undefined || (included.kind !== 'true' && included.kind !== 'false')) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
    chunk.kind = kind; chunk.defaultIncluded = included.kind === 'true';
    chunk.text = raw.required('text').string(); chunk.prefix = raw.required('prefix').string(); chunk.retrievalText = raw.required('retrievalText').string(); chunk.embeddingText = raw.required('embeddingText').string(); chunk.inputHash = raw.required('inputHash').string();
    chunk.nodeIds = pdfWorkerStrings(raw,'nodeIds',PdfBudget.nodes); chunk.cellIds = pdfWorkerStrings(raw,'cellIds',PdfBudget.cells); chunk.assetIds = pdfWorkerStrings(raw,'assetIds',PdfBudget.members);
    chunk.sourceStart = raw.required('sourceStart').integer(); chunk.sourceEnd = raw.required('sourceEnd').integer(); chunk.locators = pdfDecodeLocators(raw.required('locators'));
    if (chunk.documentId !== snapshot.documentId || chunk.generation !== generation || chunk.snapshotId !== snapshot.id || chunk.snapshotHash !== snapshot.hash || chunk.originalHash !== snapshot.binding.originalHash || chunk.originalVersion !== snapshot.binding.originalVersion || chunk.strategy !== 'PDF-CHUNK-1' || chunk.ordinal !== chunks.length || chunk.id !== generation+'-c'+chunk.ordinal || chunk.sourceStart < 0 || chunk.sourceEnd < chunk.sourceStart || chunk.nodeIds.length === 0 || chunk.nodeIds.some((id: string): boolean => !snapshot.nodes.some((node: PdfContentNode): boolean => node.id === id)) || Array.from(chunk.retrievalText).length > 512 || pdfCodecUtf8(chunk.retrievalText).length > 2048 || chunk.retrievalText !== chunk.prefix+chunk.text || chunk.embeddingText !== chunk.retrievalText) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
    chunks.push(chunk);
    const source: PdfContentNode | undefined = snapshot.nodes.find((node: PdfContentNode): boolean => node.id === chunk.nodeIds[0]);
    if (source === undefined || !source.verified || source.kind !== chunk.kind || chunk.nodeIds.length !== 1 || chunk.sourceEnd-chunk.sourceStart !== chunk.text.length || chunk.defaultIncluded !== (source.kind !== PdfNodeKind.Reference && source.kind !== PdfNodeKind.Aside) || JSON.stringify(source.assetIds) !== JSON.stringify(chunk.assetIds) || JSON.stringify(source.locators) !== JSON.stringify(chunk.locators)) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
    if (source.table === undefined) {
      if (chunk.cellIds.length !== 0 || chunk.sourceEnd > source.text.length || source.text.slice(chunk.sourceStart,chunk.sourceEnd) !== chunk.text) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
    } else {
      const cells: string[] = []; let row: number = -1;
      for (const id of chunk.cellIds) {
        const cell: PdfTableCell | undefined = source.table.cells.find((item: PdfTableCell): boolean => item.id === id);
        if (cell === undefined || (row >= 0 && cell.row !== row)) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); } row = cell.row; cells.push(cell.text);
      }
      const content: string = cells.join(' | ');
      if (cells.length === 0 || chunk.sourceEnd > content.length || content.slice(chunk.sourceStart,chunk.sourceEnd) !== chunk.text) { throw new KnowledgeFailure('WorkerResultInvalid','pdf-chunks'); }
    }
  }
  return chunks;
}
