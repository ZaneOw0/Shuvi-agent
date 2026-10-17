import { EmbeddingSpace, EmbeddingJob, TokenEligibilityEvidence, EmbeddingPurpose, EmbeddingConfig, KnowledgeVectorRow, KnowledgeVectorCandidate, EmbeddingGrant, EmbeddingUsage } from './EmbeddingModels';
import { PdfChunk, PdfKnowledgeDocument, KnowledgeCancellation, KnowledgeReadLease } from './PdfKnowledgeModels';
import { KnowledgeHit } from './KnowledgeSearchModels';
import { EmbeddingBaselineAcceptance, EmbeddingDryReview } from './EmbeddingBasisModels';
import { QueryConsentSnapshot } from './EmbeddingModels';

export enum VectorInputState { NotSent = 'NotSent', InFlight = 'InFlight', Received = 'Received', Verified = 'ReadbackVerified', Unknown = 'Unknown' }
export class VectorInputRecord { chunk: PdfChunk = new PdfChunk(); state: VectorInputState = VectorInputState.NotSent; readbackHash: string = ''; }
export class VectorCorpusPlan { document: PdfKnowledgeDocument = new PdfKnowledgeDocument(); snapshotHash: string = ''; inputs: VectorInputRecord[] = []; }
export class VectorUsageSummary { received: number = 0; reportedTotal: number = 0; missingUsage: number = 0; unknown: number = 0; }
export class VectorEligibility {
  documentId: string = ''; contentGeneration: string = ''; vectorGeneration: string = ''; spaceId: string = ''; epoch: number = 0; revision: number = 0;
  archived: boolean = false; chunkIds: string[] = [];
  inputHash: string = '';
  readbackHash: string = '';
}
export class VectorCleanupTarget { spaceId: string = ''; vectorGeneration: string = ''; contentGeneration: string = ''; owner: string = ''; state: string = 'Pending'; failure: string = ''; }
export class EmbeddingTrialScope {
  id: string = ''; job: EmbeddingJob = new EmbeddingJob(); space: EmbeddingSpace = new EmbeddingSpace();
  targets: VectorEligibility[] = []; inputs: VectorInputRecord[] = []; setHash: string = '';
}
export class EmbeddingTrialResult {
  trialId: string = ''; queryHash: string = ''; scopeHash: string = ''; grantId: string = ''; bound: number = 0;
  dimension: number = 0; elapsed: number = 0; usage: EmbeddingUsage = new EmbeddingUsage();
  vectorHits: KnowledgeHit[] = []; keywordHits: KnowledgeHit[] = []; hits: KnowledgeHit[] = [];
  notice: string = ''; expectedFull: number = 0;
}
export class EmbeddingCorpusReceipt {
  jobId: string = ''; vectorGeneration: string = ''; spaceId: string = ''; chunkId: string = ''; inputHash: string = '';
  readbackHash: string = ''; bound: number = 0; dimension: number = 0; elapsed: number = 0; total: number = -1; prompt: number = -1; grantId: string = '';
}
export class EmbeddingQueryReceipt {
  hash: string = ''; grant: string = ''; space: string = ''; bound: number = 0; dimension: number = 0;
  elapsed: number = 0; total: number = -1; prompt: number = -1; targets: number = 0; candidates: number = 0;
}
export interface EmbeddingTrialMetadataPort {
  assertTrial(job: EmbeddingJob): Promise<void>;
  trialHit(chunk: string, scope: EmbeddingTrialScope): Promise<KnowledgeHit>;
  beginTrialQuery(scope: EmbeddingTrialScope, grant: EmbeddingGrant): Promise<void>;
  finishTrialQuery(trialId: string, stage: string, result: EmbeddingTrialResult): Promise<void>;
  recordCorpusReceipt(receipt: EmbeddingCorpusReceipt): Promise<void>;
}
export interface EmbeddingTokenCounterPort { evidence(modelId: string, role: string, text: string, textHash: string): Promise<TokenEligibilityEvidence>; }
export interface EmbeddingBaselinePort { baseline(config: EmbeddingConfig): Promise<EmbeddingBaselineAcceptance>; }
export interface VectorWorkflowRepository extends EmbeddingBaselinePort, EmbeddingTrialMetadataPort {
  saveBaseline(basis: EmbeddingBaselineAcceptance): Promise<void>;
  baseline(config: EmbeddingConfig): Promise<EmbeddingBaselineAcceptance>;
  document(documentId: string): Promise<PdfKnowledgeDocument>;
  corpus(documentId: string): Promise<VectorCorpusPlan>;
  spaces(): Promise<EmbeddingSpace[]>;
  saveSpace(space: EmbeddingSpace): Promise<void>;
  begin(job: EmbeddingJob, plan: VectorCorpusPlan): Promise<void>;
  bindGrant(job: EmbeddingJob, grant: EmbeddingGrant): Promise<void>;
  authorizeResend(job: EmbeddingJob, chunk: string, grant: EmbeddingGrant): Promise<void>;
  recordUsage(job: EmbeddingJob, chunk: string, total: number | undefined, prompt: number | undefined): Promise<void>;
  jobs(): Promise<EmbeddingJob[]>;
  jobsPage?(offset: number, limit: number): Promise<EmbeddingJob[]>;
  inputs(job: EmbeddingJob): Promise<VectorInputRecord[]>;
  inputState(job: EmbeddingJob, chunk: string, state: VectorInputState, hash: string): Promise<void>;
  pauseJob(job: EmbeddingJob, failure: string): Promise<void>;
  publish(job: EmbeddingJob, expected: string[]): Promise<boolean>;
  eligibility(documentId: string): Promise<VectorEligibility | undefined>;
  acknowledge(target: VectorEligibility): Promise<void>;
  targets(spaceId: string, archived: boolean, extras: boolean): Promise<VectorEligibility[]>;
  hit(chunkId: string, target: VectorEligibility, archived: boolean, extras: boolean): Promise<KnowledgeHit | undefined>;
  reserve(id: string, bytes: number): Promise<void>;
  releaseReservation(id: string): Promise<void>;
  checkBudget(): Promise<void>;
  usage(): Promise<VectorUsageSummary>;
  releaseFailure(lease: KnowledgeReadLease, failure: string): Promise<void>;
  pendingReleases(session: string): Promise<KnowledgeReadLease[]>;
  saveReview(review: EmbeddingDryReview): Promise<void>;
}
export interface KnowledgeSemanticSearchPort {
  queryEgress: boolean;
  search(input: string, spaceId: string, consent: boolean, free: boolean, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
  searchReviewed?(approval: QueryConsentSnapshot, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
  spaces(): Promise<EmbeddingSpace[]>;
  pause(): void;
}
export interface EmbeddingInputPolicyPort {
  verify(config: EmbeddingConfig, purpose: EmbeddingPurpose, input: string, hash: string): Promise<TokenEligibilityEvidence>;
}
export interface VectorWorkflowStorePort {
  open(): Promise<void>; register(space: EmbeddingSpace): Promise<void>;
  put(row: KnowledgeVectorRow): Promise<void>; read(spaceId: string, chunk: string, generation: string): Promise<KnowledgeVectorRow | undefined>;
  synchronize(target: VectorEligibility): Promise<void>;
  filteredKnn(space: EmbeddingSpace, query: Float32Array, targets: VectorEligibility[], cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]>;
  trialKnn(space: EmbeddingSpace, query: Float32Array, targets: VectorEligibility[], cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]>;
}
