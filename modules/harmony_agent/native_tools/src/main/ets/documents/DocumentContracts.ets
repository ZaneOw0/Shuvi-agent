export const LOCAL_DOCUMENT_MAX_BYTES: number = 256 * 1024;

export class LocalDocumentError extends Error {
  readonly code: string;
  readonly uncertain: boolean;
  constructor(code: string, uncertain: boolean = false) {
    super(code);
    this.name = 'LocalDocumentError';
    this.code = code;
    this.uncertain = uncertain;
  }
}

/** Metadata never returned to a model: blobId is an implementation-owned file reference. */
export class DocumentRecord {
  documentId: string = '';
  fileName: string = '';
  version: number = 0;
  blobId: string = '';
  contentDigest: string = '';
  byteLength: number = 0;
  updatedAt: string = '';
}

export class DocumentReceipt {
  operationId: string = '';
  idempotencyKey: string = '';
  argumentsDigest: string = '';
  action: string = '';
  receipt: string = '';
  record: DocumentRecord = new DocumentRecord();
}

export class DocumentCatalogSnapshot {
  schemaVersion: string = '1';
  scopeId: string = '';
  revision: number = 0;
  documents: DocumentRecord[] = [];
  receipts: DocumentReceipt[] = [];
}

/** Atomic CAS must commit the version pointer and operation receipt together. */
export interface DocumentCatalogPort {
  load(): Promise<DocumentCatalogSnapshot | undefined>;
  compareAndSet(expectedRevision: number, next: DocumentCatalogSnapshot): Promise<boolean>;
}

export interface DocumentBlobPort {
  write(content: string): Promise<string>;
  read(blobId: string): Promise<string>;
  remove(blobId: string): Promise<void>;
}

export class DocumentWriteRequest {
  action: string = '';
  documentId: string = '';
  fileName: string = '';
  expectedVersion: number = 0;
  content: string = '';
  operationId: string = '';
  idempotencyKey: string = '';
  argumentsDigest: string = '';
}

/** Public tool result: no sandbox path, URI or internal blob reference. */
export class LocalDocumentResult {
  documentId: string = '';
  fileName: string = '';
  version: number = 0;
  contentDigest: string = '';
  byteLength: number = 0;
  updatedAt: string = '';
  content?: string;
  receipt?: string;
  replayed?: boolean;
}

export class LocalDocumentOperationStatus {
  state: string = 'unknown';
  operationId: string = '';
  result?: LocalDocumentResult;
}
