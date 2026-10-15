import {
  DocumentFileSelection, DocumentSelectedFile, DocumentOriginal, DocumentParseCancellation,
  DocumentCredentialStatus, DocumentParseSnapshot, DocumentParseAction, DocumentAllocationReceipt,
  DocumentInspection, DocumentParseResultEnvelope, DocumentParseUsage
} from './DocumentParseModels';

export interface DocumentSelectionPort { select(): Promise<DocumentFileSelection>; }
export interface DocumentAssetPort {
  save(file: DocumentSelectedFile, id: string, cancel: DocumentParseCancellation): Promise<DocumentOriginal>;
  verify(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<void>;
  remove(ids: string[]): Promise<void>;
  cancelLocal(): void;
}
export interface DocumentPreflightPort { inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal>; cancelLocal(): void; }
export interface MineruCredentialPort {
  status(): Promise<DocumentCredentialStatus>;
  save(input: string, replace: boolean): Promise<DocumentCredentialStatus>;
  remove(): Promise<DocumentCredentialStatus>;
  clearTransient(): void;
}
export interface DocumentParseRepositoryPort {
  open(): Promise<void>; load(): Promise<DocumentParseSnapshot>;
  save(snapshot: DocumentParseSnapshot): Promise<void>; close(): Promise<void>;
}
export interface MineruTaskPort {
  allocate(action: DocumentParseAction): Promise<DocumentAllocationReceipt>;
  upload(action: DocumentParseAction): Promise<void>;
  inspect(action: DocumentParseAction): Promise<DocumentInspection>;
  receive(action: DocumentParseAction, usage: DocumentParseUsage): Promise<DocumentParseResultEnvelope>;
  removeLeases(ids: string[]): Promise<void>;
  reconcileLeases(keepIds: string[]): Promise<void>;
  pause(): void;
}
export interface DocumentParseClockPort { now(): number; id(): string; sleep(ms: number): Promise<void>; }
