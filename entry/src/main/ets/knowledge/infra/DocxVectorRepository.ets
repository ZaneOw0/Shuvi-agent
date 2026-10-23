import { relationalStore } from '@kit.ArkData';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { DocxKnowledgeRepository } from './DocxKnowledgeRepository';
import { VectorWorkflowRepository, VectorCorpusPlan, VectorSourceDocument, VectorInputRecord, VectorInputState, VectorEligibility, VectorUsageSummary, EmbeddingTrialScope, EmbeddingTrialResult, EmbeddingCorpusReceipt } from '../domain/VectorWorkflowModels';
import { EmbeddingConfig, EmbeddingSpace, EmbeddingJob, EmbeddingJobStage, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility } from '../domain/EmbeddingModels';
import { EmbeddingBaselineAcceptance, EmbeddingDryReview } from '../domain/EmbeddingBasisModels';
import { KnowledgeHit, KnowledgeChannel } from '../domain/KnowledgeSearchModels';
import { KnowledgeCancellation, KnowledgeFailure, KnowledgeReadLease, KnowledgeCleanupIntent, KnowledgeCleanupTarget } from '../domain/PdfKnowledgeModels';
import { DocxDocument, DocxChunk, DocxSnapshot, DocxStage } from '../domain/DocxKnowledgeModels';
import { embeddingSpaceDecode } from '../pipeline/EmbeddingSpacePolicy';
import { VectorRdbRepository } from './VectorRdbRepository';

// Composition only: legacy public ledgers are reused, every DOCX document operation has its own SQL owner.
export class DocxVectorRepository implements VectorWorkflowRepository {
  private host: KnowledgeStoreHost; private documents: DocxKnowledgeRepository; private legacy: VectorWorkflowRepository;
  constructor(host: KnowledgeStoreHost, documents: DocxKnowledgeRepository, legacy: VectorWorkflowRepository) { this.host = host; this.documents = documents; this.legacy = legacy; }
  private async owns(id: string): Promise<boolean> {
    const rows = await this.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_docx_document WHERE id=?),(SELECT count(*) FROM kb_document WHERE id=?),(SELECT count(*) FROM kb_image_document WHERE id=?)',[id,id,id]);
    try {
      if (!rows.goToNextRow() || rows.getLong(0)+rows.getLong(1)+rows.getLong(2) !== 1) { throw new KnowledgeFailure('DocumentOwnerUnknownOrAmbiguous','vector-owner'); }
      if (rows.getLong(0) === 1 && !this.documents.ready()) { throw new KnowledgeFailure('DocxRepositoryNotReady','vector-owner'); } return rows.getLong(0) === 1;
    } finally { rows.close(); }
  }
  private async write(action: (tx: relationalStore.Transaction) => Promise<void>): Promise<void> { await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(action); }); }
  saveBaseline(basis: EmbeddingBaselineAcceptance): Promise<void> { return this.legacy.saveBaseline(basis); }
  baseline(config: EmbeddingConfig): Promise<EmbeddingBaselineAcceptance> { return this.legacy.baseline(config); }
  saveSpace(space: EmbeddingSpace): Promise<void> { return this.legacy.saveSpace(space); }
  reserve(id: string, bytes: number): Promise<void> { return this.legacy.reserve(id,bytes); }
  releaseReservation(id: string): Promise<void> { return this.legacy.releaseReservation(id); }
  checkBudget(): Promise<void> { return this.legacy.checkBudget(); }
  recordUsage(job: EmbeddingJob, chunk: string, total: number | undefined, prompt: number | undefined): Promise<void> { return this.legacy.recordUsage(job,chunk,total,prompt); }
  recordCorpusReceipt(receipt: EmbeddingCorpusReceipt): Promise<void> { return this.legacy.recordCorpusReceipt(receipt); }
  releaseFailure(lease: KnowledgeReadLease, failure: string): Promise<void> { return this.legacy.releaseFailure(lease,failure); }
  pendingReleases(session: string): Promise<KnowledgeReadLease[]> { return this.legacy.pendingReleases(session); }
  async usage(): Promise<VectorUsageSummary> {
    const usage: VectorUsageSummary = await this.legacy.usage(); const rows = await this.host.requireStore().querySql("SELECT count(*) FROM kb_docx_vector_input WHERE state='Unknown'");
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('UsageReadIncomplete','docx-vector'); } usage.unknown += rows.getLong(0); } finally { rows.close(); } return usage;
  }
  async spaces(): Promise<EmbeddingSpace[]> {
    const spaces: EmbeddingSpace[] = await this.legacy.spaces(); const rows = await this.host.requireStore().querySql('SELECT wire FROM r2v_space s WHERE EXISTS(SELECT 1 FROM kb_docx_vector v WHERE v.space=s.id) ORDER BY id');
    try { while (rows.goToNextRow()) { const space: EmbeddingSpace = embeddingSpaceDecode(rows.getString(0)); if (!spaces.some((s: EmbeddingSpace): boolean => s.id === space.id)) { spaces.push(space); } if (spaces.length > 1000) { throw new KnowledgeFailure('SpaceBudget','docx-vector'); } } } finally { rows.close(); } return spaces;
  }
  async document(id: string): Promise<VectorSourceDocument> {
    if (!(await this.owns(id))) { return this.legacy.document(id); }
    const d: DocxDocument | undefined = await this.documents.get(id);
    if (d === undefined || d.tombstone || d.chunkCount === 0 || d.activeGeneration.length === 0 || [DocxStage.Published,DocxStage.Partial].indexOf(d.stage) < 0) { throw new KnowledgeFailure('DocxCorpusUnavailable','docx-vector'); }
    const original = await this.documents.original(d.activeOriginal);
    if ((await this.documents.latestOriginal(id)).assetId !== original.assetId) { throw new KnowledgeFailure('DocxCandidateRequiresCoverageConfirmation','docx-vector'); }
    const out: VectorSourceDocument = new VectorSourceDocument(); out.id = id; out.sourceKind = 'Docx'; out.sourceId = original.sourceId; out.epoch = d.epoch; out.archived = d.archived; out.activeContentGeneration = d.activeGeneration; out.activeVectorGeneration = (await this.eligibility(id))?.vectorGeneration ?? ''; return out;
  }
  private async plan(id: string, generation: string): Promise<VectorCorpusPlan> {
    const s: DocxSnapshot = await this.documents.snapshot(generation); const plan: VectorCorpusPlan = new VectorCorpusPlan(); plan.snapshotHash = s.hash;
    for (const c of await this.documents.chunks(generation)) {
      const input: VectorInputRecord = new VectorInputRecord(); input.chunk.id = c.id; input.chunk.documentId = id; input.chunk.generation = generation; input.chunk.snapshotId = s.generation; input.chunk.snapshotHash = s.hash; input.chunk.originalHash = s.original.hash; input.chunk.originalVersion = s.original.version; input.chunk.ordinal = c.ordinal; input.chunk.text = c.text; input.chunk.retrievalText = c.text; input.chunk.embeddingText = c.embeddingText; input.chunk.inputHash = c.inputHash; plan.inputs.push(input);
    } return plan;
  }
  async corpus(id: string): Promise<VectorCorpusPlan> {
    if (!(await this.owns(id))) { return this.legacy.corpus(id); }
    const document: VectorSourceDocument = await this.document(id); const plan: VectorCorpusPlan = await this.plan(id,document.activeContentGeneration); plan.document = document;
    const d: DocxDocument | undefined = await this.documents.get(id); if (d === undefined || plan.inputs.length !== d.chunkCount || plan.inputs.length === 0) { throw new KnowledgeFailure('DocxCorpusCoverageChanged','docx-vector'); } return plan;
  }
  async saveReview(review: EmbeddingDryReview): Promise<void> {
    if (!(await this.owns(review.documentId))) { return this.legacy.saveReview(review); }
    const plan: VectorCorpusPlan = await this.corpus(review.documentId);
    if (plan.snapshotHash !== review.snapshotHash || plan.document.activeContentGeneration !== review.generation || plan.inputs.length !== review.rows.length || plan.inputs.some((i: VectorInputRecord,index: number): boolean => i.chunk.id !== review.rows[index].chunkId || i.chunk.inputHash !== review.rows[index].hash)) { throw new KnowledgeFailure('DocxReviewChanged','docx-vector'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const current = await tx.querySql('SELECT id FROM kb_docx_document WHERE id=? AND active_generation=? AND epoch=? AND tombstone=0 AND archived=0',[review.documentId,review.generation,plan.document.epoch]);
      try { if (!current.goToNextRow()) { throw new KnowledgeFailure('DocxReviewSourceChanged','review'); } } finally { current.close(); }
      await tx.execute('DELETE FROM r2v_review WHERE doc=?',[review.documentId]);
      for (const row of review.rows) { await tx.execute('INSERT INTO r2v_review VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',[review.setHash,review.documentId,review.generation,review.snapshotHash,review.configFingerprint,row.ordinal,row.chunkId,row.hash,row.bindingHash,row.state,row.bound,row.eligible ? 1 : 0,row.attemptState]); }
    });
  }
  private async assertJob(tx: relationalStore.Transaction, job: EmbeddingJob): Promise<void> {
    const rows = await tx.querySql("SELECT v.id FROM kb_docx_vector v JOIN kb_docx_document d ON d.id=v.doc JOIN kb_docx_generation c ON c.id=v.content JOIN kb_embedding_grant g ON g.id=v.grant_id WHERE v.id=? AND v.job=? AND v.doc=? AND v.content=? AND v.space=? AND v.epoch=? AND d.epoch=v.epoch AND d.active_generation=v.content AND d.tombstone=0 AND d.archived=0 AND c.state='Active' AND v.state IN ('Preparing','Paused','PartialStaged','ValidatingReadback') AND g.purpose=? AND g.revoked=0 AND g.free=? AND g.expires>? AND g.doc=v.doc AND g.generation=v.content AND g.snapshot_hash=v.snapshot AND g.space=v.space AND g.session=v.session AND g.fingerprint=v.config",[job.vectorGeneration,job.id,job.documentId,job.contentGeneration,job.spaceId,job.epoch,EmbeddingPurpose.DocxCorpus,EmbeddingFreeEligibility.Confirmed,Date.now()]);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('DocxVectorJobOrGrantStale','docx-vector'); } } finally { rows.close(); }
  }
  async begin(job: EmbeddingJob, plan: VectorCorpusPlan): Promise<void> {
    if (!(await this.owns(job.documentId))) { return this.legacy.begin(job,plan); }
    const current: VectorCorpusPlan = await this.corpus(job.documentId);
    if (plan.document.sourceKind !== 'Docx' || current.snapshotHash !== job.snapshotHash || current.document.epoch !== job.epoch || current.inputs.length !== job.expectedHashes.length || current.inputs.some((i: VectorInputRecord,at: number): boolean => i.chunk.id !== plan.inputs[at].chunk.id || i.chunk.inputHash !== job.expectedHashes[at])) { throw new KnowledgeFailure('DocxVectorPlanChanged','docx-vector'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql('SELECT id FROM kb_docx_document WHERE id=? AND epoch=? AND active_generation=? AND tombstone=0 AND archived=0',[job.documentId,job.epoch,job.contentGeneration]); try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('DocxSourceChanged','docx-vector'); } } finally { rows.close(); }
      await tx.execute('INSERT INTO kb_docx_vector VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[job.vectorGeneration,job.documentId,job.contentGeneration,job.spaceId,job.id,job.epoch,EmbeddingJobStage.Preparing,plan.inputs.length,job.grantId,job.snapshotHash,job.configFingerprint,job.sessionId,job.windowStart,'']);
      for (const i of current.inputs) { await tx.execute('INSERT INTO kb_docx_vector_input VALUES(?,?,?,?,?)',[job.vectorGeneration,i.chunk.id,i.chunk.inputHash,VectorInputState.NotSent,'']); }
    });
  }
  async jobs(): Promise<EmbeddingJob[]> {
    const jobs: EmbeddingJob[] = await this.legacy.jobs(); const rows = await this.host.requireStore().querySql("SELECT * FROM kb_docx_vector WHERE state<>'Removed' ORDER BY job");
    try { while (rows.goToNextRow()) {
      const j: EmbeddingJob = new EmbeddingJob(); j.vectorGeneration = rows.getString(0); j.documentId = rows.getString(1); j.contentGeneration = rows.getString(2); j.spaceId = rows.getString(3); j.id = rows.getString(4); j.epoch = rows.getLong(5);
      const state: string = rows.getString(6); const stage: EmbeddingJobStage | undefined = [EmbeddingJobStage.Preparing,EmbeddingJobStage.Paused,EmbeddingJobStage.Partial,EmbeddingJobStage.Readback,EmbeddingJobStage.Ready,EmbeddingJobStage.Retained,EmbeddingJobStage.Retiring].find((s: EmbeddingJobStage): boolean => s === state);
      if (stage === undefined && state !== 'PublishedPending') { throw new KnowledgeFailure('DocxVectorStageUnknown','docx-vector'); } j.stage = stage ?? EmbeddingJobStage.Readback;
      j.grantId = rows.getString(8); j.snapshotHash = rows.getString(9); j.configFingerprint = rows.getString(10); j.sessionId = rows.getString(11); j.windowStart = rows.getLong(12); j.failure = rows.getString(13);
      const inputs: VectorInputRecord[] = await this.inputs(j); j.expectedHashes = inputs.map((i: VectorInputRecord): string => i.chunk.inputHash); j.completedHashes = inputs.filter((i: VectorInputRecord): boolean => i.state === VectorInputState.Verified).map((i: VectorInputRecord): string => i.chunk.inputHash); jobs.push(j); if (jobs.length > 10000) { throw new KnowledgeFailure('VectorJobBudget','docx-vector'); }
    } } finally { rows.close(); } return jobs;
  }
  async jobsPage(offset: number, limit: number): Promise<EmbeddingJob[]> { if (!Number.isSafeInteger(offset) || offset < 0 || limit < 1 || limit > 20) { throw new KnowledgeFailure('VectorJobPageBudget','read'); } return (await this.jobs()).slice(offset,offset+limit); }
  async inputs(job: EmbeddingJob): Promise<VectorInputRecord[]> {
    if (!(await this.owns(job.documentId))) { return this.legacy.inputs(job); }
    const plan: VectorCorpusPlan = await this.plan(job.documentId,job.contentGeneration); const records: VectorInputRecord[] = [];
    const rows = await this.host.requireStore().querySql('SELECT chunk,input_hash,state,readback_hash FROM kb_docx_vector_input WHERE generation=?',[job.vectorGeneration]);
    try { while (rows.goToNextRow()) {
      const input: VectorInputRecord | undefined = plan.inputs.find((i: VectorInputRecord): boolean => i.chunk.id === rows.getString(0) && i.chunk.inputHash === rows.getString(1));
      const state: VectorInputState | undefined = [VectorInputState.NotSent,VectorInputState.InFlight,VectorInputState.Received,VectorInputState.Verified,VectorInputState.Unknown].find((s: VectorInputState): boolean => s === rows.getString(2));
      if (input === undefined || state === undefined) { throw new KnowledgeFailure('DocxVectorInputMismatch','docx-vector'); } input.state = state; input.readbackHash = rows.getString(3); records.push(input);
    } } finally { rows.close(); }
    if (records.length !== plan.inputs.length || plan.snapshotHash !== job.snapshotHash) { throw new KnowledgeFailure('DocxVectorInputCoverage','docx-vector'); } return records.sort((a: VectorInputRecord,b: VectorInputRecord): number => a.chunk.ordinal-b.chunk.ordinal);
  }
  async bindGrant(job: EmbeddingJob, grant: EmbeddingGrant): Promise<void> {
    if (!(await this.owns(job.documentId))) { return this.legacy.bindGrant(job,grant); }
    if (grant.purpose !== EmbeddingPurpose.DocxCorpus || grant.documentId !== job.documentId || grant.generation !== job.contentGeneration || grant.spaceId !== job.spaceId || grant.snapshotHash !== job.snapshotHash || grant.configFingerprint !== job.configFingerprint) { throw new KnowledgeFailure('DocxGrantMismatch','docx-vector'); }
    job.grantId = grant.id; job.sessionId = grant.sessionId; await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute("UPDATE kb_docx_vector SET grant_id=?,session=?,window=? WHERE id=? AND state IN ('Preparing','Paused','PartialStaged','ValidatingReadback')",[grant.id,grant.sessionId,Date.now(),job.vectorGeneration]); });
  }
  async inputState(job: EmbeddingJob, chunk: string, state: VectorInputState, hash: string): Promise<void> {
    if (!(await this.owns(job.documentId))) { return this.legacy.inputState(job,chunk,state,hash); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); const rows = await tx.querySql('SELECT state FROM kb_docx_vector_input WHERE generation=? AND chunk=?',[job.vectorGeneration,chunk]);
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('DocxVectorInputMissing','docx-vector'); } const old: string = rows.getString(0);
        if (!(state === VectorInputState.InFlight && old === VectorInputState.NotSent || state === VectorInputState.Received && old === VectorInputState.InFlight || state === VectorInputState.Unknown && (old === VectorInputState.InFlight || old === VectorInputState.Received) || state === VectorInputState.Verified && (old === VectorInputState.Received || old === VectorInputState.Unknown || old === VectorInputState.Verified)) || state === VectorInputState.Verified && !new RegExp('^[a-f0-9]{64}$').test(hash)) { throw new KnowledgeFailure('DocxVectorTransitionInvalid','docx-vector'); }
      } finally { rows.close(); }
      await tx.execute('UPDATE kb_docx_vector_input SET state=?,readback_hash=? WHERE generation=? AND chunk=?',[state,hash,job.vectorGeneration,chunk]);
    });
  }
  async pauseJob(job: EmbeddingJob, failure: string): Promise<void> {
    if (!(await this.owns(job.documentId))) { return this.legacy.pauseJob(job,failure); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute("UPDATE kb_docx_vector SET state='Paused',failure=? WHERE id=? AND state IN ('Preparing','Paused','PartialStaged','ValidatingReadback')",[failure,job.vectorGeneration]); await tx.execute("UPDATE kb_docx_vector_input SET state='Unknown' WHERE generation=? AND state='InFlight'",[job.vectorGeneration]); });
  }
  async authorizeResend(job: EmbeddingJob, chunk: string, grant: EmbeddingGrant): Promise<void> {
    if (!(await this.owns(job.documentId))) { return this.legacy.authorizeResend(job,chunk,grant); }
    if (grant.id !== job.grantId || !grant.inputChunkIds.includes(chunk)) { throw new KnowledgeFailure('DocxExplicitResendScopeRequired','docx-vector'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await this.assertJob(tx,job); await tx.execute('INSERT INTO r2v_resend VALUES(?,?,?,?)',[job.vectorGeneration,chunk,grant.id,Date.now()]); await tx.execute("UPDATE kb_docx_vector_input SET state='NotSent' WHERE generation=? AND chunk=? AND state IN ('Unknown','Received','InFlight')",[job.vectorGeneration,chunk]); });
  }
  async publish(job: EmbeddingJob, expected: string[]): Promise<boolean> {
    if (!(await this.owns(job.documentId))) { return this.legacy.publish(job,expected); }
    const inputs: VectorInputRecord[] = await this.inputs(job); if (inputs.length !== expected.length || inputs.some((i: VectorInputRecord,at: number): boolean => i.state !== VectorInputState.Verified || i.chunk.inputHash !== expected[at] || i.readbackHash.length !== 64)) { throw new KnowledgeFailure('DocxReadbackCoverageIncomplete','docx-vector'); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job); const rows = await tx.querySql('SELECT chunk,input_hash,state,readback_hash FROM kb_docx_vector_input WHERE generation=?',[job.vectorGeneration]); let count: number = 0;
      try { while (rows.goToNextRow()) { if (!inputs.some((i: VectorInputRecord): boolean => i.chunk.id === rows.getString(0) && i.chunk.inputHash === rows.getString(1) && rows.getString(2) === VectorInputState.Verified && i.readbackHash === rows.getString(3))) { throw new KnowledgeFailure('DocxFinalCoverageChanged','docx-vector'); } count++; } } finally { rows.close(); }
      if (count !== expected.length) { throw new KnowledgeFailure('DocxFinalCoverageMissing','docx-vector'); }
      await tx.execute("UPDATE kb_docx_vector SET state='Retained' WHERE doc=? AND state='SemanticReady'",[job.documentId]); await tx.execute("UPDATE kb_docx_vector SET state='PublishedPending' WHERE id=?",[job.vectorGeneration]);
      await tx.execute('INSERT OR REPLACE INTO kb_docx_vector_mirror VALUES(?,?,?,?,?,COALESCE((SELECT revision+1 FROM kb_docx_vector_mirror WHERE doc=?),1),?)',[job.documentId,job.contentGeneration,job.vectorGeneration,job.spaceId,job.epoch,job.documentId,'Pending']);
    }); return true;
  }
  async eligibility(id: string): Promise<VectorEligibility | undefined> {
    if (!(await this.owns(id))) { return this.legacy.eligibility(id); }
    const rows = await this.host.requireStore().querySql("SELECT m.*,d.archived FROM kb_docx_vector_mirror m JOIN kb_docx_document d ON d.id=m.doc JOIN kb_docx_vector v ON v.id=m.generation WHERE m.doc=? AND d.active_generation=m.content AND d.epoch=m.epoch AND d.tombstone=0 AND v.state IN ('PublishedPending','SemanticReady')",[id]);
    try { if (!rows.goToNextRow()) { return undefined; } const t: VectorEligibility = new VectorEligibility(); t.documentId = id; t.contentGeneration = rows.getString(1); t.vectorGeneration = rows.getString(2); t.spaceId = rows.getString(3); t.epoch = rows.getLong(4); t.revision = rows.getLong(5); t.archived = rows.getLong(7) === 1; return t; } finally { rows.close(); }
  }
  async acknowledge(t: VectorEligibility): Promise<void> {
    if (!(await this.owns(t.documentId))) { return this.legacy.acknowledge(t); }
    await this.write(async (tx: relationalStore.Transaction): Promise<void> => {
      const rows = await tx.querySql('SELECT m.doc FROM kb_docx_vector_mirror m JOIN kb_docx_document d ON d.id=m.doc WHERE m.doc=? AND m.content=? AND m.generation=? AND m.space=? AND m.revision=? AND m.epoch=? AND d.epoch=m.epoch AND d.active_generation=m.content AND d.tombstone=0',[t.documentId,t.contentGeneration,t.vectorGeneration,t.spaceId,t.revision,t.epoch]);
      try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('DocxMirrorChanged','docx-vector'); } } finally { rows.close(); }
      await tx.execute("UPDATE kb_docx_vector_mirror SET state='Synced' WHERE doc=? AND revision=?",[t.documentId,t.revision]); await tx.execute("UPDATE kb_docx_vector SET state='SemanticReady' WHERE id=? AND state='PublishedPending'",[t.vectorGeneration]);
    });
  }
  async targets(space: string, archived: boolean, extras: boolean): Promise<VectorEligibility[]> {
    const targets: VectorEligibility[] = await this.legacy.targets(space,archived,extras);
    const rows = await this.host.requireStore().querySql("SELECT i.chunk,v.doc,v.content,v.id,v.space,v.epoch,m.revision,d.archived,i.input_hash,i.readback_hash,v.expected,(SELECT count(*) FROM kb_docx_vector_input a WHERE a.generation=v.id AND a.state='ReadbackVerified' AND length(a.readback_hash)=64) FROM kb_docx_vector_input i JOIN kb_docx_vector v ON v.id=i.generation JOIN kb_docx_document d ON d.id=v.doc JOIN kb_docx_vector_mirror m ON m.doc=d.id AND m.generation=v.id WHERE v.space=? AND v.state='SemanticReady' AND m.state='Synced' AND d.active_generation=v.content AND d.epoch=v.epoch AND m.epoch=v.epoch AND d.tombstone=0 AND (?=1 OR d.archived=0) AND i.state='ReadbackVerified'",[space,archived ? 1 : 0]);
    try { while (rows.goToNextRow()) { if (rows.getLong(10) < 1 || rows.getLong(10) !== rows.getLong(11)) { throw new KnowledgeFailure('DocxVectorAuthorityIncomplete','query'); } const t: VectorEligibility = new VectorEligibility(); t.chunkIds = [rows.getString(0)]; t.documentId = rows.getString(1); t.contentGeneration = rows.getString(2); t.vectorGeneration = rows.getString(3); t.spaceId = rows.getString(4); t.epoch = rows.getLong(5); t.revision = rows.getLong(6); t.archived = rows.getLong(7) === 1; t.inputHash = rows.getString(8); t.readbackHash = rows.getString(9); targets.push(t); if (targets.length > 30000) { throw new KnowledgeFailure('MixedVectorTargetBudget','query'); } } } finally { rows.close(); } return targets;
  }
  async hit(chunk: string, t: VectorEligibility, archived: boolean, extras: boolean): Promise<KnowledgeHit | undefined> {
    if (!(await this.owns(t.documentId))) { return this.legacy.hit(chunk,t,archived,extras); }
    const targets: VectorEligibility[] = await this.targets(t.spaceId,archived,extras); if (!targets.some((i: VectorEligibility): boolean => i.documentId === t.documentId && i.contentGeneration === t.contentGeneration && i.vectorGeneration === t.vectorGeneration && i.revision === t.revision && i.epoch === t.epoch && i.chunkIds[0] === chunk && i.inputHash === t.inputHash && i.readbackHash === t.readbackHash)) { return undefined; }
    const d: DocxDocument | undefined = await this.documents.get(t.documentId); const c: DocxChunk | undefined = (await this.documents.chunks(t.contentGeneration)).find((i: DocxChunk): boolean => i.id === chunk && i.inputHash === t.inputHash); if (d === undefined || c === undefined) { throw new KnowledgeFailure('DocxVectorHitMissing','query'); }
    const hit: KnowledgeHit = await this.documents.makeHit(d,c,await this.documents.snapshot(t.contentGeneration)); hit.channels = [KnowledgeChannel.Vector]; hit.spaceId = t.spaceId; hit.vectorGeneration = t.vectorGeneration; return hit;
  }
  async assertTrial(job: EmbeddingJob): Promise<void> { if (await this.owns(job.documentId)) { throw new KnowledgeFailure('PdfTrialNotApplicableToDocx','trial'); } return this.legacy.assertTrial(job); }
  async trialHit(chunk: string, scope: EmbeddingTrialScope): Promise<KnowledgeHit> { await this.assertTrial(scope.job); return this.legacy.trialHit(chunk,scope); }
  async beginTrialQuery(scope: EmbeddingTrialScope, grant: EmbeddingGrant): Promise<void> { await this.assertTrial(scope.job); return this.legacy.beginTrialQuery(scope,grant); }
  finishTrialQuery(id: string, stage: string, result: EmbeddingTrialResult): Promise<void> { return this.legacy.finishTrialQuery(id,stage,result); }
  async cleanupDeleted(id: string, vectors: VectorRdbRepository): Promise<void> {
    if (!(await this.owns(id))) { throw new KnowledgeFailure('DocxCleanupOwnerRequired','cleanup'); }
    const document: DocxDocument | undefined = await this.documents.get(id); if (document === undefined || !document.tombstone) { throw new KnowledgeFailure('DocxTombstoneRequired','cleanup'); }
    const rows = await this.host.requireStore().querySql('SELECT count(*) FROM kb_docx_lease WHERE doc=?',[id]); try { if (!rows.goToNextRow() || rows.getLong(0) !== 0) { throw new KnowledgeFailure('DocxReadersHeld','cleanup'); } } finally { rows.close(); }
    const pending = await this.host.requireStore().querySql("SELECT id,content,space,job FROM kb_docx_vector WHERE doc=? AND state='Retiring'",[id]); const claims: KnowledgeCleanupIntent[] = [];
    try { while (pending.goToNextRow()) { const c: KnowledgeCleanupIntent = new KnowledgeCleanupIntent(); c.id = 'docx-delete-'+pending.getString(0); c.claim = c.id; c.documentId = id; c.generation = pending.getString(1); const t: KnowledgeCleanupTarget = new KnowledgeCleanupTarget(); t.spaceId = pending.getString(2); t.vectorGeneration = pending.getString(0); t.contentGeneration = c.generation; t.owner = pending.getString(3); c.vectorTargets = [t]; claims.push(c); } } finally { pending.close(); }
    for (const c of claims) { await vectors.open(); await vectors.removeTarget(c,c.vectorTargets[0].spaceId,c.vectorTargets[0].vectorGeneration); await this.write(async (tx: relationalStore.Transaction): Promise<void> => { await tx.execute("UPDATE kb_docx_vector SET state='Removed' WHERE id=? AND doc=? AND state='Retiring'",[c.vectorTargets[0].vectorGeneration,id]); }); }
  }
}
