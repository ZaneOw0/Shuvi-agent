import { EmbeddingBaselineAcceptance, EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { EmbeddingConfig, TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { UNIFIED_TEXT_POLICY, UNIFIED_QUERY_POLICY, UnifiedProcessingSettings } from '../domain/UnifiedKnowledgeModels';
export function embeddingConfigBinding(config: EmbeddingConfig): string {
  return [config.contractVersion,config.provider,config.region,config.access,config.workspaceId,config.modelId,`${config.revision}`,`${config.credentialRevision}`].map((field: string): string => encodeURIComponent(field)).join('|');
}

export function embeddingBaselineMatches(basis: EmbeddingBaselineAcceptance, config: EmbeddingConfig): boolean {
  return basis.state === 'AcceptedEngineeringBaseline' && basis.acceptedAt > 0 && basis.configFingerprint === embeddingConfigBinding(config) && basis.configRevision === config.revision && basis.model === config.modelId && basis.model === EmbeddingPinnedBasis.model && basis.profile === EmbeddingPinnedBasis.profile && basis.revision === EmbeddingPinnedBasis.revision && basis.tokenizer === EmbeddingPinnedBasis.tokenizer && basis.weights === EmbeddingPinnedBasis.weights && basis.metadata === EmbeddingPinnedBasis.metadata && basis.parameters === EmbeddingPinnedBasis.parameters && basis.policy === EmbeddingPinnedBasis.policy && basis.providerRevision === 'NotReported' && basis.providerConsistency === 'UnverifiedRevisionAndHiddenProcessing';
}
export function embeddingLocalEligible(proof: TokenEligibilityEvidence, config: EmbeddingConfig): boolean {
  return !proof.verified && proof.localState === 'SafeUnderPinnedProfile' && proof.profileBoundProven && proof.profileId === EmbeddingPinnedBasis.profile && proof.profileRevision === EmbeddingPinnedBasis.revision && proof.tokenizerSha256 === EmbeddingPinnedBasis.tokenizer && proof.evidenceVersion === EmbeddingPinnedBasis.evidence && proof.policyVersion === EmbeddingPinnedBasis.policy && proof.bindingHash.length === 64 && proof.provenance === 'ModelScopePublicSnapshot;FixedTokenizerJson;EnumeratedCharsmap' && proof.providerRevision === 'NotReported' && proof.providerConsistency === 'UnverifiedRevisionAndHiddenProcessing' && embeddingBaselineMatches(proof.baseline,config);
}
export function unifiedEmbeddingEligible(proof: TokenEligibilityEvidence, config: EmbeddingConfig, settings: UnifiedProcessingSettings): boolean {
  return settings.baselineAccepted && settings.configBinding===embeddingConfigBinding(config) && settings.policy===UNIFIED_TEXT_POLICY &&
    config.provider==='SiliconFlow' && config.modelId===EmbeddingPinnedBasis.model && !config.mutationPending && proof.policyVersion===UNIFIED_TEXT_POLICY &&
    proof.localState==='SafeUnderPinnedProfile' && proof.profileBoundProven && proof.profileId===EmbeddingPinnedBasis.profile && proof.profileRevision===EmbeddingPinnedBasis.revision &&
    proof.tokenizerSha256===EmbeddingPinnedBasis.tokenizer && proof.evidenceVersion===EmbeddingPinnedBasis.evidence && proof.provenance==='ModelScopePublicSnapshot;FixedTokenizerJson;EnumeratedCharsmap' &&
    proof.modelId===config.modelId && proof.role==='document' && proof.bindingHash.length===64 && proof.textHash.length===64 && proof.upperBound>0 && proof.upperBound<=8192 && proof.contextLimit===8192;
}
export function unifiedQueryEligible(proof: TokenEligibilityEvidence, config: EmbeddingConfig, settings: UnifiedProcessingSettings): boolean {
  return settings.baselineAccepted && settings.configBinding===embeddingConfigBinding(config) && settings.policy===UNIFIED_TEXT_POLICY && !config.mutationPending && config.provider==='SiliconFlow' && config.modelId===EmbeddingPinnedBasis.model &&
    proof.policyVersion===UNIFIED_QUERY_POLICY && proof.role==='query' && proof.modelId===config.modelId && proof.localState==='SafeUnderPinnedProfile' && proof.profileBoundProven && proof.profileId===EmbeddingPinnedBasis.profile && proof.profileRevision===EmbeddingPinnedBasis.revision && proof.tokenizerSha256===EmbeddingPinnedBasis.tokenizer && proof.evidenceVersion===EmbeddingPinnedBasis.evidence && proof.upperBound>0 && proof.upperBound<=8192 && proof.contextLimit===8192 && proof.bindingHash.length===64;
}
