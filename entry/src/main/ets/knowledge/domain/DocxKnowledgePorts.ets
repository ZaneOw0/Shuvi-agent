import { KnowledgeCancellation } from './PdfKnowledgeModels';
import { KnowledgeRangeReader } from './KnowledgePorts';
import { DocxOriginal, DocxSnapshot, DocxChunk, DocxDocument, DocxJob, DocxAssetClaim, DocxReadLease,
  DocxReleaseReceipt, DocxCleanupIntent, DocxResultBinding, DocxProjection } from './DocxKnowledgeModels';

export class DocxZipMember {
  name: string = ''; flags: number = 0; method: number = 0; crc: number = 0; compressed: number = 0; expanded: number = 0;
  localOffset: number = 0; dataOffset: number = 0; endOffset: number = 0;
}
export class DocxZipDirectory { role: string = ''; length: number = 0; directoryOffset: number = 0; members: DocxZipMember[] = []; }
export interface DocxArchivePort {
  inspect(reader: KnowledgeRangeReader, role: string, cancel: KnowledgeCancellation): Promise<DocxZipDirectory>;
  read(member: DocxZipMember, cancel: KnowledgeCancellation): Promise<Uint8Array>;
  release(): Promise<void>;
}
export interface DocxProcessingPort {
  prepare(original: DocxOriginal, result: DocxResultBinding, generation: string, cancel: KnowledgeCancellation): Promise<DocxSnapshot>;
  cancel(): void;
  retryRelease?(): Promise<void>;
}
export interface DocxResultPort { read(binding: DocxResultBinding, cancel: KnowledgeCancellation): Promise<DocxProjection>; retryRelease?(): Promise<void>; }
export interface DocxSnapshotAssetPort {
  save(snapshot: DocxSnapshot, cancel: KnowledgeCancellation): Promise<string>;
  read(assetId: string, hash: string, cancel: KnowledgeCancellation): Promise<Uint8Array>;
  remove(assetId: string): Promise<void>;
}
export interface DocxRepositoryPort {
  open(): Promise<void>; close(): Promise<void>; ready(): boolean;
  list(): Promise<DocxDocument[]>; get(id: string): Promise<DocxDocument | undefined>;
  documentForSource(sourceId: string): Promise<DocxDocument | undefined>;
  nextVersion(documentId: string): Promise<number>;
  original(assetId: string): Promise<DocxOriginal>; register(original: DocxOriginal, assets: DocxAssetClaim[]): Promise<void>;
  holdAsset(asset: DocxAssetClaim): Promise<void>;
  begin(job: DocxJob): Promise<void>; checkpoint(job: DocxJob): Promise<void>; jobs(): Promise<DocxJob[]>;
  acquireRead(lease: DocxReadLease): Promise<void>; releaseRead(receipt: DocxReleaseReceipt): Promise<void>;
  archive(id: string, archived: boolean): Promise<void>; deleteDocument(id: string): Promise<void>;
  cleanups(): Promise<DocxCleanupIntent[]>;
}
export interface DocxPublicationPort extends DocxRepositoryPort {
  snapshot(generation: string): Promise<DocxSnapshot>; chunks(generation: string): Promise<DocxChunk[]>;
  prepare(job: DocxJob, snapshot: DocxSnapshot, chunks: DocxChunk[]): Promise<void>;
  publish(job: DocxJob, reportHash: string): Promise<boolean>;
}
