import { common } from '@kit.AbilityKit';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { PdfKnowledgeRepository } from '../infra/PdfKnowledgeRepository';
import { PdfVectorRepository } from '../infra/PdfVectorRepository';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { EmbeddingWorkflow } from '../application/EmbeddingWorkflow';
import { EmbeddingTransportPort } from '../domain/KnowledgePorts';
import { EmbeddingConfig, EmbeddingGrant, EmbeddingPurpose, EmbeddingVectorResponse, EmbeddingModelInfo, EmbeddingDetectionStatus, QueryConsentSnapshot } from '../domain/EmbeddingModels';
import { KnowledgeCancellation, KnowledgeFailure, PdfKnowledgeDocument, PdfIngestionJob, PdfChunk, KnowledgePin, PdfPartialApproval, PdfStage } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
class BasisSmallTransport implements EmbeddingTransportPort {
  requests: number = 0; failure: string = '';
  requestCount(): number { return this.requests; }
  async models(_config: EmbeddingConfig, _grant: EmbeddingGrant, _cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> { throw new KnowledgeFailure('NoFixtureModels','suite'); }
  async embed(config: EmbeddingConfig, _grant: EmbeddingGrant, _purpose: EmbeddingPurpose, _input: string, cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> { this.requests++; cancel.check(); if (this.failure.length > 0) { throw new KnowledgeFailure(this.failure,'fixture'); } const result: EmbeddingVectorResponse = new EmbeddingVectorResponse(); result.model = config.modelId; result.index = 0; result.vector = new Float32Array([1,0,0]); return result; }
  cancel(): void {}
}
function basisContractPaused(workflow: EmbeddingWorkflow): boolean { return workflow.progressStage === 'ContractRejectedPaused' && workflow.detection.status === EmbeddingDetectionStatus.Failed; }
export async function embeddingSmallScopeCase(context: common.Context, host: KnowledgeStoreHost, pdf: PdfKnowledgeRepository, scope: KnowledgeStorageScope): Promise<void> {
  scope.requireTestOwner(scope.key); const identity = new KnowledgePlatformIdentity(); const document: PdfKnowledgeDocument = new PdfKnowledgeDocument(); document.id = identity.id(); document.sourceKey = `small-${scope.key}`; document.binding.originalId = 'small-source'; document.binding.originalAssetId = 'small-original'; document.binding.resultAssetId = 'small-result'; document.binding.originalHash = '1'.repeat(64); document.binding.zipHash = '2'.repeat(64); document.binding.originalVersion = 1; document.binding.originalPages = 1; document.binding.originalBytes = 128;
  const job: PdfIngestionJob = new PdfIngestionJob(); job.id = identity.id(); job.documentId = document.id; job.generation = identity.id(); job.sourceId = document.binding.originalId; job.binding = document.binding; job.processingKey = `small-${scope.key}`; job.ownerSession = scope.key;
  const pins: KnowledgePin[] = []; for (let at: number = 0; at < 2; at++) { const pin: KnowledgePin = new KnowledgePin(); pin.id = identity.id(); pin.ownerId = job.id; pin.documentId = document.id; pin.generation = job.generation; pin.sourceId = job.sourceId; pin.assetId = at === 0 ? document.binding.originalAssetId : document.binding.resultAssetId; pin.assetHash = at === 0 ? document.binding.originalHash : document.binding.zipHash; pins.push(pin); }
  await pdf.register(document,job,pins); job.snapshotId = identity.id(); job.snapshotHash = '3'.repeat(64); job.reportHash = '4'.repeat(64); job.stage = PdfStage.Review; job.checkpoint = PdfStage.Review; await pdf.checkpoint(job);
  const chunks: PdfChunk[] = []; for (let at: number = 0; at < 5; at++) { const chunk: PdfChunk = new PdfChunk(); chunk.id = `${job.generation}-${at}`; chunk.documentId = document.id; chunk.generation = job.generation; chunk.snapshotId = job.snapshotId; chunk.snapshotHash = job.snapshotHash; chunk.originalHash = document.binding.originalHash; chunk.originalVersion = 1; chunk.ordinal = at; chunk.text = 'fixture duplicate input'; chunk.retrievalText = chunk.text; chunk.inputHash = await identity.hash(pdfCodecUtf8(chunk.text)); chunks.push(chunk); }
  const approval: PdfPartialApproval = new PdfPartialApproval(); approval.reportHash = job.reportHash; approval.snapshotHash = job.snapshotHash; approval.confirmedAt = Date.now(); await pdf.prepare(document,job,chunks,approval); await pdf.publish(document,job,approval);
  const metadata = new PdfVectorRepository(host,pdf); const vectors = new VectorRdbRepository(context,scope); const transport = new BasisSmallTransport(); const workflow = new EmbeddingWorkflow(metadata,vectors,transport,identity,pdf,pdf,scope.key,new EmbeddingTokenAdapter(context,identity)); workflow.config.modelId = 'BAAI/bge-m3'; workflow.credentialReady = true; workflow.detection.status = EmbeddingDetectionStatus.Passed; workflow.detection.configFingerprint = embeddingFingerprint(workflow.config); workflow.detection.requestedModel = workflow.config.modelId; workflow.detection.returnedModel = workflow.config.modelId; workflow.detection.dimension = 3; await workflow.acceptBaseline();
  try {
    await workflow.vectorize(document.id,true,true); const first = workflow.current;
    if (first === undefined || transport.requests !== 3 || workflow.progressStage !== 'SmallScopePaused' || (await pdf.get(document.id))?.activeVectorGeneration !== '') { throw new KnowledgeFailure('SmallScopeExceededOrPublished','suite'); }
    const trial = await workflow.trialScope(first.id); if (trial.inputs.length !== 3 || trial.targets.some((target): boolean => !trial.inputs.some((input): boolean => input.chunk.id === target.chunkIds[0]))) { throw new KnowledgeFailure('TrialScopeEscaped','suite'); }
    const proof = await workflow.queryReview('fixture evidence');
    for (const purpose of ['query','trial']) { for (const edit of ['text','space','config','role','purpose','scope','hash','binding']) {
      if (purpose === 'query' && edit === 'scope') { continue; }
      const approval = new QueryConsentSnapshot(); approval.actual = edit === 'text' ? 'changed' : 'fixture evidence'; approval.inputHash = edit === 'hash' ? 'a'.repeat(64) : proof.textHash; approval.bindingHash = edit === 'binding' ? 'b'.repeat(64) : proof.bindingHash; approval.role = edit === 'role' ? 'document' : 'query'; approval.purpose = edit === 'purpose' ? 'other' : purpose; approval.space = edit === 'space' ? 'other' : trial.space.id; approval.config = edit === 'config' ? 'stale' : embeddingFingerprint(workflow.config); approval.approved = true; approval.free = true; approval.trial = purpose === 'trial' ? trial.id : ''; approval.scopeHash = purpose === 'trial' ? edit === 'scope' ? 'c'.repeat(64) : trial.setHash : '';
      const beforeRows = await host.requireStore().querySql('SELECT count(*) FROM kb_embedding_grant'); let before: number = 0; try { beforeRows.goToNextRow(); before = beforeRows.getLong(0); } finally { beforeRows.close(); }
      let rejected: boolean = false; try { if (purpose === 'trial') { await workflow.trialQuery(first.id,'fixture evidence',true,true,approval); } else { await workflow.searchReviewed(approval,false,false,new KnowledgeCancellation()); } } catch { rejected = true; }
      const afterRows = await host.requireStore().querySql('SELECT count(*) FROM kb_embedding_grant'); try { afterRows.goToNextRow(); if (edit !== 'scope' || purpose === 'trial') { if (!rejected || transport.requests !== 3 || afterRows.getLong(0) !== before) { throw new KnowledgeFailure('StaleSnapshotCreatedGrantOrCall','suite'); } } } finally { afterRows.close(); }
    } }
    for (const mode of ['consent','free']) { let rejected: boolean = false; try { await workflow.trialQuery(first.id,'fixture evidence',mode !== 'consent',mode !== 'free'); } catch { rejected = true; } if (!rejected || transport.requestCount() !== 3) { throw new KnowledgeFailure('TrialConsentBoundarySent','suite'); } }
    const result = await workflow.trialQuery(first.id,'fixture evidence',true,true);
    if (transport.requestCount() !== 4 || result.vectorHits.length !== 3 || result.vectorHits.some((hit): boolean => !trial.targets.some((target): boolean => target.chunkIds[0] === hit.chunkId)) || (await pdf.get(document.id))?.activeVectorGeneration !== '') { throw new KnowledgeFailure('TrialQueryExpandedOrPublished','suite'); }
    let duplicate: boolean = false; try { await workflow.trialQuery(first.id,'fixture evidence',true,true); } catch { duplicate = true; } if (!duplicate || transport.requestCount() !== 4) { throw new KnowledgeFailure('TrialQueryRepeated','suite'); }
    await workflow.vectorize(document.id,true,true,first.id,false,true); if (transport.requestCount() !== 6 || (await pdf.get(document.id))?.activeVectorGeneration !== first.vectorGeneration) { throw new KnowledgeFailure('SmallResumeDuplicatedVerified','suite'); }
    await vectors.close(); await workflow.restoreActive(document.id); if (transport.requestCount() !== 6 || (await metadata.targets(first.spaceId,false,false)).length !== 5) { throw new KnowledgeFailure('FullRestoreSentOrLostMirror','suite'); }
    for (const failure of ['HttpRejected:400','VectorModelMismatch']) { transport.failure = failure; const before = transport.requestCount(); let rejected: boolean = false; try { await workflow.vectorize(document.id,true,true); } catch { rejected = true; } if (!rejected || transport.requestCount() !== before+1 || !basisContractPaused(workflow) || (await pdf.get(document.id))?.activeVectorGeneration !== first.vectorGeneration) { throw new KnowledgeFailure('ContractErrorDidNotPause','suite'); } workflow.detection.status = EmbeddingDetectionStatus.Passed; }
  } finally { await vectors.close(); }
}
