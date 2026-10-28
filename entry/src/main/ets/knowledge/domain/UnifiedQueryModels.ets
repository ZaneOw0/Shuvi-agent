import { EmbeddingGrant, EmbeddingConfig, EmbeddingSpace, TokenEligibilityEvidence } from './EmbeddingModels';
import { UnifiedTextInput, UnifiedImageRecord, UnifiedEffectiveAnnotation, UnifiedIndexBinding, UNIFIED_QUERY_POLICY, UNIFIED_TEXT_POLICY } from './UnifiedKnowledgeModels';
import { ParsedTextChunk, ParsedDocumentRecord, ParsedCancellation } from './ParsedDocumentModels';
import { VectorEligibility } from './VectorWorkflowModels';

export class UnifiedSearchRange { start: number=0; end: number=0; }
export class UnifiedSearchReason {
  id: string=''; route: string=''; text: string=''; version: string=''; inputId: string=''; occurrenceId: string='';
  ranges: UnifiedSearchRange[]=[]; distance?: number; rank: number=0;
  savedReason: string='';
}
export class UnifiedSearchParent {
  documentKey: string=''; generation: string=''; occurrenceId: string=''; title: string=''; precision: string='Block';
}
export class UnifiedSearchCard {
  key: string=''; kind: string='Text'; title: string=''; text: string=''; imageHash: string=''; effectiveId: string='None';
  documentKey: string=''; generation: string=''; assetId: string=''; occurrenceId: string='';
  parents: UnifiedSearchParent[]=[]; reasons: UnifiedSearchReason[]=[]; current: boolean=true;
  localRank: number=0; vectorRank: number=0; score: number=0;
}
export class UnifiedSearchGroup {
  id: string=''; cards: UnifiedSearchCard[]=[]; busy: boolean=false; error: string=''; cursor: string='0';
  exhausted: boolean=false; revision: number=0;
}
export class UnifiedSearchState {
  session: string=''; question: string=''; epoch: number=0; includeArchived: boolean=false;
  direct: UnifiedSearchGroup=new UnifiedSearchGroup(); related: UnifiedSearchGroup=new UnifiedSearchGroup();
  semanticState: string='NotRequested'; semanticError: string=''; review: UnifiedQueryApproval | undefined;
  unupgraded: number=0; coverageMessage: string=''; historyPending: boolean=false; historyId: string='';
}
export class UnifiedQueryTextSource {
  document: ParsedDocumentRecord=new ParsedDocumentRecord(); chunks: ParsedTextChunk[]=[];
}
export class UnifiedQueryImageSource {
  record: UnifiedImageRecord=new UnifiedImageRecord(); annotation: UnifiedEffectiveAnnotation | undefined;
}
export class UnifiedQueryTarget {
  input: UnifiedTextInput=new UnifiedTextInput(); qualification: VectorEligibility=new VectorEligibility();
  binding: UnifiedIndexBinding=new UnifiedIndexBinding();
}
export class UnifiedQueryScope {
  hash: string=''; localHash: string=''; texts: UnifiedQueryTextSource[]=[]; images: UnifiedQueryImageSource[]=[]; targets: UnifiedQueryTarget[]=[];
  space: EmbeddingSpace | undefined; spaces: EmbeddingSpace[]=[]; unupgraded: number=0; includeArchived: boolean=false; complete: boolean=false;
}
export class UnifiedQueryApproval {
  id: string=''; policy: string=UNIFIED_QUERY_POLICY; session: string=''; epoch: number=0; actual: string=''; inputHash: string='';
  configBinding: string=''; credentialRevision: number=0; settingsRevision: number=0; costRevision: number=0;
  scopeHash: string=''; spaceId: string=''; proofBinding: string=''; approved: boolean=false; costAccepted: boolean=false;
  revoked: boolean=false; consumed: boolean=false; includeArchived: boolean=false;
}
export class UnifiedQueryGrant extends EmbeddingGrant {
  unifiedPolicy: string=UNIFIED_QUERY_POLICY; approval: UnifiedQueryApproval=new UnifiedQueryApproval(); proof: TokenEligibilityEvidence=new TokenEligibilityEvidence();
  cancellation: ParsedCancellation | undefined;
}
export class UnifiedSearchHistoryPage {
  wire: string='UNIFIED-KNOWLEDGE-HISTORY-1'; recordId: string=''; eventId: string=''; revision: number=0; createdAt: number=0;
  question: string=''; policy: string=UNIFIED_QUERY_POLICY; space: string=UNIFIED_TEXT_POLICY; scopeHash: string='';
  direct: UnifiedSearchCard[]=[]; related: UnifiedSearchCard[]=[]; semanticState: string=''; unupgraded: number=0;
  directCursor: string=''; relatedCursor: string=''; sortVersion: string='APPEND-CARD-RRF-1';
}
export interface UnifiedQueryScopePort {
  captureLocal?(config: EmbeddingConfig, includeArchived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryScope>;
  capture(config: EmbeddingConfig, includeArchived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryScope>;
  visible(card: UnifiedSearchCard, includeArchived: boolean): Promise<boolean>;
}
export interface UnifiedQueryAdmissionPort {
  admitUnified(approval: UnifiedQueryApproval, input: string, cancel: ParsedCancellation, launch: () => void): Promise<void>;
}
export interface UnifiedQueryPersistentPort {
  saveQueryApproval(approval: UnifiedQueryApproval): Promise<void>;
  revokeQuery(session: string, epoch: number): Promise<void>;
  consumeQuery(approval: UnifiedQueryApproval, currentScope: string, launch: () => void): Promise<void>;
}
