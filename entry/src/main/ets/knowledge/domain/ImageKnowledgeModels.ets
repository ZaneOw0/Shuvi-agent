export enum ImageEncoding { Jpeg = 'JPEG', Png = 'PNG', Webp = 'WEBP' }
export enum ImagePreviewState { NotRequested = 'NotRequested', Ready = 'Ready', Failed = 'Failed', Unavailable = 'Unavailable' }
export class ImageTextProjection {
  kind: string = ''; member: string = ''; memberHash: string = ''; zipHash: string = '';
  taskId: string = ''; dataId: string = ''; text: string = '';
}
export enum ImageIngestionStage {
  Saved = 'OriginalSaved', Review = 'AwaitingCoverageReview', Published = 'KeywordPublished',
  Empty = 'OcrCompleteNoText', Paused = 'Paused', Unknown = 'Unknown', Failed = 'Failed', Deleted = 'Deleted'
}
export class ImageKnowledgeFailure extends Error {
  category: string; stage: string;
  constructor(category: string, stage: string) { super(`${category} · ${stage}`); this.category = category; this.stage = stage; }
}
export class ImageLimits {
  static readonly bytes: number = 20 * 1024 * 1024;
  static readonly pixels: number = 20000000;
  static readonly headerParts: number = 4096;
  static readonly readBytes: number = 65536;
  static readonly pixelReadBytes: number = 1048576;
  static readonly nodes: number = 20000;
  static readonly chunks: number = 2000;
  static readonly activeChunks: number = 10000;
  static readonly allChunks: number = 30000;
}
export class ImageHeaderEvidence {
  encoding: ImageEncoding = ImageEncoding.Jpeg;
  mime: string = ''; width: number = 0; height: number = 0;
  staticContainer: boolean = false; alpha: boolean = false; variant: string = '';
  orientation: number = 0; orientationEvidence: string = 'Unknown';
  warnings: string[] = [];
}
export class ImageOriginal {
  documentId: string = ''; assetId: string = ''; sourceId: string = ''; version: number = 0;
  title: string = ''; suffix: string = ''; hash: string = ''; bytes: number = 0;
  header: ImageHeaderEvidence = new ImageHeaderEvidence();
  sdkVerified: boolean = false; frames: number = 0; savedAt: number = 0;
  basicQualified: boolean = false;
  preview: ImagePreviewState = ImagePreviewState.NotRequested; previewReason: string = '';
}
export class ImageLocator {
  originalAssetId: string = ''; originalHash: string = ''; originalVersion: number = 0;
  width: number = 0; height: number = 0; orientation: number = 0;
  blockId: string = ''; paragraph: number = 0; start: number = 0; end: number = 0;
  // No region field: IMAGE-NORMALIZED-1 deliberately makes no pixel-box claim.
}
export class ImageOcrBlock {
  id: string = ''; ordinal: number = 0; text: string = ''; locator: ImageLocator = new ImageLocator();
  sourceStart: number = 0; sourceEnd: number = 0;
}
export class ImageCoverage {
  identified: number = 0; excluded: number = 0; unknown: number = 0; empty: number = 0;
  fullDocument: boolean = false; hash: string = ''; issues: string[] = [];
}
export class ImageSnapshot {
  wire: string = 'IMAGE-NORMALIZED-2'; profile: string = ''; producer: string = '';
  documentId: string = ''; generation: string = ''; original: ImageOriginal = new ImageOriginal();
  resultHash: string = ''; contentHash: string = ''; coverage: ImageCoverage = new ImageCoverage();
  blocks: ImageOcrBlock[] = [];
  projection: ImageTextProjection = new ImageTextProjection();
}
export class ImageChunk {
  id: string = ''; documentId: string = ''; generation: string = ''; ordinal: number = 0;
  text: string = ''; inputHash: string = ''; locator: ImageLocator = new ImageLocator();
}
export class ImageDocument {
  id: string = ''; title: string = ''; epoch: number = 0; archived: boolean = false; tombstone: boolean = false;
  activeOriginal: string = ''; activeGeneration: string = ''; chunkCount: number = 0;
  stage: ImageIngestionStage = ImageIngestionStage.Saved;
  originalSummary: string = '';
  testInputId: string = ''; parseControlId: string = '';
  parseBinding: string = ''; parseSourceId: string = '';
}
export class ImageJob {
  id: string = ''; documentId: string = ''; generation: string = ''; originalAssetId: string = '';
  epoch: number = 0; expectedActive: string = ''; reportHash: string = ''; snapshotHash: string = '';
  stage: ImageIngestionStage = ImageIngestionStage.Saved; checkpoint: ImageIngestionStage = ImageIngestionStage.Saved;
  failure: string = ''; serviceTaskId: string = ''; resultAssetId: string = ''; resultHash: string = '';
}
export class ImageAssetClaim {
  assetId: string = ''; documentId: string = ''; owner: string = ''; hash: string = ''; bytes: number = 0;
  generation: string = ''; role: string = ''; pins: number = 0;
}
export class ImageReadLease {
  id: string = ''; documentId: string = ''; assetId: string = ''; owner: string = ''; epoch: number = 0;
}
export class ImageReleaseReceipt {
  leaseId: string = ''; pixel: string = 'NotAcquired'; source: string = 'NotAcquired';
  file: string = 'NotAcquired'; lease: string = 'Held'; failure: string = '';
}
export class ImageCleanupIntent { id: string = ''; documentId: string = ''; assetId: string = ''; owner: string = ''; state: string = 'Pending'; failure: string = ''; }
export class ImageParseConsent {
  id: string = ''; sourceId: string = ''; hash: string = ''; version: number = 0; configRevision: number = 0;
  purpose: string = 'ImageParse'; profile: string = ''; session: string = ''; issued: number = 0;
  free: boolean = false; fullFile: boolean = false; revoked: boolean = false;
}
export class ImageWorkerResult {
  wire: string = 'IMAGE-WORKER-RESULT-1'; operation: string = ''; status: string = '';
  payload: Uint8Array = new Uint8Array(0); category: string = ''; stage: string = ''; code: number = 0;
}
export class KnowledgeScopeSourceReceipt {
  kind: string = ''; revision: string = ''; count: number = 0; complete: boolean = false;
}
export class KnowledgeScopeReceipt {
  id: string = ''; queryHash: string = ''; scopeHash: string = ''; archived: boolean = false; extras: boolean = false;
  sources: KnowledgeScopeSourceReceipt[] = []; complete: boolean = false; noDirect: boolean = false; consumed: boolean = false;
}
export class KnowledgeVectorInput {
  sourceKind: string = ''; actualFormat: string = ''; documentId: string = ''; generation: string = '';
  epoch: number = 0; chunkId: string = ''; text: string = ''; inputHash: string = ''; snapshotHash: string = '';
}
export function imageIdentity(id: string): boolean { return new RegExp('^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$').test(id); }
export function imageHash(hash: string): boolean { return new RegExp('^[a-f0-9]{64}$').test(hash); }
export function imageStage(raw: string): ImageIngestionStage {
  for (const stage of [ImageIngestionStage.Saved, ImageIngestionStage.Review, ImageIngestionStage.Published, ImageIngestionStage.Empty,
    ImageIngestionStage.Paused, ImageIngestionStage.Unknown, ImageIngestionStage.Failed, ImageIngestionStage.Deleted]) { if (stage === raw) { return stage; } }
  throw new ImageKnowledgeFailure('UnknownStage', 'image-reader');
}
export function imageEncoding(raw: string): ImageEncoding {
  for (const encoding of [ImageEncoding.Jpeg, ImageEncoding.Png, ImageEncoding.Webp]) { if (encoding === raw) { return encoding; } }
  throw new ImageKnowledgeFailure('UnknownEncoding', 'image-reader');
}
