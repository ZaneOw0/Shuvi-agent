import { UnifiedQueryApproval, UnifiedQueryScope, UnifiedQueryTarget, UnifiedQueryGrant, UnifiedSearchCard, UnifiedSearchHistoryPage } from './UnifiedQueryModels';
import { EmbeddingConfig, EmbeddingVectorResponse, TokenEligibilityEvidence, EmbeddingSpace, KnowledgeVectorCandidate } from './EmbeddingModels';
import { ParsedCancellation } from './ParsedDocumentModels';
export interface UnifiedQueryTokenPort { unifiedQueryEvidence(config: EmbeddingConfig, text: string, hash: string): Promise<TokenEligibilityEvidence>; }
export interface UnifiedQueryTransportPort {
  embedUnifiedQuery(config: EmbeddingConfig, grant: UnifiedQueryGrant, input: string, cancel: ParsedCancellation): Promise<EmbeddingVectorResponse>;
}
export interface UnifiedQueryNumericPort {
  open(): Promise<void>; registeredSpaces(): EmbeddingSpace[];
  filteredKnnAll(space: EmbeddingSpace, query: Float32Array, targets: UnifiedQueryTarget[], cancel: ParsedCancellation): Promise<KnowledgeVectorCandidate[]>;
}
export interface UnifiedQueryHistoryPort {
  append(page: UnifiedSearchHistoryPage): Promise<void>;
  list(offset: number, limit: number): Promise<UnifiedSearchHistoryPage[]>;
}
export interface UnifiedQueryEnginePort {
  review(actual: string, session: string, epoch: number, archived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryApproval>;
  approve(approval: UnifiedQueryApproval, cost: boolean): Promise<void>;
  revoke(session: string, epoch: number): Promise<void>;
  semantic(approval: UnifiedQueryApproval, cancel: ParsedCancellation): Promise<UnifiedSearchCard[]>;
}
