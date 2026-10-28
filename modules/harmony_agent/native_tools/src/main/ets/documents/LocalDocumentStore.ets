import { NativeCancellationSignalPort, NativeClockPort, NativeDigestPort } from '../native/NativeToolContracts';
import { nativeCanonicalJson } from '../native/NativeToolSupport';
import {
  DocumentBlobPort, DocumentCatalogPort, DocumentCatalogSnapshot, DocumentRecord, DocumentReceipt,
  DocumentWriteRequest, LOCAL_DOCUMENT_MAX_BYTES, LocalDocumentError, LocalDocumentOperationStatus,
  LocalDocumentResult
} from './DocumentContracts';

export function documentTextBytes(content: string): Uint8Array {
  // Strict UTF-16 -> UTF-8: reject unpaired surrogates instead of silently storing replacement characters.
  const bytes: Uint8Array = new Uint8Array(content.length * 3);
  let length: number = 0;
  for (let i: number = 0; i < content.length; i++) {
    let point: number = content.charCodeAt(i);
    if (point >= 0xD800 && point <= 0xDBFF) {
      const low: number = content.charCodeAt(++i);
      if (!(low >= 0xDC00 && low <= 0xDFFF)) throw new LocalDocumentError('DOCUMENT_INVALID_UTF8');
      point = 0x10000 + ((point - 0xD800) << 10) + low - 0xDC00;
    } else if (point >= 0xDC00 && point <= 0xDFFF) throw new LocalDocumentError('DOCUMENT_INVALID_UTF8');
    if (point < 0x80) bytes[length++] = point;
    else if (point < 0x800) {
      bytes[length++] = 0xC0 | (point >> 6);
      bytes[length++] = 0x80 | (point & 0x3F);
    } else if (point < 0x10000) {
      bytes[length++] = 0xE0 | (point >> 12);
      bytes[length++] = 0x80 | ((point >> 6) & 0x3F);
      bytes[length++] = 0x80 | (point & 0x3F);
    } else {
      bytes[length++] = 0xF0 | (point >> 18);
      bytes[length++] = 0x80 | ((point >> 12) & 0x3F);
      bytes[length++] = 0x80 | ((point >> 6) & 0x3F);
      bytes[length++] = 0x80 | (point & 0x3F);
    }
  }
  return bytes.slice(0, length);
}

export function validDocumentScope(scopeId: string): boolean {
  return /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(scopeId);
}

function validId(value: string): boolean { return /^doc-[a-f0-9]{64}$/.test(value); }
function validDigest(value: string): boolean { return /^[a-f0-9]{64}$/.test(value); }
function validFileName(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 120 && value.trim() === value &&
    !/[\u0000-\u001f/\\]/.test(value) && /\.(txt|md)$/i.test(value);
}
function validToken(value: string): boolean {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= 512;
}
function cancelled(signal: NativeCancellationSignalPort): void {
  if (signal.isCancellationRequested()) throw new LocalDocumentError('DOCUMENT_CANCELLED');
}
function result(record: DocumentRecord): LocalDocumentResult {
  const value: LocalDocumentResult = new LocalDocumentResult();
  value.documentId = record.documentId;
  value.fileName = record.fileName;
  value.version = record.version;
  value.contentDigest = record.contentDigest;
  value.byteLength = record.byteLength;
  value.updatedAt = record.updatedAt;
  return value;
}
function receiptResult(receipt: DocumentReceipt, replayed: boolean): LocalDocumentResult {
  const value: LocalDocumentResult = result(receipt.record);
  value.receipt = receipt.receipt;
  value.replayed = replayed;
  return value;
}

/** Backend-only document service. Version bodies are immutable; the catalog is the commit boundary. */
export class LocalDocumentStore {
  readonly scopeId: string;
  readonly storageIdentity: string;
  private readonly catalog: DocumentCatalogPort;
  private readonly blobs: DocumentBlobPort;
  private readonly digest: NativeDigestPort;
  private readonly clock: NativeClockPort;

  constructor(scopeId: string, catalog: DocumentCatalogPort, blobs: DocumentBlobPort,
    digest: NativeDigestPort, clock: NativeClockPort, storageIdentity?: string) {
    if (!validDocumentScope(scopeId)) throw new LocalDocumentError('DOCUMENT_INVALID_SCOPE');
    this.scopeId = scopeId;
    this.storageIdentity = storageIdentity === undefined ? scopeId : storageIdentity;
    this.catalog = catalog;
    this.blobs = blobs;
    this.digest = digest;
    this.clock = clock;
  }

  async read(documentId: string, signal: NativeCancellationSignalPort): Promise<LocalDocumentResult> {
    cancelled(signal);
    if (!validId(documentId)) throw new LocalDocumentError('DOCUMENT_INVALID_ID');
    const state: DocumentCatalogSnapshot = await this.load();
    const record: DocumentRecord | undefined = state.documents.find(
      (value: DocumentRecord): boolean => value.documentId === documentId);
    if (record === undefined) throw new LocalDocumentError('DOCUMENT_NOT_FOUND');
    const content: string = await this.blobs.read(record.blobId);
    if (this.digest.digest(content) !== record.contentDigest || documentTextBytes(content).byteLength !== record.byteLength) {
      throw new LocalDocumentError('DOCUMENT_CONTENT_CORRUPT');
    }
    cancelled(signal);
    const value: LocalDocumentResult = result(record);
    value.content = content;
    return value;
  }

  async write(request: DocumentWriteRequest, signal: NativeCancellationSignalPort): Promise<LocalDocumentResult> {
    // Capture caller-owned values before the first await.
    const command: DocumentWriteRequest = JSON.parse(nativeCanonicalJson(request)) as DocumentWriteRequest;
    this.validateCommand(command);
    if (command.content.length > LOCAL_DOCUMENT_MAX_BYTES) throw new LocalDocumentError('DOCUMENT_TOO_LARGE');
    const byteLength: number = documentTextBytes(command.content).byteLength;
    if (byteLength > LOCAL_DOCUMENT_MAX_BYTES) throw new LocalDocumentError('DOCUMENT_TOO_LARGE');
    const contentDigest: string = this.digest.digest(command.content);
    if (!validDigest(contentDigest)) throw new LocalDocumentError('DOCUMENT_INVALID_DIGEST_PORT');
    let staged: string | undefined = undefined;
    let committed: boolean = false;
    let uncertain: boolean = false;
    try {
      for (let attempt: number = 0; attempt < 8; attempt++) {
        cancelled(signal);
        const state: DocumentCatalogSnapshot = await this.load();
        const previousReceipt: DocumentReceipt | undefined = state.receipts.find(
          (value: DocumentReceipt): boolean => value.operationId === command.operationId ||
            value.idempotencyKey === command.idempotencyKey);
        if (previousReceipt !== undefined) {
          if (previousReceipt.operationId !== command.operationId || previousReceipt.idempotencyKey !== command.idempotencyKey ||
            previousReceipt.argumentsDigest !== command.argumentsDigest || previousReceipt.action !== command.action ||
            previousReceipt.record.contentDigest !== contentDigest ||
            (command.action === 'create' && previousReceipt.record.fileName !== command.fileName) ||
            (command.action === 'update' && (previousReceipt.record.documentId !== command.documentId ||
              previousReceipt.record.version !== command.expectedVersion + 1))) {
            throw new LocalDocumentError('DOCUMENT_IDEMPOTENCY_CONFLICT');
          }
          return receiptResult(previousReceipt, true);
        }
        if (state.receipts.length >= 4096) throw new LocalDocumentError('DOCUMENT_OPERATION_QUOTA');
        const documentId: string = command.action === 'create' ?
          'doc-' + this.digest.digest('document-id-v1|' + this.scopeId + '|' + command.operationId) : command.documentId;
        const index: number = state.documents.findIndex((value: DocumentRecord): boolean => value.documentId === documentId);
        if (command.action === 'create') {
          if (index >= 0) throw new LocalDocumentError('DOCUMENT_ALREADY_EXISTS');
          if (state.documents.length >= 256) throw new LocalDocumentError('DOCUMENT_QUOTA');
        } else if (index < 0) throw new LocalDocumentError('DOCUMENT_NOT_FOUND');
        else if (state.documents[index].version !== command.expectedVersion) throw new LocalDocumentError('DOCUMENT_VERSION_CONFLICT');
        if (staged === undefined) staged = await this.blobs.write(command.content);
        cancelled(signal);
        const record: DocumentRecord = new DocumentRecord();
        record.documentId = documentId;
        record.fileName = command.action === 'create' ? command.fileName : state.documents[index].fileName;
        record.version = command.action === 'create' ? 1 : command.expectedVersion + 1;
        record.blobId = staged;
        record.contentDigest = contentDigest;
        record.byteLength = byteLength;
        record.updatedAt = this.clock.nowIso();
        this.validateRecord(record);
        const receipt: DocumentReceipt = new DocumentReceipt();
        receipt.operationId = command.operationId;
        receipt.idempotencyKey = command.idempotencyKey;
        receipt.argumentsDigest = command.argumentsDigest;
        receipt.action = command.action;
        receipt.record = record;
        receipt.receipt = 'native-document:' + this.scopeId + ':' + this.digest.digest(nativeCanonicalJson(receipt));
        if (index < 0) state.documents.push(record); else state.documents[index] = record;
        state.receipts.push(receipt);
        const expectedRevision: number = state.revision;
        state.revision++;
        try {
          committed = await this.catalog.compareAndSet(expectedRevision, state);
        } catch (_error) {
          uncertain = true;
          throw new LocalDocumentError('DOCUMENT_COMMIT_UNCERTAIN', true);
        }
        if (committed) return receiptResult(receipt, false);
      }
      throw new LocalDocumentError('DOCUMENT_CONCURRENT_WRITE_LIMIT');
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_STORAGE_FAILURE', uncertain);
    } finally {
      // A blob potentially referenced by an uncertain commit must remain available for reconciliation.
      if (staged !== undefined && !committed && !uncertain) {
        try { await this.blobs.remove(staged); } catch (_error) { /* Unreferenced immutable blob retained for host maintenance. */ }
      }
    }
  }

  async operationStatus(operationId: string): Promise<LocalDocumentOperationStatus> {
    if (!validToken(operationId)) throw new LocalDocumentError('DOCUMENT_INVALID_OPERATION');
    const state: DocumentCatalogSnapshot = await this.load();
    const receipt: DocumentReceipt | undefined = state.receipts.find(
      (value: DocumentReceipt): boolean => value.operationId === operationId);
    const status: LocalDocumentOperationStatus = new LocalDocumentOperationStatus();
    status.operationId = operationId;
    if (receipt !== undefined) {
      status.state = 'committed';
      status.result = receiptResult(receipt, true);
    }
    // Absence of a receipt cannot prove NOT_EXECUTED while another writer may still be in flight.
    return status;
  }

  private validateCommand(value: DocumentWriteRequest): void {
    if ((value.action !== 'create' && value.action !== 'update') || !validToken(value.operationId) ||
      !validToken(value.idempotencyKey) || !validDigest(value.argumentsDigest) || typeof value.content !== 'string') {
      throw new LocalDocumentError('DOCUMENT_INVALID_WRITE');
    }
    if (value.action === 'create' && !validFileName(value.fileName)) throw new LocalDocumentError('DOCUMENT_INVALID_NAME');
    if (value.action === 'update' && (!validId(value.documentId) || !Number.isSafeInteger(value.expectedVersion) ||
      value.expectedVersion < 1 || value.expectedVersion >= Number.MAX_SAFE_INTEGER)) {
      throw new LocalDocumentError('DOCUMENT_INVALID_UPDATE');
    }
  }

  private async load(): Promise<DocumentCatalogSnapshot> {
    const loaded: DocumentCatalogSnapshot | undefined = await this.catalog.load();
    if (loaded === undefined) {
      const empty: DocumentCatalogSnapshot = new DocumentCatalogSnapshot();
      empty.scopeId = this.scopeId;
      return empty;
    }
    const value: DocumentCatalogSnapshot = JSON.parse(nativeCanonicalJson(loaded)) as DocumentCatalogSnapshot;
    if (value.schemaVersion !== '1' || value.scopeId !== this.scopeId || !Number.isSafeInteger(value.revision) ||
      value.revision < 1 || !Array.isArray(value.documents) || !Array.isArray(value.receipts) ||
      value.documents.length > 256 || value.receipts.length > 4096) throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
    const ids: Set<string> = new Set<string>();
    const operations: Set<string> = new Set<string>();
    const keys: Set<string> = new Set<string>();
    for (let i: number = 0; i < value.documents.length; i++) {
      this.validateRecord(value.documents[i]);
      if (ids.has(value.documents[i].documentId)) throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
      ids.add(value.documents[i].documentId);
    }
    for (let i: number = 0; i < value.receipts.length; i++) {
      const receipt: DocumentReceipt = value.receipts[i];
      this.validateRecord(receipt.record);
      if (!validToken(receipt.operationId) || !validToken(receipt.idempotencyKey) || !validDigest(receipt.argumentsDigest) ||
        (receipt.action !== 'create' && receipt.action !== 'update') || !validToken(receipt.receipt) ||
        operations.has(receipt.operationId) || keys.has(receipt.idempotencyKey)) throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
      operations.add(receipt.operationId);
      keys.add(receipt.idempotencyKey);
    }
    return value;
  }

  private validateRecord(value: DocumentRecord): void {
    if (value === undefined || value === null || !validId(value.documentId) || !validFileName(value.fileName) ||
      !Number.isSafeInteger(value.version) || value.version < 1 || !validDigest(value.contentDigest) ||
      typeof value.blobId !== 'string' || !/^[a-f0-9-]{36}$/.test(value.blobId) ||
      !Number.isSafeInteger(value.byteLength) || value.byteLength < 0 || value.byteLength > LOCAL_DOCUMENT_MAX_BYTES ||
      typeof value.updatedAt !== 'string' || !Number.isFinite(Date.parse(value.updatedAt))) {
      throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
    }
  }
}
