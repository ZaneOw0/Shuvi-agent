import { ParsedCancellation } from './ParsedDocumentModels';
import { UnifiedQueryScope, UnifiedSearchCard } from './UnifiedQueryModels';

export const KNOWLEDGE_LEXICAL_POLICY: string = 'UNIFIED-LEXICAL-1';
export class KnowledgeLexicalRequest {
  query: string = '';
  keywords: string[] = [];
  intent: string = 'keywords';
  includeArchived: boolean = false;
  cursor: string = '';
  scopeRevision: string = '';
}
export class KnowledgeLexicalCapabilities {
  state: string = 'NotBuilt';
  revision: string = '';
  directReady: boolean = false;
  tokenizer: string = 'customtokenizer';
}
export class KnowledgeLexicalCoverage {
  readableBodies: number = 0;
  readableImages: number = 0;
  indexed: number = 0;
  scanned: number = 0;
  candidateReadback: number = 0;
  complete: boolean = false;
}
export class KnowledgeLexicalResult {
  coverage: KnowledgeLexicalCoverage = new KnowledgeLexicalCoverage();
  status: string = 'unavailable';
  scopeRevision: string = '';
  indexState: string = 'NotBuilt';
  engine: string = 'literal-scan';
  fallbackReason: string = '';
  scanned: number = 0;
  readback: number = 0;
  hasMore: boolean = false;
  cursor: string = '';
  readableDocuments: number = 0;
  scope: UnifiedQueryScope = new UnifiedQueryScope();
  cards: UnifiedSearchCard[] = [];
}
/** Host supplies scope/archival policy; model tool arguments cannot supply these fields. */
export interface KnowledgeLexicalSearchPort {
  capabilities(): Promise<KnowledgeLexicalCapabilities>;
  search(request: KnowledgeLexicalRequest, cancel: ParsedCancellation): Promise<KnowledgeLexicalResult>;
  validate(cards: UnifiedSearchCard[], includeArchived: boolean, cancel: ParsedCancellation): Promise<boolean>;
}
