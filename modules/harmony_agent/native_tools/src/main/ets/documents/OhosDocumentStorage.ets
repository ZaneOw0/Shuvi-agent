import fs from '@ohos.file.fs';
import util from '@ohos.util';
import cryptoFramework from '@ohos.security.cryptoFramework';
import relationalStore from '@ohos.data.relationalStore';
import { NativeDigestPort } from '../native/NativeToolContracts';
import { nativeCanonicalJson } from '../native/NativeToolSupport';
import {
  DocumentBlobPort, DocumentCatalogPort, DocumentCatalogSnapshot, LOCAL_DOCUMENT_MAX_BYTES, LocalDocumentError
} from './DocumentContracts';
import { documentTextBytes, validDocumentScope } from './LocalDocumentStore';

export class SystemNativeDocumentDigest implements NativeDigestPort {
  digest(value: string): string {
    try {
      const hash: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const input: Uint8Array = documentTextBytes(value);
      if (input.byteLength > 0) hash.updateSync({ data: input });
      const bytes: Uint8Array = hash.digestSync().data;
      let output: string = '';
      for (let i: number = 0; i < bytes.length; i++) output += bytes[i].toString(16).padStart(2, '0');
      return output;
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_DIGEST_UNAVAILABLE');
    }
  }
}

function assertDirectory(path: string): void {
  try {
    const stat: fs.Stat = fs.lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new LocalDocumentError('DOCUMENT_UNSAFE_DIRECTORY');
  } catch (_error) { throw new LocalDocumentError('DOCUMENT_UNSAFE_DIRECTORY'); }
}

function syncDirectory(path: string): void {
  try {
    const directory: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
    try { fs.fsyncSync(directory.fd); } finally { fs.closeSync(directory.fd); }
  } catch (_error) { throw new LocalDocumentError('DOCUMENT_DIRECTORY_SYNC_FAILED'); }
}

/** Host passes context.filesDir. Model arguments never select a directory or URI. */
export class OhosDocumentBlobStore implements DocumentBlobPort {
  readonly directory: string;

  constructor(filesDir: string, scopeId: string) {
    if (!filesDir.startsWith('/') || filesDir.split('/').indexOf('..') >= 0 || !validDocumentScope(scopeId)) {
      throw new LocalDocumentError('DOCUMENT_INVALID_DIRECTORY');
    }
    const parent: string = filesDir.replace(/\/+$/, '') + '/agent_documents';
    this.directory = parent + '/' + scopeId;
    try {
      if (!fs.accessSync(this.directory)) {
        try { fs.mkdirSync(this.directory, true); } catch (_error) {
          if (!fs.accessSync(this.directory)) throw new LocalDocumentError('DOCUMENT_DIRECTORY_UNAVAILABLE');
        }
      }
      assertDirectory(parent);
      assertDirectory(this.directory);
    } catch (_error) { throw new LocalDocumentError('DOCUMENT_DIRECTORY_UNAVAILABLE'); }
  }

  async write(content: string): Promise<string> {
    const bytes: Uint8Array = documentTextBytes(content);
    if (bytes.byteLength > LOCAL_DOCUMENT_MAX_BYTES) throw new LocalDocumentError('DOCUMENT_TOO_LARGE');
    assertDirectory(this.directory);
    const id: string = util.generateRandomUUID(false).toLowerCase();
    const directory: string = this.blobDirectory(id);
    // mkdir is exclusive: another writer cannot reuse or truncate an existing version body.
    try { fs.mkdirSync(directory); } catch (_error) { throw new LocalDocumentError('DOCUMENT_STAGE_CREATE_FAILED'); }
    let file: fs.File | undefined = undefined;
    let complete: boolean = false;
    try {
      file = await fs.open(directory + '/content.txt', fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.NOFOLLOW);
      let written: number = 0;
      while (written < bytes.byteLength) {
        const count: number = await fs.write(file.fd, bytes.slice(written).buffer);
        if (count <= 0) throw new LocalDocumentError('DOCUMENT_SHORT_WRITE');
        written += count;
      }
      await fs.fsync(file.fd);
      await fs.close(file.fd);
      file = undefined;
      syncDirectory(directory);
      syncDirectory(this.directory);
      complete = true;
      return id;
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_STAGE_FAILED');
    } finally {
      if (file !== undefined) {
        try { await fs.close(file.fd); } catch (_error) { /* Original write failure remains primary. */ }
      }
      if (!complete) {
        try { await this.remove(id); } catch (_error) { /* Incomplete unreferenced version is not published. */ }
      }
    }
  }

  async read(blobId: string): Promise<string> {
    try {
      assertDirectory(this.directory);
      const directory: string = this.blobDirectory(blobId);
      assertDirectory(directory);
      const path: string = directory + '/content.txt';
      const stat: fs.Stat = fs.lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > LOCAL_DOCUMENT_MAX_BYTES || stat.size < 0) {
        throw new LocalDocumentError('DOCUMENT_CONTENT_CORRUPT');
      }
      const file: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const bytes: Uint8Array = new Uint8Array(stat.size);
        let read: number = 0;
        while (read < bytes.byteLength) {
          const part: ArrayBuffer = new ArrayBuffer(bytes.byteLength - read);
          const count: number = await fs.read(file.fd, part);
          if (count <= 0) throw new LocalDocumentError('DOCUMENT_CONTENT_CORRUPT');
          bytes.set(new Uint8Array(part).subarray(0, count), read);
          read += count;
        }
        // OHOS ignoreBOM=true removes the BOM; false preserves the exact document text.
        return bytes.byteLength === 0 ? '' :
          new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decodeToString(bytes);
      } finally { await fs.close(file.fd); }
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_READ_FAILED');
    }
  }

  async remove(blobId: string): Promise<void> {
    try {
      assertDirectory(this.directory);
      const directory: string = this.blobDirectory(blobId);
      assertDirectory(directory);
      if (fs.accessSync(directory + '/content.txt')) await fs.unlink(directory + '/content.txt');
      fs.rmdirSync(directory);
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_STAGE_CLEANUP_FAILED');
    }
  }

  private blobDirectory(id: string): string {
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(id)) {
      throw new LocalDocumentError('DOCUMENT_INVALID_BLOB');
    }
    return this.directory + '/' + id;
  }
}

const TABLE: string = 'harmony_agent_local_documents';

/** One atomic RDB row holds all heads and receipts for a host-controlled scope. */
export class RdbDocumentCatalog implements DocumentCatalogPort {
  private readonly store: relationalStore.RdbStore;
  private readonly scopeId: string;
  private readonly digest: NativeDigestPort;

  constructor(store: relationalStore.RdbStore, scopeId: string, digest: NativeDigestPort) {
    if (!validDocumentScope(scopeId)) throw new LocalDocumentError('DOCUMENT_INVALID_SCOPE');
    this.store = store;
    this.scopeId = scopeId;
    this.digest = digest;
  }

  async initialize(): Promise<void> {
    try {
      await this.store.execute('CREATE TABLE IF NOT EXISTS ' + TABLE +
        ' (scope_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload_json TEXT NOT NULL, payload_digest TEXT NOT NULL)');
    } catch (_error) { throw new LocalDocumentError('DOCUMENT_CATALOG_OPEN_FAILED'); }
  }

  async load(): Promise<DocumentCatalogSnapshot | undefined> {
    try {
      const rows: relationalStore.ResultSet = await this.store.querySql(
        'SELECT revision, payload_json, payload_digest FROM ' + TABLE + ' WHERE scope_id = ?', [this.scopeId]);
      try {
        if (!rows.goToFirstRow()) return undefined;
        const payload: string = rows.getString(1);
        if (payload.length > 16 * 1024 * 1024 || this.digest.digest(payload) !== rows.getString(2)) {
          throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
        }
        const value: DocumentCatalogSnapshot = JSON.parse(payload) as DocumentCatalogSnapshot;
        if (value.scopeId !== this.scopeId || value.revision !== rows.getLong(0)) {
          throw new LocalDocumentError('DOCUMENT_CATALOG_CORRUPT');
        }
        return value;
      } finally { rows.close(); }
    } catch (error) {
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_CATALOG_READ_FAILED');
    }
  }

  async compareAndSet(expectedRevision: number, next: DocumentCatalogSnapshot): Promise<boolean> {
    try {
      if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0 || next.revision !== expectedRevision + 1 ||
        next.scopeId !== this.scopeId) throw new LocalDocumentError('DOCUMENT_INVALID_CAS');
      const payload: string = nativeCanonicalJson(next);
      const values: relationalStore.ValuesBucket = {
        'revision': next.revision, 'payload_json': payload, 'payload_digest': this.digest.digest(payload)
      };
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE);
      predicates.equalTo('scope_id', this.scopeId).and().equalTo('revision', expectedRevision);
      if (await this.store.update(values, predicates) === 1) return true;
      if (expectedRevision !== 0) return false;
      const inserted: relationalStore.ValuesBucket = {
        'scope_id': this.scopeId, 'revision': next.revision, 'payload_json': payload,
        'payload_digest': this.digest.digest(payload)
      };
      return await this.store.insert(TABLE, inserted, relationalStore.ConflictResolution.ON_CONFLICT_IGNORE) >= 0;
    } catch (error) { throw error as Error; }
  }
}
