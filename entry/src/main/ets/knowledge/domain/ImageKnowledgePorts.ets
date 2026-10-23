import { ImageOriginal, ImageDocument, ImageJob, ImageAssetClaim, ImageReadLease, ImageReleaseReceipt, ImageSnapshot, ImageChunk, ImageCleanupIntent, ImageHeaderEvidence, ImageTextProjection } from './ImageKnowledgeModels';
import { KnowledgeCancellation } from './PdfKnowledgeModels';
import { KnowledgeHit } from './KnowledgeSearchModels';
import { TextQueryInput } from './TextKnowledgeModels';

export interface ImageHeaderReader { length: number; read(offset: number, length: number): Promise<Uint8Array>; }
export interface ImageOriginalPort {
  verify(original: ImageOriginal, cancel: KnowledgeCancellation): Promise<ImageHeaderEvidence>;
  preview?(original: ImageOriginal, cancel: KnowledgeCancellation): Promise<ImageHeaderEvidence>;
  release(): Promise<ImageReleaseReceipt>;
}
export interface ImageRepositoryPort {
  open(): Promise<void>; close(): Promise<void>; ready(): boolean;
  register(original: ImageOriginal, assets: ImageAssetClaim[]): Promise<void>;
  list(): Promise<ImageDocument[]>; get(id: string): Promise<ImageDocument | undefined>;
  original(asset: string): Promise<ImageOriginal>;
  latestOriginal(documentId: string): Promise<ImageOriginal>;
  begin(job: ImageJob): Promise<void>; checkpoint(job: ImageJob): Promise<void>; jobs(): Promise<ImageJob[]>;
  prepare(job: ImageJob, snapshot: ImageSnapshot, chunks: ImageChunk[]): Promise<void>;
  snapshot(generation: string): Promise<ImageSnapshot>; chunks(generation: string): Promise<ImageChunk[]>;
  publish(job: ImageJob, reportHash: string): Promise<boolean>;
  acquireRead(lease: ImageReadLease): Promise<void>; releaseRead(receipt: ImageReleaseReceipt): Promise<void>;
  archive(id: string, archived: boolean): Promise<void>; deleteDocument(id: string): Promise<void>;
  cleanups(): Promise<ImageCleanupIntent[]>;
  claimCleanup(id: string): Promise<ImageCleanupIntent | undefined>; finishCleanup(claim: ImageCleanupIntent, failure: string): Promise<void>;
  removeSnapshotClaim(claim: ImageCleanupIntent): Promise<void>;
  directCandidates(input: TextQueryInput, archived: boolean, extras: boolean, cancel: KnowledgeCancellation): Promise<KnowledgeHit[]>;
}
export interface ImageContentPort { normalize(original: ImageOriginal, bytes: Uint8Array, profile: string, generation: string, cancel: KnowledgeCancellation): Promise<ImageSnapshot>; }
export interface ImageResultReaderPort { read(original: ImageOriginal, taskId: string, cancel: KnowledgeCancellation): Promise<ImageTextProjection>; }
export interface ImageSnapshotAssetPort {
  save(snapshot: ImageSnapshot, cancel: KnowledgeCancellation): Promise<string>;
  read(asset: string, hash: string, cancel: KnowledgeCancellation): Promise<Uint8Array>;
  remove(asset: string): Promise<void>;
}
