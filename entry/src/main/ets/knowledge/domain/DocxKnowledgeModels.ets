export enum DocxStage {
  Saved = '原件已保存', Processing = '本机结构处理中', Review = '待正文与覆盖审查',
  Published = '关键词已发布', Partial = '部分关键词可用', Empty = '无支持文字',
  Paused = '已暂停', Failed = '本机处理失败', Deleted = '已删除'
}
export enum DocxNodeKind { Heading = 'Heading', Paragraph = 'Paragraph', List = 'List', Cell = 'Cell' }
export enum DocxCoverageKind { Excluded = 'Excluded', Unsupported = 'Unsupported', Ambiguous = 'Ambiguous', Unmatched = 'Unmatched' }
export class DocxLimits {
  static readonly directory: number = 2*1024*1024; static readonly entries: number = 4096;
  static readonly expanded: number = 100*1024*1024; static readonly xml: number = 8*1024*1024;
  static readonly depth: number = 64; static readonly attributes: number = 256; static readonly events: number = 200000;
  static readonly textEvent: number = 256*1024; static readonly snapshot: number = 8*1024*1024;
  static readonly nodes: number = 20000; static readonly cells: number = 40000; static readonly media: number = 200;
  static readonly chunks: number = 2000; static readonly activeChunks: number = 10000;
}
export class DocxFailure extends Error {
  category: string; stage: string;
  constructor(category: string, stage: string) { super(`${category} · ${stage}`); this.category = category; this.stage = stage; }
}
export class DocxOriginal {
  documentId: string = ''; sourceId: string = ''; assetId: string = ''; hash: string = ''; version: number = 0;
  bytes: number = 0; title: string = ''; mainPart: string = ''; savedAt: number = 0;
}
export class DocxPathStep { namespace: string = ''; localName: string = ''; ordinal: number = 0; }
export class DocxTextFragment {
  runPath: DocxPathStep[] = []; textPath: DocxPathStep[] = [];
  start: number = 0; end: number = 0; rawStart: number = 0; rawEnd: number = 0; kind: string = 'Text';
}
export class DocxHeadingIdentity { nodeId: string = ''; text: string = ''; level: number = 0; }
export class DocxCellAddress {
  tableId: string = ''; physicalRow: number = 0; physicalCell: number = 0; row: number = 0; column: number = 0;
  rowSpan: number = 1; columnSpan: number = 1; anchorId: string = ''; continuation: boolean = false;
}
export class DocxLocator {
  policy: string = 'DOCX-LOCATOR-1'; originalAssetId: string = ''; originalHash: string = ''; originalVersion: number = 0;
  part: string = ''; nodeId: string = ''; path: DocxPathStep[] = []; headings: DocxHeadingIdentity[] = [];
  paragraph: number = 0; cell: DocxCellAddress | undefined = undefined;
  start: number = 0; end: number = 0; fragments: DocxTextFragment[] = [];
}
export class DocxListIdentity {
  numId: string = ''; level: number = 0; abstractId: string = ''; format: string = ''; pattern: string = '';
  display: string = ''; displayEvidence: string = 'Unknown';
}
export class DocxNativeNode {
  id: string = ''; kind: DocxNodeKind = DocxNodeKind.Paragraph; order: number = 0; text: string = '';
  locator: DocxLocator = new DocxLocator(); list: DocxListIdentity | undefined = undefined; outline: number = -1;
}
export class DocxTable { id: string = ''; part: string = ''; path: DocxPathStep[] = []; rows: number = 0; columns: number = 0; cells: DocxCellAddress[] = []; }
export class DocxMedia {
  id: string = ''; sourcePart: string = ''; relationshipId: string = ''; targetPart: string = ''; hash: string = '';
  parentId: string = ''; parentPath: DocxPathStep[] = []; external: boolean = false; captionNodeId: string = ''; captionEvidence: string = 'Unknown';
}
export class DocxPartEvidence { part: string = ''; hash: string = ''; bytes: number = 0; crcVerified: boolean = false; }
export class DocxRelationship { sourcePart: string = ''; id: string = ''; type: string = ''; target: string = ''; external: boolean = false; }
export class DocxCoverageIssue {
  kind: DocxCoverageKind = DocxCoverageKind.Unsupported; code: string = ''; part: string = ''; nodeId: string = '';
  path: DocxPathStep[] = []; count: number = 1;
}
export class DocxCoverage {
  version: string = 'DOCX-COVERAGE-1'; supported: number = 0; excluded: number = 0; unsupported: number = 0;
  matched: number = 0; ambiguous: number = 0; unmatched: number = 0; partial: boolean = false; empty: boolean = true;
  issues: DocxCoverageIssue[] = []; hash: string = '';
}
export class DocxResultBinding {
  taskId: string = ''; dataId: string = ''; assetId: string = ''; hash: string = ''; bytes: number = 0;
  originalHash: string = ''; originalVersion: number = 0;
}
export class DocxProjectionRange { start: number = 0; end: number = 0; artifactStart: number = 0; artifactEnd: number = 0; }
export class DocxProjection {
  version: string = 'DOCX-MARKDOWN-PROJECTION-1'; member: string = ''; memberHash: string = ''; text: string = '';
  ranges: DocxProjectionRange[] = []; producer: string = 'Unreported';
}
export class DocxCorrespondence {
  nodeId: string = ''; nativeStart: number = 0; nativeEnd: number = 0; projectedStart: number = 0; projectedEnd: number = 0;
  method: string = 'LiteralUniqueMonotonic'; artifactRanges: DocxProjectionRange[] = [];
}
export class DocxSnapshot {
  wire: string = 'DOCX-NORMALIZED-1'; normalization: string = 'DOCX-NATIVE-1'; filter: string = 'DOCX-FINAL-VISIBLE-1';
  documentId: string = ''; generation: string = ''; original: DocxOriginal = new DocxOriginal();
  result: DocxResultBinding = new DocxResultBinding(); parts: DocxPartEvidence[] = []; relationships: DocxRelationship[] = [];
  nodes: DocxNativeNode[] = []; tables: DocxTable[] = []; media: DocxMedia[] = [];
  projection: DocxProjection = new DocxProjection(); correspondence: DocxCorrespondence[] = [];
  coverage: DocxCoverage = new DocxCoverage(); nativeHash: string = ''; correspondenceHash: string = ''; hash: string = '';
}
export class DocxChunk {
  id: string = ''; documentId: string = ''; generation: string = ''; ordinal: number = 0; text: string = '';
  embeddingText: string = ''; inputHash: string = ''; inputVersion: string = 'DOCX-EMBED-TEXT-1'; locator: DocxLocator = new DocxLocator();
}
export class DocxDocument {
  id: string = ''; title: string = ''; epoch: number = 0; archived: boolean = false; tombstone: boolean = false;
  activeOriginal: string = ''; activeGeneration: string = ''; chunkCount: number = 0; stage: DocxStage = DocxStage.Saved;
}
export class DocxJob {
  id: string = ''; documentId: string = ''; generation: string = ''; originalAssetId: string = ''; epoch: number = 0;
  expectedActive: string = ''; reportHash: string = ''; snapshotHash: string = ''; stage: DocxStage = DocxStage.Saved;
  checkpoint: DocxStage = DocxStage.Saved; failure: string = ''; result: DocxResultBinding = new DocxResultBinding();
}
export class DocxAssetClaim {
  assetId: string = ''; documentId: string = ''; owner: string = ''; hash: string = ''; bytes: number = 0;
  generation: string = ''; role: string = ''; pins: number = 1;
}
export class DocxReadLease { id: string = ''; documentId: string = ''; assetId: string = ''; owner: string = ''; epoch: number = 0; }
export class DocxReleaseReceipt { leaseId: string = ''; resource: string = 'NotAcquired'; state: string = 'Held'; failure: string = ''; }
export class DocxCleanupIntent { id: string = ''; documentId: string = ''; assetId: string = ''; owner: string = ''; state: string = 'Pending'; failure: string = ''; }
export function docxId(text: string): boolean { return new RegExp('^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').test(text); }
export function docxHash(text: string): boolean { return new RegExp('^[a-f0-9]{64}$').test(text); }
export function docxStage(text: string): DocxStage {
  for (const stage of [DocxStage.Saved,DocxStage.Processing,DocxStage.Review,DocxStage.Published,DocxStage.Partial,DocxStage.Empty,DocxStage.Paused,DocxStage.Failed,DocxStage.Deleted]) { if (stage === text) { return stage; } }
  throw new DocxFailure('StoredStageUnknown','docx-store');
}
