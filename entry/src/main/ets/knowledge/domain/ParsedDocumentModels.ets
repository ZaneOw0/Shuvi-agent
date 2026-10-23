export const PARSED_DOCUMENT_WIRE: string = 'UNIFIED-PARSED-DOCUMENT-1';
export const PARSED_STORE_LAYOUT: string = 'UPD-STORE-1';
export class ParsedLimits {
  static readonly sharedBytes: number = 500 * 1024 * 1024;
  static readonly manifestBytes: number = 1024 * 1024;
  static readonly payloadBytes: number = 8 * 1024 * 1024;
  static readonly generationBytes: number = 100 * 1024 * 1024;
  static readonly imageBytes: number = 20 * 1024 * 1024;
  static readonly imagePixels: number = 20000000;
  static readonly blocks: number = 20000;
  static readonly cells: number = 40000;
  static readonly occurrences: number = 1000;
  static readonly chunks: number = 2000;
  static readonly currentInputs: number = 30000;
}
export class ParsedFailure extends Error {
  category: string; stage: string;
  constructor(category: string, stage: string) { super(`${category} / ${stage}`); this.category = category; this.stage = stage; }
}
export class ParsedCancellation {
  invalid: boolean = false; deadline: number = Date.now() + 15 * 60 * 1000;
  check(): void {
    if (this.invalid || Date.now() >= this.deadline) { throw new ParsedFailure(this.invalid ? 'Canceled' : 'Timeout','local'); }
  }
}
export enum ParsedFormat { Text = 'Text', Pdf = 'Pdf', Image = 'Image', Docx = 'Docx' }
export enum ParsedKind { Text = 'Text', Heading = 'Heading', Image = 'Image', Formula = 'Formula', Table = 'Table', Cell = 'Cell', Container = 'Container', Unknown = 'Unknown' }
export enum ParsedPrecision { Unknown = 'Unknown', File = 'File', Block = 'Block', Page = 'OriginalPage', Paragraph = 'OriginalParagraph', Cell = 'OriginalCell' }
export enum ParsedCoverageState { Complete = 'Complete', Partial = 'Partial', Unknown = 'Unknown', Unsupported = 'Unsupported' }
export enum ParsedAssetState { Reserved = 'Reserved', Ready = 'Ready', Missing = 'Missing', Unsupported = 'Unsupported', Removed = 'Removed' }
export enum ParsedProvenance { Original = 'IndependentOriginal', Native = 'NativeMember', Derived = 'ProviderDerived', Unresolved = 'Unresolved' }
export class ParsedCoverage {
  state: ParsedCoverageState = ParsedCoverageState.Unknown; expected: number = 0; recovered: number = 0; reasons: string[] = [];
}
export class ParsedCoverageSet {
  selectedOutput: ParsedCoverage = new ParsedCoverage(); nativeLocation: ParsedCoverage = new ParsedCoverage(); imageRecovery: ParsedCoverage = new ParsedCoverage();
}
export class ParsedLocator {
  precision: ParsedPrecision = ParsedPrecision.Unknown; sourceHash: string = ''; evidenceId: string = '';
  pageIndex0: number = -1; paragraphId: string = ''; cellId: string = ''; limitations: string[] = [];
}
export class ParsedFormula {
  text: string = ''; latex: string = ''; imageOccurrenceId: string = ''; unsupportedReason: string = '';
}
export class ParsedInline {
  id: string = ''; order: number = 0; kind: ParsedKind = ParsedKind.Text; text: string = '';
  imageOccurrenceId: string = ''; formula: ParsedFormula = new ParsedFormula(); limitation: string = '';
}
export class ParsedBlock {
  id: string = ''; parentId: string = ''; order: number = 0; kind: ParsedKind = ParsedKind.Text;
  text: string = ''; inlines: ParsedInline[] = []; formula: ParsedFormula = new ParsedFormula();
  imageOccurrenceId: string = ''; evidenceType: string = 'ParserOutput'; locator: ParsedLocator = new ParsedLocator();
  limitation: string = ''; row: number = -1; column: number = -1; rowSpan: number = 1; columnSpan: number = 1;
}
export class ParsedImageAsset {
  id: string = ''; owner: string = 'ParsedDocumentAssets'; relativePath: string = ''; payloadHash: string = ''; bytes: number = 0;
  mime: string = ''; pixelWidth: number = 0; pixelHeight: number = 0; frames: number = 0;
  state: ParsedAssetState = ParsedAssetState.Missing; legacyContainerHash: string = ''; member: string = ''; limitation: string = '';
}
export class ParsedImageOccurrence {
  id: string = ''; documentKey: string = ''; generation: string = ''; blockId: string = ''; inlineId: string = ''; order: number = 0;
  assetId: string = ''; provenance: ParsedProvenance = ParsedProvenance.Unresolved; member: string = '';
  locator: ParsedLocator = new ParsedLocator(); ocr: string = ''; ocrVersion: string = ''; caption: string = '';
  annotationLineage: string = ''; effectiveAnnotationId: string = 'None'; limitation: string = '';
}
export class ParsedDocument {
  // The six public producer fields retain their contract names.
  markdown: string = ''; blocks?: ParsedBlock[]; asset_dir?: string;
  source_hash: string = ''; parser_signature: string = ''; engine: string = '';
  wire: string = PARSED_DOCUMENT_WIRE; documentKey: string = ''; generation: string = ''; sourceVersion: number = 1;
  title: string = ''; format: ParsedFormat = ParsedFormat.Text; images: ParsedImageAsset[] = []; occurrences: ParsedImageOccurrence[] = [];
  coverage: ParsedCoverageSet = new ParsedCoverageSet(); warnings: string[] = [];
}
export class ParsedDocumentRecord {
  id: string = ''; namespace: string = ''; legacyId: string = ''; title: string = ''; epoch: number = 0;
  activeGeneration: string = ''; sourceHash: string = ''; archived: boolean = false; tombstone: boolean = false;
}
export class ParsedTextChunk {
  id: string = ''; documentKey: string = ''; generation: string = ''; ordinal: number = 0;
  text: string = ''; inputHash: string = ''; blockId: string = ''; occurrenceId: string = '';
  evidence: string = 'Body'; start: number = 0; end: number = 0;
}
export class ParsedPayloadPart {
  id: string = ''; hash: string = ''; bytes: number = 0; ordinal: number = 0; role: string = '';
}
export class ParsedSnapshotManifest {
  wire: string = PARSED_DOCUMENT_WIRE; documentKey: string = ''; generation: string = ''; sourceVersion: number = 1;
  source_hash: string = ''; parser_signature: string = ''; engine: string = ''; title: string = ''; format: ParsedFormat = ParsedFormat.Text;
  hasBlocks: boolean = false; coverage: ParsedCoverageSet = new ParsedCoverageSet(); warnings: string[] = [];
  parts: ParsedPayloadPart[] = []; contentHash: string = '';
}
export class ParsedSnapshotBundle {
  manifest: ParsedSnapshotManifest = new ParsedSnapshotManifest(); manifestBytes: Uint8Array = new Uint8Array(0); payloads: Uint8Array[] = [];
}
export class ParsedAssetRef {
  holder: string = ''; documentKey: string = ''; generation: string = ''; assetId: string = ''; owner: string = ''; role: string = '';
}
export class ParsedAssetWrite {
  id: string = ''; documentKey: string = ''; generation: string = ''; role: string = ''; hash: string = ''; bytes: number = 0;
  relativePath: string = ''; phase: string = 'Reserved'; reserved: number = 0; failure: string = '';
}
export class ParsedReadLease {
  id: string = ''; assetId: string = ''; owner: string = ''; session: string = ''; holder: string = '';
}
export class ParsedLegacyLink {
  namespace: string = ''; legacyId: string = ''; legacyGeneration: string = ''; legacyWire: string = ''; legacyHash: string = '';
  documentKey: string = ''; generation: string = ''; epoch: number = 0; oldActive: string = ''; state: string = 'Staging';
  snapshotAsset: string = ''; sourceVersion: number = 0; archived: boolean = false;
}
export class ParsedImportState {
  busy: boolean = false; stage: string = 'Idle'; message: string = ''; enhancement: string = 'AwaitingConfig';
  document: ParsedDocument = new ParsedDocument(); documents: ParsedDocumentRecord[] = []; chunks: ParsedTextChunk[] = [];
}
export class ParsedAssetPreview { path: string = ''; leaseId: string = ''; assetId: string = ''; }
export function parsedId(id: string): boolean { return new RegExp('^[A-Za-z0-9][A-Za-z0-9_-]{0,160}$').test(id); }
export function parsedHash(hash: string): boolean { return new RegExp('^[a-f0-9]{64}$').test(hash); }
