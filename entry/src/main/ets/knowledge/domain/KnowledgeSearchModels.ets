import { TextQueryInput, TextSourceRange } from './TextKnowledgeModels';
import { PdfLocator } from './PdfKnowledgeModels';
import { QueryConsentSnapshot } from './EmbeddingModels';
import { ResultPageReference } from './PdfLocalModels';
import { ImageLocator } from './ImageKnowledgeModels';

export enum KnowledgeMatchKind { Direct = 'Direct', Similar = 'Similar', Unclassified = 'Unclassified' }
export class KnowledgeResultRange { start: number = 0; end: number = 0; }
export class KnowledgeResultSegment { id: string = ''; text: string = ''; matched: boolean = false; }
export class KnowledgeResultMatch {
  policyVersion: string = 'LITERAL-ASCII-FOLD-1'; kind: KnowledgeMatchKind = KnowledgeMatchKind.Unclassified;
  actualInput: string = ''; terms: string[] = []; matchedTerms: string[] = []; textHash: string = '';
  ranges: KnowledgeResultRange[] = []; compatibility: boolean = false;
}
export class KnowledgeResultPresentation {
  wire: string = 'KNOWLEDGE-RESULT-1'; citationId: string = ''; match: KnowledgeResultMatch = new KnowledgeResultMatch(); pages: ResultPageReference = new ResultPageReference();
}

export enum KnowledgeSourceKind { Text = 'Text', Pdf = 'Pdf', Image = 'Image' }
export enum KnowledgeChannel { Keyword = 'keyword', Vector = 'vector', Hybrid = 'hybrid' }
export enum KnowledgeRouteState { Available = 'Available', Skipped = 'Skipped', Failed = 'Failed' }
export enum KnowledgeReferenceState { Current = 'Current', Old = 'Old', Invalid = 'Invalid' }
export class KnowledgeLocator {
  kind: KnowledgeSourceKind = KnowledgeSourceKind.Text; textRanges: TextSourceRange[] = []; pdfRegions: PdfLocator[] = [];
  image: ImageLocator | undefined = undefined;
}
export class KnowledgeHit {
  id: string = ''; documentId: string = ''; sourceKind: KnowledgeSourceKind = KnowledgeSourceKind.Text;
  chunkId: string = ''; generation: string = ''; snapshotId: string = ''; snapshotHash: string = '';
  originalHash: string = ''; originalVersion: number = 0; title: string = ''; text: string = ''; retrievalText: string = '';
  locator: KnowledgeLocator = new KnowledgeLocator(); channels: KnowledgeChannel[] = []; keywordScore: number = 0;
  vectorDistance: number | undefined = undefined; rrfScore: number = 0; spaceId: string = ''; epoch: number = 0;
  vectorGeneration: string = ''; keywordRank: number = 0; vectorRank: number = 0;
  referenceState: KnowledgeReferenceState = KnowledgeReferenceState.Current;
  nodeIds: string[] = []; cellIds: string[] = []; assetIds: string[] = [];
  match: KnowledgeResultMatch = new KnowledgeResultMatch(); pages: ResultPageReference = new ResultPageReference();
  actualFormat: string = '';
}
export class KnowledgeRoute {
  channel: KnowledgeChannel = KnowledgeChannel.Keyword; state: KnowledgeRouteState = KnowledgeRouteState.Skipped;
  reason: string = ''; actualEgress: boolean = false;
}
export class KnowledgeQueryResult {
  input: TextQueryInput = new TextQueryInput(); hits: KnowledgeHit[] = []; routes: KnowledgeRoute[] = [];
  channel: KnowledgeChannel = KnowledgeChannel.Keyword; failed: boolean = false; notice: string = '';
  keywordHits: KnowledgeHit[] = []; vectorHits: KnowledgeHit[] = [];
}
export class KnowledgeHistory {
  id: string = ''; createdAt: number = 0; source: string = 'kb'; result: KnowledgeQueryResult = new KnowledgeQueryResult();
}
export class KnowledgeHistoryCursor {
  kbCreated: number = Number.MAX_SAFE_INTEGER; kbId: string = '';
  textCreated: number = Number.MAX_SAFE_INTEGER; textId: string = '';
}
export class KnowledgeHistoryPage { records: KnowledgeHistory[] = []; next: KnowledgeHistoryCursor = new KnowledgeHistoryCursor(); }
export class KnowledgeSearchState {
  question: string = ''; busy: boolean = false; includeArchived: boolean = false; includeReferenceAside: boolean = false;
  result: KnowledgeQueryResult = new KnowledgeQueryResult(); message: string = ''; queryConsent: boolean = false;
  historyPending: boolean = false; historyId: string = '';
  selectedSpaceId: string = ''; queryFree: boolean = false;
  queryApproval: QueryConsentSnapshot | undefined = undefined;
}
export class KnowledgeSearchBudget { static readonly candidates: number = 20; static readonly results: number = 5; static readonly queryMs: number = 10000; static readonly rrfK: number = 60; }
