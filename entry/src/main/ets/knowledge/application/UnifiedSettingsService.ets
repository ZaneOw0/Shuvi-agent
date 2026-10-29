import { UnifiedProcessingRepositoryPort } from '../domain/UnifiedProcessingPorts';
import { VisionCredentialPort, VisionCredentialStatus, VisionPolicyVersions } from '../domain/VisionModels';
import { UnifiedProcessingSettings, UnifiedInputKind, UNIFIED_TEXT_POLICY } from '../domain/UnifiedKnowledgeModels';
import { EmbeddingConfig } from '../domain/EmbeddingModels';
import { UnifiedEmbeddingConfigPort } from '../domain/UnifiedEmbeddingPorts';
import { UnifiedProcessingQueue } from './UnifiedProcessingQueue';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';
import { VISION_ENDPOINT } from '../pipeline/VisionPolicy';
import { ParsedFailure } from '../domain/ParsedDocumentModels';

export class UnifiedSettingsService {
  private repository: UnifiedProcessingRepositoryPort; private credentials: VisionCredentialPort; private config: UnifiedEmbeddingConfigPort; private queue: UnifiedProcessingQueue;
  constructor(repository: UnifiedProcessingRepositoryPort, credentials: VisionCredentialPort, config: UnifiedEmbeddingConfigPort, queue: UnifiedProcessingQueue) { this.repository=repository; this.credentials=credentials; this.config=config; this.queue=queue; }
  async setting(purpose: string): Promise<UnifiedProcessingSettings> { return this.repository.settings(purpose); }
  async invalidateEmbedding(): Promise<void> {
    const settings: UnifiedProcessingSettings = await this.repository.settings('Embedding');
    if (settings.enabled || settings.automatic || settings.costAcknowledged || settings.baselineAccepted) {
      settings.revision++; settings.enabled=false; settings.automatic=false; settings.costAcknowledged=false; settings.baselineAccepted=false; settings.paused=true;
      await this.repository.saveSettings(settings);
    }
    await this.queue.awaitEmbeddingConfiguration();
  }
  async reconcileEmbeddingConfig(): Promise<void> {
    const settings: UnifiedProcessingSettings = await this.repository.settings('Embedding'); const config: EmbeddingConfig = this.config.currentConfig();
    if (settings.configBinding.length>0 && (settings.configBinding!==embeddingConfigBinding(config) || settings.credentialRevision!==config.credentialRevision || config.mutationPending)) { await this.invalidateEmbedding(); }
  }
  async credentialStatus(): Promise<VisionCredentialStatus> { return this.credentials.status(); }
  async saveVisionKey(secret: string, remove: boolean=false): Promise<void> {
    const settings=await this.repository.settings('Vision'); settings.enabled=false; settings.costAcknowledged=false; settings.revision++; settings.credentialRevision++; await this.repository.saveSettings(settings);
    if (remove) { await this.credentials.remove(); } else { await this.credentials.save(secret); }
  }
  async enableVision(enabled: boolean, acceptsCost: boolean): Promise<void> {
    const settings=await this.repository.settings('Vision');
    if (enabled && (!acceptsCost || !(await this.credentials.status()).present)) { throw new ParsedFailure('VisionCredentialAndCostRequired','settings'); }
    settings.revision++; settings.enabled=enabled; settings.automatic=enabled; settings.costAcknowledged=enabled && acceptsCost; settings.costRevision++; settings.paused=false;
    settings.recipient=VISION_ENDPOINT; settings.model=VisionPolicyVersions.model; settings.policy=VisionPolicyVersions.prompt; settings.imageScope='CurrentManagedImageOnly';
    await this.repository.saveSettings(settings); this.queue.kick();
  }
  async enableEmbedding(enabled: boolean, acceptsCost: boolean, baseline: boolean): Promise<void> {
    const settings=await this.repository.settings('Embedding'); const config: EmbeddingConfig=this.config.currentConfig();
    if (enabled && (!acceptsCost || !baseline || config.provider!=='SiliconFlow' || config.modelId!=='BAAI/bge-m3' || config.mutationPending)) { throw new ParsedFailure('UnifiedBaselineConfigAndCostRequired','settings'); }
    const binding: string=embeddingConfigBinding(config);
    if (enabled) { await this.queue.awaitEmbeddingConfiguration(); }
    if (enabled && (binding!==embeddingConfigBinding(this.config.currentConfig()) || this.config.currentConfig().mutationPending)) { throw new ParsedFailure('UnifiedConfigChanged','settings'); }
    settings.revision++; settings.enabled=enabled; settings.automatic=enabled; settings.costAcknowledged=enabled && acceptsCost; settings.costRevision++; settings.paused=false; settings.credentialRevision=config.credentialRevision;
    settings.recipient='SiliconFlow'; settings.model=config.modelId; settings.policy=UNIFIED_TEXT_POLICY; settings.inputKinds=[UnifiedInputKind.Body,UnifiedInputKind.Ocr,UnifiedInputKind.ImageProxy]; settings.configBinding=enabled?binding:settings.configBinding; settings.baselineAccepted=enabled && baseline;
    await this.repository.saveSettings(settings); this.queue.kick();
  }
  async pausePurpose(purpose: string, paused: boolean): Promise<void> { const s=await this.setting(purpose); s.revision++; s.paused=paused; await this.repository.saveSettings(s); if (!paused) { this.queue.resume(); } }
}
