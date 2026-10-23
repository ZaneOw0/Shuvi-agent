import { common } from '@kit.AbilityKit';
import { CloseoutSourceFixture } from './CloseoutSourceFixture';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingWorkflow } from '../application/EmbeddingWorkflow';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { EmbeddingCredentialPort, EmbeddingTransportPort } from '../domain/KnowledgePorts';
import { EmbeddingConfig, EmbeddingCredentialStatus, EmbeddingGrant, EmbeddingPurpose, EmbeddingModelInfo, EmbeddingVectorResponse, EmbeddingDetectionStatus } from '../domain/EmbeddingModels';
import { PdfChunk, PdfPartialApproval, KnowledgeCancellation, KnowledgeFailure } from '../domain/PdfKnowledgeModels';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { EmbeddingTokenAdapter } from '../infra/EmbeddingTokenAdapter';
import { VectorRdbRepository } from '../infra/VectorRdbRepository';
import { PdfVectorRepository } from '../infra/PdfVectorRepository';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { hilog } from '@kit.PerformanceAnalysisKit';
class CloseoutNoCredential implements EmbeddingCredentialPort {
  async status(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { return EmbeddingCredentialStatus.Configured; }
  async save(_config: EmbeddingConfig,_input: string,_replace: boolean): Promise<EmbeddingCredentialStatus> { throw new KnowledgeFailure('FixtureNoCredentialWrite','fixture'); }
  async remove(_config: EmbeddingConfig): Promise<EmbeddingCredentialStatus> { throw new KnowledgeFailure('FixtureNoCredentialWrite','fixture'); }
  clearTransient(): void {}
}
class CloseoutOnlyInjectedTransport implements EmbeddingTransportPort {
  calls: number = 0;
  async models(_config: EmbeddingConfig,_grant: EmbeddingGrant,_cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]> { throw new KnowledgeFailure('FixtureNoModels','fixture'); }
  async embed(config: EmbeddingConfig,_grant: EmbeddingGrant,purpose: EmbeddingPurpose,_input: string,_cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse> { this.calls++; if (this.calls > 3 || purpose !== EmbeddingPurpose.Corpus) { throw new KnowledgeFailure('UnexpectedFixtureQueryCall','fixture'); } const response = new EmbeddingVectorResponse(); response.model = config.modelId; response.index = 0; response.vector = new Float32Array([1,0,0]); return response; }
  cancel(): void {}
}
export class CloseoutQueryFixture {
  source: CloseoutSourceFixture; embedding: EmbeddingService; workflow: EmbeddingWorkflow; search: KnowledgeSearchService; vectors: VectorRdbRepository; metadata: PdfVectorRepository;
  private transport: CloseoutOnlyInjectedTransport = new CloseoutOnlyInjectedTransport(); job: string = ''; space: string = '';
  constructor(context: common.Context,scope: KnowledgeStorageScope) {
    this.source = new CloseoutSourceFixture(context,scope); const identity = new KnowledgePlatformIdentity(); this.vectors = new VectorRdbRepository(context,scope); this.metadata = new PdfVectorRepository(this.source.host,this.source.pdf);
    this.workflow = new EmbeddingWorkflow(this.metadata,this.vectors,this.transport,identity,this.source.pdf,this.source.pdf,scope.key,new EmbeddingTokenAdapter(context,identity)); this.embedding = new EmbeddingService(this.source.pdf,new CloseoutNoCredential(),this.transport,identity); this.embedding.attachWorkflow(this.workflow); this.search = new KnowledgeSearchService(this.source.text,this.source.pdf,identity); this.search.attachSemantic(this.workflow);
  }
  async prepare(): Promise<void> {
    await this.source.prepare(); const identity = new KnowledgePlatformIdentity(); const chunks: PdfChunk[] = [];
    for (let at: number = 0; at < 5; at++) { const chunk = new PdfChunk(); chunk.id = `ui-chunk-${at}`; chunk.documentId = this.source.job.documentId; chunk.generation = this.source.job.generation; chunk.snapshotId = this.source.snapshot.id; chunk.snapshotHash = this.source.snapshot.hash; chunk.originalHash = this.source.binding.originalHash; chunk.originalVersion = 1; chunk.ordinal = at; chunk.text = 'synthetic consent fixture'; chunk.retrievalText = chunk.text; chunk.inputHash = await identity.hash(pdfCodecUtf8(chunk.text)); chunks.push(chunk); }
    const approval = new PdfPartialApproval(); approval.snapshotHash = this.source.snapshot.hash; approval.reportHash = this.source.job.reportHash; approval.confirmedAt = Date.now(); const document = await this.source.pdf.get(this.source.job.documentId); if (document === undefined) { throw new Error('FixtureDocument'); } await this.source.pdf.prepare(document,this.source.job,chunks,approval); await this.source.pdf.publish(document,this.source.job,approval);
    const state = this.embedding.state; state.config.modelId = 'BAAI/bge-m3'; state.credential = EmbeddingCredentialStatus.Configured; state.detection.status = EmbeddingDetectionStatus.Passed; state.detection.dimension = 3; state.detection.configFingerprint = embeddingFingerprint(state.config); state.detection.requestedModel = state.config.modelId; state.detection.returnedModel = state.config.modelId; await this.embedding.acceptBaseline(); await this.embedding.dryReview(document.id); await this.embedding.vectorizePdf(document.id,true,true); const job = this.workflow.current; if (job === undefined || this.transport.calls !== 3) { throw new Error('FixtureThreeInputs'); } this.job = job.id; this.space = job.spaceId;
  }
  async audit(): Promise<void> { const rows = await this.source.host.requireStore().querySql('SELECT (SELECT count(*) FROM kb_embedding_grant WHERE purpose=?),(SELECT count(*) FROM r2v_trial_query)',[EmbeddingPurpose.Query]); try { rows.goToNextRow(); const grants = rows.getLong(0); const trials = rows.getLong(1); hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_CLOSEOUT_UI injected=${this.transport.calls} initial=3 query_grants=${grants} trial_attempts=${trials} requests=0`); if (grants !== 0 || trials !== 0 || this.transport.calls !== 3) { throw new KnowledgeFailure('ConsentUiUnexpectedGrantOrCall','fixture'); } } finally { rows.close(); } }
  async close(): Promise<void> { this.embedding.pause(); await this.vectors.close(); await this.source.close(); }
}
