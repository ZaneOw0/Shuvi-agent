import { EmbeddingTokenCounterPort, VectorWorkflowRepository, VectorWorkflowStorePort, VectorCorpusPlan, VectorInputRecord, VectorInputState, VectorEligibility, KnowledgeSemanticSearchPort, VectorUsageSummary } from '../domain/VectorWorkflowModels';
import { EmbeddingConfig, EmbeddingDetection, EmbeddingDetectionStatus, EmbeddingJob, EmbeddingJobStage, EmbeddingSpace, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, EmbeddingBudget, TokenEligibilityEvidence, KnowledgeVectorRow, KnowledgeVectorCandidate, EmbeddingVectorResponse } from '../domain/EmbeddingModels';
import { KnowledgeIdentityPort, EmbeddingTransportPort, KnowledgeSourceReadPort, KnowledgeStateListener } from '../domain/KnowledgePorts';
import { KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit } from '../domain/KnowledgeSearchModels';
import { embeddingAuthorize, embeddingFingerprint, embeddingValidateVector } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { KnowledgeVectorMirrorPort } from './KnowledgeLifecycleService';
import { EmbeddingPinnedBasis, EmbeddingBaselineAcceptance, EmbeddingDryReview, EmbeddingInputReview } from '../domain/EmbeddingBasisModels';
import { embeddingLocalEligible, embeddingBaselineMatches } from '../pipeline/EmbeddingBasisPolicy';
import { EmbeddingTrialScope, EmbeddingTrialResult, EmbeddingCorpusReceipt, EmbeddingQueryReceipt } from '../domain/VectorWorkflowModels';
import { prepareTextQuery, textKeywordScore } from '../pipeline/QueryPreparation';
import { knowledgeFuse } from '../pipeline/KnowledgeRetrievalPolicy';
import { KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { QueryConsentSnapshot } from '../domain/EmbeddingModels';

export interface EmbeddingWorkflowGrantPort { saveGrant(grant: EmbeddingGrant): Promise<void>; }
export function vectorReadbackProjection(row: KnowledgeVectorRow): Uint8Array {
  const numbers: number[] = []; for (const value of row.values) { numbers.push(value); }
  return pdfCodecUtf8(JSON.stringify([row.spaceId,row.chunkId,row.documentId,row.contentGeneration,row.vectorGeneration,row.inputHash,numbers]));
}
export class EmbeddingWorkflow implements KnowledgeSemanticSearchPort, KnowledgeVectorMirrorPort {
  queryEgress: boolean = false;
  private repository: VectorWorkflowRepository; private vectors: VectorWorkflowStorePort; private transport: EmbeddingTransportPort;
  private identity: KnowledgeIdentityPort; private grants: EmbeddingWorkflowGrantPort; private readers: KnowledgeSourceReadPort;
  private counter: EmbeddingTokenCounterPort | undefined; private session: string; private epoch: number = 0;
  private active: KnowledgeCancellation | undefined; private running: boolean = false;
  releasing: boolean = false;
  private failedLeases: Set<string> = new Set<string>();
  private async releaseLease(lease: KnowledgeReadLease): Promise<void> { if (this.failedLeases.has(lease.id)) { throw new KnowledgeFailure('ReadLeaseReleaseUnconfirmed','embedding'); } try { await this.readers.releaseRead(lease.id); await this.repository.releaseFailure(lease,''); } catch (error) { this.failedLeases.add(lease.id); this.releasing = true; await this.repository.releaseFailure(lease,error instanceof KnowledgeFailure ? error.category : 'PlatformReleaseFailed'); this.progress('ReleaseUnconfirmed'); throw new KnowledgeFailure('ReadLeaseReleaseUnconfirmed','embedding'); } }
  async retryReleases(): Promise<void> { let failed: boolean = false; for (const lease of await this.repository.pendingReleases(this.session)) { this.failedLeases.delete(lease.id); try { await this.releaseLease(lease); } catch { failed = true; } } this.releasing = failed; if (failed) { throw new KnowledgeFailure('ReadLeaseReleaseStillPending','embedding'); } this.progress('Released'); }
  config: EmbeddingConfig = new EmbeddingConfig(); detection: EmbeddingDetection = new EmbeddingDetection(); credentialReady: boolean = false;
  current: EmbeddingJob | undefined; message: string = ''; totalTokens: number = 0;
  review: EmbeddingDryReview = new EmbeddingDryReview(); completed: number = 0; expected: number = 0; progressStage: string = 'Idle';
  trialResult: EmbeddingTrialResult = new EmbeddingTrialResult();
  queryReceipt: EmbeddingQueryReceipt = new EmbeddingQueryReceipt();
  private listeners: KnowledgeStateListener[] = [];
  subscribe(listener: KnowledgeStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: KnowledgeStateListener): void { this.listeners = this.listeners.filter((item: KnowledgeStateListener): boolean => item !== listener); }
  private progress(stage: string): void { this.progressStage = stage; for (const listener of this.listeners) { listener.changed(); } }
  async baseline(): Promise<EmbeddingBaselineAcceptance> { return this.repository.baseline(this.config); }
  async acceptBaseline(): Promise<void> {
    if (this.config.modelId !== EmbeddingPinnedBasis.model || this.config.provider !== 'SiliconFlow' || this.config.mutationPending) { throw new KnowledgeFailure('BaselineModelOrConfigMismatch','baseline'); }
    const basis: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance(); basis.state = 'AcceptedEngineeringBaseline'; basis.configFingerprint = embeddingFingerprint(this.config); basis.configRevision = this.config.revision; basis.acceptedAt = Date.now(); await this.repository.saveBaseline(basis);
  }
  async dryReview(documentId: string): Promise<EmbeddingDryReview> {
    if (this.running || this.releasing) { throw new KnowledgeFailure('VectorJobBusyOrReleasing','review'); } this.running = true;
    const cancel: KnowledgeCancellation = new KnowledgeCancellation(); this.active = cancel; const epoch: number = this.epoch; let lease: KnowledgeReadLease | undefined;
    try {
      const document = await this.repository.document(documentId); const candidate: KnowledgeReadLease = new KnowledgeReadLease(); candidate.id = this.identity.id(); candidate.generation = document.activeContentGeneration; candidate.sourceId = document.sourceId; candidate.sessionId = this.session; await this.readers.acquireRead(candidate); lease = candidate;
      const plan = await this.repository.corpus(documentId); const review: EmbeddingDryReview = new EmbeddingDryReview(); review.documentId = documentId; review.generation = document.activeContentGeneration; review.snapshotHash = plan.snapshotHash; review.configFingerprint = embeddingFingerprint(this.config); review.model = this.config.modelId; review.baseline = await this.baseline(); this.expected = plan.inputs.length; this.completed = 0;
      const latestJobs = (await this.jobs()).filter((job: EmbeddingJob): boolean => job.documentId === documentId && job.contentGeneration === review.generation); const latest = latestJobs[latestJobs.length-1]; const attempts = latest === undefined ? [] : await this.repository.inputs(latest);
      for (const input of plan.inputs) { cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('ReviewCanceled','review'); } const proof = await this.evidence(input.chunk.embeddingText,'document',input.chunk.inputHash); const row: EmbeddingInputReview = new EmbeddingInputReview(); row.chunkId = input.chunk.id; row.ordinal = input.chunk.ordinal; row.hash = proof.textHash; row.bindingHash = proof.bindingHash; row.state = proof.localState; row.bound = proof.upperBound; row.eligible = embeddingLocalEligible(proof,this.config); if (row.state === 'SafeUnderPinnedProfile') { review.safe++; } else if (row.state === 'BoundUnproven') { review.unproven++; } else { review.invalid++; } if (row.eligible) { review.eligible++; } review.totalBound += Math.max(0,row.bound); review.maxBound = Math.max(review.maxBound,row.bound); review.rows.push(row); this.completed++; this.progress('CountingLocal'); }
      for (const row of review.rows) { row.attemptState = attempts.find((input: VectorInputRecord): boolean => input.chunk.id === row.chunkId)?.state ?? 'NotSent'; }
      review.setHash = await this.identity.hash(pdfCodecUtf8(JSON.stringify([review.documentId,review.generation,review.snapshotHash,review.configFingerprint,review.rows.map((row: EmbeddingInputReview): string => `${row.chunkId}|${row.hash}|${row.bindingHash}|${row.bound}|${row.state}`)]))); await this.repository.saveReview(review); this.review = review; this.progress('ReviewReadyNoNetwork'); return review;
    } finally { try { if (lease !== undefined) { await this.releaseLease(lease); } } finally { this.running = false; this.active = undefined; } }
  }
  async queryReview(text: string): Promise<TokenEligibilityEvidence> { return this.evidence(text,'query',await this.identity.hash(pdfCodecUtf8(text))); }
  async assertCurrentReview(documentId: string): Promise<void> {
    const plan = await this.repository.corpus(documentId); if (this.review.documentId !== documentId || this.review.generation !== plan.document.activeContentGeneration || this.review.snapshotHash !== plan.snapshotHash || this.review.configFingerprint !== embeddingFingerprint(this.config) || this.review.rows.length !== plan.inputs.length || this.review.eligible !== plan.inputs.length || plan.inputs.some((input: VectorInputRecord,index: number): boolean => input.chunk.id !== this.review.rows[index].chunkId || input.chunk.inputHash !== this.review.rows[index].hash)) { throw new KnowledgeFailure('CurrentInputReviewRequired','embedding'); }
  }
  constructor(repository: VectorWorkflowRepository, vectors: VectorWorkflowStorePort, transport: EmbeddingTransportPort, identity: KnowledgeIdentityPort, grants: EmbeddingWorkflowGrantPort, readers: KnowledgeSourceReadPort, session: string, counter?: EmbeddingTokenCounterPort) { this.repository = repository; this.vectors = vectors; this.transport = transport; this.identity = identity; this.grants = grants; this.readers = readers; this.session = session; this.counter = counter; }
  gate(): string { return this.counter === undefined ? 'InputLimitUnverified' : !this.credentialReady ? 'CredentialMissing' : this.detection.status !== EmbeddingDetectionStatus.Passed ? 'CurrentDetectionRequired' : 'RequiresReviewedScopeAndExplicitConsent'; }
  pause(): void { this.epoch++; if (this.active !== undefined) { this.active.invalid = true; } this.transport.cancel(); }
  async spaces(): Promise<EmbeddingSpace[]> { return this.repository.spaces(); }
  async jobs(): Promise<EmbeddingJob[]> { return this.repository.jobs(); }
  async jobsPage(offset: number, limit: number): Promise<EmbeddingJob[]> { if (this.repository.jobsPage === undefined) { throw new KnowledgeFailure('TaskPagingUnavailable','read'); } return this.repository.jobsPage(offset,limit); }
  async usage(): Promise<VectorUsageSummary> { return this.repository.usage(); }
  private async evidence(input: string, role: string, hash: string): Promise<TokenEligibilityEvidence> {
    if (this.counter === undefined) { throw new KnowledgeFailure('InputLimitUnverified','embedding-workflow'); }
    const proof = await this.counter.evidence(this.config.modelId,role,input,hash); proof.baseline = await this.baseline(); return proof;
  }
  private requireDetection(): void {
    if (!this.credentialReady || this.detection.status !== EmbeddingDetectionStatus.Passed || this.detection.configFingerprint !== embeddingFingerprint(this.config) || this.detection.credentialRevision !== this.config.credentialRevision || this.detection.requestedModel !== this.config.modelId || this.detection.returnedModel !== this.config.modelId || this.detection.dimension < 1) { throw new KnowledgeFailure('CurrentDetectionAndCredentialRequired','embedding-workflow'); }
  }
  private invalidateResponse(error: Error): void {
    if (error instanceof KnowledgeFailure && ['VectorModelMismatch','VectorResponseIdentity','QueryResponseIdentity','HttpRejected:400','HttpRejected:413','HttpRejected:422'].includes(error.category)) { this.detection.status = EmbeddingDetectionStatus.Failed; this.detection.failure = 'TokenOrModelContractRejected'; this.pause(); this.progress('ContractRejectedPaused'); }
  }
  private async space(sourceKind: string = 'Pdf'): Promise<EmbeddingSpace> {
    this.requireDetection(); const basis = await this.baseline(); if (!embeddingBaselineMatches(basis,this.config)) { throw new KnowledgeFailure('EngineeringBaselineNotAccepted','space'); }
    const space: EmbeddingSpace = new EmbeddingSpace(); space.id = this.identity.id(); space.provider = this.config.provider; space.region = this.config.region; space.access = this.config.access; space.workspaceId = this.config.workspaceId; space.configFingerprint = embeddingFingerprint(this.config); space.requestedModel = this.config.modelId; space.returnedModel = this.detection.returnedModel; space.dimension = this.detection.dimension; space.profileId = basis.profile; space.profileRevision = basis.revision; space.tokenizerSha256 = basis.tokenizer; space.profileParameters = basis.parameters; space.rolePair = 'SingleStringNoInventedPrefix'; space.detectionFingerprint = `${this.detection.probeHash}|${this.detection.dimension}`;
    if (sourceKind === 'Image') { space.preprocessing = 'IMAGE-EMBED-TEXT-1'; }
    space.fingerprint = await this.identity.hash(pdfCodecUtf8(JSON.stringify([space.provider,space.region,space.access,space.workspaceId,space.requestedModel,space.returnedModel,space.providerRevision,space.dimension,space.profileId,space.profileRevision,space.tokenizerSha256,space.profileParameters,space.preprocessing,space.rolePair,space.normalization,space.metric])));
    const existing = (await this.spaces()).find((item: EmbeddingSpace): boolean => item.fingerprint === space.fingerprint); return existing ?? space;
  }
  private grant(purpose: EmbeddingPurpose, space: EmbeddingSpace, free: boolean): EmbeddingGrant { const grant: EmbeddingGrant = new EmbeddingGrant(); grant.id = this.identity.id(); grant.purpose = purpose; grant.provider = this.config.provider; grant.configFingerprint = embeddingFingerprint(this.config); grant.credentialRevision = this.config.credentialRevision; grant.spaceId = space.id; grant.sessionId = this.session; grant.free = free ? EmbeddingFreeEligibility.Confirmed : EmbeddingFreeEligibility.Unknown; grant.issuedAt = Date.now(); grant.expiresAt = grant.issuedAt+EmbeddingBudget.windowMs; return grant; }
  async vectorize(documentId: string, consent: boolean, free: boolean, resumeId: string = '', resendUnknown: boolean = false, fullScope: boolean = false): Promise<void> {
    if (this.running || this.releasing) { throw new KnowledgeFailure('VectorJobBusy','embedding-workflow'); }
    if (!consent || !free) { throw new KnowledgeFailure('CorpusConsentRequired','embedding-workflow'); }
    this.current = undefined;
    this.running = true; const epoch: number = this.epoch; const cancel: KnowledgeCancellation = new KnowledgeCancellation(); cancel.deadline = Date.now()+EmbeddingBudget.windowMs; this.active = cancel;
    let lease: KnowledgeReadLease | undefined;
    try {
      this.requireDetection(); const document = await this.repository.document(documentId); cancel.check();
      const candidate: KnowledgeReadLease = new KnowledgeReadLease(); candidate.id = this.identity.id(); candidate.generation = document.activeContentGeneration; candidate.sourceId = document.sourceId; candidate.sessionId = this.session;
      await this.readers.acquireRead(candidate); lease = candidate; cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleVectorPreparation','embedding-workflow'); }
      await this.vectorizeLeased(documentId,free,resumeId,resendUnknown,fullScope,epoch,cancel);
    } finally { try { if (lease !== undefined) { await this.releaseLease(lease); } } finally { this.active = undefined; this.running = false; } }
  }
  private async vectorizeLeased(documentId: string, free: boolean, resumeId: string, resendUnknown: boolean, fullScope: boolean, epoch: number, cancel: KnowledgeCancellation): Promise<void> {
    this.requireDetection(); const plan: VectorCorpusPlan = await this.repository.corpus(documentId); if (plan.document.archived) { throw new KnowledgeFailure('ArchivedCorpusNotWritable','embedding-workflow'); } const space: EmbeddingSpace = await this.space(plan.document.sourceKind);
    const corpusPurpose: EmbeddingPurpose = plan.document.sourceKind === 'Image' ? EmbeddingPurpose.ImageCorpus : EmbeddingPurpose.Corpus;
    const grant: EmbeddingGrant = this.grant(corpusPurpose,space,free); grant.documentId = documentId; grant.generation = plan.document.activeContentGeneration; grant.snapshotHash = plan.snapshotHash;
    grant.expiresAt = Math.min(grant.expiresAt,cancel.deadline);
    for (const input of plan.inputs) { cancel.check(); const hash: string = await this.identity.hash(pdfCodecUtf8(input.chunk.embeddingText)); if (hash !== input.chunk.inputHash) { throw new KnowledgeFailure('CorpusInputHashMismatch','embedding-workflow'); } grant.inputHashes.push(hash); grant.inputEvidence.push(await this.evidence(input.chunk.embeddingText,'document',hash)); }
    const allHashes: string[] = grant.inputHashes.slice();
    const resumed = resumeId.length > 0 ? (await this.jobs()).find((item: EmbeddingJob): boolean => item.id === resumeId) : undefined;
    const previous = resumed === undefined ? [] : await this.repository.inputs(resumed);
    if (fullScope && (resumed === undefined || previous.filter((input: VectorInputRecord): boolean => input.state === VectorInputState.Verified).length < Math.min(3,plan.inputs.length))) { throw new KnowledgeFailure('SmallTrialRequiredBeforeFullScope','embedding'); }
    const selected: number[] = [];
    for (let at: number = 0; at < plan.inputs.length; at++) { if (previous.some((input: VectorInputRecord): boolean => input.chunk.id === plan.inputs[at].chunk.id && input.state === VectorInputState.Verified)) { continue; } if (fullScope || selected.length < 3) { selected.push(at); } }
    if (selected.length > 0) { const proofs = grant.inputEvidence; grant.inputEvidence = selected.map((at: number): TokenEligibilityEvidence => proofs[at]); grant.inputHashes = selected.map((at: number): string => allHashes[at]); }
    const selectedChunks: Set<string> = new Set<string>(selected.map((at: number): string => plan.inputs[at].chunk.id));
    grant.inputChunkIds = selected.map((at: number): string => plan.inputs[at].chunk.id);
    cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleVectorPreparation','embedding-workflow'); } embeddingAuthorize(this.config,grant,corpusPurpose);
    let job: EmbeddingJob | undefined;
    try {
      await this.grants.saveGrant(grant); cancel.check(); await this.vectors.open(); await this.vectors.register(space); await this.repository.saveSpace(space);
      if (resumeId.length > 0) { job = (await this.jobs()).find((item: EmbeddingJob): boolean => item.id === resumeId); if (job === undefined || job.documentId !== documentId || job.contentGeneration !== grant.generation || job.spaceId !== space.id || job.configFingerprint !== grant.configFingerprint || job.epoch !== plan.document.epoch) { throw new KnowledgeFailure('ResumeIdentityChanged','embedding-workflow'); }
        if (job.stage === EmbeddingJobStage.Retained || job.stage === EmbeddingJobStage.Retiring || job.stage === EmbeddingJobStage.Claimed) { throw new KnowledgeFailure('RetiredVectorCannotResume','embedding-workflow'); }
        if (plan.document.activeVectorGeneration === job.vectorGeneration && job.stage === EmbeddingJobStage.Ready) { await this.sync(documentId); await this.repository.releaseReservation(job.id); this.current = job; this.message = 'AlreadyPublishedMirrorReconciled'; return; }
      }
      else { job = new EmbeddingJob(); job.id = this.identity.id(); job.vectorGeneration = this.identity.id(); job.documentId = documentId; job.contentGeneration = grant.generation; job.snapshotHash = plan.snapshotHash; job.spaceId = space.id; job.epoch = plan.document.epoch; job.grantId = grant.id; job.configFingerprint = grant.configFingerprint; job.sessionId = this.session; job.windowStart = Date.now(); job.oldVectorGeneration = plan.document.activeVectorGeneration; job.expectedHashes = allHashes; await this.repository.reserve(job.id,plan.inputs.length*(space.dimension*8+8192)+1048576); await this.repository.begin(job,plan); }
      this.current = job;
      this.expected = job.expectedHashes.length; this.completed = job.completedHashes.length; this.progress('Preparing');
      await this.repository.bindGrant(job,grant);
      for (const input of await this.repository.inputs(job)) {
        cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleVectorWindow','embedding-workflow'); }
        if (input.state !== VectorInputState.NotSent) {
          const read = await this.vectors.read(space.id,input.chunk.id,job.vectorGeneration);
          if (read !== undefined) { await this.verify(job,input,read); this.completed = (await this.repository.inputs(job)).filter((row: VectorInputRecord): boolean => row.state === VectorInputState.Verified).length; this.progress('ReadbackVerified'); continue; }
          if (input.state === VectorInputState.Verified) { throw new KnowledgeFailure('VerifiedVectorMissing','embedding-workflow'); }
          if (!resendUnknown || resumeId.length === 0) { throw new KnowledgeFailure('UnknownSubmissionRequiresExplicitCostConfirmation','embedding-workflow'); }
          await this.repository.authorizeResend(job,input.chunk.id,grant); input.state = VectorInputState.NotSent;
        }
        if (!selectedChunks.has(input.chunk.id)) { await this.repository.pauseJob(job,'SmallScopeAwaitingNextExplicitGrant'); this.progress('SmallScopePaused'); return; }
        await this.repository.checkBudget(); await this.repository.inputState(job,input.chunk.id,VectorInputState.InFlight,''); cancel.check(); embeddingAuthorize(this.config,grant,corpusPurpose);
        this.progress('RequestInFlight');
        const started: number = Date.now();
        const requestCancel: KnowledgeCancellation = new KnowledgeCancellation(); requestCancel.deadline = Math.min(cancel.deadline,Date.now()+EmbeddingBudget.requestMs); this.active = requestCancel;
        const response: EmbeddingVectorResponse = await this.transport.embed(this.config,grant,corpusPurpose,input.chunk.embeddingText,requestCancel); this.active = cancel; requestCancel.check(); cancel.check();
        if (epoch !== this.epoch || response.model !== space.returnedModel || response.index !== 0 || response.vector.length !== space.dimension) { throw new KnowledgeFailure('VectorResponseIdentity','embedding-workflow'); }
        await this.repository.recordUsage(job,input.chunk.id,response.usage.totalTokens,response.usage.promptTokens);
        const numbers: number[] = []; for (const value of response.vector) { numbers.push(value); } const values: Float32Array = embeddingValidateVector(numbers,space.dimension);
        await this.repository.inputState(job,input.chunk.id,VectorInputState.Received,''); const row: KnowledgeVectorRow = new KnowledgeVectorRow(); row.chunkId = input.chunk.id; row.documentId = documentId; row.contentGeneration = job.contentGeneration; row.vectorGeneration = job.vectorGeneration; row.spaceId = space.id; row.inputHash = input.chunk.inputHash; row.epoch = job.epoch; row.values = values;
        await this.vectors.put(row); await this.repository.checkBudget(); const read = await this.vectors.read(space.id,row.chunkId,row.vectorGeneration); if (read === undefined) { throw new KnowledgeFailure('VectorReadbackMissing','embedding-workflow'); } await this.verify(job,input,read); response.vector.fill(0); if (response.usage.totalTokens !== undefined) { this.totalTokens += response.usage.totalTokens; }
        const receipt = new EmbeddingCorpusReceipt(); receipt.jobId = job.id; receipt.vectorGeneration = job.vectorGeneration; receipt.spaceId = space.id; receipt.chunkId = input.chunk.id; receipt.inputHash = input.chunk.inputHash; receipt.readbackHash = await this.identity.hash(vectorReadbackProjection(read)); receipt.bound = grant.inputEvidence.find((proof: TokenEligibilityEvidence): boolean => proof.textHash === receipt.inputHash)?.upperBound ?? -1; receipt.dimension = space.dimension; receipt.elapsed = Date.now()-started; receipt.total = response.usage.totalTokens ?? -1; receipt.prompt = response.usage.promptTokens ?? -1; receipt.grantId = grant.id; await this.repository.recordCorpusReceipt(receipt);
         this.completed = (await this.repository.inputs(job)).filter((row: VectorInputRecord): boolean => row.state === VectorInputState.Verified).length; this.progress('ReadbackVerified');
      }
      cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleVectorWindow','embedding-workflow'); }
      for (const input of await this.repository.inputs(job)) { const read = await this.vectors.read(space.id,input.chunk.id,job.vectorGeneration); if (read === undefined || await this.identity.hash(vectorReadbackProjection(read)) !== input.readbackHash) { throw new KnowledgeFailure('CoverageReadbackChanged','embedding-workflow'); } }
      await this.repository.checkBudget(); await this.repository.publish(job,allHashes); await this.sync(documentId); await this.repository.releaseReservation(job.id); job.stage = EmbeddingJobStage.Ready; this.message = 'SemanticReady'; this.progress('SemanticReady');
    } catch (error) { if (error instanceof Error) { this.invalidateResponse(error); } if (job !== undefined) { await this.repository.pauseJob(job,error instanceof KnowledgeFailure ? error.category : 'PlatformOrTransportFailed'); job.stage = EmbeddingJobStage.Paused; } if (error instanceof Error) { throw error; } throw new KnowledgeFailure('VectorWorkflowFailed','embedding-workflow'); }
  }
  private async verify(job: EmbeddingJob, input: VectorInputRecord, row: KnowledgeVectorRow): Promise<void> {
    if (row.documentId !== job.documentId || row.contentGeneration !== job.contentGeneration || row.vectorGeneration !== job.vectorGeneration || row.spaceId !== job.spaceId || row.inputHash !== input.chunk.inputHash || row.chunkId !== input.chunk.id || row.epoch !== job.epoch || row.eligible) { throw new KnowledgeFailure('VectorReadbackIdentity','embedding-workflow'); }
    await this.repository.inputState(job,input.chunk.id,VectorInputState.Verified,await this.identity.hash(vectorReadbackProjection(row)));
  }
  async trialScope(jobId: string): Promise<EmbeddingTrialScope> {
    this.requireDetection(); const job = (await this.jobs()).find((item: EmbeddingJob): boolean => item.id === jobId);
    if (job === undefined || job.configFingerprint !== embeddingFingerprint(this.config)) { throw new KnowledgeFailure('TrialJobConfigMismatch','trial-query'); }
    await this.repository.assertTrial(job); const inputs = await this.repository.inputs(job);
    if (inputs.length <= 3 || inputs.slice(0,3).some((input: VectorInputRecord): boolean => input.state !== VectorInputState.Verified) || inputs.slice(3).some((input: VectorInputRecord): boolean => input.state !== VectorInputState.NotSent)) { throw new KnowledgeFailure('TrialRequiresExactlyFirstThreeVerified','trial-query'); }
    const current = await this.space(); if (current.id !== job.spaceId) { throw new KnowledgeFailure('TrialSpaceMismatch','trial-query'); }
    const scope = new EmbeddingTrialScope(); scope.id = `trial-${job.id}`; scope.job = job; scope.space = current; scope.inputs = inputs.slice(0,3);
    await this.vectors.open();
    for (const input of scope.inputs) {
      const row = await this.vectors.read(current.id,input.chunk.id,job.vectorGeneration);
      if (row === undefined || row.spaceId !== job.spaceId || row.documentId !== job.documentId || row.contentGeneration !== job.contentGeneration || row.vectorGeneration !== job.vectorGeneration || row.chunkId !== input.chunk.id || row.inputHash !== input.chunk.inputHash || row.epoch !== job.epoch || row.eligible || row.values.length !== current.dimension || await this.identity.hash(vectorReadbackProjection(row)) !== input.readbackHash) { throw new KnowledgeFailure('TrialReadbackIdentityChanged','trial-query'); }
      const target = new VectorEligibility(); target.documentId = job.documentId; target.contentGeneration = job.contentGeneration; target.vectorGeneration = job.vectorGeneration; target.spaceId = current.id; target.epoch = job.epoch; target.chunkIds = [input.chunk.id]; target.inputHash = input.chunk.inputHash; target.readbackHash = input.readbackHash; scope.targets.push(target);
    }
    scope.setHash = await this.identity.hash(pdfCodecUtf8(JSON.stringify([scope.id,job.documentId,job.contentGeneration,job.snapshotHash,job.vectorGeneration,job.epoch,job.configFingerprint,current.fingerprint,scope.targets.map((target: VectorEligibility): string => `${target.chunkIds[0]}|${target.inputHash}|${target.readbackHash}`)])));
    return scope;
  }
  async trialQuery(jobId: string, question: string, consent: boolean, free: boolean, approval?: QueryConsentSnapshot): Promise<EmbeddingTrialResult> {
    if (this.running || this.releasing || !consent || !free) { throw new KnowledgeFailure('TrialQueryConsentOrBusy','trial-query'); }
    this.running = true; const cancel = new KnowledgeCancellation(); cancel.deadline = Date.now()+10000; this.active = cancel; const epoch: number = this.epoch; let lease: KnowledgeReadLease | undefined; let scope: EmbeddingTrialScope | undefined; let committed: boolean = false;
    const result = new EmbeddingTrialResult(); const started: number = Date.now();
    try {
      const initial = (await this.jobs()).find((job: EmbeddingJob): boolean => job.id === jobId); if (initial === undefined) { throw new KnowledgeFailure('TrialJobMissing','trial-query'); }
      const document = await this.repository.document(initial.documentId); const reading = new KnowledgeReadLease(); reading.id = this.identity.id(); reading.sourceId = document.sourceId; reading.generation = initial.contentGeneration; reading.sessionId = this.session; await this.readers.acquireRead(reading); lease = reading;
      scope = await this.trialScope(jobId); cancel.check(); const actual = prepareTextQuery(question); if (actual.actualInput !== question) { throw new KnowledgeFailure('TrialQueryMustUseExactReviewedInput','trial-query'); }
      result.trialId = scope.id; result.scopeHash = scope.setHash; result.expectedFull = scope.job.expectedHashes.length; result.queryHash = await this.identity.hash(pdfCodecUtf8(question));
      const proof = await this.evidence(question,'query',result.queryHash); result.bound = proof.upperBound;
      if (approval !== undefined) { this.assertQueryApproval(approval,question,proof,scope.space.id,'trial',scope.id,scope.setHash); }
      const grant = this.grant(EmbeddingPurpose.Query,scope.space,free); grant.expiresAt = Math.min(grant.expiresAt,cancel.deadline); grant.documentId = scope.job.documentId; grant.generation = scope.job.contentGeneration; grant.snapshotHash = scope.job.snapshotHash; grant.trialId = scope.id; grant.trialSetHash = scope.setHash; grant.scopeChunkIds = scope.targets.map((target: VectorEligibility): string => target.chunkIds[0]); grant.scopeInputHashes = scope.targets.map((target: VectorEligibility): string => target.inputHash); grant.inputHashes = [result.queryHash]; grant.inputEvidence = [proof]; result.grantId = grant.id;
      embeddingAuthorize(this.config,grant,EmbeddingPurpose.Query); cancel.check(); await this.grants.saveGrant(grant); await this.repository.beginTrialQuery(scope,grant); committed = true; cancel.check();
      const response = await this.transport.embed(this.config,grant,EmbeddingPurpose.Query,question,cancel); cancel.check(); if (epoch !== this.epoch || response.model !== scope.space.returnedModel || response.index !== 0 || response.vector.length !== scope.space.dimension) { throw new KnowledgeFailure('QueryResponseIdentity','trial-query'); }
      result.dimension = response.vector.length; result.usage = response.usage; const candidates = await this.vectors.trialKnn(scope.space,response.vector,scope.targets,cancel); response.vector.fill(0);
      for (const candidate of candidates) {
        const target = scope.targets.find((item: VectorEligibility): boolean => item.chunkIds[0] === candidate.row.chunkId); if (target === undefined || await this.identity.hash(vectorReadbackProjection(candidate.row)) !== target.readbackHash || candidate.row.eligible) { throw new KnowledgeFailure('TrialCandidateIdentityChanged','trial-query'); }
        const hit = await this.repository.trialHit(candidate.row.chunkId,scope); hit.vectorDistance = candidate.distance; result.vectorHits.push(hit);
      }
      for (const input of scope.inputs) { const hit = await this.repository.trialHit(input.chunk.id,scope); hit.spaceId = ''; hit.vectorGeneration = ''; hit.channels = [KnowledgeChannel.Keyword]; hit.keywordScore = textKeywordScore(hit.retrievalText,actual.terms); if (hit.keywordScore > 0) { result.keywordHits.push(hit); } }
      result.keywordHits.sort((a: KnowledgeHit,b: KnowledgeHit): number => b.keywordScore-a.keywordScore || a.id.localeCompare(b.id)); result.hits = knowledgeFuse(result.keywordHits,result.vectorHits); await this.repository.assertTrial(scope.job); cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('TrialQueryCanceled','trial-query'); }
      result.elapsed = Date.now()-started; result.notice = `试验范围 3/${result.expectedFull}，不是完整语义就绪；仅检索证据，未生成回答`; await this.repository.finishTrialQuery(scope.id,'Verified',result); this.trialResult = result; this.progress('TrialQueryVerified'); return result;
    } catch (error) { if (committed && scope !== undefined) { await this.repository.finishTrialQuery(scope.id,'UnknownOrFailed',result); } if (error instanceof Error) { this.invalidateResponse(error); throw error; } throw new KnowledgeFailure('TrialQueryFailed','trial-query'); }
    finally { try { if (lease !== undefined) { await this.releaseLease(lease); } } finally { this.active = undefined; this.running = false; } }
  }
  async sync(documentId: string): Promise<void> {
    const target = await this.repository.eligibility(documentId); if (target === undefined) { return; }
    await this.vectors.open(); const job = (await this.jobs()).find((item: EmbeddingJob): boolean => item.vectorGeneration === target.vectorGeneration && item.contentGeneration === target.contentGeneration && item.spaceId === target.spaceId);
    if (job === undefined) { throw new KnowledgeFailure('MirrorJobMissing','mirror'); }
    const inputs = await this.repository.inputs(job);
    for (const input of inputs) { const read = await this.vectors.read(target.spaceId,input.chunk.id,target.vectorGeneration); if (read === undefined || read.documentId !== documentId || read.contentGeneration !== target.contentGeneration || read.inputHash !== input.chunk.inputHash || await this.identity.hash(vectorReadbackProjection(read)) !== input.readbackHash || input.state !== VectorInputState.Verified) { throw new KnowledgeFailure('MirrorCoverageReadbackChanged','mirror'); } }
    await this.vectors.synchronize(target);
    for (const input of inputs) { const read = await this.vectors.read(target.spaceId,input.chunk.id,target.vectorGeneration); if (read === undefined || !read.eligible || read.epoch !== target.epoch || await this.identity.hash(vectorReadbackProjection(read)) !== input.readbackHash) { throw new KnowledgeFailure('MirrorEligibilityReadbackChanged','mirror'); } }
    await this.repository.acknowledge(target);
  }
  async restoreActive(documentId: string): Promise<void> {
    const document = await this.repository.document(documentId); if (document.activeVectorGeneration.length === 0) { return; }
    const lease = new KnowledgeReadLease(); lease.id = this.identity.id(); lease.sourceId = document.sourceId; lease.generation = document.activeContentGeneration; lease.sessionId = this.session;
    await this.readers.acquireRead(lease); try { await this.sync(documentId); } finally { await this.releaseLease(lease); }
  }
  async search(input: string, spaceId: string, consent: boolean, free: boolean, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    if (this.running || this.releasing) { throw new KnowledgeFailure('VectorJobBusy','query'); }
    this.running = true; this.active = cancel;
    try { const hits = await this.searchWindow(input,spaceId,consent,free,archived,extras,cancel); cancel.check(); return hits; }
    catch (error) { if (error instanceof Error) { this.invalidateResponse(error); throw error; } throw new KnowledgeFailure('QueryContractFailed','query'); }
    finally { this.active = undefined; this.running = false; }
  }
  private assertQueryApproval(approval: QueryConsentSnapshot,input: string,proof: TokenEligibilityEvidence,space: string,purpose: string,trial: string = '',scopeHash: string = ''): void {
    if (!approval.approved || !approval.free || approval.actual !== input || approval.inputHash !== proof.textHash || approval.bindingHash !== proof.bindingHash || approval.role !== 'query' || approval.purpose !== purpose || approval.space !== space || approval.config !== embeddingFingerprint(this.config) || approval.trial !== trial || approval.scopeHash !== scopeHash || !embeddingLocalEligible(proof,this.config)) { throw new KnowledgeFailure('NoRequestQuerySnapshotChanged','query'); }
  }
  async searchReviewed(approval: QueryConsentSnapshot,archived: boolean,extras: boolean,cancel: KnowledgeCancellation): Promise<KnowledgeHit[]> {
    if (this.running || this.releasing) { throw new KnowledgeFailure('VectorJobBusy','query'); } this.running = true; this.active = cancel;
    try { const hits = await this.searchWindow(approval.actual,approval.space,approval.approved,approval.free,archived,extras,cancel,approval); cancel.check(); return hits; }
    catch (error) { this.queryEgress = this.transport.queryEgress ?? false; if (error instanceof Error) { this.invalidateResponse(error); if (this.detection.status === EmbeddingDetectionStatus.Failed) { approval.approved = false; approval.free = false; } throw error; } throw new KnowledgeFailure('QueryContractFailed','query'); }
    finally { this.active = undefined; this.running = false; }
  }
  private async searchWindow(input: string, spaceId: string, consent: boolean, free: boolean, archived: boolean, extras: boolean, cancel: KnowledgeCancellation, approval?: QueryConsentSnapshot): Promise<KnowledgeHit[]> {
    this.queryEgress = false;
    const epoch: number = this.epoch;
    const started: number = Date.now();
    if (!consent || !free) { throw new KnowledgeFailure('QueryConsentOff','query'); } this.requireDetection();
    const space = (await this.spaces()).find((item: EmbeddingSpace): boolean => item.id === spaceId); const current = await this.space(space?.preprocessing === 'IMAGE-EMBED-TEXT-1' ? 'Image' : 'Pdf'); if (space === undefined || current.fingerprint !== space.fingerprint || current.id !== spaceId) { throw new KnowledgeFailure('QuerySpaceMismatch','query'); }
    const grant: EmbeddingGrant = this.grant(EmbeddingPurpose.Query,space,free); grant.expiresAt = Math.min(grant.expiresAt,cancel.deadline); const hash: string = await this.identity.hash(pdfCodecUtf8(input)); grant.inputHashes = [hash]; grant.inputEvidence = [await this.evidence(input,'query',hash)]; embeddingAuthorize(this.config,grant,EmbeddingPurpose.Query); cancel.check();
    const targets: VectorEligibility[] = await this.repository.targets(spaceId,archived,extras); if (targets.length === 0) { throw new KnowledgeFailure('NoSyncedVectorAuthority','query'); }
    cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQueryPreparation','query'); }
    const leases: KnowledgeReadLease[] = [];
    try {
      for (const target of targets) { cancel.check(); if (leases.some((lease: KnowledgeReadLease): boolean => lease.generation === target.contentGeneration)) { continue; } const document = await this.repository.document(target.documentId); const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = this.identity.id(); lease.sourceId = document.sourceId; lease.generation = target.contentGeneration; lease.sessionId = this.session; await this.readers.acquireRead(lease); leases.push(lease); }
      if (approval === undefined || approval.scopeHash.length !== 64) { throw new KnowledgeFailure('NoRequestScopeBoundApprovalRequired','query'); }
      this.assertQueryApproval(approval,input,grant.inputEvidence[0],spaceId,'query','',approval.scopeHash); grant.queryApproval = approval;
      await this.grants.saveGrant(grant); cancel.check(); this.active = cancel; const response = await this.transport.embed(this.config,grant,EmbeddingPurpose.Query,input,cancel); this.queryEgress = this.transport.queryEgress ?? false; cancel.check(); if (epoch !== this.epoch || response.model !== space.returnedModel || response.index !== 0 || response.vector.length !== space.dimension) { throw new KnowledgeFailure('QueryResponseIdentity','query'); }
      await this.vectors.open(); const candidates: KnowledgeVectorCandidate[] = await this.vectors.filteredKnn(space,response.vector,targets,cancel); response.vector.fill(0); const hits: KnowledgeHit[] = [];
      for (const candidate of candidates) { cancel.check(); const target = targets.find((item: VectorEligibility): boolean => item.chunkIds[0] === candidate.row.chunkId && item.vectorGeneration === candidate.row.vectorGeneration && item.documentId === candidate.row.documentId && item.contentGeneration === candidate.row.contentGeneration && item.epoch === candidate.row.epoch && item.inputHash === candidate.row.inputHash); if (target === undefined) { continue; } if (await this.identity.hash(vectorReadbackProjection(candidate.row)) !== target.readbackHash) { throw new KnowledgeFailure('QueryVectorReadbackCorrupted','query'); } const hit = await this.repository.hit(candidate.row.chunkId,target,archived,extras); cancel.check(); if (hit !== undefined) { hit.vectorDistance = candidate.distance; hits.push(hit); } }
      const receipt = new EmbeddingQueryReceipt(); receipt.hash = hash; receipt.grant = grant.id; receipt.space = space.id; receipt.bound = grant.inputEvidence[0].upperBound; receipt.dimension = space.dimension; receipt.elapsed = Date.now()-started; receipt.total = response.usage.totalTokens ?? -1; receipt.prompt = response.usage.promptTokens ?? -1; receipt.targets = targets.length; receipt.candidates = hits.length; this.queryReceipt = receipt; return hits;
    } finally { let failure: boolean = false; for (const lease of leases) { try { await this.releaseLease(lease); } catch { failure = true; } } this.active = undefined; if (failure) { throw new KnowledgeFailure('QueryLeaseReleaseUnconfirmed','query'); } cancel.check(); if (epoch !== this.epoch) { throw new KnowledgeFailure('StaleQueryRelease','query'); } }
  }
}
