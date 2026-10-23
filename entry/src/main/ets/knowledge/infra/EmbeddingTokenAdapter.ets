import { common } from '@kit.AbilityKit';
import { util, taskpool } from '@kit.ArkTS';
import { EmbeddingTokenCounterPort } from '../domain/VectorWorkflowModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { BgeM3CountInput, BgeM3CountEvidence, BgeM3InputRole, BgeM3TokenProfile } from './EmbeddingTokenCounter';
import { EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { embeddingCountWorker } from './EmbeddingCountWorker';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { EmbeddingConfig } from '../domain/EmbeddingModels';
import { UNIFIED_TEXT_POLICY, UNIFIED_QUERY_POLICY } from '../domain/UnifiedKnowledgeModels';
import { UnifiedQueryTokenPort } from '../domain/UnifiedQueryPorts';
import { UnifiedTokenPort } from '../domain/UnifiedEmbeddingPorts';

export class EmbeddingTokenAdapter implements EmbeddingTokenCounterPort, UnifiedTokenPort, UnifiedQueryTokenPort {
  private context: common.Context; private identity: KnowledgeIdentityPort; private weights: string = ''; private loading: Promise<void> | undefined;
  constructor(context: common.Context, identity: KnowledgeIdentityPort) { this.context = context; this.identity = identity; }
  private async load(): Promise<void> {
    const weights = await this.context.resourceManager.getRawFileContent(BgeM3TokenProfile.weightsResource);
    const metadata = await this.context.resourceManager.getRawFileContent(BgeM3TokenProfile.metadataResource);
    const notice = await this.context.resourceManager.getRawFileContent('embedding/bge_m3/NOTICE.txt');
    if (weights.length !== 3663 || metadata.length !== 24183 || notice.length !== 1747 || await this.identity.hash(weights) !== EmbeddingPinnedBasis.weights || await this.identity.hash(metadata) !== EmbeddingPinnedBasis.metadata || await this.identity.hash(notice) !== '2bdaf2bd304c20213a0b21c08740f0ff54e3dbef9363e231137a2c2822b37bdb') { throw new KnowledgeFailure('PinnedResourceIntegrity','input-count'); }
    this.weights = util.TextDecoder.create('utf-8',{ fatal: true }).decodeToString(weights);
  }
  async evidence(modelId: string, role: string, text: string, textHash: string): Promise<TokenEligibilityEvidence> {
    return this.count(modelId,role,text,textHash,EmbeddingPinnedBasis.policy);
  }
  async unifiedEvidence(config: EmbeddingConfig, text: string, hash: string): Promise<TokenEligibilityEvidence> { return this.count(config.modelId,'document',text,hash,UNIFIED_TEXT_POLICY); }
  async unifiedQueryEvidence(config: EmbeddingConfig, text: string, hash: string): Promise<TokenEligibilityEvidence> { return this.count(config.modelId,'query',text,hash,UNIFIED_QUERY_POLICY); }
  private async count(modelId: string, role: string, text: string, textHash: string, policy: string): Promise<TokenEligibilityEvidence> {
    if (this.loading === undefined) { this.loading = this.load(); }
    const loading: Promise<void> = this.loading;
    await loading;
    const input: BgeM3CountInput = new BgeM3CountInput(); input.fullInput = text; input.modelId = modelId; input.policyVersion = policy;
    if (role === 'document') { input.role = BgeM3InputRole.Document; } else if (role === 'query') { input.role = BgeM3InputRole.Query; } else if (role === 'probe') { input.role = BgeM3InputRole.Probe; } else { throw new KnowledgeFailure('InputRoleInvalid','input-count'); }
    const result: BgeM3CountEvidence = await taskpool.execute<[string,BgeM3CountInput],BgeM3CountEvidence>(embeddingCountWorker,this.weights,input);
    if (result.textHash.length > 0) {
      const binding: string[] = [result.evidenceVersion,result.modelId,result.profileId,result.profileRevision,result.tokenizerSha256,result.role,result.policyVersion,`${input.tokenBudget}`,result.textHash];
      if (result.textHash !== textHash || result.textHash !== await this.identity.hash(pdfCodecUtf8(text)) || result.bindingHash !== await this.identity.hash(pdfCodecUtf8(binding.map((field: string): string => `${field.length}:${field}`).join(''))) || result.profileId !== BgeM3TokenProfile.id || result.profileRevision !== BgeM3TokenProfile.revision || result.tokenizerSha256 !== BgeM3TokenProfile.tokenizerSha256 || result.providerRevision !== 'NotReported' || result.providerConsistency !== 'UnverifiedRevisionAndHiddenProcessing') { throw new KnowledgeFailure('CounterEvidenceBindingMismatch','input-count'); }
    }
    const proof: TokenEligibilityEvidence = new TokenEligibilityEvidence(); proof.localState = result.state; proof.profileBoundProven = result.profileBoundProven;
    proof.evidenceVersion = result.evidenceVersion; proof.modelId = result.modelId; proof.role = role; proof.textHash = result.textHash; proof.bindingHash = result.bindingHash;
    proof.upperBound = result.upperBound; proof.contextLimit = result.contextLimit; proof.applicableScope = result.applicableScope; proof.profileId = result.profileId;
    proof.profileRevision = result.profileRevision; proof.tokenizerSha256 = result.tokenizerSha256; proof.policyVersion = result.policyVersion; proof.provenance = result.evidenceProvenance;
    proof.providerRevision = result.providerRevision; proof.providerConsistency = result.providerConsistency; return proof;
  }
}
