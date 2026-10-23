import { EmbeddingConfig, TokenEligibilityEvidence, EmbeddingVectorResponse, EmbeddingSpace, KnowledgeVectorRow } from './EmbeddingModels';
import { ParsedCancellation } from './ParsedDocumentModels';
export interface UnifiedTokenPort {
  unifiedEvidence(config: EmbeddingConfig, text: string, hash: string): Promise<TokenEligibilityEvidence>;
}
export interface UnifiedCorpusTransportPort {
  embedUnifiedCorpus(config: EmbeddingConfig, input: string, proof: TokenEligibilityEvidence, cancel: ParsedCancellation, admit: (launch: () => void) => Promise<void>): Promise<EmbeddingVectorResponse>;
}
export interface UnifiedNumericVectorPort {
  open(): Promise<void>; register(space: EmbeddingSpace): Promise<void>;
  put(row: KnowledgeVectorRow): Promise<void>; read(space: string, chunk: string, generation: string): Promise<KnowledgeVectorRow | undefined>;
  synchronizeUnified(space: string, owner: string, content: string, generation: string, epoch: number): Promise<void>;
  revokeUnified?(space: string, owner: string): Promise<void>;
}
export interface UnifiedEmbeddingConfigPort { currentConfig(): EmbeddingConfig; }
