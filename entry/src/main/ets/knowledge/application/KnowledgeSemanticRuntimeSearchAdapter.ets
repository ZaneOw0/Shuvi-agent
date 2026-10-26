import { KnowledgeQuerySession } from './KnowledgeQuerySession';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { UnifiedSearchCard, UnifiedSearchReason } from '../domain/UnifiedQueryModels';
import {
  KnowledgeRuntimeCitation, KnowledgeRuntimeSearchPort, KnowledgeRuntimeSearchRequest, KnowledgeRuntimeSearchResult
} from '../domain/KnowledgeRuntimePorts';
import { prepareTextQuery } from '../pipeline/QueryPreparation';

const RAG_MAX_RESULTS: number = 5;
const RAG_MAX_EXCERPT: number = 800;
const RAG_MAX_TOTAL_TEXT: number = 3200;
const RAG_MAX_TITLE: number = 256;

function bounded(value: string, limit: number): string {
  if (value.length <= limit) { return value; }
  let end: number = limit;
  if (end > 0) {
    const code: number = value.charCodeAt(end - 1);
    if (code >= 0xD800 && code <= 0xDBFF) { end--; }
  }
  return value.slice(0, end);
}

function evidenceRoute(card: UnifiedSearchCard): string | undefined {
  const preferred: string[] = ['BodyDirect', 'OcrDirect', 'Vector'];
  for (let routeIndex: number = 0; routeIndex < preferred.length; routeIndex++) {
    for (let reasonIndex: number = 0; reasonIndex < card.reasons.length; reasonIndex++) {
      const reason: UnifiedSearchReason = card.reasons[reasonIndex];
      if (reason.route === preferred[routeIndex]) { return reason.route; }
    }
  }
  return undefined;
}

/** Retrieval-first RAG: local body/tags are loaded before one approved query embedding and local KNN. */
export class KnowledgeSemanticRuntimeSearchAdapter implements KnowledgeRuntimeSearchPort {
  private readonly createSession: () => KnowledgeQuerySession;
  private active: KnowledgeQuerySession | undefined = undefined;

  constructor(createSession: () => KnowledgeQuerySession) { this.createSession = createSession; }

  async search(request: KnowledgeRuntimeSearchRequest, cancel: ParsedCancellation): Promise<KnowledgeRuntimeSearchResult> {
    if (this.active !== undefined || request.query.trim() !== request.query || request.query.length < 1 ||
      request.query.length > 500 || !Number.isSafeInteger(request.maxResults) || request.maxResults < 1 ||
      request.maxResults > RAG_MAX_RESULTS) {
      throw new ParsedFailure('RuntimeRagInputOrBusy', 'runtime-rag-search');
    }
    const query: string = prepareTextQuery(request.query).actualInput;
    const session: KnowledgeQuerySession = this.createSession(); this.active = session;
    try {
      await session.start(query, false, cancel); cancel.check();
      if (session.state.direct.error.length > 0 || session.state.related.error.length > 0) {
        throw new ParsedFailure('RuntimeRagLocalScopeUnavailable', 'runtime-rag-search');
      }
      await session.review(); cancel.check();
      await session.allowSemantic(true, true); cancel.check();
      if (session.state.semanticState !== 'Complete') {
        throw new ParsedFailure('RuntimeRagSemanticUnavailable', 'runtime-rag-search');
      }
      const result: KnowledgeRuntimeSearchResult = new KnowledgeRuntimeSearchResult();
      result.query = request.query; result.route = 'local-rag';
      const candidates: UnifiedSearchCard[] = session.state.direct.cards.concat(session.state.related.cards);
      const seen: string[] = []; let remaining: number = RAG_MAX_TOTAL_TEXT;
      for (let index: number = 0; index < candidates.length && result.citations.length < request.maxResults && remaining > 0; index++) {
        cancel.check(); const card: UnifiedSearchCard = candidates[index]; const route: string | undefined = evidenceRoute(card);
        if (!card.current || route === undefined || seen.indexOf(card.key) >= 0 || card.key.length < 1 ||
          card.key.length > 512 || card.documentKey.length < 1 || card.generation.length < 1) { continue; }
        const excerpt: string = bounded(card.text.trim(), Math.min(RAG_MAX_EXCERPT, remaining));
        if (excerpt.length === 0) { continue; }
        seen.push(card.key);
        const citation: KnowledgeRuntimeCitation = new KnowledgeRuntimeCitation();
        citation.citationId = result.citations.length + 1; citation.evidenceId = card.key;
        citation.documentId = card.documentKey; citation.generation = card.generation;
        citation.title = bounded(card.title.trim(), RAG_MAX_TITLE); citation.excerpt = excerpt;
        citation.kind = card.kind; citation.evidence = route;
        result.citations.push(citation); remaining -= excerpt.length;
      }
      return result;
    } finally {
      if (this.active === session) { this.active = undefined; }
      await session.close();
    }
  }

  async close(): Promise<void> {
    const session: KnowledgeQuerySession | undefined = this.active;
    if (session !== undefined) { await session.close(); }
  }
}
