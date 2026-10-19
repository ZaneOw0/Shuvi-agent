import {
  PdfSourceBinding, PdfZipManifest, PdfZipMember, PdfNormalizedDocument, PdfKnowledgeDocument, PdfIngestionJob,
  PdfPartialApproval, PdfChunk, KnowledgePin, KnowledgeReadLease, KnowledgeCleanupIntent, KnowledgeCancellation,
  PdfMappingEvidence, PdfLocator
} from './PdfKnowledgeModels';
import {
  EmbeddingConfig, EmbeddingModelInfo, EmbeddingCredentialStatus, EmbeddingPurpose, EmbeddingVectorResponse,
  EmbeddingDetection, EmbeddingGrant, EmbeddingSpace, EmbeddingJob, KnowledgeVectorRow, KnowledgeVectorCandidate
} from './EmbeddingModels';
import { KnowledgeHit, KnowledgeHistory, KnowledgeHistoryCursor, KnowledgeHistoryPage } from './KnowledgeSearchModels';
import { TextQueryInput } from './TextKnowledgeModels';
import { PdfPageIdentityEvidence, ResultPageReference } from './PdfLocalModels';
import { KnowledgeScopeReceipt } from './ImageKnowledgeModels';
import { QueryConsentSnapshot } from './EmbeddingModels';

export class KnowledgeSourceScan { kind: string = ''; revision: string = ''; count: number = 0; complete: boolean = false; hits: KnowledgeHit[] = []; }
export interface KnowledgeSearchSourcePort {
  kind: string;
  scan(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeSourceScan>;
  visible(hit: KnowledgeHit, archived: boolean): Promise<boolean>;
}
export interface KnowledgeQueryAdmissionPort {
  admit(approval: QueryConsentSnapshot, input: string, cancel: KnowledgeCancellation, launch: () => void): Promise<void>;
}
export interface KnowledgeScopePort {
  scan(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeScopeReceipt>;
  hits(receiptId: string): KnowledgeHit[];
  visible(hit: KnowledgeHit, archived: boolean): Promise<boolean>;
  admit(approval: QueryConsentSnapshot, input: string, cancel: KnowledgeCancellation, launch: () => void): Promise<void>;
}

export interface KnowledgePageReferencePort { resolve(hit: KnowledgeHit, cancel: KnowledgeCancellation): Promise<ResultPageReference>; }
export interface PdfPageIdentityRepositoryPort extends KnowledgeSourceReadPort {
  get(id: string): Promise<PdfKnowledgeDocument | undefined>;
  generationJob(generation: string): Promise<PdfIngestionJob>;
  chunkSources(id: string, generation: string): Promise<string[]>;
  pageIdentities(generation: string, node: string): Promise<PdfPageIdentityEvidence[]>;
  appendPageIdentity(evidence: PdfPageIdentityEvidence): Promise<void>;
  sourceRelease(lease: KnowledgeReadLease, failure: string): Promise<void>;
}

export interface KnowledgeStateListener { changed(): void; }
export interface KnowledgeDocumentListPort { list(): Promise<PdfKnowledgeDocument[]>; listPage(offset: number, limit: number): Promise<PdfKnowledgeDocument[]>; }
export interface KnowledgeSourceReadPort { acquireRead(lease: KnowledgeReadLease): Promise<void>; releaseRead(id: string): Promise<void>; }
export class KnowledgeCallbackListener implements KnowledgeStateListener {
  private callback: () => void;
  constructor(callback: () => void) { this.callback = callback; }
  changed(): void { this.callback(); }
}
export interface KnowledgeIdentityPort { id(): string; hash(bytes: Uint8Array): Promise<string>; }
export interface KnowledgeRangeReader { length: number; read(offset: number, length: number, cancel: KnowledgeCancellation): Promise<Uint8Array>; close(): Promise<void>; }
export interface PdfArchivePort {
  capability(): string;
  inspect(binding: PdfSourceBinding, cancel: KnowledgeCancellation): Promise<PdfZipManifest>;
  readMember(manifest: PdfZipManifest, member: PdfZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array>;
  release(): Promise<void>;
}
export interface PdfNormalizationPort {
  normalize(binding: PdfSourceBinding, manifest: PdfZipManifest, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument>;
  cancel?(): void;
  chunks?(snapshot: PdfNormalizedDocument, generation: string, cancel: KnowledgeCancellation): Promise<PdfChunk[]>;
  verifySnapshot?(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<void>;
  sealSnapshot?(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument>;
}
export interface PdfAssetPort {
  saveImages(snapshot: PdfNormalizedDocument, archive: PdfArchivePort, cancel: KnowledgeCancellation): Promise<void>;
  save(snapshot: PdfNormalizedDocument, cancel: KnowledgeCancellation): Promise<void>;
  read(snapshotId: string, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument>;
  remove(claim: KnowledgeCleanupIntent): Promise<void>; usageBytes(): Promise<number>; reconcile(): Promise<void>;
  recoverSnapshot?(generation: string, cancel: KnowledgeCancellation): Promise<PdfNormalizedDocument | undefined>;
}
export interface PdfPagePort {
  capability(): string; openOriginal(binding: PdfSourceBinding, cancel: KnowledgeCancellation): Promise<void>;
  verifiedLocator(locator: PdfLocator, evidence: PdfMappingEvidence[]): PdfLocator;
  close(): Promise<void>;
}
export interface KnowledgeSourceProtectionPort {
  withSource<T>(sourceId: string, action: () => Promise<T>): Promise<T>;
  assertDeletable(sourceId: string, assetIds: string[]): Promise<void>;
  assertCleanup(assetIds: string[]): Promise<void>;
}
export interface PdfRepositoryPort {
  open(): Promise<void>; close(): Promise<void>; ready(): boolean;
  register(document: PdfKnowledgeDocument, job: PdfIngestionJob, pins: KnowledgePin[]): Promise<PdfIngestionJob>;
  checkpoint(job: PdfIngestionJob): Promise<void>; jobs(): Promise<PdfIngestionJob[]>;
  list(): Promise<PdfKnowledgeDocument[]>; get(id: string): Promise<PdfKnowledgeDocument | undefined>;
  prepare(document: PdfKnowledgeDocument, job: PdfIngestionJob, chunks: PdfChunk[], approval: PdfPartialApproval): Promise<void>;
  publish(document: PdfKnowledgeDocument, job: PdfIngestionJob, approval: PdfPartialApproval): Promise<boolean>;
  candidates(input: TextQueryInput, archived: boolean, referenceAside: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
  visible(hit: KnowledgeHit, archived: boolean): Promise<boolean>;
  pins(sourceId: string, assetIds: string[]): Promise<KnowledgePin[]>;
  acquireRead(lease: KnowledgeReadLease): Promise<void>; releaseRead(id: string): Promise<void>;
  archive(id: string, archived: boolean): Promise<void>; deleteDocument(id: string): Promise<void>; abandon(jobId: string): Promise<void>;
  cleanups(): Promise<KnowledgeCleanupIntent[]>; claimCleanup(id: string): Promise<KnowledgeCleanupIntent | undefined>;
  finishCleanup(claim: KnowledgeCleanupIntent, failure: string): Promise<void>; reconcile(sessionId: string): Promise<void>;
  saveConfig(config: EmbeddingConfig): Promise<void>; configs(): Promise<EmbeddingConfig[]>;
  saveDetection(detection: EmbeddingDetection): Promise<void>; saveModels(config: EmbeddingConfig, models: EmbeddingModelInfo[]): Promise<void>;
  saveGrant(grant: EmbeddingGrant): Promise<void>; revokeGrants(fingerprint: string): Promise<void>;
  saveSpace(space: EmbeddingSpace): Promise<void>; saveVectorJob(job: EmbeddingJob): Promise<void>;
  publishVectors(job: EmbeddingJob, expectedHashes: string[]): Promise<boolean>;
  saveHistory(history: KnowledgeHistory): Promise<void>; history(cursor: KnowledgeHistoryCursor, limit: number): Promise<KnowledgeHistoryPage>;
}
export interface EmbeddingCredentialPort {
  status(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus>;
  save(config: EmbeddingConfig, input: string, replace: boolean): Promise<EmbeddingCredentialStatus>;
  remove(config: EmbeddingConfig): Promise<EmbeddingCredentialStatus>; clearTransient(): void;
}
export interface EmbeddingTransportPort {
  queryEgress?: boolean;
  models(config: EmbeddingConfig, grant: EmbeddingGrant, cancel: KnowledgeCancellation): Promise<EmbeddingModelInfo[]>;
  embed(config: EmbeddingConfig, grant: EmbeddingGrant, purpose: EmbeddingPurpose, input: string, cancel: KnowledgeCancellation): Promise<EmbeddingVectorResponse>;
  cancel(): void;
}
export interface KnowledgeVectorPort {
  capability(): string; open(): Promise<void>; register(space: EmbeddingSpace): Promise<void>;
  put(row: KnowledgeVectorRow): Promise<void>; read(spaceId: string, chunkId: string, vectorGeneration: string): Promise<KnowledgeVectorRow | undefined>;
  knn(space: EmbeddingSpace, query: Float32Array, limit: number, cancel: KnowledgeCancellation): Promise<KnowledgeVectorCandidate[]>;
  remove(claim: KnowledgeCleanupIntent): Promise<void>; close(): Promise<void>;
}
