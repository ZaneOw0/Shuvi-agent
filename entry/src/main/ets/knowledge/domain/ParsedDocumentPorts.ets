import {
  ParsedDocument, ParsedDocumentRecord, ParsedTextChunk, ParsedImageAsset, ParsedAssetRef, ParsedAssetWrite,
  ParsedReadLease, ParsedLegacyLink, ParsedCancellation, ParsedSnapshotBundle, ParsedFormat, ParsedAssetPreview
} from './ParsedDocumentModels';
import {
  UnifiedProcessingSettings, UnifiedProcessingGrant, UnifiedProcessingBatch, UnifiedProcessingJob, UnifiedProcessingAttempt,
  UnifiedEffectiveAnnotation, UnifiedHistoryRevision, UnifiedIndexBinding
} from './UnifiedKnowledgeModels';

export interface ParsedIdentityPort { id(): string; hash(bytes: Uint8Array): Promise<string>; }
export class ParsedSourceAsset { id: string = ''; owner: string = ''; role: string = ''; }
export class ParsedImportRequest {
  namespace: string = ''; sourceId: string = ''; sourceHash: string = ''; sourceVersion: number = 1;
  title: string = ''; format: ParsedFormat = ParsedFormat.Text; parserSignature: string = ''; engine: string = '';
  outputIdentity: string = ''; sources: ParsedSourceAsset[] = [];
}
export interface ParsedProducerPort {
  produce(request: ParsedImportRequest, documentKey: string, generation: string, assets: ParsedAssetPort, cancel: ParsedCancellation): Promise<ParsedDocument>;
}
export interface ParsedImageBytesPort { read(cancel: ParsedCancellation): Promise<Uint8Array>; }
export interface ParsedPhysicalUsagePort { totalBytes(): Promise<number>; }
export interface ParsedPublicationVerificationPort {
  verifyPublication(document: ParsedDocument, manifestId: string, contentHash: string): Promise<void>;
}
export interface ParsedAssetLedgerPort {
  reusableImage?(hash: string): Promise<ParsedImageAsset | undefined>;
  reserve(write: ParsedAssetWrite, asset: ParsedImageAsset): Promise<void>;
  assetWrite(id: string): Promise<ParsedAssetWrite | undefined>; assetWrites(): Promise<ParsedAssetWrite[]>;
  asset(id: string): Promise<ParsedImageAsset | undefined>;
  materialized(id: string): Promise<void>; commitAsset(id: string): Promise<void>; assetMissing(id: string, reason: string): Promise<void>;
  restoreReservation(id: string, materializedBytes: number): Promise<void>;
  acquireLease(lease: ParsedReadLease): Promise<void>; releaseLease(id: string): Promise<void>;
  addRef(ref: ParsedAssetRef): Promise<void>; releaseRefs(holder: string): Promise<void>;
  claimAssetCleanup(id: string): Promise<boolean>; finishAssetCleanup(id: string, failure: string): Promise<void>;
}
export interface ParsedAssetPort {
  reuseImage?(hash: string, document: string, generation: string, cancel: ParsedCancellation): Promise<ParsedImageAsset | undefined>;
  openPreview(assetId: string, cancel: ParsedCancellation): Promise<ParsedAssetPreview>;
  closePreview(preview: ParsedAssetPreview): Promise<void>;
  save(asset: ParsedImageAsset, write: ParsedAssetWrite, bytes: Uint8Array, cancel: ParsedCancellation): Promise<ParsedImageAsset>;
  read(assetId: string, cancel: ParsedCancellation): Promise<Uint8Array>;
  saveSnapshot(document: ParsedDocument, cancel: ParsedCancellation): Promise<ParsedSnapshotBundle>;
  readSnapshot(manifestId: string, cancel: ParsedCancellation): Promise<ParsedDocument>;
  reconcile(cancel: ParsedCancellation): Promise<void>;
}
export interface ParsedRepositoryPort extends ParsedAssetLedgerPort {
  open(): Promise<void>; close(): Promise<void>; ready(): boolean;
  get(id: string): Promise<ParsedDocumentRecord | undefined>; list(): Promise<ParsedDocumentRecord[]>;
  register(record: ParsedDocumentRecord): Promise<void>;
  publish(document: ParsedDocument, chunks: ParsedTextChunk[], manifestId: string, contentHash: string, expectedEpoch: number, expectedOld: string, legacy?: ParsedLegacyLink): Promise<boolean>;
  chunks(id: string): Promise<ParsedTextChunk[]>;
  saveLegacyLink(link: ParsedLegacyLink): Promise<void>;
  settings(purpose: string): Promise<UnifiedProcessingSettings>; saveSettings(settings: UnifiedProcessingSettings): Promise<void>;
  saveGrant(grant: UnifiedProcessingGrant): Promise<void>; saveBatch(batch: UnifiedProcessingBatch): Promise<void>;
  saveJob(job: UnifiedProcessingJob): Promise<void>; jobs(): Promise<UnifiedProcessingJob[]>;
  saveAttempt(attempt: UnifiedProcessingAttempt): Promise<void>;
  saveAnnotation(annotation: UnifiedEffectiveAnnotation): Promise<void>;
  saveBinding(binding: UnifiedIndexBinding): Promise<void>;
  appendHistory(revision: UnifiedHistoryRevision): Promise<void>;
  assertLegacyUnheld(owner: string, assets: string[]): Promise<void>; heldLegacyAssets(owner: string): Promise<string[]>;
}
