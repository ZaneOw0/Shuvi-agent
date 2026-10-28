import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { UnifiedQueryScopePort, UnifiedQueryScope, UnifiedSearchCard } from '../domain/UnifiedQueryModels';
import {
  KnowledgeRuntimeCitation, KnowledgeRuntimeSearchPort, KnowledgeRuntimeSearchRequest, KnowledgeRuntimeSearchResult
} from '../domain/KnowledgeRuntimePorts';
import { unifiedLocalDirect } from '../pipeline/KnowledgeRetrievalPolicy';
import { prepareTextQuery } from '../pipeline/QueryPreparation';

const KNOWLEDGE_RUNTIME_MAX_RESULTS: number = 5;
const KNOWLEDGE_RUNTIME_EXCERPT: number = 800;
const KNOWLEDGE_RUNTIME_TOTAL_TEXT: number = 3200;

function boundedExcerpt(value: string, available: number): string {
  const limit: number = Math.min(KNOWLEDGE_RUNTIME_EXCERPT,available);
  if (value.length <= limit) { return value; }
  let end: number = limit;
  if (end > 0) {
    const code: number = value.charCodeAt(end-1);
    if (code >= 0xD800 && code <= 0xDBFF) { end--; }
  }
  return value.slice(0,end);
}

/** Local, read-only retrieval for Runtime. It never requests semantic egress and never injects tag-only matches as evidence. */
export class KnowledgeRuntimeSearchAdapter implements KnowledgeRuntimeSearchPort {
  private readonly scope: UnifiedQueryScopePort;
  private readonly config: UnifiedEmbeddingConfigPort;

  constructor(scope: UnifiedQueryScopePort, config: UnifiedEmbeddingConfigPort) {
    this.scope = scope; this.config = config;
  }

  async search(request: KnowledgeRuntimeSearchRequest, cancel: ParsedCancellation): Promise<KnowledgeRuntimeSearchResult> {
    if (request.query.trim() !== request.query || request.query.length < 1 || request.query.length > 500 ||
      !Number.isSafeInteger(request.maxResults) || request.maxResults < 1 || request.maxResults > KNOWLEDGE_RUNTIME_MAX_RESULTS) {
      throw new ParsedFailure('RuntimeKnowledgeInput','runtime-knowledge-search');
    }
    const scopePort: UnifiedQueryScopePort = this.scope;
    if (scopePort.captureLocal === undefined) { throw new ParsedFailure('RuntimeKnowledgeLocalScopeRequired','runtime-knowledge-search'); }
    const query: string = prepareTextQuery(request.query).actualInput;
    const scope: UnifiedQueryScope = await scopePort.captureLocal(this.config.currentConfig(),false,cancel); cancel.check();
    if (!scope.complete || scope.includeArchived) { throw new ParsedFailure('RuntimeKnowledgeScopeIncomplete','runtime-knowledge-search'); }
    const candidates: UnifiedSearchCard[] = unifiedLocalDirect(scope,query);
    const result: KnowledgeRuntimeSearchResult = new KnowledgeRuntimeSearchResult(); result.query = request.query;
    let remaining: number = KNOWLEDGE_RUNTIME_TOTAL_TEXT;
    const seen: string[] = [];
    for (let index: number = 0; index < candidates.length && result.citations.length < request.maxResults && remaining > 0; index++) {
      cancel.check(); const card: UnifiedSearchCard = candidates[index];
      if (!card.current || !await this.scope.visible(card,false)) { continue; }
      if (seen.indexOf(card.key) >= 0) { continue; }
      seen.push(card.key);
      cancel.check(); const excerpt: string = boundedExcerpt(card.text.trim(),remaining);
      if (excerpt.length === 0) { continue; }
      const citation: KnowledgeRuntimeCitation = new KnowledgeRuntimeCitation(); citation.citationId = result.citations.length+1;
      citation.evidenceId = card.key; citation.documentId = card.documentKey; citation.generation = card.generation; citation.title = card.title;
      citation.excerpt = excerpt; citation.kind = card.kind;
      if (card.reasons.length > 0 && card.reasons[0].route.length > 0) { citation.evidence = card.reasons[0].route; }
      result.citations.push(citation); remaining -= excerpt.length;
    }
    return result;
  }
}
