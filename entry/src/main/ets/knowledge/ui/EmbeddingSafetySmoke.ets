import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { EmbeddingConfig, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, EmbeddingCredentialStatus, EmbeddingDetection, EmbeddingModelInfo, EmbeddingVectorResponse } from '../domain/EmbeddingModels';
import { EmbeddingCredentialPort, EmbeddingTransportPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { EmbeddingService, EmbeddingMetadataPort } from '../application/EmbeddingService';
import { EmbeddingPinnedBasis, EmbeddingBaselineAcceptance } from '../domain/EmbeddingBasisModels';
import { embeddingAuthorize, embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingLocalEligible } from '../pipeline/EmbeddingBasisPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { hilog } from '@kit.PerformanceAnalysisKit';
class BasisSmokeMissingCredential implements EmbeddingCredentialPort {
  async status(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { return EmbeddingCredentialStatus.Missing; }
  async save(_config: EmbeddingConfig, _input: string, _replace: boolean): Promise<EmbeddingCredentialStatus> { throw new Error('NoCredentialMutation'); }
  async remove(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { throw new Error('NoCredentialMutation'); }
  clearTransient(): void {}
}
class BasisSmokeTransport implements EmbeddingTransportPort {
  requests: number = 0;
  async models(_config: EmbeddingConfig, _grant: EmbeddingGrant, _cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> { this.requests++; throw new Error('NoNetwork'); }
  async embed(_config: EmbeddingConfig, _grant: EmbeddingGrant, _purpose: EmbeddingPurpose, _input: string, _cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> { this.requests++; throw new Error('NoNetwork'); }
  cancel(): void {}
}
class BasisSmokeMetadata implements EmbeddingMetadataPort {
  async saveConfig(_config: EmbeddingConfig): Promise<void> {}
  async configs(): Promise<EmbeddingConfig[]> { return []; }
  async saveDetection(_detection: EmbeddingDetection): Promise<void> {}
  async revokeGrants(_fingerprint: string): Promise<void> {}
  async saveGrant(_grant: EmbeddingGrant): Promise<void> {}
  async saveModels(_config: EmbeddingConfig, _models: EmbeddingModelInfo[]): Promise<void> {}
}

@Component
export struct EmbeddingSafetySmoke {
  onBack: () => void = (): void => {};
  @State outcome: string = 'NotRun';
  @State busy: boolean = false;
  private async run(kind: string): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.busy) { return; } this.busy = true;
    try {
      const identity = new KnowledgePlatformIdentity(); const counter = new EmbeddingTokenAdapter(context,identity); const config: EmbeddingConfig = new EmbeddingConfig(); config.modelId = kind === 'model' ? 'Pro/BAAI/bge-m3' : EmbeddingPinnedBasis.model;
      const input: string = kind === 'bound' ? 'ﷺ'.repeat(512) : 'fixture'; const proof = await counter.evidence(config.modelId,'query',input,await identity.hash(pdfCodecUtf8(input)));
      const basis: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance(); basis.state = 'AcceptedEngineeringBaseline'; basis.configFingerprint = embeddingFingerprint(config); basis.configRevision = config.revision; basis.acceptedAt = Date.now(); proof.baseline = basis;
      const grant: EmbeddingGrant = new EmbeddingGrant(); grant.purpose = kind === 'consent' ? EmbeddingPurpose.Corpus : EmbeddingPurpose.Query; grant.configFingerprint = embeddingFingerprint(config); grant.issuedAt = Date.now(); grant.expiresAt = Date.now()+10000; grant.sessionId = 'ui-fixture'; grant.spaceId = 'ui-fixture'; grant.inputHashes = [proof.textHash]; grant.inputEvidence = [proof]; grant.free = kind === 'free' ? EmbeddingFreeEligibility.Unknown : EmbeddingFreeEligibility.Confirmed;
      let rejected: boolean = false;
      if (kind === 'key') { const transport = new BasisSmokeTransport(); const service = new EmbeddingService(new BasisSmokeMetadata(),new BasisSmokeMissingCredential(),transport,identity); await service.initialize(); service.state.config.modelId = EmbeddingPinnedBasis.model; await service.probe(true); rejected = service.state.credential === EmbeddingCredentialStatus.Missing && transport.requests === 0 && service.state.message.includes('CredentialMissing'); }
      else { try { embeddingAuthorize(config,grant,EmbeddingPurpose.Query); } catch { rejected = true; } }
      if ((kind === 'bound' || kind === 'model') && embeddingLocalEligible(proof,config)) { throw new Error('InvalidInputAccepted'); }
      if (!rejected) { throw new Error('GuardDidNotReject'); }
      this.outcome = `PASS ${kind} / ${proof.localState} / bound ${proof.upperBound} / requests=0`;
      hilog.info(0x0001,'SHUVI_R2','R2_UI_GUARD case=%{public}s pass=1 requests=0',kind);
    } catch { this.outcome = `FAIL ${kind}`; hilog.info(0x0001,'SHUVI_R2','R2_UI_GUARD case=%{public}s pass=0 requests=0',kind); }
    finally { this.busy = false; }
  }
  build() {
    Column({ space: 10 }) {
      Text('隔离输入安全检查').fontSize(20)
      Text(this.outcome).id('r2-smoke-outcome')
      Text('固定非敏感输入；无凭据，无传输对象，不访问正式 PDF。').fontSize(13)
      Button('拒绝未授权用途').id('r2-smoke-consent').enabled(!this.busy).onClick((): void => { this.run('consent'); })
      Button('拒绝免费未知').id('r2-smoke-free').enabled(!this.busy).onClick((): void => { this.run('free'); })
      Button('拒绝缺少凭据').id('r2-smoke-key').enabled(!this.busy).onClick((): void => { this.run('key'); })
      Button('拒绝宽界未证').id('r2-smoke-bound').enabled(!this.busy).onClick((): void => { this.run('bound'); })
      Button('拒绝其他模型').id('r2-smoke-model').enabled(!this.busy).onClick((): void => { this.run('model'); })
      Button('返回').id('r2-smoke-back').enabled(!this.busy).onClick(this.onBack)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
