import { UnifiedQueryEnginePort, UnifiedQueryNumericPort, UnifiedQueryTokenPort, UnifiedQueryTransportPort } from '../domain/UnifiedQueryPorts';
import { UnifiedQueryApproval, UnifiedQueryGrant, UnifiedQueryPersistentPort, UnifiedQueryScopePort, UnifiedSearchCard } from '../domain/UnifiedQueryModels';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { ParsedIdentityPort } from '../domain/ParsedDocumentPorts';
import { ParsedCancellation, ParsedFailure } from '../domain/ParsedDocumentModels';
import { EmbeddingPurpose, EmbeddingConfig } from '../domain/EmbeddingModels';
import { unifiedQueryEligible, embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';
import { prepareTextQuery } from '../pipeline/QueryPreparation';
import { parsedUtf8 } from '../pipeline/ParsedDocumentCodec';
import { unifiedSemanticCards } from '../pipeline/KnowledgeRetrievalPolicy';

export class UnifiedQueryService implements UnifiedQueryEnginePort {
  private scope: UnifiedQueryScopePort; private persistent: UnifiedQueryPersistentPort; private repository: UnifiedProcessingRepositoryPort; private numeric: UnifiedQueryNumericPort;
  private config: UnifiedEmbeddingConfigPort; private counter: UnifiedQueryTokenPort; private transport: UnifiedQueryTransportPort; private identity: ParsedIdentityPort;
  constructor(scope: UnifiedQueryScopePort, persistent: UnifiedQueryPersistentPort, repository: UnifiedProcessingRepositoryPort, numeric: UnifiedQueryNumericPort, config: UnifiedEmbeddingConfigPort, counter: UnifiedQueryTokenPort, transport: UnifiedQueryTransportPort, identity: ParsedIdentityPort) { this.scope=scope; this.persistent=persistent; this.repository=repository; this.numeric=numeric; this.config=config; this.counter=counter; this.transport=transport; this.identity=identity; }
  async review(actual: string, session: string, epoch: number, archived: boolean, cancel: ParsedCancellation): Promise<UnifiedQueryApproval> {
    if (actual!==prepareTextQuery(actual).actualInput) { throw new ParsedFailure('ActualQuestionRequired','query-review'); }
    const config: EmbeddingConfig=this.config.currentConfig(); const setting=await this.repository.settings('Embedding');
    if (!setting.enabled) { throw new ParsedFailure('UnifiedEmbeddingDisabled','query-review'); }
    if (!setting.costAcknowledged) { throw new ParsedFailure('UnifiedEmbeddingCostRequired','query-review'); }
    if (setting.paused) { throw new ParsedFailure('UnifiedEmbeddingPaused','query-review'); }
    if (!setting.baselineAccepted) { throw new ParsedFailure('UnifiedEmbeddingBaselineRequired','query-review'); }
    if (setting.configBinding!==embeddingConfigBinding(config)) { throw new ParsedFailure('UnifiedEmbeddingConfigChanged','query-review'); }
    const scope=await this.scope.capture(config,archived,cancel);
    if (!scope.complete) { throw new ParsedFailure('UnifiedScopeIncomplete','query-review'); }
    if (scope.space===undefined) { throw new ParsedFailure('UnifiedSpaceMissing','query-review'); }
    if (scope.targets.length===0) { throw new ParsedFailure('UnifiedTargetsMissing','query-review'); }
    const a: UnifiedQueryApproval=new UnifiedQueryApproval(); a.id=this.identity.id(); a.session=session; a.epoch=epoch; a.actual=actual; a.inputHash=await this.identity.hash(parsedUtf8(actual));
    const proof=await this.counter.unifiedQueryEvidence(config,actual,a.inputHash); if (!unifiedQueryEligible(proof,config,setting)) { throw new ParsedFailure('UnifiedQueryCountOrBaseline','query-review'); }
    a.proofBinding=proof.bindingHash; a.configBinding=embeddingConfigBinding(config); a.credentialRevision=config.credentialRevision; a.settingsRevision=setting.revision; a.costRevision=setting.costRevision; a.scopeHash=scope.hash; a.spaceId=scope.space.id; a.includeArchived=archived;
    cancel.check(); await this.persistent.saveQueryApproval(a); return a;
  }
  async approve(a: UnifiedQueryApproval, cost: boolean): Promise<void> { if (!cost || !a.approved || !a.costAccepted || a.revoked || a.consumed) { throw new ParsedFailure('CurrentQuestionCostRequired','query-approval'); } await this.persistent.saveQueryApproval(a); }
  async revoke(session: string, epoch: number): Promise<void> { await this.persistent.revokeQuery(session,epoch); }
  async semantic(a: UnifiedQueryApproval, cancel: ParsedCancellation): Promise<UnifiedSearchCard[]> {
    cancel.check(); const config: EmbeddingConfig=this.config.currentConfig(); const scope=await this.scope.capture(config,a.includeArchived,cancel); const setting=await this.repository.settings('Embedding');
    if (!scope.complete || scope.hash!==a.scopeHash || scope.space?.id!==a.spaceId || a.configBinding!==embeddingConfigBinding(config)) { throw new ParsedFailure('QueryScopeChanged','query'); }
    const proof=await this.counter.unifiedQueryEvidence(config,a.actual,a.inputHash); if (!unifiedQueryEligible(proof,config,setting) || proof.bindingHash!==a.proofBinding) { throw new ParsedFailure('QueryProofChanged','query'); }
    const grant: UnifiedQueryGrant=new UnifiedQueryGrant(); grant.id=a.id; grant.purpose=EmbeddingPurpose.Query; grant.provider=config.provider; grant.configFingerprint=a.configBinding; grant.credentialRevision=a.credentialRevision; grant.inputHashes=[a.inputHash]; grant.spaceId=a.spaceId; grant.sessionId=a.session; grant.approval=a; grant.proof=proof; grant.issuedAt=Date.now(); grant.expiresAt=Date.now()+120000;
    grant.cancellation=cancel;
    const response=await this.transport.embedUnifiedQuery(config,grant,a.actual,cancel); cancel.check();
    const current=await this.scope.capture(this.config.currentConfig(),a.includeArchived,cancel); if (current.hash!==scope.hash || current.space?.id!==a.spaceId || response.vector.length!==scope.space.dimension || response.model!==config.modelId) { throw new ParsedFailure('QueryResultScopeChanged','query'); }
    const candidates=await this.numeric.filteredKnnAll(scope.space,response.vector,scope.targets,cancel); cancel.check(); const latest=await this.scope.capture(this.config.currentConfig(),a.includeArchived,cancel); if (latest.hash!==scope.hash) { throw new ParsedFailure('QueryCandidatesScopeChanged','query'); } return unifiedSemanticCards(scope,candidates);
  }
}
