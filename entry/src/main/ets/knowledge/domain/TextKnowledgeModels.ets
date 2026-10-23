export class TextBudget {
  static readonly fileBytes: number = 1048576;
  static readonly batchFiles: number = 10;
  static readonly batchBytes: number = 5242880;
  static readonly documents: number = 100;
  static readonly originalBytes: number = 20971520;
  static readonly activeChunks: number = 10000;
  static readonly nodes: number = 20000;
  static readonly cells: number = 40000;
  static readonly indexMs: number = 60000;
  static readonly searchMs: number = 10000;
  static readonly chunkUnits: number = 512;
  static readonly overlap: number = 51;
  static readonly queryCharacters: number = 512;
  static readonly queryBytes: number = 1000;
  static readonly snapshotBytes: number = 12582912;
  static readonly transferEstimateBytes: number = 12582912;
  static readonly historyPage: number = 20;
}

export enum TextFormat { Txt = 'TXT', Markdown = 'MD' }
export enum TextNodeKind {
  Heading = 'HEADING', Paragraph = 'PARAGRAPH', List = 'LIST', Code = 'CODE',
  Table = 'TABLE', Image = 'IMAGE_REFERENCE', Raw = 'RAW'
}
export enum TextStage {
  Saved = '原件已保存', Normalized = '规范化已校验', Prepared = '索引已准备',
  Ready = '就绪', Paused = '暂停，可继续', Failed = '失败，可重试'
}
export enum TextChannel { Fts = 'FTS5 关键词', Like = 'LIKE 字面关键词（降级）', Unavailable = '检索不可用' }
export enum TextScreen { Documents = '资料', Search = '检索', History = '历史', Detail = '原文', Record = '历史详情' }
export enum TextReferenceState { Current = '当前版本', Old = '引用旧版本，仅保留快照', Deleted = '原文档已删除，引用已失效' }
export enum TextRangeRole { Evidence = 'EVIDENCE', Heading = 'HEADING_PREFIX', Header = 'TABLE_HEADER_PREFIX' }

export class TextFailure extends Error {
  category: string;
  stage: string;
  constructor(category: string, stage: string, message: string) {
    super(message);
    this.category = category;
    this.stage = stage;
  }
}

export class TextCancellation {
  invalid: boolean = false;
  deadline: number = 0;
  check(): void {
    if (this.invalid) { throw new TextFailure('CANCELED', 'task', '已暂停，已保存资料保留'); }
    if (this.deadline > 0 && Date.now() >= this.deadline) {
      throw new TextFailure('TIMEOUT', 'task', '处理超时，已保存资料与旧索引保留');
    }
  }
}

export class TextSelectedFile {
  uri: string = '';
  name: string = '';
  bytes: number = 0;
  format: TextFormat = TextFormat.Txt;
}
export class TextSelection {
  canceled: boolean = false;
  files: TextSelectedFile[] = [];
}
export class TextOriginal {
  assetId: string = '';
  hash: string = '';
  bytes: number = 0;
}
export class TextDocument {
  id: string = '';
  title: string = '';
  format: TextFormat = TextFormat.Txt;
  original: TextOriginal = new TextOriginal();
  version: number = 1;
  activeGeneration: string = '';
  archived: boolean = false;
  stage: TextStage = TextStage.Saved;
  failure: string = '';
  chunkCount: number = 0;
  warnings: string[] = [];
  createdAt: number = 0;
  updatedAt: number = 0;
}

// All offsets are UTF-16, half-open. They are never binary byte offsets.
export class TextSourceRange {
  role: TextRangeRole = TextRangeRole.Evidence;
  originalStart: number = 0;
  originalEnd: number = 0;
  normalizedStart: number = 0;
  normalizedEnd: number = 0;
  startLine: number = 1;
  endLine: number = 1;
  nodeId: string = '';
  headingPath: string[] = [];
}
export class TextNormalized {
  originalText: string = '';
  text: string = '';
  originalOffsets: number[] = [];
  lineStarts: number[] = [0];
  bom: boolean = false;
}
export class TextCell {
  row: number = 0;
  column: number = 0;
  header: boolean = false;
  rowSpan: number = 1;
  columnSpan: number = 1;
  text: string = '';
  range: TextSourceRange = new TextSourceRange();
}
export class TextNode {
  id: string = '';
  parentId: string = '';
  kind: TextNodeKind = TextNodeKind.Paragraph;
  order: number = 0;
  level: number = 0;
  headingPath: string[] = [];
  text: string = '';
  range: TextSourceRange = new TextSourceRange();
  cells: TextCell[] = [];
  references: string[] = [];
}
export class TextSnapshot {
  schemaVersion: number = 1;
  parserVersion: string = 'text-structure-v1';
  mappingVersion: string = 'utf8-utf16-v1';
  strategyVersion: string = 'structure-512-51-v1';
  id: string = '';
  documentId: string = '';
  documentVersion: number = 1;
  originalHash: string = '';
  normalized: TextNormalized = new TextNormalized();
  nodes: TextNode[] = [];
  warnings: string[] = [];
  assets: string[] = [];
}
export class TextChunk {
  id: string = '';
  documentId: string = '';
  snapshotId: string = '';
  generation: string = '';
  ordinal: number = 0;
  kind: TextNodeKind = TextNodeKind.Paragraph;
  retrievalText: string = '';
  evidenceText: string = '';
  prefix: string = '';
  blockIds: string[] = [];
  ranges: TextSourceRange[] = [];
}
export class TextProcessed {
  snapshot: TextSnapshot = new TextSnapshot();
  chunks: TextChunk[] = [];
}
export class TextJob {
  id: string = '';
  documentId: string = '';
  generation: string = '';
  stage: TextStage = TextStage.Saved;
  checkpoint: TextStage = TextStage.Saved;
  cancelGeneration: number = 0;
  startedAt: number = 0;
  failure: string = '';
}
export class TextCleanup {
  id: string = '';
  documentId: string = '';
  generation: string = '';
  assetIds: string[] = [];
  failure: string = '';
}
export class TextUsage {
  documents: number = 0;
  originalBytes: number = 0;
  activeChunks: number = 0;
}
export class TextQueryInput {
  fullQuestion: string = '';
  actualInput: string = '';
  notice: string = '';
  terms: string[] = [];
  droppedRanges: string[] = [];
}
export class TextHit {
  documentId: string = '';
  title: string = '';
  documentVersion: number = 1;
  originalHash: string = '';
  generation: string = '';
  snapshotId: string = '';
  chunkId: string = '';
  text: string = '';
  retrievalText: string = '';
  kind: TextNodeKind = TextNodeKind.Paragraph;
  ranges: TextSourceRange[] = [];
  channel: TextChannel = TextChannel.Unavailable;
  score: number = 0;
  referenceState: TextReferenceState = TextReferenceState.Current;
}
export class TextSearchResult {
  input: TextQueryInput = new TextQueryInput();
  hits: TextHit[] = [];
  channel: TextChannel = TextChannel.Unavailable;
  notice: string = '';
}
export class TextHistory {
  id: string = '';
  createdAt: number = 0;
  result: TextSearchResult = new TextSearchResult();
}
export class TextDetail {
  title: string = '';
  originalText: string = '';
  excerpts: string[] = [];
  ranges: TextSourceRange[] = [];
  note: string = '';
}
export class TextViewState {
  screen: TextScreen = TextScreen.Documents;
  previousScreen: TextScreen = TextScreen.Documents;
  documents: TextDocument[] = [];
  jobs: TextJob[] = [];
  selectedIds: string[] = [];
  question: string = '';
  includeArchived: boolean = false;
  busy: boolean = false;
  searching: boolean = false;
  message: string = '';
  channel: TextChannel = TextChannel.Unavailable;
  result: TextSearchResult = new TextSearchResult();
  detail: TextDetail = new TextDetail();
  history: TextHistory[] = [];
  historyOffset: number = 0;
  cleanupCount: number = 0;
}

export function textErrorMessage(error: Error): string {
  return error instanceof TextFailure ? `${error.category} / ${error.stage}：${error.message}` : '本机操作失败，资料保留，请重试';
}
