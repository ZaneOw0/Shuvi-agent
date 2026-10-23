export class PdfBudget {
  static readonly originalBytes: number = 20971520;
  static readonly pages: number = 50;
  static readonly zipBytes: number = 31457280;
  static readonly expandedBytes: number = 104857600;
  static readonly members: number = 1000;
  static readonly memberBytes: number = 33554432;
  static readonly jsonBytes: number = 8388608;
  static readonly pixels: number = 20000000;
  static readonly nodes: number = 20000;
  static readonly cells: number = 40000;
  static readonly documentChunks: number = 2000;
  static readonly activeChunks: number = 10000;
  static readonly derivedBytes: number = 524288000;
  static readonly localMs: number = 120000;
  static readonly rowBytes: number = 262144;
}
export class KnowledgeFailure extends Error {
  category: string;
  stage: string;
  code?: number;
  constructor(category: string, stage: string, code?: number) { super(`${category} / ${stage}${code === undefined ? '' : ' / code='+code}`); this.category = category; this.stage = stage; this.code = code; }
}
export class KnowledgeCancellation {
  now: () => number = (): number => Date.now();
  invalid: boolean = false;
  epoch: number = 0;
  deadline: number = Date.now() + PdfBudget.localMs;
  check(): void {
    if (this.invalid) { throw new KnowledgeFailure('Canceled', 'session'); }
    if (this.now() >= this.deadline) { throw new KnowledgeFailure('Timeout', 'session'); }
  }
}
export enum PdfStage {
  Received = 'ReceivedUnvalidated', Validating = 'Validating', Normalized = 'Normalized',
  Review = 'AwaitingCoverageReview', Chunks = 'ChunkPrepared', Prepared = 'KeywordPrepared',
  Published = 'KeywordPublished', Paused = 'Paused', Failed = 'Failed', Deleted = 'Deleted'
}
export enum PdfNodeKind {
  Text = 'text', Title = 'title', Formula = 'formula', Table = 'table', Caption = 'caption',
  Image = 'image', Header = 'header', PageNumber = 'page_number', Reference = 'reference',
  Aside = 'aside', Unsupported = 'unsupported'
}
export enum PdfMappingTier {
  Unknown = 'ProviderUnverified', Package = 'PackageCorrespondence', Page = 'OriginalPageVerified', Region = 'OriginalRegionVerified'
}
export enum KnowledgeGenerationState {
  Staging = 'Staging', Publishable = 'Publishable', Active = 'Active', Retained = 'Retained',
  Retiring = 'Retiring', Claimed = 'CleanupClaimed', Removed = 'Removed'
}
export enum KnowledgePinState {
  Preparing = 'Preparing', Checkpoint = 'Checkpoint', Active = 'Active', ReleasePending = 'ReleasePending', Released = 'Released'
}
export class PdfSourceBinding {
  originalId: string = ''; originalAssetId: string = ''; originalHash: string = ''; originalVersion: number = 0;
  originalBytes: number = 0; originalPages: number = 0; taskId: string = ''; dataId: string = '';
  resultAssetId: string = ''; zipHash: string = ''; zipBytes: number = 0;
  requestMode: string = ''; backend: string = ''; producerVersion: string = '';
}
export class PdfZipMember {
  id: string = ''; logicalName: string = ''; method: number = -1; flags: number = -1;
  localOffset: number = 0; payloadOffset: number = 0; compressedBytes: number = 0; declaredBytes: number = 0;
  actualBytes: number = 0; crc32: number = 0; actualCrc32: number = -1; sha256: string = '';
  directory: boolean = false; verified: boolean = false;
}
export class PdfZipManifest {
  id: string = ''; policy: string = 'ZIP-PDF-SAFE-1'; zipHash: string = ''; zipBytes: number = 0;
  members: PdfZipMember[] = []; expandedBytes: number = 0; hardPassed: boolean = false;
}
export class PdfBox { left: number = 0; top: number = 0; right: number = 0; bottom: number = 0; }
export class PdfMappingEvidence {
  id: string = ''; tier: PdfMappingTier = PdfMappingTier.Unknown; originalHash: string = ''; zipHash: string = '';
  snapshotHash: string = ''; nodeId: string = ''; providerPageIndex0: number = -1; originalPageIndex0: number = -1;
  unit: string = 'Unverified'; origin: string = 'Unverified'; referenceBox: string = 'Unverified';
  rotation: number | undefined = undefined; transformVersion: string = ''; evidenceSource: string = '';
  points: PdfBox[] = [];
  wire: string = 'PDF-MAPPING-1'; originalVersion: number = 0; generation: string = ''; snapshotId: string = ''; protocol: string = '';
  media: PdfBox = new PdfBox(); crop: PdfBox = new PdfBox();
}
export class PdfLocator {
  originalHash: string = ''; originalVersion: number = 0; providerPageIndex0: number = -1;
  candidatePhysicalPageIndex0: number = -1; printedLabel: string = ''; coordinateSpace: string = 'ProviderUnverified';
  providerBoxes: PdfBox[] = []; pageEvidenceId: string = ''; regionEvidenceIds: string[] = [];
  tier: PdfMappingTier = PdfMappingTier.Unknown;
}
export class PdfInlineRun { kind: string = 'text'; text: string = ''; assetIds: string[] = []; }
export class PdfTableCell {
  id: string = ''; row: number = 0; column: number = 0; rowSpan: number = 1; columnSpan: number = 1;
  text: string = ''; runs: PdfInlineRun[] = [];
}
export class PdfTable {
  id: string = ''; cells: PdfTableCell[] = []; rows: number = 0; columns: number = 0; occupancy: number = 0;
  headerEvidence: string = 'NotReported'; sourceHtml: string = ''; locators: PdfLocator[] = [];
}
export class PdfDerivedImage {
  id: string = ''; memberId: string = ''; parentNodeId: string = ''; relationship: string = '';
  sha256: string = ''; bytes: number = 0; mime: string = ''; pixelWidth: number = 0; pixelHeight: number = 0;
  provenance: string = 'ProviderDerivedUnverified';
}
export class PdfContentNode {
  id: string = ''; parentId: string = ''; order: number = 0; kind: PdfNodeKind = PdfNodeKind.Unsupported;
  providerType: string = ''; sourceMemberId: string = ''; sourceRecord: number = -1; pageIndex0: number = -1;
  runs: PdfInlineRun[] = []; text: string = ''; rawLatex: string = ''; headingPath: string[] = [];
  table: PdfTable | undefined = undefined; assetIds: string[] = []; captionIds: string[] = [];
  locators: PdfLocator[] = []; verified: boolean = false; excludedReason: string = '';
}
export class PdfCoverageIssue {
  code: string = ''; nodeId: string = ''; pageIndex0: number = -1; hard: boolean = false; detail: string = '';
}
export class PdfCoverageReport {
  id: string = ''; hash: string = ''; snapshotHash: string = ''; hardPassed: boolean = false;
  validatedNodes: number = 0; excludedNodes: number = 0; unresolvedNodes: number = 0;
  issues: PdfCoverageIssue[] = []; unknownPages: number[] = []; filterVersion: string = 'PDF-FILTER-1';
}
export class PdfPartialApproval {
  reportHash: string = ''; snapshotHash: string = ''; limitations: string[] = []; confirmedAt: number = 0;
}
export class PdfNormalizedDocument {
  wire: string = 'PDF-NORMALIZED-1'; id: string = ''; hash: string = ''; documentId: string = '';
  generation: string = '';
  binding: PdfSourceBinding = new PdfSourceBinding(); manifest: PdfZipManifest = new PdfZipManifest();
  profile: string = 'MINERU-HOSTED-PDF-3.4.4-OBSERVED-1'; adapterVersion: string = 'MINERU-PDF-1';
  normalizationVersion: string = 'PDF-NORMALIZE-1'; filterVersion: string = 'PDF-FILTER-1';
  nodes: PdfContentNode[] = []; images: PdfDerivedImage[] = []; coverage: PdfCoverageReport = new PdfCoverageReport();
}
export class PdfChunk {
  id: string = ''; documentId: string = ''; generation: string = ''; snapshotId: string = ''; snapshotHash: string = '';
  originalHash: string = ''; originalVersion: number = 0; strategy: string = 'PDF-CHUNK-1';
  ordinal: number = 0; kind: PdfNodeKind = PdfNodeKind.Unsupported; text: string = ''; prefix: string = '';
  retrievalText: string = ''; embeddingText: string = ''; inputHash: string = ''; nodeIds: string[] = [];
  cellIds: string[] = []; assetIds: string[] = []; sourceStart: number = 0; sourceEnd: number = 0;
  locators: PdfLocator[] = []; defaultIncluded: boolean = true;
}
export class PdfKnowledgeDocument {
  id: string = ''; sourceKey: string = ''; title: string = ''; binding: PdfSourceBinding = new PdfSourceBinding();
  activeContentGeneration: string = ''; activeVectorGeneration: string = ''; activeSpaceId: string = '';
  archived: boolean = false; tombstone: boolean = false; epoch: number = 0; stage: PdfStage = PdfStage.Received;
  chunkCount: number = 0; partial: boolean = false; createdAt: number = 0; updatedAt: number = 0;
}
export class KnowledgePin {
  id: string = ''; sourceId: string = ''; assetId: string = ''; assetHash: string = ''; ownerId: string = '';
  documentId: string = ''; generation: string = ''; state: KnowledgePinState = KnowledgePinState.Preparing;
}
export class PdfIngestionJob {
  id: string = ''; processingKey: string = ''; documentId: string = ''; sourceId: string = ''; generation: string = '';
  epoch: number = 0; stage: PdfStage = PdfStage.Received; checkpoint: PdfStage = PdfStage.Received;
  snapshotId: string = ''; snapshotHash: string = ''; reportHash: string = ''; expectedOldGeneration: string = '';
  cleanupClaim: string = ''; failure: string = ''; terminated: boolean = false;
  binding: PdfSourceBinding | undefined = undefined; attempt: number = 1; ownerSession: string = '';
  profile: string = 'MINERU-HOSTED-PDF-3.4.4-OBSERVED-1'; normalizeVersion: string = 'PDF-NORMALIZE-1'; filterVersion: string = 'PDF-FILTER-1'; chunkVersion: string = 'PDF-CHUNK-1';
}
export class KnowledgeCleanupTarget {
  spaceId: string = ''; vectorGeneration: string = ''; contentGeneration: string = ''; owner: string = ''; state: string = 'Pending'; failure: string = '';
}
export class KnowledgeCleanupIntent {
  id: string = ''; documentId: string = ''; generation: string = ''; claim: string = '';
  assets: string[] = []; vectorSpaceId: string = ''; failure: string = '';
  vectorTargets: KnowledgeCleanupTarget[] = [];
}
export class KnowledgeReadLease { id: string = ''; generation: string = ''; sourceId: string = ''; sessionId: string = ''; sessionEpoch: number = 0; }
export class PdfIngestionState {
  busy: boolean = false; releasing: boolean = false; message: string = ''; stage: PdfStage = PdfStage.Received;
  document: PdfKnowledgeDocument | undefined = undefined; job: PdfIngestionJob | undefined = undefined;
  report: PdfCoverageReport | undefined = undefined; vectorState: string = 'Off'; mappingState: string = 'ProviderUnverified';
  nativeMembers: number = 0; nativeExpanded: number = 0; decodedImages: number = 0; snapshotId: string = '';
}
export class PdfAssetWriteRecord {
  id: string = ''; owner: string = ''; generation: string = ''; member: string = ''; type: string = ''; hash: string = ''; bytes: number = 0; actual: number = 0; phase: string = '';
}
export class PdfAssetDescriptor { id: string = ''; generation: string = ''; hash: string = ''; bytes: number = 0; format: string = ''; member: string = ''; }
