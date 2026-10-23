import { relationalStore } from '@kit.ArkData';
import { PdfVectorRepository } from './PdfVectorRepository';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';
import { ImageKnowledgeRepository } from './ImageKnowledgeRepository';
import { PdfRepositoryPort } from '../domain/KnowledgePorts';
import { VectorCorpusPlan, VectorSourceDocument, VectorInputRecord, VectorInputState, VectorEligibility } from '../domain/VectorWorkflowModels';
import { EmbeddingJob, EmbeddingJobStage, EmbeddingGrant, EmbeddingPurpose, EmbeddingFreeEligibility, EmbeddingSpace } from '../domain/EmbeddingModels';
import { embeddingSpaceDecode } from '../pipeline/EmbeddingSpacePolicy';
import { EmbeddingDryReview } from '../domain/EmbeddingBasisModels';
import { KnowledgeFailure, KnowledgeCancellation, KnowledgeCleanupIntent, KnowledgeCleanupTarget } from '../domain/PdfKnowledgeModels';
import { KnowledgeHit, KnowledgeChannel, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { ImageChunk, ImageIngestionStage } from '../domain/ImageKnowledgeModels';
import { TextQueryInput } from '../domain/TextKnowledgeModels';
import { VectorRdbRepository } from './VectorRdbRepository';

// Reuses common space/usage/reservation/readback machinery without constructing fake PDF models.
export class ImageVectorRepository extends PdfVectorRepository {
  private images: ImageKnowledgeRepository;
  constructor(host: KnowledgeStoreHost, pdf: PdfRepositoryPort, images: ImageKnowledgeRepository) { super(host,pdf); this.images = images; }
  private async isImage(id: string): Promise<boolean> {
    if (!this.images.ready()) { throw new KnowledgeFailure('ImageOwnerUnavailable','vector-owner'); }
    if (await this.images.get(id) !== undefined) { return true; }
    const rows = await this.store().querySql('SELECT id FROM kb_document WHERE id=?',[id]);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('LegacySourceOwnerUnknown','vector-owner'); } } finally { rows.close(); } return false;
  }
  async spaces(): Promise<EmbeddingSpace[]> {
    const all: EmbeddingSpace[] = await super.spaces(); if (!this.images.ready()) { return all; }
    const rows = await this.store().querySql('SELECT wire FROM r2v_space s WHERE EXISTS (SELECT 1 FROM kb_image_vector v WHERE v.space=s.id) ORDER BY id');
    try { while (rows.goToNextRow()) { const space = embeddingSpaceDecode(rows.getString(0)); if (!all.some((item: EmbeddingSpace): boolean => item.id === space.id)) { all.push(space); } if (all.length > 1000) { throw new KnowledgeFailure('SpaceBudget','image-vector'); } } } finally { rows.close(); } return all;
  }
  async document(id: string): Promise<VectorSourceDocument> {
    if (!(await this.isImage(id))) { return super.document(id); }
    const doc = await this.images.get(id); if (doc === undefined || doc.tombstone || doc.activeGeneration.length === 0 || doc.chunkCount === 0 || doc.stage !== ImageIngestionStage.Published) { throw new KnowledgeFailure('ImageCorpusUnavailableOrNoText','image-vector'); }
    if ((await this.images.latestOriginal(id)).assetId !== doc.activeOriginal) { throw new KnowledgeFailure('ImageCandidateNeedsBodyConfirmation','image-vector'); }
    const original = await this.images.original(doc.activeOriginal); const result: VectorSourceDocument = new VectorSourceDocument(); result.id = id; result.sourceKind = 'Image'; result.sourceId = original.sourceId; result.epoch = doc.epoch; result.archived = doc.archived; result.activeContentGeneration = doc.activeGeneration;
    const target = await this.eligibility(id); result.activeVectorGeneration = target?.vectorGeneration ?? ''; return result;
  }
  async corpus(id: string): Promise<VectorCorpusPlan> {
    if (!(await this.isImage(id))) { return super.corpus(id); }
    const plan: VectorCorpusPlan = new VectorCorpusPlan(); plan.document = await this.document(id); const snapshot = await this.images.snapshot(plan.document.activeContentGeneration); plan.snapshotHash = snapshot.contentHash;
    for (const c of await this.images.chunks(plan.document.activeContentGeneration)) { const input: VectorInputRecord = new VectorInputRecord(); input.chunk.id = c.id; input.chunk.documentId = id; input.chunk.generation = c.generation; input.chunk.snapshotId = snapshot.generation; input.chunk.snapshotHash = snapshot.contentHash; input.chunk.originalHash = snapshot.original.hash; input.chunk.originalVersion = snapshot.original.version; input.chunk.ordinal = c.ordinal; input.chunk.text = c.text; input.chunk.retrievalText = c.text; input.chunk.embeddingText = c.text; input.chunk.inputHash = c.inputHash; plan.inputs.push(input); }
    const document = await this.images.get(id);
    if (plan.inputs.length === 0 || plan.inputs.length !== document?.chunkCount) { throw new KnowledgeFailure('ImageNoTextOrChunkCoverageChanged','image-vector'); } return plan;
  }
  private async historicalInputs(job: EmbeddingJob): Promise<VectorInputRecord[]> {
    const snapshot = await this.images.snapshot(job.contentGeneration); const inputs: VectorInputRecord[] = [];
    for (const c of await this.images.chunks(job.contentGeneration)) { const i: VectorInputRecord = new VectorInputRecord(); i.chunk.id = c.id; i.chunk.documentId = c.documentId; i.chunk.generation = c.generation; i.chunk.snapshotHash = snapshot.contentHash; i.chunk.snapshotId = snapshot.generation; i.chunk.text = c.text; i.chunk.retrievalText = c.text; i.chunk.embeddingText = c.text; i.chunk.inputHash = c.inputHash; i.chunk.ordinal = c.ordinal; inputs.push(i); } return inputs;
  }
  async saveReview(review: EmbeddingDryReview): Promise<void> {
    if (!(await this.isImage(review.documentId))) { await super.saveReview(review); return; }
    const plan = await this.corpus(review.documentId); if (plan.snapshotHash !== review.snapshotHash || plan.document.activeContentGeneration !== review.generation || review.rows.length !== plan.inputs.length) { throw new KnowledgeFailure('ImageReviewChanged','image-vector'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const doc = await tx.querySql('SELECT id FROM kb_image_document WHERE id=? AND active_generation=? AND epoch=? AND tombstone=0',[review.documentId,review.generation,plan.document.epoch]); try { if (!doc.goToNextRow()) { throw new KnowledgeFailure('ImageReviewSourceChanged','review'); } } finally { doc.close(); }
      await tx.execute('DELETE FROM r2v_review WHERE doc=?',[review.documentId]);
      for (const row of review.rows) { await tx.execute('INSERT INTO r2v_review VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',[review.setHash,review.documentId,review.generation,review.snapshotHash,review.configFingerprint,row.ordinal,row.chunkId,row.hash,row.bindingHash,row.state,row.bound,row.eligible ? 1 : 0,row.attemptState]); }
    }); });
  }
  protected async assertJob(tx: relationalStore.Transaction, job: EmbeddingJob): Promise<void> {
    if (!(await this.isImage(job.documentId))) { await super.assertJob(tx,job); return; }
    const rows = await tx.querySql("SELECT v.id FROM kb_image_vector v JOIN kb_image_document d ON d.id=v.doc JOIN kb_image_generation c ON c.id=v.content JOIN kb_embedding_grant g ON g.id=v.grant_id WHERE v.id=? AND v.job=? AND v.doc=? AND v.content=? AND v.space=? AND v.epoch=? AND d.epoch=v.epoch AND d.active_generation=v.content AND d.tombstone=0 AND d.archived=0 AND c.state='Active' AND v.state IN ('Preparing','Paused','PartialStaged','ValidatingReadback') AND g.purpose=? AND g.revoked=0 AND g.free=? AND g.expires>? AND g.doc=v.doc AND g.generation=v.content AND g.snapshot_hash=v.snapshot AND g.space=v.space AND g.session=v.session AND g.fingerprint=v.config",[job.vectorGeneration,job.id,job.documentId,job.contentGeneration,job.spaceId,job.epoch,EmbeddingPurpose.ImageCorpus,EmbeddingFreeEligibility.Confirmed,Date.now()]);
    try { if (!rows.goToNextRow()) { throw new KnowledgeFailure('ImageVectorJobOrGrantStale','image-vector'); } } finally { rows.close(); }
  }
  async begin(job: EmbeddingJob, plan: VectorCorpusPlan): Promise<void> {
    if (plan.document.sourceKind !== 'Image') { await super.begin(job,plan); return; }
    const current = await this.corpus(job.documentId); if (current.snapshotHash !== job.snapshotHash || current.document.epoch !== job.epoch || current.inputs.length !== job.expectedHashes.length) { throw new KnowledgeFailure('ImageVectorPlanChanged','image-vector'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      const source = await tx.querySql('SELECT id FROM kb_image_document WHERE id=? AND epoch=? AND active_generation=? AND tombstone=0 AND archived=0',[job.documentId,job.epoch,job.contentGeneration]); try { if (!source.goToNextRow()) { throw new KnowledgeFailure('ImageVectorSourceChanged','image-vector'); } } finally { source.close(); }
      await tx.execute('INSERT INTO kb_image_vector VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',[job.vectorGeneration,job.documentId,job.contentGeneration,job.spaceId,job.id,job.epoch,EmbeddingJobStage.Preparing,plan.inputs.length,job.grantId,job.snapshotHash,job.configFingerprint,job.sessionId,job.windowStart,'']);
      for (const input of plan.inputs) { await tx.execute('INSERT INTO kb_image_vector_input VALUES(?,?,?,?,?)',[job.vectorGeneration,input.chunk.id,input.chunk.inputHash,VectorInputState.NotSent,'']); }
    }); });
  }
  async jobs(offset: number = 0, limit: number = 10000): Promise<EmbeddingJob[]> {
    const all: EmbeddingJob[] = await super.jobs(); if (!this.images.ready()) { return all.slice(offset,offset+limit); }
    const rows = await this.store().querySql('SELECT * FROM kb_image_vector ORDER BY job');
    try { while (rows.goToNextRow()) {
      const job: EmbeddingJob = new EmbeddingJob(); job.vectorGeneration = rows.getString(0); job.documentId = rows.getString(1); job.contentGeneration = rows.getString(2); job.spaceId = rows.getString(3); job.id = rows.getString(4); job.epoch = rows.getLong(5);
      const stage = [EmbeddingJobStage.Preparing,EmbeddingJobStage.Paused,EmbeddingJobStage.Partial,EmbeddingJobStage.Readback,EmbeddingJobStage.Ready,EmbeddingJobStage.Retained,EmbeddingJobStage.Retiring].find((s: EmbeddingJobStage): boolean => s === rows.getString(6)); if (stage === undefined) { throw new KnowledgeFailure('ImageVectorStageUnknown','image-vector'); } job.stage = stage;
      job.grantId = rows.getString(8); job.snapshotHash = rows.getString(9); job.configFingerprint = rows.getString(10); job.sessionId = rows.getString(11); job.windowStart = rows.getLong(12); job.failure = rows.getString(13);
      for (const input of await this.inputs(job)) { job.expectedHashes.push(input.chunk.inputHash); if (input.state === VectorInputState.Verified) { job.completedHashes.push(input.chunk.inputHash); } } all.push(job);
    } } finally { rows.close(); } return all.slice(offset,offset+limit);
  }
  async inputs(job: EmbeddingJob): Promise<VectorInputRecord[]> {
    if (!(await this.isImage(job.documentId))) { return super.inputs(job); }
    const planInputs = await this.historicalInputs(job);
    const rows = await this.store().querySql('SELECT chunk,input_hash,state,readback_hash FROM kb_image_vector_input WHERE generation=? ORDER BY chunk',[job.vectorGeneration]); const inputs: VectorInputRecord[] = [];
    try { while (rows.goToNextRow()) { const input = planInputs.find((i: VectorInputRecord): boolean => i.chunk.id === rows.getString(0) && i.chunk.inputHash === rows.getString(1)); if (input === undefined) { throw new KnowledgeFailure('ImageVectorInputMismatch','image-vector'); }
      const state = [VectorInputState.NotSent,VectorInputState.InFlight,VectorInputState.Received,VectorInputState.Verified,VectorInputState.Unknown].find((s: VectorInputState): boolean => s === rows.getString(2)); if (state === undefined) { throw new KnowledgeFailure('ImageVectorInputState','image-vector'); } input.state = state; input.readbackHash = rows.getString(3); inputs.push(input);
    } } finally { rows.close(); } if (inputs.length !== planInputs.length) { throw new KnowledgeFailure('ImageVectorInputCoverage','image-vector'); } return inputs.sort((a: VectorInputRecord,b: VectorInputRecord): number => a.chunk.ordinal-b.chunk.ordinal);
  }
  async bindGrant(job: EmbeddingJob, grant: EmbeddingGrant): Promise<void> {
    if (!(await this.isImage(job.documentId))) { await super.bindGrant(job,grant); return; }
    if (grant.purpose !== EmbeddingPurpose.ImageCorpus || grant.documentId !== job.documentId || grant.generation !== job.contentGeneration || grant.snapshotHash !== job.snapshotHash || grant.spaceId !== job.spaceId || grant.configFingerprint !== job.configFingerprint) { throw new KnowledgeFailure('ImageCorpusGrantMismatch','image-vector'); }
    job.grantId = grant.id; job.sessionId = grant.sessionId;
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('UPDATE kb_image_vector SET grant_id=?,session=?,window=? WHERE id=?',[grant.id,grant.sessionId,Date.now(),job.vectorGeneration]); });
  }
  async inputState(job: EmbeddingJob, chunk: string, state: VectorInputState, hash: string): Promise<void> {
    if (!(await this.isImage(job.documentId))) { await super.inputState(job,chunk,state,hash); return; }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => { await this.assertJob(tx,job);
      const rows = await tx.querySql('SELECT state,input_hash FROM kb_image_vector_input WHERE generation=? AND chunk=?',[job.vectorGeneration,chunk]);
      try {
        if (!rows.goToNextRow()) { throw new KnowledgeFailure('ImageVectorInputMissing','image-vector'); } const old: string = rows.getString(0);
        if (!((state === VectorInputState.InFlight && old === VectorInputState.NotSent) || (state === VectorInputState.Received && old === VectorInputState.InFlight) || (state === VectorInputState.Unknown && (old === VectorInputState.InFlight || old === VectorInputState.Received)) || (state === VectorInputState.Verified && (old === VectorInputState.Received || old === VectorInputState.Unknown || old === VectorInputState.Verified)))) { throw new KnowledgeFailure('ImageVectorInputTransition','image-vector'); }
        if (state === VectorInputState.Verified && !new RegExp('^[a-f0-9]{64}$').test(hash)) { throw new KnowledgeFailure('ImageVectorReadbackDigestRequired','image-vector'); }
      } finally { rows.close(); }
      await tx.execute('UPDATE kb_image_vector_input SET state=?,readback_hash=? WHERE generation=? AND chunk=?',[state,hash,job.vectorGeneration,chunk]);
    }); });
  }
  async pauseJob(job: EmbeddingJob, failure: string): Promise<void> {
    if (!(await this.isImage(job.documentId))) { await super.pauseJob(job,failure); return; }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await tx.execute("UPDATE kb_image_vector SET state=?,failure=? WHERE id=? AND state IN ('Preparing','Paused','PartialStaged','ValidatingReadback')",[EmbeddingJobStage.Paused,failure,job.vectorGeneration]);
      await tx.execute('UPDATE kb_image_vector_input SET state=? WHERE generation=? AND state=?',[VectorInputState.Unknown,job.vectorGeneration,VectorInputState.InFlight]);
    }); });
  }
  async authorizeResend(job: EmbeddingJob, chunk: string, grant: EmbeddingGrant): Promise<void> {
    if (!(await this.isImage(job.documentId))) { await super.authorizeResend(job,chunk,grant); return; }
    if (grant.id !== job.grantId || !grant.inputChunkIds.includes(chunk)) { throw new KnowledgeFailure('ImageResendExplicitScopeRequired','image-vector'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => { await this.assertJob(tx,job); await tx.execute('UPDATE kb_image_vector_input SET state=? WHERE generation=? AND chunk=? AND state IN (?,?,?)',[VectorInputState.NotSent,job.vectorGeneration,chunk,VectorInputState.Unknown,VectorInputState.Received,VectorInputState.InFlight]); }); });
  }
  async publish(job: EmbeddingJob, expected: string[]): Promise<boolean> {
    if (!(await this.isImage(job.documentId))) { return super.publish(job,expected); }
    const inputs = await this.inputs(job); if (expected.length !== inputs.length || inputs.some((i: VectorInputRecord,index: number): boolean => i.state !== VectorInputState.Verified || i.readbackHash.length !== 64 || i.chunk.inputHash !== expected[index])) { throw new KnowledgeFailure('ImageVectorReadbackCoverage','image-vector'); }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.host.transaction(async (tx: relationalStore.Transaction): Promise<void> => {
      await this.assertJob(tx,job);
      const coverage = await tx.querySql('SELECT chunk,input_hash,state,readback_hash FROM kb_image_vector_input WHERE generation=?',[job.vectorGeneration]); let covered: number = 0;
      try { while (coverage.goToNextRow()) { if (!inputs.some((i: VectorInputRecord): boolean => i.chunk.id === coverage.getString(0) && i.chunk.inputHash === coverage.getString(1) && coverage.getString(2) === VectorInputState.Verified && i.readbackHash === coverage.getString(3))) { throw new KnowledgeFailure('ImageVectorFinalCoverageChanged','image-vector'); } covered++; } } finally { coverage.close(); }
      if (covered !== expected.length) { throw new KnowledgeFailure('ImageVectorFinalCoverageMissing','image-vector'); }
      await tx.execute("UPDATE kb_image_vector SET state='Retained' WHERE doc=? AND state='SemanticReady'",[job.documentId]);
      await tx.execute('UPDATE kb_image_vector SET state=? WHERE id=?',[EmbeddingJobStage.Ready,job.vectorGeneration]);
      await tx.execute('INSERT OR REPLACE INTO kb_image_vector_mirror VALUES(?,?,?,?,?,COALESCE((SELECT revision+1 FROM kb_image_vector_mirror WHERE doc=?),1),?)',[job.documentId,job.contentGeneration,job.vectorGeneration,job.spaceId,job.epoch,job.documentId,'Pending']);
    }); }); return true;
  }
  async eligibility(id: string): Promise<VectorEligibility | undefined> {
    if (!(await this.isImage(id))) { return super.eligibility(id); }
    const rows = await this.store().querySql("SELECT m.* FROM kb_image_vector_mirror m JOIN kb_image_document d ON d.id=m.doc JOIN kb_image_vector v ON v.id=m.generation WHERE m.doc=? AND d.active_generation=m.content AND d.epoch=m.epoch AND d.tombstone=0 AND v.state='SemanticReady'",[id]);
    try { if (!rows.goToNextRow()) { return undefined; } const t: VectorEligibility = new VectorEligibility(); t.documentId = id; t.contentGeneration = rows.getString(1); t.vectorGeneration = rows.getString(2); t.spaceId = rows.getString(3); t.epoch = rows.getLong(4); t.revision = rows.getLong(5); return t; } finally { rows.close(); }
  }
  async acknowledge(t: VectorEligibility): Promise<void> {
    if (!(await this.isImage(t.documentId))) { await super.acknowledge(t); return; }
    await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql('UPDATE kb_image_vector_mirror SET state=? WHERE doc=? AND generation=? AND revision=? AND epoch=?',['Synced',t.documentId,t.vectorGeneration,t.revision,t.epoch]); });
  }
  async targets(space: string, archived: boolean, extras: boolean): Promise<VectorEligibility[]> {
    const targets = await super.targets(space,archived,extras); if (!this.images.ready()) { return targets; }
    const coverage = await this.store().querySql("SELECT v.expected,(SELECT count(*) FROM kb_image_vector_input i WHERE i.generation=v.id AND i.state='ReadbackVerified' AND length(i.readback_hash)=64) FROM kb_image_vector v JOIN kb_image_document d ON d.id=v.doc JOIN kb_image_vector_mirror m ON m.generation=v.id AND m.doc=d.id WHERE v.space=? AND v.state='SemanticReady' AND d.tombstone=0 AND d.active_generation=v.content AND d.epoch=v.epoch AND m.epoch=v.epoch AND m.state='Synced' AND (?=1 OR d.archived=0)",[space,archived ? 1 : 0]);
    try { while (coverage.goToNextRow()) { if (coverage.getLong(0) < 1 || coverage.getLong(0) !== coverage.getLong(1)) { throw new KnowledgeFailure('ImageVectorAuthorityIncomplete','query'); } } } finally { coverage.close(); }
    const rows = await this.store().querySql("SELECT i.chunk,v.doc,v.content,v.id,v.space,v.epoch,m.revision,d.archived,i.input_hash,i.readback_hash FROM kb_image_vector_input i JOIN kb_image_vector v ON v.id=i.generation JOIN kb_image_document d ON d.id=v.doc JOIN kb_image_vector_mirror m ON m.doc=d.id AND m.generation=v.id WHERE v.space=? AND v.state='SemanticReady' AND m.state='Synced' AND d.active_generation=v.content AND d.epoch=v.epoch AND m.epoch=v.epoch AND d.tombstone=0 AND (?=1 OR d.archived=0) AND i.state=?",[space,archived ? 1 : 0,VectorInputState.Verified]);
    try { while (rows.goToNextRow()) { const t: VectorEligibility = new VectorEligibility(); t.chunkIds = [rows.getString(0)]; t.documentId = rows.getString(1); t.contentGeneration = rows.getString(2); t.vectorGeneration = rows.getString(3); t.spaceId = rows.getString(4); t.epoch = rows.getLong(5); t.revision = rows.getLong(6); t.archived = rows.getLong(7) === 1; t.inputHash = rows.getString(8); t.readbackHash = rows.getString(9); targets.push(t); if (targets.length > 30000) { throw new KnowledgeFailure('MixedVectorTargetBudget','image-vector'); } } } finally { rows.close(); } return targets;
  }
  async hit(chunk: string, t: VectorEligibility, archived: boolean, extras: boolean): Promise<KnowledgeHit | undefined> {
    if (!(await this.isImage(t.documentId))) { return super.hit(chunk,t,archived,extras); }
    const doc = await this.images.get(t.documentId); if (doc === undefined || doc.tombstone || doc.activeGeneration !== t.contentGeneration || doc.epoch !== t.epoch || !archived && doc.archived) { return undefined; }
    const authority = await this.store().querySql("SELECT m.doc FROM kb_image_vector_mirror m JOIN kb_image_vector v ON v.id=m.generation JOIN kb_image_vector_input i ON i.generation=v.id WHERE m.doc=? AND m.content=? AND m.generation=? AND m.space=? AND m.epoch=? AND m.revision=? AND m.state='Synced' AND v.state='SemanticReady' AND i.chunk=? AND i.input_hash=? AND i.readback_hash=? AND i.state='ReadbackVerified'",[t.documentId,t.contentGeneration,t.vectorGeneration,t.spaceId,t.epoch,t.revision,chunk,t.inputHash,t.readbackHash]);
    try { if (!authority.goToNextRow()) { return undefined; } } finally { authority.close(); }
    const snapshot = await this.images.snapshot(t.contentGeneration); const c = (await this.images.chunks(t.contentGeneration)).find((item: ImageChunk): boolean => item.id === chunk && item.inputHash === t.inputHash); if (c === undefined) { throw new KnowledgeFailure('ImageVectorHitChunkMissing','image-vector'); }
    const hit: KnowledgeHit = new KnowledgeHit(); hit.id = 'image:'+c.id; hit.documentId = doc.id; hit.chunkId = c.id; hit.sourceKind = KnowledgeSourceKind.Image; hit.actualFormat = snapshot.original.header.encoding; hit.title = doc.title; hit.text = c.text; hit.retrievalText = c.text; hit.generation = c.generation; hit.snapshotId = snapshot.generation; hit.snapshotHash = snapshot.contentHash; hit.originalHash = snapshot.original.hash; hit.originalVersion = snapshot.original.version; hit.epoch = doc.epoch; hit.spaceId = t.spaceId; hit.vectorGeneration = t.vectorGeneration; hit.locator.kind = hit.sourceKind; hit.locator.image = c.locator; hit.channels = [KnowledgeChannel.Vector]; return hit;
  }
  async cleanupDeleted(id: string, vectors: VectorRdbRepository): Promise<void> {
    const doc = await this.images.get(id); if (doc === undefined || !doc.tombstone) { throw new KnowledgeFailure('ImageDeleteIntentRequired','image-vector-cleanup'); }
    const readers = await this.store().querySql('SELECT count(*) FROM kb_image_lease WHERE doc=?',[id]); try { if (!readers.goToNextRow() || readers.getLong(0) !== 0) { throw new KnowledgeFailure('ImageDeleteReadersHeld','image-vector-cleanup'); } } finally { readers.close(); }
    const rows = await this.store().querySql("SELECT id,content,space,job FROM kb_image_vector WHERE doc=? AND state='Retiring'",[id]); const claims: KnowledgeCleanupIntent[] = [];
    try { while (rows.goToNextRow()) { const claim: KnowledgeCleanupIntent = new KnowledgeCleanupIntent(); claim.id = 'image-delete-'+rows.getString(0); claim.claim = claim.id; claim.documentId = id; claim.generation = rows.getString(1); const target: KnowledgeCleanupTarget = new KnowledgeCleanupTarget(); target.spaceId = rows.getString(2); target.vectorGeneration = rows.getString(0); target.contentGeneration = claim.generation; target.owner = rows.getString(3); claim.vectorTargets = [target]; claims.push(claim); } } finally { rows.close(); }
    for (const claim of claims) { await vectors.open(); await vectors.removeTarget(claim,claim.vectorTargets[0].spaceId,claim.vectorTargets[0].vectorGeneration); await this.host.enqueue<void>(async (): Promise<void> => { await this.store().executeSql("UPDATE kb_image_vector SET state='Removed' WHERE id=? AND doc=? AND state='Retiring'",[claim.vectorTargets[0].vectorGeneration,id]); }); }
  }
}
