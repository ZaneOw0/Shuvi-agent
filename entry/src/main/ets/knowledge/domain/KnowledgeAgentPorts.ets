import { ParsedCancellation } from './ParsedDocumentModels';
import { KnowledgeRuntimeCitation } from './KnowledgeRuntimePorts';

export class KnowledgeAgentQuery {
  query: string = '';
  keywords: string[] = [];
  topK: number = 5;
  mode: string = 'auto';
}
export function parseKnowledgeAgentQuery(json: string): KnowledgeAgentQuery {
  if (json.length > 5000) { throw new Error('KNOWLEDGE_INVALID_ARGUMENTS'); }
  const value: KnowledgeAgentQuery = JSON.parse(json);
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).sort().join(',') !== 'keywords,mode,query,topK' ||
    typeof value.query !== 'string' || value.query.trim().length < 1 || value.query.trim().length > 500 ||
    !Array.isArray(value.keywords) || value.keywords.length < 1 || value.keywords.length > 8 ||
    !Number.isSafeInteger(value.topK) || value.topK < 1 || value.topK > 5 ||
    !['auto', 'semantic', 'direct'].includes(value.mode)) { throw new Error('KNOWLEDGE_INVALID_ARGUMENTS'); }
  const result: KnowledgeAgentQuery = new KnowledgeAgentQuery(); result.query = value.query.trim();
  result.topK = value.topK; result.mode = value.mode;
  for (const word of value.keywords) {
    if (typeof word !== 'string' || word.trim().length < 1 || word.trim().length > 40 ||
      result.keywords.includes(word.trim())) { throw new Error('KNOWLEDGE_INVALID_ARGUMENTS'); }
    result.keywords.push(word.trim());
  }
  return result;
}
export class KnowledgeAgentCapabilities {
  storeState: string = 'unavailable';
  directReady: boolean = false;
  semanticReady: boolean = false;
  reasonCode: string = 'NotOpened';
}
export class KnowledgeAgentResult {
  schemaVersion: string = '2.0';
  status: string = 'unavailable';
  route: string = 'none';
  engine: string = 'none';
  fallbackReason: string = '';
  scopeRevision: string = '';
  complete: boolean = false;
  readableDocuments: number = 0;
  eligibleTargets?: number;
  unupgraded: number = 0;
  hasMore: boolean = false;
  truncated: boolean = false;
  hits: KnowledgeRuntimeCitation[] = [];
}
/** Host-owned consent and cancellation; never supplied by the model. */
export class KnowledgeAgentContext {
  originalQuestion: string = '';
  turnId: string = '';
  toolCallId: string = '';
  consentRevision: number = 0;
  queryEgressAllowed: boolean = false;
  excerptEgressAllowed: boolean = false;
  deadline: number = 0;
}
export interface KnowledgeAgentSearchPort {
  open(): Promise<void>;
  capabilities(): Promise<KnowledgeAgentCapabilities>;
  search(query: KnowledgeAgentQuery, context: KnowledgeAgentContext, cancel: ParsedCancellation): Promise<KnowledgeAgentResult>;
  validate(hits: KnowledgeRuntimeCitation[], cancel: ParsedCancellation): Promise<boolean>;
  close(): Promise<void>;
}
