import { EmbeddingCredentialPort, EmbeddingTransportPort, KnowledgeIdentityPort, KnowledgeStateListener, KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import {
  EmbeddingConfig, EmbeddingViewState, EmbeddingProvider, EmbeddingGrant, EmbeddingPurpose,
  EmbeddingFreeEligibility, EmbeddingDetection, EmbeddingDetectionStatus, EmbeddingBudget,
  EmbeddingCredentialStatus, EmbeddingModelInfo, EmbeddingVectorResponse
} from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { embeddingFingerprint, embeddingValidateConfig, embeddingAuthorize } from '../pipeline/EmbeddingPolicy';
import { embeddingValidateVector } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { EmbeddingWorkflow, EmbeddingWorkflowGrantPort } from './EmbeddingWorkflow';
import { EmbeddingJob } from '../domain/EmbeddingModels';
import { VectorUsageSummary } from '../domain/VectorWorkflowModels';
import { EmbeddingDryReview, EmbeddingBaselineAcceptance, EmbeddingPinnedBasis } from '../domain/EmbeddingBasisModels';
import { TokenEligibilityEvidence } from '../domain/EmbeddingModels';
import { EmbeddingTrialScope, EmbeddingTrialResult } from '../domain/VectorWorkflowModels';
import { QueryConsentSnapshot } from '../domain/EmbeddingModels';

export interface EmbeddingMetadataPort extends EmbeddingWorkflowGrantPort {
  saveConfig(config: EmbeddingConfig): Promise<void>; configs(): Promise<EmbeddingConfig[]>;
  saveDetection(detection: EmbeddingDetection): Promise<void>; revokeGrants(fingerprint: string): Promise<void>;
  saveGrant(grant: EmbeddingGrant): Promise<void>; saveModels(config: EmbeddingConfig, models: EmbeddingModelInfo[]): Promise<void>;
  loadDetection?(config: EmbeddingConfig): Promise<EmbeddingDetection | undefined>;
}
export function copyEmbeddingConfig(source: EmbeddingConfig): EmbeddingConfig {
  const config: EmbeddingConfig = new EmbeddingConfig(); config.provider = source.provider; config.region = source.region;
  config.access = source.access; config.workspaceId = source.workspaceId; config.modelId = source.modelId;
  config.modelSource = source.modelSource; config.revision = source.revision; config.credentialRevision = source.credentialRevision;
  config.mutationPending = source.mutationPending; config.contractVersion = source.contractVersion; return config;
}
export class EmbeddingService {
  private configInvalidation: (() => Promise<void>) | undefined;
  attachConfigInvalidation(callback: () => Promise<void>): void { this.configInvalidation = callback; }
  private workflow: EmbeddingWorkflow | undefined;
  attachWorkflow(workflow: EmbeddingWorkflow): void { this.workflow = workflow; workflow.subscribe(new KnowledgeCallbackListener((): void => { this.emit(); })); }
  async preparePinnedModel(): Promise<void> { const config = copyEmbeddingConfig(this.state.config); config.modelId = EmbeddingPinnedBasis.model; await this.saveConfiguration(config); }
  async acceptBaseline(): Promise<void> { if (this.state.busy) { return; } await this.bindWorkflow().acceptBaseline(); this.state.message = '已接受固定工程基线；providerRevision=NotReported / providerConsistency=UnverifiedRevisionAndHiddenProcessing；未授权外发'; this.emit(); }
  async baseline(): Promise<EmbeddingBaselineAcceptance> { return this.bindWorkflow().baseline(); }
  async dryReview(document: string): Promise<EmbeddingDryReview> { if (this.state.busy) { throw new KnowledgeFailure('EmbeddingBusy','review'); } this.state.busy = true; this.emit(); try { return await this.bindWorkflow().dryReview(document); } finally { this.state.busy = false; this.emit(); } }
  async reviewQuery(input: string): Promise<TokenEligibilityEvidence> { return this.bindWorkflow().queryReview(input); }
  progress(): string { return this.workflow === undefined ? 'Idle' : `${this.workflow.progressStage} ${this.workflow.completed}/${this.workflow.expected}`; }
  async retryReleases(): Promise<void> { await this.bindWorkflow().retryReleases(); }
  async prepareTrial(job: string): Promise<EmbeddingTrialScope> { return this.bindWorkflow().trialScope(job); }
  async submitReviewedTrial(job: string, approval: QueryConsentSnapshot): Promise<EmbeddingTrialResult> {
    if (this.state.busy) { throw new KnowledgeFailure('EmbeddingBusy','trial-query'); } this.state.busy = true; this.emit();
    try {
      const scope = await this.prepareTrial(job); const proof = await this.reviewQuery(approval.actual);
      if (!approval.approved || !approval.free || approval.purpose !== 'trial' || approval.role !== 'query' || approval.config !== embeddingFingerprint(this.state.config) || approval.space !== scope.space.id || approval.trial !== scope.id || approval.scopeHash !== scope.setHash || approval.inputHash !== proof.textHash || approval.bindingHash !== proof.bindingHash) { throw new KnowledgeFailure('NoRequestTrialBindingChanged','consent'); }
      const result = await this.bindWorkflow().trialQuery(job,approval.actual,approval.approved,approval.free,approval); this.state.message = result.notice; return result;
    }
    catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : 'TrialQueryFailed'; if (error instanceof Error) { throw error; } throw new KnowledgeFailure('TrialQueryFailed','trial-query'); }
    finally { this.state.busy = false; this.emit(); }
  }
  private bindWorkflow(): EmbeddingWorkflow {
    if (this.workflow === undefined) { throw new KnowledgeFailure('VectorWorkflowUnavailable','embedding'); }
    this.workflow.config = copyEmbeddingConfig(this.state.config); this.workflow.detection = this.state.detection; this.workflow.credentialReady = this.state.credential === EmbeddingCredentialStatus.Configured; return this.workflow;
  }
  async vectorJobs(): Promise<EmbeddingJob[]> { return this.bindWorkflow().jobs(); }
  async vectorJobsPage(offset: number, limit: number): Promise<EmbeddingJob[]> { return this.bindWorkflow().jobsPage(offset,limit); }
  async vectorUsage(): Promise<VectorUsageSummary> { return this.bindWorkflow().usage(); }
  state: EmbeddingViewState = new EmbeddingViewState();
  private repository: EmbeddingMetadataPort; private credential: EmbeddingCredentialPort; private transport: EmbeddingTransportPort;
  private identity: KnowledgeIdentityPort; private listeners: KnowledgeStateListener[] = [];
  private epoch: number = 0; private active: KnowledgeCancellation | undefined = undefined;
  constructor(repository: EmbeddingMetadataPort, credential: EmbeddingCredentialPort, transport: EmbeddingTransportPort, identity: KnowledgeIdentityPort) {
    this.repository = repository; this.credential = credential; this.transport = transport; this.identity = identity;
  }
  subscribe(listener: KnowledgeStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); }
  private emit(): void { if (this.workflow !== undefined) { this.bindWorkflow(); } for (const listener of this.listeners) { listener.changed(); } }
  viewState(): EmbeddingViewState {
    const state: EmbeddingViewState = new EmbeddingViewState(); state.config = copyEmbeddingConfig(this.state.config);
    state.models = this.state.models.slice(); state.credential = this.state.credential; state.detection = this.state.detection;
    state.busy = this.state.busy; state.message = this.state.message; state.inputEpoch = this.state.inputEpoch; return state;
  }
  clearInput(): void { this.state.inputEpoch++; this.credential.clearTransient(); this.emit(); }
  pause(): void { this.epoch++; if (this.active !== undefined) { this.active.invalid = true; } this.workflow?.pause(); this.transport.cancel(); this.clearInput(); }
  async initialize(): Promise<void> { await this.select(EmbeddingProvider.SiliconFlow); }
  async select(provider: EmbeddingProvider): Promise<void> {
    if (this.state.busy) { return; } this.pause();
    const configs: EmbeddingConfig[] = await this.repository.configs();
    const existing: EmbeddingConfig | undefined = configs.find((config: EmbeddingConfig): boolean => config.provider === provider);
    this.state.config = existing === undefined ? new EmbeddingConfig() : copyEmbeddingConfig(existing); this.state.config.provider = provider;
    this.state.models = []; this.state.detection = new EmbeddingDetection(); this.state.credential = await this.credential.status(this.state.config);
    const saved = await this.repository.loadDetection?.(this.state.config); if (saved !== undefined) { this.state.detection = saved; }
    this.state.message = existing?.mutationPending ? '配置变更未确认，须重新保存并检测；未外发' : '配置未检测；语料与问题外发关闭'; this.emit();
  }
  private async invalidate(): Promise<void> {
    const callback: (() => Promise<void>) | undefined = this.configInvalidation;
    if (callback !== undefined) { await callback(); }
    this.pause(); await this.repository.revokeGrants(embeddingFingerprint(this.state.config));
    this.state.models = []; this.state.detection = new EmbeddingDetection(); this.state.detection.status = EmbeddingDetectionStatus.Stale;
  }
  async saveConfiguration(input: EmbeddingConfig): Promise<void> {
    if (this.state.busy || input.provider !== this.state.config.provider) { return; }
    embeddingValidateConfig(input); this.state.busy = true;
    try {
      const current: EmbeddingConfig = this.state.config;
      if (!current.mutationPending && input.provider === current.provider && input.region === current.region && input.access === current.access && input.workspaceId === current.workspaceId && input.modelId === current.modelId && input.modelSource === current.modelSource && input.contractVersion === current.contractVersion) {
        this.state.message = '配置未变化，已保留当前检测与自动入库确认'; return;
      }
      await this.invalidate(); const config: EmbeddingConfig = copyEmbeddingConfig(input);
      config.revision = this.state.config.revision + 1; config.credentialRevision = this.state.config.credentialRevision;
      config.mutationPending = false; await this.repository.saveConfig(config); this.state.config = config;
      this.state.credential = await this.credential.status(config); this.state.message = '配置已保存，未联网；检测及外发同意已失效';
    } catch { this.state.message = '配置保存未确认，未联网；保留旧索引'; }
    finally { this.state.busy = false; this.emit(); }
  }
  async changeCredential(input: string, replace: boolean, remove: boolean = false): Promise<void> {
    if (this.state.busy) { input = ''; return; } this.state.busy = true;
    try {
      await this.invalidate(); const config: EmbeddingConfig = copyEmbeddingConfig(this.state.config);
      config.revision++; config.credentialRevision++; config.mutationPending = true;
      // Durable invalidation precedes a potentially uncertain secure-store mutation.
      await this.repository.saveConfig(config); this.state.config = config;
      this.state.credential = remove ? await this.credential.remove(config) : await this.credential.save(config,input,replace);
      config.mutationPending = false; await this.repository.saveConfig(config);
      this.state.message = remove ? 'Key 删除已确认，未联网' : '本机安全存储已确认，未检测或联网';
    } catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : '安全存储或修订确认失败，须重新配置；未明文降级'; this.state.credential = EmbeddingCredentialStatus.Unavailable; }
    finally { input = ''; this.credential.clearTransient(); this.state.inputEpoch++; this.state.busy = false; this.emit(); }
  }
  private grant(purpose: EmbeddingPurpose, free: boolean): EmbeddingGrant {
    const grant: EmbeddingGrant = new EmbeddingGrant(); grant.id = this.identity.id(); grant.purpose = purpose;
    grant.provider = this.state.config.provider; grant.configFingerprint = embeddingFingerprint(this.state.config);
    grant.credentialRevision = this.state.config.credentialRevision; grant.free = free ? EmbeddingFreeEligibility.Confirmed : EmbeddingFreeEligibility.Unknown;
    grant.issuedAt = Date.now(); grant.expiresAt = grant.issuedAt + EmbeddingBudget.requestMs; return grant;
  }
  async discover(free: boolean): Promise<void> {
    if (this.state.busy) { return; } const grant: EmbeddingGrant = this.grant(EmbeddingPurpose.Models,free);
    try { embeddingAuthorize(this.state.config,grant,EmbeddingPurpose.Models); if (this.state.credential !== EmbeddingCredentialStatus.Configured) { throw new KnowledgeFailure('CredentialMissing','models'); } } catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : 'NoRequest'; this.emit(); return; }
    this.state.busy = true; const epoch: number = this.epoch; const config: EmbeddingConfig = copyEmbeddingConfig(this.state.config);
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel;
    try {
      await this.repository.saveGrant(grant); cancel.check();
      const models: EmbeddingModelInfo[] = await this.transport.models(config,grant,cancel); cancel.check();
      if (epoch !== this.epoch || embeddingFingerprint(this.state.config) !== grant.configFingerprint) { throw new KnowledgeFailure('StaleConfiguration','models'); }
      await this.repository.saveModels(config,models); this.state.models = models; this.state.message = `当前 Key 返回 ${models.length} 个模型；未执行嵌入检测`;
    } catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : '模型发现失败；没有伪造列表或自动重试'; }
    finally { this.active = undefined; this.state.busy = false; this.emit(); }
  }
  async probe(free: boolean): Promise<void> {
    if (this.state.busy) { return; }
    const grant: EmbeddingGrant = this.grant(EmbeddingPurpose.Probe,free);
    try {
      embeddingAuthorize(this.state.config,grant,EmbeddingPurpose.Probe);
      if (this.state.credential !== EmbeddingCredentialStatus.Configured) { throw new KnowledgeFailure('CredentialMissing','probe'); }
    } catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : 'NoRequest'; this.emit(); return; }
    const epoch: number = this.epoch; const config: EmbeddingConfig = copyEmbeddingConfig(this.state.config);
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel; this.state.busy = true;
    const detection: EmbeddingDetection = new EmbeddingDetection(); detection.configFingerprint = grant.configFingerprint;
    detection.credentialRevision = config.credentialRevision; detection.requestedModel = config.modelId; detection.status = EmbeddingDetectionStatus.Running;
    this.state.detection = detection; this.emit(); const start: number = Date.now();
    try {
      await this.repository.saveGrant(grant); cancel.check();
      detection.probeHash = await this.identity.hash(pdfCodecUtf8(EmbeddingBudget.probe)); cancel.check();
      const response: EmbeddingVectorResponse = await this.transport.embed(config,grant,EmbeddingPurpose.Probe,EmbeddingBudget.probe,cancel);
      cancel.check();
      if (epoch !== this.epoch || embeddingFingerprint(this.state.config) !== grant.configFingerprint || response.model !== config.modelId || response.index !== 0) { throw new KnowledgeFailure('StaleOrMismatchedProbe','embedding'); }
      const numbers: number[] = []; for (const value of response.vector) { numbers.push(value); } embeddingValidateVector(numbers);
      detection.returnedModel = response.model; detection.dimension = response.vector.length; detection.usage = response.usage;
      detection.elapsedMs = Date.now()-start; detection.observedAt = Date.now(); detection.status = EmbeddingDetectionStatus.Passed;
      // The probe vector is never exposed as a document/query vector or persisted.
      response.vector.fill(0); await this.repository.saveDetection(detection); cancel.check();
      if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleProbe','embedding'); }
      this.state.detection = detection; this.state.message = `固定句检测通过：实际 ${detection.dimension} 维，${detection.elapsedMs} ms；不证明免费余额、语料质量或 KNN`;
    } catch (error) {
      detection.status = epoch === this.epoch ? EmbeddingDetectionStatus.Failed : EmbeddingDetectionStatus.Stale;
      detection.failure = error instanceof KnowledgeFailure ? error.message : 'ProbeFailedNoRetry';
      this.state.message = detection.failure; this.state.detection = detection;
      try { await this.repository.saveDetection(detection); } catch { this.state.message = '检测记录未确认，不能作为通过证据'; }
    } finally { this.active = undefined; this.state.busy = false; this.emit(); }
  }
  corpusGate(): string { return this.workflow?.gate() ?? 'InputLimitUnverified'; }
  queryGate(): string { return this.workflow?.gate() ?? 'InputLimitUnverified'; }
  async vectorizePdf(documentId: string, corpusConsent: boolean, free: boolean, resumeId: string = '', resendUnknown: boolean = false, fullScope: boolean = false): Promise<void> {
    if (this.state.busy) { return; } this.state.busy = true;
    try { const workflow = this.bindWorkflow(); await workflow.assertCurrentReview(documentId); await workflow.vectorize(documentId,corpusConsent,free,resumeId,resendUnknown,fullScope); this.state.message = workflow.progressStage === 'SmallScopePaused' ? '本次小范围已完成；未完整覆盖，等待下一次独立确认' : '向量完整读回并发布，资格镜像已同步'; }
    catch (error) { this.state.message = error instanceof KnowledgeFailure ? error.message : '向量平台或传输失败，已保留检查点；未自动重试'; }
    finally { this.state.busy = false; this.emit(); }
  }
}
