import { KnowledgeLexicalSearchPort, KnowledgeLexicalRequest, KnowledgeLexicalResult } from '../domain/KnowledgeLexicalPorts';
import { KnowledgeAgentCapabilities, KnowledgeAgentContext, KnowledgeAgentQuery, KnowledgeAgentResult,
  KnowledgeAgentSearchPort } from '../domain/KnowledgeAgentPorts';
import { KnowledgeRuntimeCitation } from '../domain/KnowledgeRuntimePorts';
import { ParsedCancellation } from '../domain/ParsedDocumentModels';
import { UnifiedQueryScope, UnifiedQueryScopePort, UnifiedSearchCard } from '../domain/UnifiedQueryModels';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { KnowledgeQuerySession } from './KnowledgeQuerySession';
import { unifiedLocalDirect, unifiedMergeCard } from '../pipeline/KnowledgeRetrievalPolicy';
import { ragHeadingLike } from './KnowledgeSemanticRuntimeSearchAdapter';
import { KnowledgeQueryAuthorization } from './KnowledgeQueryAuthorization';

class AgentQueryCancellation extends ParsedCancellation {
  private readonly upstream: ParsedCancellation;
  constructor(upstream: ParsedCancellation) { super(); this.upstream = upstream; this.deadline = upstream.deadline; }
  check(): void { this.upstream.check(); super.check(); }
}

/** Shared production scope, with independent query state. No ingestion or UI query session is used. */
export class KnowledgeAgentSearchAdapter implements KnowledgeAgentSearchPort {
  private readonly scope: UnifiedQueryScopePort;
  private readonly config: UnifiedEmbeddingConfigPort;
  private readonly createSession: () => KnowledgeQuerySession;
  private readonly acquire: () => Promise<void>;
  private readonly release: () => Promise<void>;
  private opened: boolean = false;
  private active?: KnowledgeQuerySession;
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private readonly evidence: Map<string, UnifiedSearchCard> = new Map<string, UnifiedSearchCard>();
  private readonly queryAuthorization?: KnowledgeQueryAuthorization;
  private readonly lexical?: KnowledgeLexicalSearchPort;
  constructor(scope: UnifiedQueryScopePort, config: UnifiedEmbeddingConfigPort, createSession: () => KnowledgeQuerySession,
    acquire: () => Promise<void>, release: () => Promise<void>, queryAuthorization?: KnowledgeQueryAuthorization, lexical?: KnowledgeLexicalSearchPort) {
    this.lexical=lexical;
    this.scope = scope; this.config = config; this.createSession = createSession; this.acquire = acquire; this.release = release;
    this.queryAuthorization = queryAuthorization;
  }
  async open(): Promise<void> {
    if (this.closing !== undefined) { await this.closing; }
    if (this.opened) { return; }
    if (this.opening === undefined) { this.opening = this.acquire().then((): void => { this.opened = true; }); }
    try { await this.opening; } finally { this.opening = undefined; }
  }
  private async local(cancel: ParsedCancellation): Promise<UnifiedQueryScope> {
    if (!this.opened || this.scope.captureLocal === undefined) { throw new Error('KNOWLEDGE_STORE_UNAVAILABLE'); }
    const result: UnifiedQueryScope = await this.scope.captureLocal(this.config.currentConfig(), false, cancel);
    cancel.check(); return result;
  }
  async capabilities(): Promise<KnowledgeAgentCapabilities> {
    const result: KnowledgeAgentCapabilities = new KnowledgeAgentCapabilities();
    try {
      if (this.lexical!==undefined && this.opened) { const local=await this.lexical.capabilities(); result.directReady=local.directReady; result.storeState='ready'; result.reasonCode='LocalLexicalReady'; const config=this.config.currentConfig(); result.semanticReady=!config.mutationPending && config.provider==='SiliconFlow' && config.modelId==='BAAI/bge-m3'; return result; }
      const scope: UnifiedQueryScope = await this.local(new ParsedCancellation());
      result.storeState = scope.complete ? 'ready' : 'partial'; result.directReady = scope.complete;
      const config = this.config.currentConfig();
      result.semanticReady = scope.complete && !config.mutationPending && config.provider === 'SiliconFlow' && config.modelId === 'BAAI/bge-m3';
      result.reasonCode = scope.complete ? 'LocalReadySemanticCheckedOnQuery' : 'ScopeIncomplete';
    } catch { result.reasonCode = 'StoreUnavailable'; }
    return result;
  }
  async search(query: KnowledgeAgentQuery, context: KnowledgeAgentContext, cancel: ParsedCancellation): Promise<KnowledgeAgentResult> {
    if (!context.excerptEgressAllowed || this.active !== undefined) { throw new Error('KNOWLEDGE_DENIED'); }
    cancel.check(); if (!this.opened) { throw new Error('KNOWLEDGE_STORE_UNAVAILABLE'); } const scope: UnifiedQueryScope = this.lexical===undefined?await this.local(cancel):new UnifiedQueryScope(); if (this.lexical!==undefined) { scope.complete=true; }
    const result: KnowledgeAgentResult = new KnowledgeAgentResult(); result.scopeRevision = scope.localHash;
    result.complete = scope.complete;
    const documents: Set<string> = new Set<string>();
    for (const text of scope.texts) { documents.add(text.document.id); }
    for (const image of scope.images) { documents.add(image.record.documentKey); }
    result.readableDocuments = documents.size;
    result.unupgraded = scope.unupgraded;
    if (!scope.complete) { result.status = 'unavailable'; result.fallbackReason = 'ScopeIncomplete'; return result; }
    const candidates: UnifiedSearchCard[] = [];
    const add = (card: UnifiedSearchCard): void => {
      const prior: UnifiedSearchCard | undefined = candidates.find((item: UnifiedSearchCard): boolean => item.key === card.key);
      if (prior === undefined) { candidates.push(card); } else { unifiedMergeCard(prior, card); }
    };
    if (query.mode !== 'direct' && context.queryEgressAllowed) {
      const session: KnowledgeQuerySession = this.createSession(); this.active = session;
      try {
        await session.start(query.query, false, new AgentQueryCancellation(cancel)); cancel.check();
        this.queryAuthorization?.allow(session.state.session, session.state.epoch, context.consentRevision, cancel);
        await session.review(); cancel.check();
        await session.allowSemantic(true, true); cancel.check();
        if (session.state.semanticState !== 'Complete') { throw new Error('SEMANTIC_UNAVAILABLE'); }
        for (const card of session.state.related.cards) {
          if (card.reasons.some((reason): boolean => reason.route === 'Vector')) { add(card); }
        }
        result.route = 'semantic'; result.engine = 'exact-knn';
      } catch {
        cancel.check(); result.fallbackReason = 'EmbeddingUnavailable';
      } finally { this.active = undefined; await session.close(); }
    } else if (query.mode !== 'direct') { result.fallbackReason = 'QueryConsentMissing'; }
    if (candidates.length === 0) {
      // Page and Agent share the lexical application port; legacy callers retain their literal policy.
      if (this.lexical!==undefined) {
        const request: KnowledgeLexicalRequest=new KnowledgeLexicalRequest(); request.query=query.query; request.keywords=query.keywords;
        let local: KnowledgeLexicalResult=await this.lexical.search(request,cancel);
        // One bounded continuation also covers descriptions when the body pass was exhausted.
        for (const card of local.cards) { add(card); }
        if (local.hasMore && candidates.length<query.topK) { request.cursor=local.cursor; request.scopeRevision=local.scopeRevision; local=await this.lexical.search(request,cancel); for (const card of local.cards) { add(card); } }
        result.engine=local.engine; result.scopeRevision=local.scopeRevision; result.complete=!local.hasMore; result.hasMore=local.hasMore; result.readableDocuments=local.readableDocuments; result.unupgraded=local.scope.unupgraded;
        if (local.fallbackReason.length>0) { result.fallbackReason=local.fallbackReason; }
      } else {
        for (const word of query.keywords) { for (const card of unifiedLocalDirect(scope, word)) { add(card); } }
        result.engine = 'literal-scan';
      }
      result.route = 'direct';
    }
    let remaining: number = 3200;
    for (let pass: number = 0; pass < 2; pass++) {
      for (const card of candidates) {
        cancel.check();
        if (result.hits.length >= query.topK || remaining <= 0) { result.hasMore = true; break; }
        if (!card.current || !await this.scope.visible(card, false) || ragHeadingLike(card.text, card.title) !== (pass === 1)) { continue; }
        const vector: boolean = card.reasons.some((reason): boolean => reason.route === 'Vector');
        const direct: boolean = card.reasons.some((reason): boolean => reason.route === 'BodyDirect' || reason.route === 'OcrDirect' || reason.route === 'Keyword');
        if (!vector && !direct || !card.text.trim()) { continue; }
        const hit: KnowledgeRuntimeCitation = new KnowledgeRuntimeCitation(); hit.citationId = result.hits.length + 1;
        hit.evidenceId = card.key; hit.documentId = card.documentKey; hit.generation = card.generation;
        const lexicalReason=card.reasons.find((reason): boolean=>reason.route==='Keyword'); const evidenceText: string=lexicalReason?.text ?? card.text;
        hit.title = card.title.slice(0, 256); hit.excerpt = evidenceText.trim().slice(0, Math.min(800, remaining));
        hit.matchKind=vector?'Semantic':lexicalReason?.matchKind ?? 'Literal'; hit.evidenceType=lexicalReason?.evidenceType ?? (vector?'Vector':'Body'); hit.engine=lexicalReason?.engine ?? result.engine;
        hit.kind = card.kind; hit.evidence = vector ? 'Vector' : 'BodyDirect';
        result.truncated = result.truncated || hit.excerpt.length < card.text.trim().length;
        this.evidence.set(hit.evidenceId, card); result.hits.push(hit); remaining -= hit.excerpt.length;
      }
    }
    cancel.check();
    if (!await this.validate(result.hits, cancel)) { throw new Error('KNOWLEDGE_EVIDENCE_CHANGED'); }
    result.status = !result.complete?'partial':result.hits.length > 0 ? 'ok' : 'empty'; return result;
  }
  async validate(hits: KnowledgeRuntimeCitation[], cancel: ParsedCancellation): Promise<boolean> {
    if (this.lexical===undefined) { const scope: UnifiedQueryScope = await this.local(cancel); if (!scope.complete) { return false; } }
    for (const hit of hits) {
      const card: UnifiedSearchCard | undefined = this.evidence.get(hit.evidenceId);
      if (card === undefined || card.documentKey !== hit.documentId || card.generation !== hit.generation ||
        !(card.text.includes(hit.excerpt) || card.reasons.some((reason): boolean=>reason.text.includes(hit.excerpt))) || !await this.scope.visible(card, false) || this.lexical!==undefined && !await this.lexical.validate([card],false,cancel)) { return false; }
      cancel.check();
    }
    return true;
  }
  close(): Promise<void> {
    if (this.closing !== undefined) { return this.closing; }
    this.closing = this.closeOnce().finally((): void => { this.closing = undefined; }); return this.closing;
  }
  private async closeOnce(): Promise<void> {
    if (this.opening !== undefined) { try { await this.opening; } catch { return; } }
    await this.active?.close();
    if (this.opened) { await this.release(); this.opened = false; this.evidence.clear(); }
  }
}
