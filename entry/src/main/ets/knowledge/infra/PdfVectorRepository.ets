import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { EmbeddingSpace, EmbeddingJob, EmbeddingJobStage, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, EmbeddingConfig } from '../domain/EmbeddingModels';
import { EmbeddingBaselineAcceptance, EmbeddingDryReview } from '../domain/EmbeddingBasisModels';
import { embeddingConfigBinding, embeddingBaselineMatches } from '../pipeline/EmbeddingBasisPolicy';
import { KnowledgeFailure, KnowledgeCancellation, PdfChunk, PdfBudget, PdfKnowledgeDocument, KnowledgeReadLease } from '../domain/PdfKnowledgeModels';
import { VectorWorkflowRepository, VectorCorpusPlan, VectorInputRecord, VectorInputState, VectorEligibility, VectorUsageSummary } from '../domain/VectorWorkflowModels';
import { KnowledgeHit, KnowledgeSourceKind, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { embeddingSpaceDecode } from '../pipeline/EmbeddingSpacePolicy';
import { BoundedDocumentJson } from '../pipeline/BoundedDocumentJson';
import { pdfCodecUtf8, pdfDecodeLocators } from '../pipeline/PdfSnapshotCodec';
import { PdfRepositoryPort } from '../domain/KnowledgePorts';
import { KnowledgePhysicalBudgetPort } from './KnowledgeDerivedBudget';
import { EmbeddingTrialMetadataPort, EmbeddingTrialScope, EmbeddingTrialResult, EmbeddingCorpusReceipt } from '../domain/VectorWorkflowModels';

export class PdfVectorRepository implements VectorWorkflowRepository, EmbeddingTrialMetadataPort {
  private host: KnowledgeStoreHost; private documents: PdfRepositoryPort;
  constructor(host: KnowledgeStoreHost, documents: PdfRepositoryPort) { this.host = host; this.documents = documents; }
  private physical: KnowledgePhysicalBudgetPort | undefined;
  private budgetLimit: number = PdfBudget.derivedBytes;
  testBudgetLimit(owner: string, bytes: number): void { this.host.storageScope.requireTestOwner(owner); if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > PdfBudget.derivedBytes) { throw new KnowledgeFailure('TestBudgetInvalid','test'); } this.budgetLimit = bytes; }
  private fault: string = '';
  injectFault(owner: string, stage: string): void { this.host.storageScope.requireTestOwner(owner); if (['Publish','PublishAck','Acknowledge'].indexOf(stage) < 0) { throw new KnowledgeFailure('FaultStageInvalid','test'); } this.fault = stage; }
  private boundary(stage: string): void { if (this.fault === stage) { this.fault = ''; throw new KnowledgeFailure(`Injected${stage}`,'vector-test'); } }
  attachPhysical(port: KnowledgePhysicalBudgetPort): void { this.physical = port; }
  async bootstrap(): Promise<void> {
    const rows = await this.store().querySql('SELECT state FROM kb_migration WHERE id=?',['KB-PDF-VECTOR-1']); try { if (!rows.goToNextRow() || rows.getString(0) !== 'Committed') { throw new KnowledgeFailure('VectorMetadataMigrationRequired','vector-open'); } } finally { rows.close(); }
  }
  private store(): relationalStore.RdbStore { if (!this.documents.ready()) { throw new KnowledgeFailure('VectorMetadataUnavailable','vector-job'); } return this.host.requireStore(); }
  async saveBaseline(basis: EmbeddingBaselineAcceptance): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('INSERT OR REPLACE INTO r2v_baseline VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',[basis.configFingerprint,basis.model,basis.profile,basis.revision,basis.tokenizer,basis.weights,basis.metadata,basis.parameters,basis.policy,basis.configRevision,basis.acceptedAt,basis.providerRevision,basis.providerConsistency]); });
  }
  async baseline(config: EmbeddingConfig): Promise<EmbeddingBaselineAcceptance> {
    const basis: EmbeddingBaselineAcceptance = new EmbeddingBaselineAcceptance(); const rows = await this.store().querySql('SELECT * FROM r2v_baseline WHERE fingerprint=?',[embeddingConfigBinding(config)]);
    try { if (rows.goToNextRow()) { basis.configFingerprint = rows.getString(0); basis.model = rows.getString(1); basis.profile = rows.getString(2); basis.revision = rows.getString(3); basis.tokenizer = rows.getString(4); basis.weights = rows.getString(5); basis.metadata = rows.getString(6); basis.parameters = rows.getString(7); basis.policy = rows.getString(8); basis.configRevision = rows.getLong(9); basis.acceptedAt = rows.getLong(10); basis.providerRevision = rows.getString(11); basis.providerConsistency = rows.getString(12); basis.state = 'AcceptedEngineeringBaseline'; } } finally { rows.close(); }
    if (basis.state !== 'NotAccepted' && !embeddingBaselineMatches(basis,config)) { throw new KnowledgeFailure('BaselineStoredIdentityMismatch','baseline'); } return basis;
  }
  async releaseFailure(lease: KnowledgeReadLease, failure: string): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { if (failure.length === 0) { await this.store().executeSql('DELETE FROM r2v_release WHERE id=?',[lease.id]); } else { await this.store().executeSql('INSERT OR REPLACE INTO r2v_release VALUES(?,?,?,?)',[lease.id,lease.sessionId,lease.generation,failure]); } }); }
  async saveReview(review: EmbeddingDryReview): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const doc = await tx.querySql('SELECT id FROM kb_document WHERE id=? AND active_content=? AND tombstone=0',[review.documentId,review.generation]); try { if (!doc.goToNextRow()) { throw new KnowledgeFailure('ReviewSourceChanged','review'); } } finally { doc.close(); }
      await tx.execute('DELETE FROM r2v_review WHERE doc=?',[review.documentId]);
      for (const row of review.rows) { await tx.execute('INSERT INTO r2v_review VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',[review.setHash,review.documentId,review.generation,review.snapshotHash,review.configFingerprint,row.ordinal,row.chunkId,row.hash,row.bindingHash,row.state,row.bound,row.eligible ? 1 : 0,row.attemptState]); }
    }); });
  }
  async pendingReleases(session: string): Promise<KnowledgeReadLease[]> { const rows = await this.store().querySql('SELECT id,generation,session FROM r2v_release WHERE session=?',[session]); const result: KnowledgeReadLease[] = []; try { while (rows.goToNextRow()) { const lease: KnowledgeReadLease = new KnowledgeReadLease(); lease.id = rows.getString(0); lease.generation = rows.getString(1); lease.sessionId = rows.getString(2); result.push(lease); } } finally { rows.close(); } return result; }
  async document(documentId: string): Promise<PdfKnowledgeDocument> { const document = await this.documents.get(documentId); if (document === undefined || document.tombstone || document.activeContentGeneration.length === 0) { throw new KnowledgeFailure('CorpusUnavailable','vector-job'); } return document; }
  async assertTrial(job: EmbeddingJob): Promise<void> {
    const rows = await this.store().querySql('SELECT v.expected,v.state FROM kb_vector_generation v JOIN kb_document d ON d.id=v.doc JOIN kb_content_generation g ON g.id=v.content_generation WHERE v.job=? AND v.id=? AND v.space=? AND v.content_generation=? AND v.epoch=? AND v.cleanup_claim=? AND d.id=? AND d.active_content=v.content_generation AND d.epoch=v.epoch AND d.tombstone=0 AND d.archived=0 AND d.active_vector=? AND g.state=? AND g.cleanup_claim=?',[job.id,job.vectorGeneration,job.spaceId,job.contentGeneration,job.epoch,'',job.documentId,'','Active','']);
    try { if (!rows.goToNextRow() || rows.getLong(0) <= 3 || !['Paused','Preparing','PartialStaged'].includes(rows.getString(1))) { throw new KnowledgeFailure('TrialSourceEpochOrStateChanged','trial-query'); } } finally { rows.close(); }
  }
  async trialHit(chunkId: string, scope: EmbeddingTrialScope): Promise<KnowledgeHit> {
    await this.assertTrial(scope.job); const target = scope.targets.find((item: VectorEligibility): boolean => item.chunkIds[0] === chunkId); if (target === undefined) { throw new KnowledgeFailure('TrialHitOutsideScope','trial-query'); }
    const rows = await this.store().querySql('SELECT c.*,a.state,a.readback_hash FROM kb_chunk c JOIN kb_input_attempt a ON a.chunk=c.id AND a.generation=? WHERE c.id=? AND c.doc=? AND c.generation=? AND c.input_hash=? AND c.snapshot_hash=? AND a.input_hash=c.input_hash AND a.owner=?',[scope.job.vectorGeneration,chunkId,scope.job.documentId,scope.job.contentGeneration,target.inputHash,scope.job.snapshotHash,scope.job.id]);
    try { if (!rows.goToNextRow() || rows.getString(14) !== VectorInputState.Verified || rows.getString(15) !== target.readbackHash) { throw new KnowledgeFailure('TrialHitReadbackChanged','trial-query'); } const hit = new KnowledgeHit(); hit.id = 'pdf:'+chunkId; hit.chunkId = chunkId; hit.documentId = scope.job.documentId; hit.generation = scope.job.contentGeneration; hit.snapshotId = rows.getString(3); hit.snapshotHash = rows.getString(4); hit.originalHash = rows.getString(5); hit.originalVersion = rows.getLong(6); hit.retrievalText = rows.getString(9); hit.text = rows.getString(10); hit.epoch = scope.job.epoch; hit.spaceId = scope.space.id; hit.vectorGeneration = scope.job.vectorGeneration; hit.sourceKind = KnowledgeSourceKind.Pdf; hit.channels = [KnowledgeChannel.Vector]; hit.locator.kind = KnowledgeSourceKind.Pdf; hit.locator.pdfRegions = pdfDecodeLocators(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(12)),new KnowledgeCancellation()).read()); return hit; } finally { rows.close(); }
  }
  async beginTrialQuery(scope: EmbeddingTrialScope, grant: EmbeddingGrant): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertTrial(scope.job); if (grant.trialId !== scope.id || grant.trialSetHash !== scope.setHash || grant.scopeChunkIds.length !== 3 || grant.inputHashes.length !== 1) { throw new KnowledgeFailure('TrialQueryGrantScopeMismatch','trial-query'); }
      const rows = await tx.querySql('SELECT id FROM kb_embedding_grant WHERE id=? AND purpose=? AND fingerprint=? AND credential_revision=? AND space=? AND doc=? AND generation=? AND snapshot_hash=? AND revoked=0 AND free=? AND expires>?',[grant.id,EmbeddingPurpose.Query,scope.job.configFingerprint,grant.credentialRevision,scope.space.id,scope.job.documentId,scope.job.contentGeneration,scope.job.snapshotHash,EmbeddingFreeEligibility.Confirmed,Date.now()]); try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('TrialQueryDurableGrantMissing','trial-query'); } } finally { rows.close(); }
      await tx.execute('INSERT INTO r2v_trial_query VALUES(?,?,?,?,?,?,?,?,?)',[scope.id,scope.setHash,grant.id,grant.inputHashes[0],scope.job.id,scope.job.vectorGeneration,scope.space.id,'InFlight','']);
    }); });
  }
  async finishTrialQuery(trialId: string, stage: string, result: EmbeddingTrialResult): Promise<void> {
    const safe: string = JSON.stringify([result.queryHash,result.scopeHash,result.bound,result.dimension,result.elapsed,result.usage,result.vectorHits.map((hit: KnowledgeHit): string => `${hit.chunkId}|${hit.vectorDistance}`)]);
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('UPDATE r2v_trial_query SET state=?,result=? WHERE trial=? AND state=?',[stage,safe,trialId,'InFlight']); });
  }
  async recordCorpusReceipt(item: EmbeddingCorpusReceipt): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('INSERT INTO r2v_rpc_receipt VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',[item.jobId,item.vectorGeneration,item.spaceId,item.chunkId,item.inputHash,item.readbackHash,item.bound,item.dimension,item.elapsed,item.total,item.prompt,item.grantId]); });
  }
  private async assertJob(tx: relationalStore.Transaction, job: EmbeddingJob): Promise<void> {
    const rows = await tx.querySql('SELECT v.id FROM kb_vector_generation v JOIN kb_document d ON d.id=v.doc JOIN kb_content_generation g ON g.id=v.content_generation WHERE v.id=? AND v.job=? AND v.doc=? AND v.content_generation=? AND v.space=? AND v.epoch=? AND v.cleanup_claim=? AND v.state IN (?,?,?,?,?) AND d.epoch=? AND d.tombstone=0 AND d.archived=0 AND d.active_content=v.content_generation AND g.state=? AND g.cleanup_claim=?',[job.vectorGeneration,job.id,job.documentId,job.contentGeneration,job.spaceId,job.epoch,'','Preparing','Paused','PartialStaged','ValidatingReadback','SemanticReady',job.epoch,'Active','']);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('VectorJobStaleOrClaimed','vector-job'); } } finally { rows.close(); }
    const grant = await tx.querySql('SELECT g.id FROM kb_embedding_grant g JOIN r2v_job j ON j.grant_id=g.id WHERE j.id=? AND g.purpose=? AND g.fingerprint=? AND g.doc=? AND g.generation=? AND g.snapshot_hash=? AND g.space=? AND g.session=? AND g.free=? AND g.revoked=0 AND g.expires>?',[job.id,EmbeddingPurpose.Corpus,job.configFingerprint,job.documentId,job.contentGeneration,job.snapshotHash,job.spaceId,job.sessionId,EmbeddingFreeEligibility.Confirmed,Date.now()]);
    try { if (!grant.goToNextRow()) { throw new KnowledgeFailure('VectorDurableGrantExpiredOrRevoked','vector-job'); } } finally { grant.close(); }
  }
  async bindGrant(job: EmbeddingJob, grant: EmbeddingGrant): Promise<void> {
    if (grant.documentId !== job.documentId || grant.generation !== job.contentGeneration || grant.snapshotHash !== job.snapshotHash || grant.spaceId !== job.spaceId || grant.configFingerprint !== job.configFingerprint) { throw new KnowledgeFailure('ResumeGrantIdentity','vector-job'); }
    job.grantId = grant.id; job.sessionId = grant.sessionId;
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('UPDATE r2v_job SET grant_id=?,session=?,window=? WHERE id=?',[grant.id,grant.sessionId,Date.now(),job.id]); });
  }
  async authorizeResend(job: EmbeddingJob, chunk: string, grant: EmbeddingGrant): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); if (job.grantId !== grant.id || grant.sessionId !== job.sessionId) { throw new KnowledgeFailure('ResendGrantMismatch','resume'); }
      const rows = await tx.querySql('SELECT state,input_hash FROM kb_input_attempt WHERE generation=? AND chunk=? AND owner=?',[job.vectorGeneration,chunk,job.id]);
      try { if (!rows.goToNextRow() || (rows.getString(0) !== VectorInputState.Unknown && rows.getString(0) !== VectorInputState.Received && rows.getString(0) !== VectorInputState.InFlight) || !grant.inputHashes.includes(rows.getString(1))) { throw new KnowledgeFailure('UnknownResendStateMismatch','resume'); } } finally { rows.close(); }
      await tx.execute('INSERT INTO r2v_resend VALUES(?,?,?,?)',[job.vectorGeneration,chunk,grant.id,Date.now()]);
      await tx.execute('UPDATE kb_input_attempt SET state=? WHERE generation=? AND chunk=?',[VectorInputState.NotSent,job.vectorGeneration,chunk]);
    }); });
  }
  async recordUsage(job: EmbeddingJob, chunk: string, total: number | undefined, prompt: number | undefined): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('INSERT INTO r2v_usage VALUES(?,?,?,?,?,?)',[job.vectorGeneration,chunk,job.grantId,total ?? null,prompt ?? null,Date.now()]); });
  }
  async usage(): Promise<VectorUsageSummary> {
    const summary: VectorUsageSummary = new VectorUsageSummary(); const rows = await this.store().querySql('SELECT count(*),coalesce(sum(total),0),coalesce(sum(CASE WHEN total IS NULL THEN 1 ELSE 0 END),0),(SELECT count(*) FROM kb_input_attempt WHERE state=?) FROM r2v_usage',[VectorInputState.Unknown]);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('UsageReadFailed','usage'); } summary.received = rows.getLong(0); summary.reportedTotal = rows.getLong(1); summary.missingUsage = rows.getLong(2); summary.unknown = rows.getLong(3); } finally { rows.close(); } return summary;
  }
  async corpus(documentId: string): Promise<VectorCorpusPlan> {
    const document = await this.documents.get(documentId);
    if (document === undefined || document.tombstone || document.activeContentGeneration.length === 0) { throw new KnowledgeFailure('CorpusUnavailable','vector-job'); }
    const plan: VectorCorpusPlan = new VectorCorpusPlan(); plan.document = document;
    const rows = await this.store().querySql('SELECT * FROM kb_chunk WHERE doc=? AND generation=? ORDER BY ordinal,id',[documentId,document.activeContentGeneration]);
    try { while (rows.goToNextRow()) { const input: VectorInputRecord = new VectorInputRecord(); const chunk = input.chunk; chunk.id = rows.getString(0); chunk.documentId = rows.getString(1); chunk.generation = rows.getString(2); chunk.snapshotId = rows.getString(3); chunk.snapshotHash = rows.getString(4); chunk.originalHash = rows.getString(5); chunk.originalVersion = rows.getLong(6); chunk.ordinal = rows.getLong(7); chunk.retrievalText = rows.getString(9); chunk.embeddingText = chunk.retrievalText; chunk.text = rows.getString(10); chunk.inputHash = rows.getString(11); chunk.defaultIncluded = rows.getLong(13) === 1;
      if (plan.inputs.length >= PdfBudget.documentChunks || (plan.inputs.length > 0 && plan.snapshotHash !== chunk.snapshotHash)) { throw new KnowledgeFailure('CorpusSetInvalid','vector-job'); } plan.snapshotHash = chunk.snapshotHash; plan.inputs.push(input);
    } } finally { rows.close(); }
    if (plan.inputs.length !== document.chunkCount || plan.inputs.length < 1) { throw new KnowledgeFailure('CorpusCoverageMismatch','vector-job'); } return plan;
  }
  async spaces(): Promise<EmbeddingSpace[]> {
    const rows = await this.store().querySql('SELECT wire FROM r2v_space s WHERE EXISTS (SELECT 1 FROM kb_vector_generation v WHERE v.space=s.id) ORDER BY id'); const result: EmbeddingSpace[] = [];
    try { while (rows.goToNextRow()) { result.push(embeddingSpaceDecode(rows.getString(0))); if (result.length > 1000) { throw new KnowledgeFailure('SpaceBudget','vector-job'); } } } finally { rows.close(); } return result;
  }
  async saveSpace(space: EmbeddingSpace): Promise<void> {
    const checked: EmbeddingSpace = embeddingSpaceDecode(JSON.stringify(space));
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const old = await tx.querySql('SELECT wire FROM r2v_space WHERE id=?',[space.id]); let exists: boolean = false;
      try { if (old.goToNextRow()) { exists = true; if (old.getString(0) !== JSON.stringify(checked)) { throw new KnowledgeFailure('SpaceIdentityConflict','vector-job'); } } } finally { old.close(); }
      if (!exists) { await tx.execute('INSERT INTO r2v_space VALUES(?,?)',[space.id,JSON.stringify(checked)]); }
    }); });
  }
  async begin(job: EmbeddingJob, plan: VectorCorpusPlan): Promise<void> {
    if (plan.inputs.length < 1 || job.expectedHashes.length !== plan.inputs.length || job.snapshotHash !== plan.snapshotHash || new Set<string>(plan.inputs.map((input: VectorInputRecord): string => input.chunk.id)).size !== plan.inputs.length) { throw new KnowledgeFailure('VectorExpectedSetInvalid','vector-job'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const doc = await tx.querySql('SELECT id FROM kb_document WHERE id=? AND epoch=? AND active_content=? AND active_vector=? AND tombstone=0 AND archived=0',[job.documentId,job.epoch,job.contentGeneration,job.oldVectorGeneration]);
      try { if (!doc.goToNextRow()) { throw new KnowledgeFailure('VectorSourceChanged','vector-job'); } } finally { doc.close(); }
      await tx.execute('INSERT INTO kb_vector_generation VALUES(?,?,?,?,?,?,?,?,?,?,?)',[job.vectorGeneration,job.documentId,job.contentGeneration,job.spaceId,job.id,job.epoch,'Preparing',plan.inputs.length,0,0,'']);
      await tx.execute('INSERT INTO r2v_job VALUES(?,?,?,?,?,?,?,?,?)',[job.id,job.vectorGeneration,job.snapshotHash,job.oldVectorGeneration,job.grantId,job.configFingerprint,job.sessionId,job.windowStart,'']);
      for (let at: number = 0; at < plan.inputs.length; at++) {
        const chunk: PdfChunk = plan.inputs[at].chunk; if (job.expectedHashes[at] !== chunk.inputHash || !new RegExp('^[a-f0-9]{64}$').test(chunk.inputHash)) { throw new KnowledgeFailure('VectorInputIdentity','vector-job'); }
        const source = await tx.querySql('SELECT id FROM kb_chunk WHERE id=? AND generation=? AND doc=? AND input_hash=? AND snapshot_hash=? AND text=?',[chunk.id,job.contentGeneration,job.documentId,chunk.inputHash,job.snapshotHash,chunk.embeddingText]);
        try { if (!source.goToNextRow()) { throw new KnowledgeFailure('VectorSourceInputChanged','vector-job'); } } finally { source.close(); }
        await tx.execute('INSERT INTO kb_vector_input VALUES(?,?,?,?)',[job.vectorGeneration,chunk.id,chunk.inputHash,'']);
        await tx.execute('INSERT INTO kb_input_attempt VALUES(?,?,?,?,?,?)',[job.vectorGeneration,chunk.id,chunk.inputHash,VectorInputState.NotSent,'',job.id]);
      }
    }); });
  }
  async jobs(offset: number = 0, limit: number = 10000): Promise<EmbeddingJob[]> {
    if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 10000) { throw new KnowledgeFailure('VectorJobPageBudget','read'); }
    const rows = await this.store().querySql('SELECT v.*,j.* FROM kb_vector_generation v JOIN r2v_job j ON j.vector=v.id ORDER BY j.id LIMIT ? OFFSET ?',[limit,offset]); const jobs: EmbeddingJob[] = [];
    try { while (rows.goToNextRow()) { const job: EmbeddingJob = new EmbeddingJob(); job.vectorGeneration = rows.getString(0); job.documentId = rows.getString(1); job.contentGeneration = rows.getString(2); job.spaceId = rows.getString(3); job.id = rows.getString(4); job.epoch = rows.getLong(5); const stage = [EmbeddingJobStage.Preparing,EmbeddingJobStage.Partial,EmbeddingJobStage.Readback,EmbeddingJobStage.Ready,EmbeddingJobStage.Paused,EmbeddingJobStage.Failed,EmbeddingJobStage.Retained,EmbeddingJobStage.Retiring,EmbeddingJobStage.Claimed].find((value: EmbeddingJobStage): boolean => value === rows.getString(6)); if (stage === undefined) { throw new KnowledgeFailure('VectorJobStageUnknown','read'); } job.stage = stage; job.snapshotHash = rows.getString(13); job.oldVectorGeneration = rows.getString(14); job.grantId = rows.getString(15); job.configFingerprint = rows.getString(16); job.sessionId = rows.getString(17); job.windowStart = rows.getLong(18); job.failure = rows.getString(19); jobs.push(job); if (jobs.length > 10000) { throw new KnowledgeFailure('VectorJobBudget','vector-job'); } } } finally { rows.close(); }
    for (const job of jobs) { const inputs = await this.inputs(job); job.expectedHashes = inputs.map((input: VectorInputRecord): string => input.chunk.inputHash); job.completedHashes = inputs.filter((input: VectorInputRecord): boolean => input.state === VectorInputState.Verified).map((input: VectorInputRecord): string => input.chunk.inputHash); } return jobs;
  }
  async jobsPage(offset: number, limit: number): Promise<EmbeddingJob[]> { if (limit > 20) { throw new KnowledgeFailure('VectorJobPageBudget','read'); } return this.jobs(offset,limit); }
  async inputs(job: EmbeddingJob): Promise<VectorInputRecord[]> {
    const rows = await this.store().querySql('SELECT c.*,a.state,a.readback_hash,a.input_hash FROM kb_input_attempt a JOIN kb_chunk c ON c.id=a.chunk AND c.generation=? AND c.doc=? WHERE a.generation=? AND a.owner=? ORDER BY c.ordinal,c.id',[job.contentGeneration,job.documentId,job.vectorGeneration,job.id]); const records: VectorInputRecord[] = [];
    try { while (rows.goToNextRow()) { const input: VectorInputRecord = new VectorInputRecord(); const chunk = input.chunk; chunk.id = rows.getString(0); chunk.documentId = rows.getString(1); chunk.generation = rows.getString(2); chunk.snapshotId = rows.getString(3); chunk.snapshotHash = rows.getString(4); chunk.originalHash = rows.getString(5); chunk.originalVersion = rows.getLong(6); chunk.ordinal = rows.getLong(7); chunk.retrievalText = rows.getString(9); chunk.embeddingText = chunk.retrievalText; chunk.text = rows.getString(10); chunk.inputHash = rows.getString(11); chunk.defaultIncluded = rows.getLong(13) === 1;
      if (chunk.snapshotHash !== job.snapshotHash || chunk.inputHash !== rows.getString(16) || records.length >= PdfBudget.documentChunks) { throw new KnowledgeFailure('VectorInputSetChanged','vector-job'); }
      const state = [VectorInputState.NotSent,VectorInputState.InFlight,VectorInputState.Received,VectorInputState.Verified,VectorInputState.Unknown].find((item: VectorInputState): boolean => item === rows.getString(14)); if (state === undefined) { throw new KnowledgeFailure('VectorInputStateInvalid','vector-job'); } input.state = state; input.readbackHash = rows.getString(15); records.push(input);
    } } finally { rows.close(); }
    const expected = await this.store().querySql('SELECT expected FROM kb_vector_generation WHERE id=? AND job=?',[job.vectorGeneration,job.id]); try { if (!expected.goToNextRow() || expected.getLong(0) !== records.length || records.length < 1) { throw new KnowledgeFailure('VectorInputSetIncomplete','vector-job'); } } finally { expected.close(); } return records;
  }
  async inputState(job: EmbeddingJob, chunk: string, state: VectorInputState, hash: string): Promise<void> {
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); const rows = await tx.querySql('SELECT state,input_hash FROM kb_input_attempt WHERE generation=? AND chunk=? AND owner=?',[job.vectorGeneration,chunk,job.id]);
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('VectorInputMissing','vector-job'); } const old: string = rows.getString(0);
        if (!((state === VectorInputState.InFlight && old === VectorInputState.NotSent) || (state === VectorInputState.Received && old === VectorInputState.InFlight) || (state === VectorInputState.Unknown && (old === VectorInputState.InFlight || old === VectorInputState.Received)) || (state === VectorInputState.Verified && (old === VectorInputState.Received || old === VectorInputState.Unknown || old === VectorInputState.Verified)))) { throw new KnowledgeFailure('VectorInputTransition','vector-job'); }
        if (state === VectorInputState.Verified && !new RegExp('^[a-f0-9]{64}$').test(hash)) { throw new KnowledgeFailure('VectorReadbackHashRequired','vector-job'); }
      } finally { rows.close(); }
      await tx.execute('UPDATE kb_input_attempt SET state=?,readback_hash=? WHERE generation=? AND chunk=?',[state,hash,job.vectorGeneration,chunk]);
      if (state === VectorInputState.Verified) { await tx.execute('UPDATE kb_vector_input SET readback_hash=? WHERE generation=? AND chunk=?',[hash,job.vectorGeneration,chunk]); }
    }); });
  }
  async pauseJob(job: EmbeddingJob, failure: string): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute('UPDATE kb_vector_generation SET state=? WHERE id=? AND job=? AND cleanup_claim=? AND state IN (?,?,?,?)',[EmbeddingJobStage.Paused,job.vectorGeneration,job.id,'',EmbeddingJobStage.Preparing,EmbeddingJobStage.Partial,EmbeddingJobStage.Readback,EmbeddingJobStage.Paused]); await tx.execute('UPDATE r2v_job SET failure=? WHERE id=?',[failure,job.id]); await tx.execute('UPDATE kb_input_attempt SET state=? WHERE generation=? AND state=?',[VectorInputState.Unknown,job.vectorGeneration,VectorInputState.InFlight]); }); }); }
  async publish(job: EmbeddingJob, expected: string[]): Promise<boolean> {
    let published: boolean = false;
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); const inputs = await this.inputs(job);
      if (inputs.length !== expected.length || inputs.some((input: VectorInputRecord,index: number): boolean => input.state !== VectorInputState.Verified || input.chunk.inputHash !== expected[index] || input.readbackHash.length !== 64)) { throw new KnowledgeFailure('VectorCoverageIncomplete','vector-publish'); }
      const coverage = await tx.querySql('SELECT i.chunk,i.input_hash,i.readback_hash FROM kb_vector_input i WHERE generation=? ORDER BY chunk',[job.vectorGeneration]); let count: number = 0;
      try { while (coverage.goToNextRow()) { const match = inputs.find((input: VectorInputRecord): boolean => input.chunk.id === coverage.getString(0) && input.chunk.inputHash === coverage.getString(1) && input.readbackHash === coverage.getString(2)); if (match === undefined) { throw new KnowledgeFailure('OrdinaryVectorInputSetMismatch','vector-publish'); } count++; } } finally { coverage.close(); }
      if (count !== inputs.length) { throw new KnowledgeFailure('OrdinaryVectorInputSetIncomplete','vector-publish'); }
      const rows = await tx.querySql('SELECT active_vector FROM kb_document WHERE id=?',[job.documentId]); let old: string = '';
      try { if (!rows.goToNextRow()) { return; } old = rows.getString(0); } finally { rows.close(); }
      if (old !== job.oldVectorGeneration && old !== job.vectorGeneration) { throw new KnowledgeFailure('VectorOldPointerChanged','vector-publish'); }
      await tx.execute('UPDATE kb_vector_generation SET state=?,completed=?,eligibility=0 WHERE id=?',[EmbeddingJobStage.Ready,inputs.length,job.vectorGeneration]);
      if (old !== job.vectorGeneration) { await tx.execute('UPDATE kb_vector_generation SET state=?,eligibility=0 WHERE id=?',['Retained',old]); }
      await tx.execute('UPDATE kb_document SET active_vector=?,active_space=? WHERE id=?',[job.vectorGeneration,job.spaceId,job.documentId]);
      await tx.execute('INSERT OR REPLACE INTO kb_eligibility_mirror VALUES(?,?,?,?,?,?,?)',[job.documentId,job.contentGeneration,job.vectorGeneration,job.spaceId,job.epoch,Date.now(),'Pending']); this.boundary('Publish'); published = true;
    }); }); this.boundary('PublishAck'); return published;
  }
  async eligibility(documentId: string): Promise<VectorEligibility | undefined> {
    const rows = await this.store().querySql('SELECT d.id,d.active_content,d.active_vector,d.active_space,d.epoch,d.archived,m.revision FROM kb_document d JOIN kb_eligibility_mirror m ON m.doc=d.id WHERE d.id=? AND d.tombstone=0 AND d.active_vector<>?',[documentId,'']);
    try { if (!rows.goToNextRow()) { return undefined; } const target: VectorEligibility = new VectorEligibility(); target.documentId = rows.getString(0); target.contentGeneration = rows.getString(1); target.vectorGeneration = rows.getString(2); target.spaceId = rows.getString(3); target.epoch = rows.getLong(4); target.archived = rows.getLong(5) === 1; target.revision = rows.getLong(6); return target; } finally { rows.close(); }
  }
  async acknowledge(target: VectorEligibility): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { this.boundary('Acknowledge'); await this.store().executeSql('UPDATE kb_eligibility_mirror SET state=? WHERE doc=? AND revision=? AND content_generation=? AND vector_generation=? AND space=? AND epoch=?',['Synced',target.documentId,target.revision,target.contentGeneration,target.vectorGeneration,target.spaceId,target.epoch]); }); }
  async targets(spaceId: string, archived: boolean, extras: boolean): Promise<VectorEligibility[]> {
    const rows = await this.store().querySql('SELECT c.id,d.id,d.active_content,d.active_vector,d.active_space,d.epoch,m.revision,d.archived,c.input_hash,i.readback_hash FROM kb_chunk c JOIN kb_document d ON d.id=c.doc AND c.generation=d.active_content JOIN kb_eligibility_mirror m ON m.doc=d.id AND m.content_generation=d.active_content AND m.vector_generation=d.active_vector AND m.space=d.active_space AND m.epoch=d.epoch JOIN kb_vector_generation v ON v.id=d.active_vector JOIN kb_vector_input i ON i.generation=v.id AND i.chunk=c.id AND i.input_hash=c.input_hash WHERE d.tombstone=0 AND d.active_space=? AND m.state=? AND v.state=? AND v.cleanup_claim=? AND (?=1 OR d.archived=0) AND (?=1 OR c.default_included=1)',[spaceId,'Synced',EmbeddingJobStage.Ready,'',archived ? 1 : 0,extras ? 1 : 0]); const targets: VectorEligibility[] = [];
    try { while (rows.goToNextRow()) { const item: VectorEligibility = new VectorEligibility(); item.chunkIds = [rows.getString(0)]; item.documentId = rows.getString(1); item.contentGeneration = rows.getString(2); item.vectorGeneration = rows.getString(3); item.spaceId = rows.getString(4); item.epoch = rows.getLong(5); item.revision = rows.getLong(6); item.archived = rows.getLong(7) === 1; item.inputHash = rows.getString(8); item.readbackHash = rows.getString(9); targets.push(item); if (targets.length > PdfBudget.activeChunks) { throw new KnowledgeFailure('VectorTargetBudget','query'); } } } finally { rows.close(); } return targets;
  }
  async hit(chunkId: string, target: VectorEligibility, archived: boolean, extras: boolean): Promise<KnowledgeHit | undefined> {
    const authority = await this.store().querySql('SELECT c.id FROM kb_chunk c JOIN kb_document d ON d.id=c.doc JOIN kb_eligibility_mirror m ON m.doc=d.id JOIN kb_vector_generation v ON v.id=d.active_vector WHERE c.id=? AND c.doc=? AND c.generation=? AND d.active_content=c.generation AND d.active_vector=? AND d.active_space=? AND d.epoch=? AND d.tombstone=0 AND m.content_generation=c.generation AND m.vector_generation=d.active_vector AND m.space=d.active_space AND m.epoch=d.epoch AND m.revision=? AND m.state=? AND v.state=? AND v.cleanup_claim=? AND (?=1 OR d.archived=0) AND (?=1 OR c.default_included=1)',[chunkId,target.documentId,target.contentGeneration,target.vectorGeneration,target.spaceId,target.epoch,target.revision,'Synced',EmbeddingJobStage.Ready,'',archived ? 1 : 0,extras ? 1 : 0]);
    try { if (!authority.goToNextRow()) { return undefined; } } finally { authority.close(); }
    const rows = await this.store().querySql('SELECT c.*,d.title FROM kb_chunk c JOIN kb_document d ON d.id=c.doc WHERE c.id=? AND c.generation=?',[chunkId,target.contentGeneration]);
    try { if (!rows.goToNextRow()) { return undefined; } const hit: KnowledgeHit = new KnowledgeHit(); hit.chunkId = chunkId; hit.id = 'pdf:'+chunkId; hit.documentId = target.documentId; hit.generation = target.contentGeneration; hit.snapshotId = rows.getString(3); hit.snapshotHash = rows.getString(4); hit.originalHash = rows.getString(5); hit.originalVersion = rows.getLong(6); hit.retrievalText = rows.getString(9); hit.text = rows.getString(10); hit.title = rows.getString(14); hit.epoch = target.epoch; hit.spaceId = target.spaceId; hit.vectorGeneration = target.vectorGeneration; hit.sourceKind = KnowledgeSourceKind.Pdf; hit.channels = [KnowledgeChannel.Vector]; hit.locator.kind = KnowledgeSourceKind.Pdf; hit.locator.pdfRegions = pdfDecodeLocators(new BoundedDocumentJson(pdfCodecUtf8(rows.getString(12)),new KnowledgeCancellation()).read()); return hit; } finally { rows.close(); }
  }
  async reserve(id: string, bytes: number): Promise<void> {
    if (!Number.isSafeInteger(bytes) || bytes < 0) { throw new KnowledgeFailure('VectorReservationInvalid','budget'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const usage = this.physical === undefined ? undefined : await this.physical.usage();
      const rows = await tx.querySql('SELECT (SELECT coalesce(sum(bytes),0) FROM kb_asset),(SELECT coalesce(sum(reserved),0) FROM kb_derived_reservation WHERE state=?),(SELECT coalesce(min(actual),0) FROM kb_derived_reservation WHERE state=?)',['Reserved','Reserved']); let reserved: number = 0;
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('BudgetLedgerMissing','budget'); } const vectorPhysical: number = usage?.vectorPhysical ?? 0; const unused: number = Math.max(0,rows.getLong(1)-Math.max(0,vectorPhysical-rows.getLong(2))); reserved = Math.max(usage?.assetsPhysical ?? 0,rows.getLong(0))+vectorPhysical+unused; } finally { rows.close(); }
      const metadata: number = Math.max(usage?.sharedNonReclaimable ?? 0,await this.metadataBytes());
      if (bytes > this.budgetLimit-reserved-metadata) { throw new KnowledgeFailure('DerivedBudget','vector-job'); }
      await tx.execute('INSERT INTO kb_derived_reservation VALUES(?,?,?,?,?,?)',[id,id,'VectorAndMetadata',bytes,usage?.vectorPhysical ?? 0,'Reserved']);
    }); });
  }
  async metadataBytes(): Promise<number> {
    const tables = await this.store().querySql("SELECT name FROM sqlite_master WHERE type='table' AND (name GLOB 'kb_*' OR name GLOB 'r2v_*')"); const names: string[] = [];
    try { while (tables.goToNextRow()) { const name: string = tables.getString(0); if (!new RegExp('^(kb_|r2v_)[a-z_]+$').test(name)) { throw new KnowledgeFailure('MetadataTableInvalid','budget'); } names.push(name); } } finally { tables.close(); }
    let total: number = 1048576;
    for (const name of names) {
      const columns = await this.store().querySql(`PRAGMA table_info(${name})`); const parts: string[] = [];
      try { while (columns.goToNextRow()) { const column: string = columns.getString(1); if (!new RegExp('^[a-z_]+$').test(column)) { throw new KnowledgeFailure('MetadataColumnInvalid','budget'); } parts.push(`length(CAST(coalesce(${column},'') AS BLOB))`); } } finally { columns.close(); }
      const rows = await this.store().querySql(`SELECT coalesce(sum(${parts.join('+')}+4096),0) FROM ${name}`); try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('MetadataMeasureFailed','budget'); } total += rows.getLong(0)*2; } finally { rows.close(); }
    } return total;
  }
  async checkBudget(): Promise<void> {
    if (this.physical === undefined) { return; }
    const usage = await this.physical.usage();
    usage.metadataReserved = await this.metadataBytes();
    if (usage.total() > this.budgetLimit) { throw new KnowledgeFailure('DerivedPhysicalBudgetExceeded','vector-job'); }
  }
  async releaseReservation(id: string): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('UPDATE kb_derived_reservation SET state=?,reserved=0 WHERE id=?',['AccountedPhysical',id]); }); }
}
