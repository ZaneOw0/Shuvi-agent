import { fileIo, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import {
  ParsedImageAsset, ParsedAssetWrite, ParsedAssetState, ParsedReadLease, ParsedDocument, ParsedSnapshotBundle,
  ParsedSnapshotManifest, ParsedPayloadPart, ParsedCancellation, ParsedFailure, ParsedLimits, ParsedAssetPreview, ParsedAssetRef, parsedId
} from '../domain/ParsedDocumentModels';
import { ParsedAssetPort, ParsedAssetLedgerPort, ParsedIdentityPort, ParsedPublicationVerificationPort } from '../domain/ParsedDocumentPorts';
import { ParsedLifecycleAssetsPort } from '../domain/ParsedLifecyclePorts';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import {
  parsedEncodeSnapshot, parsedDecodeManifest, parsedDocumentFromManifest, parsedApplyPayload, parsedValidate, parsedUtf8
} from '../pipeline/ParsedDocumentCodec';
import { ImageHeaderReader } from '../domain/ImageKnowledgePorts';
import { ImageHeaderEvidence } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { imageInspectHeader } from '../pipeline/ImageHeaderPolicy';

class ParsedImageHeaderBytes implements ImageHeaderReader {
  length: number; private bytes: Uint8Array;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.length = bytes.length; }
  async read(at: number, length: number): Promise<Uint8Array> { return this.bytes.slice(at,at+length); }
}
export function parsedUnifiedDirectory(scope: KnowledgeStorageScope): string { return scope.testing ? `knowledge_unified_v1_${scope.key}` : 'knowledge_unified_v1'; }
export class ParsedDocumentAssets implements ParsedAssetPort, ParsedPublicationVerificationPort, ParsedLifecycleAssetsPort {
  private static tail: Promise<void> = Promise.resolve();
  private root: string; private cacheRoot: string; private ledger: ParsedAssetLedgerPort; private identity: ParsedIdentityPort; private session: string;
  constructor(filesDir: string, cacheDir: string, scope: KnowledgeStorageScope, ledger: ParsedAssetLedgerPort, identity: ParsedIdentityPort, session: string) {
    this.root = `${filesDir}/${parsedUnifiedDirectory(scope)}`; this.cacheRoot = `${cacheDir}/${parsedUnifiedDirectory(scope)}`;
    this.ledger = ledger; this.identity = identity; this.session = session;
  }
  assetDirectory(): string { return this.root; }
  async reuseImage(hash: string, document: string, generation: string, cancel: ParsedCancellation): Promise<ParsedImageAsset | undefined> {
    if (this.ledger.reusableImage===undefined) { return undefined; } const asset=await this.ledger.reusableImage(hash); if (asset===undefined) { return undefined; }
    const ref: ParsedAssetRef=new ParsedAssetRef(); ref.holder=generation; ref.documentKey=document; ref.generation=generation; ref.assetId=asset.id; ref.owner='ParsedDocumentAssets'; ref.role='image';
    await this.ledger.addRef(ref); await this.read(asset.id,cancel); return asset;
  }
  async contentHash(bytes: Uint8Array): Promise<string> { return this.identity.hash(bytes); }
  async openPreview(assetId: string, cancel: ParsedCancellation): Promise<ParsedAssetPreview> {
    const lease: ParsedReadLease = new ParsedReadLease(); lease.id = this.identity.id(); lease.assetId = assetId; lease.owner = 'ParsedDocumentAssets'; lease.session = this.session; lease.holder = 'image-preview';
    await this.ledger.acquireLease(lease);
    try { await this.read(assetId,cancel); const asset: ParsedImageAsset | undefined = await this.ledger.asset(assetId);
      if (asset === undefined || asset.state !== ParsedAssetState.Ready || !asset.relativePath.startsWith('images/')) { throw new ParsedFailure('PreviewAssetUnavailable','asset'); }
      const preview: ParsedAssetPreview = new ParsedAssetPreview(); preview.assetId = assetId; preview.leaseId = lease.id; preview.path = `file://${this.path(asset.relativePath)}`; return preview;
    } catch (error) { await this.ledger.releaseLease(lease.id); if (error instanceof Error) { throw error; } throw new ParsedFailure('PreviewOpenFailed','asset'); }
  }
  async closePreview(preview: ParsedAssetPreview): Promise<void> { if (preview.leaseId.length > 0) { await this.ledger.releaseLease(preview.leaseId); preview.leaseId = ''; } }
  async saveHistory(id: string, record: string, bytes: Uint8Array, cancel: ParsedCancellation): Promise<string> {
    return this.serialized<string>(async (): Promise<string>=> {
      if (bytes.length<1 || bytes.length>ParsedLimits.payloadBytes) { throw new ParsedFailure('HistoryFileBudget','history'); }
      const asset: ParsedImageAsset=new ParsedImageAsset(); asset.id=id; asset.relativePath=`history/${id}`; asset.bytes=bytes.length; asset.payloadHash=await this.identity.hash(bytes); asset.state=ParsedAssetState.Reserved;
      const existing=await this.ledger.asset(id); if (existing!==undefined) { const read=await this.read(id,cancel); if (read.length!==bytes.length || await this.identity.hash(read)!==asset.payloadHash) { throw new ParsedFailure('HistoryAssetConflict','history'); } return asset.payloadHash; }
      const write: ParsedAssetWrite=new ParsedAssetWrite(); write.id=id; write.documentKey=record; write.generation=record; write.role='history'; write.bytes=bytes.length; write.hash=asset.payloadHash; write.relativePath=asset.relativePath;
      await this.ledger.reserve(write,asset); await this.writeFile(write,bytes,cancel); return asset.payloadHash;
    });
  }
  private serialized<T>(action: () => Promise<T>): Promise<T> {
    const operation: Promise<T> = ParsedDocumentAssets.tail.then(action);
    ParsedDocumentAssets.tail = operation.then((): void => {},(_error: Error): void => {}); return operation;
  }
  private path(relative: string): string {
    if (!new RegExp('^(images|snapshots|annotations|history)/[A-Za-z0-9_-]{1,161}$').test(relative)) { throw new ParsedFailure('ManagedPath','asset'); }
    return `${this.root}/${relative}`;
  }
  private async directory(path: string): Promise<void> {
    if (!(await fileIo.access(path))) { await fileIo.mkdir(path); }
    const stat: fileIo.Stat = await fileIo.lstat(path); if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new ParsedFailure('ManagedDirectory','asset'); }
  }
  private async prepare(): Promise<void> {
    await this.directory(this.root); await this.directory(this.cacheRoot);
    for (const sub of ['images','snapshots','annotations','history']) { await this.directory(`${this.root}/${sub}`); }
  }
  private async readPath(path: string, maximum: number, cancel: ParsedCancellation): Promise<Uint8Array> {
    cancel.check(); const file: fileIo.File = await fileIo.open(path,fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      if (!stat.isFile() || stat.size < 1 || stat.size > maximum) { throw new ParsedFailure('AssetReadBudget','asset'); }
      const bytes: Uint8Array = new Uint8Array(stat.size);
      for (let at: number = 0; at < bytes.length;) {
        cancel.check(); const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536,bytes.length-at)); const options: ReadOptions = { offset: at, length: buffer.byteLength };
        const n: number = await fileIo.read(file.fd,buffer,options);
        if (n < 1 || n > buffer.byteLength) { throw new ParsedFailure('AssetTruncated','asset'); } bytes.set(new Uint8Array(buffer,0,n),at); at += n;
      }
      const after: fileIo.Stat = await fileIo.stat(file.fd); const extra: ArrayBuffer = new ArrayBuffer(1); const options: ReadOptions = { offset: bytes.length, length: 1 };
      if (after.size !== stat.size || after.mtime !== stat.mtime || await fileIo.read(file.fd,extra,options) !== 0) { throw new ParsedFailure('AssetChangedDuringRead','asset'); }
      cancel.check(); return bytes;
    } finally { await fileIo.close(file); }
  }
  private async verify(path: string, write: ParsedAssetWrite, cancel: ParsedCancellation): Promise<Uint8Array> {
    const bytes: Uint8Array = await this.readPath(path,write.bytes,cancel);
    if (bytes.length !== write.bytes || await this.identity.hash(bytes) !== write.hash) { throw new ParsedFailure('AssetReadbackHash','asset'); } return bytes;
  }
  private async syncFile(path: string): Promise<void> {
    const file: fileIo.File = await fileIo.open(path,fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    try { await fileIo.fsync(file.fd); } finally { await fileIo.close(file); }
  }
  private async writeFile(write: ParsedAssetWrite, bytes: Uint8Array, cancel: ParsedCancellation): Promise<void> {
    await this.prepare(); const path: string = this.path(write.relativePath);
    // Same-directory temp makes rename a same-filesystem operation. DB is a separate commit.
    const temp: string = `${path}-pending`;
    if (await fileIo.access(path)) { await this.verify(path,write,cancel); await this.ledger.materialized(write.id); await this.ledger.commitAsset(write.id); return; }
    let tempValid: boolean = false;
    if (await fileIo.access(temp)) {
      const stat: fileIo.Stat = await fileIo.lstat(temp); if (!stat.isFile() || stat.isSymbolicLink()) { throw new ParsedFailure('TempType','asset'); }
      try { await this.verify(temp,write,cancel); tempValid = true; }
      catch (error) { cancel.check(); if (stat.size > write.bytes) { throw new ParsedFailure('TempConflict','asset'); } await fileIo.unlink(temp); }
    }
    if (!tempValid) {
      await this.ledger.restoreReservation(write.id,0);
      const file: fileIo.File = await fileIo.open(temp,fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
      try {
        for (let at: number = 0; at < bytes.length;) {
          cancel.check(); const part: Uint8Array = bytes.slice(at,at+65536); const options: WriteOptions = { offset: at, length: part.length };
          const n: number = await fileIo.write(file.fd,part.buffer,options);
          if (n < 1 || n > part.length) { throw new ParsedFailure('AssetWriteIncomplete','asset'); } at += n;
        }
        await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file); }
      await this.verify(temp,write,cancel);
    }
    if (tempValid) { await this.syncFile(temp); }
    await this.ledger.materialized(write.id); cancel.check(); await fileIo.rename(temp,path);
    await this.verify(path,write,cancel); await this.ledger.commitAsset(write.id);
  }
  async save(asset: ParsedImageAsset, write: ParsedAssetWrite, bytes: Uint8Array, cancel: ParsedCancellation): Promise<ParsedImageAsset> {
    return this.serialized<ParsedImageAsset>(async (): Promise<ParsedImageAsset> => {
      cancel.check(); if (bytes.length < 1 || bytes.length > ParsedLimits.imageBytes || asset.bytes !== bytes.length || write.role !== 'image' || asset.relativePath !== `images/${asset.id}` || await this.identity.hash(bytes) !== asset.payloadHash) { throw new ParsedFailure('ImageWriteIdentity','asset'); }
      const token: KnowledgeCancellation = new KnowledgeCancellation(); token.deadline = cancel.deadline;
      const header: ImageHeaderEvidence = await imageInspectHeader(new ParsedImageHeaderBytes(bytes),'',token); cancel.check();
      if (!header.staticContainer || header.mime !== asset.mime || header.width !== asset.pixelWidth || header.height !== asset.pixelHeight || asset.frames !== 1) { throw new ParsedFailure('ImageHeaderIdentity','asset'); }
      asset.state = ParsedAssetState.Reserved; await this.ledger.reserve(write,asset); await this.writeFile(write,bytes,cancel);
      const ready: ParsedImageAsset | undefined = await this.ledger.asset(asset.id); if (ready?.state !== ParsedAssetState.Ready) { throw new ParsedFailure('ImageCommitReadback','asset'); } return ready;
    });
  }
  async read(assetId: string, cancel: ParsedCancellation): Promise<Uint8Array> {
    const lease: ParsedReadLease = new ParsedReadLease(); lease.id = this.identity.id(); lease.assetId = assetId; lease.owner = 'ParsedDocumentAssets'; lease.session = this.session; lease.holder = 'asset-read';
    await this.ledger.acquireLease(lease);
    try {
      const a: ParsedImageAsset | undefined = await this.ledger.asset(assetId); const w: ParsedAssetWrite | undefined = await this.ledger.assetWrite(assetId);
      if (a === undefined || w === undefined || a.state !== ParsedAssetState.Ready || w.phase !== 'Ready') { throw new ParsedFailure('AssetNotReady','asset'); }
      try { return await this.verify(this.path(w.relativePath),w,cancel); }
      catch (error) { cancel.check(); await this.ledger.assetMissing(assetId,'ReadbackMissingOrChanged'); if (error instanceof Error) { throw error; } throw new ParsedFailure('AssetMissing','asset'); }
    } finally { await this.ledger.releaseLease(lease.id); }
  }
  private async savePayload(id: string, document: ParsedDocument, role: string, bytes: Uint8Array, cancel: ParsedCancellation): Promise<void> {
    const a: ParsedImageAsset = new ParsedImageAsset(); a.id = id; a.relativePath = `snapshots/${id}`; a.payloadHash = await this.identity.hash(bytes);
    a.bytes = bytes.length; a.state = ParsedAssetState.Reserved;
    const w: ParsedAssetWrite = new ParsedAssetWrite(); w.id = id; w.documentKey = document.documentKey; w.generation = document.generation;
    w.relativePath = a.relativePath; w.hash = a.payloadHash; w.bytes = a.bytes; w.role = role;
    await this.ledger.reserve(w,a); await this.writeFile(w,bytes,cancel);
  }
  async saveSnapshot(document: ParsedDocument, cancel: ParsedCancellation): Promise<ParsedSnapshotBundle> {
    return this.serialized<ParsedSnapshotBundle>(async (): Promise<ParsedSnapshotBundle> => {
      const bundle: ParsedSnapshotBundle = await parsedEncodeSnapshot(document,this.identity,cancel,async (part: ParsedPayloadPart, bytes: Uint8Array): Promise<void> => { await this.savePayload(part.id,document,'payload',bytes,cancel); });
      await this.savePayload(`${document.generation}-manifest`,document,'manifest',bundle.manifestBytes,cancel); return bundle;
    });
  }
  async readSnapshot(manifestId: string, cancel: ParsedCancellation): Promise<ParsedDocument> {
    const lease: ParsedReadLease=new ParsedReadLease(); lease.id=this.identity.id(); lease.assetId=manifestId; lease.owner='ParsedDocumentAssets'; lease.session=this.session; lease.holder='snapshot-read';
    await this.ledger.acquireLease(lease);
    try {
      const bytes: Uint8Array = await this.read(manifestId,cancel); const m: ParsedSnapshotManifest = await parsedDecodeManifest(bytes,this.identity,cancel);
      if (manifestId !== `${m.generation}-manifest`) { throw new ParsedFailure('ManifestAssetBinding','snapshot'); }
      const d: ParsedDocument = parsedDocumentFromManifest(m);
      for (const part of m.parts) { const payload: Uint8Array = await this.read(part.id,cancel); await parsedApplyPayload(d,part,payload,this.identity,cancel); }
      parsedValidate(d); d.asset_dir = this.root; return d;
    } finally { await this.ledger.releaseLease(lease.id); }
  }
  async verifyPublication(document: ParsedDocument, manifestId: string, contentHash: string): Promise<void> {
    const cancel: ParsedCancellation = new ParsedCancellation();
    const manifestBytes: Uint8Array = await this.read(manifestId,cancel);
    const m: ParsedSnapshotManifest = await parsedDecodeManifest(manifestBytes,this.identity,cancel);
    if (manifestId !== `${document.generation}-manifest` || m.contentHash !== contentHash || m.documentKey !== document.documentKey) { throw new ParsedFailure('PublicationManifestBinding','asset'); }
    const restored: ParsedDocument = await this.readSnapshot(manifestId,cancel);
    const expected: ParsedSnapshotBundle = await parsedEncodeSnapshot(document,this.identity,cancel,async (part: ParsedPayloadPart, bytes: Uint8Array): Promise<void> => {
      const original: ParsedPayloadPart | undefined = m.parts[part.ordinal];
      if (original === undefined || original.id !== part.id || original.hash !== part.hash || bytes.length !== original.bytes) { throw new ParsedFailure('PublicationPayloadBinding','asset'); }
    });
    if (expected.manifest.contentHash !== contentHash || restored.generation !== document.generation || restored.source_hash !== document.source_hash ||
      await this.identity.hash(parsedUtf8(JSON.stringify(expected.manifest))) !== await this.identity.hash(manifestBytes)) { throw new ParsedFailure('PublicationContentBinding','asset'); }
  }
  async reconcile(cancel: ParsedCancellation): Promise<void> {
    await this.serialized<void>(async (): Promise<void> => {
      await this.prepare();
      for (const w of await this.ledger.assetWrites()) {
        cancel.check(); if (w.phase === 'Removed') { continue; } const path: string = this.path(w.relativePath); const temp: string = `${path}-pending`;
        if (await fileIo.access(path)) {
          try { await this.verify(path,w,cancel); await this.ledger.materialized(w.id); await this.ledger.commitAsset(w.id); }
          catch (error) { cancel.check(); await this.ledger.assetMissing(w.id,'FinalReadbackFailed'); }
        } else if (await fileIo.access(temp)) {
          try { await this.verify(temp,w,cancel); await this.syncFile(temp); await this.ledger.materialized(w.id); await fileIo.rename(temp,path); await this.ledger.commitAsset(w.id); }
          catch (error) { cancel.check(); await this.ledger.assetMissing(w.id,'StagingIncompleteOrRenamePending'); }
        } else if (w.phase !== 'Reserved') { await this.ledger.assetMissing(w.id,'FileMissingAfterRestore'); }
      }
      // Only ledger-owned paths are touched. Unknown files remain counted, never swept.
    });
  }
  async cleanup(id: string): Promise<boolean> {
    if (!parsedId(id)) { throw new ParsedFailure('CleanupIdentity','asset'); }
    return this.serialized<boolean>(async (): Promise<boolean> => {
      if (!(await this.ledger.claimAssetCleanup(id))) { return false; }
      let failure: string = '';
      try {
        const w: ParsedAssetWrite | undefined = await this.ledger.assetWrite(id); if (w === undefined) { throw new ParsedFailure('CleanupOwnerMissing','asset'); }
        const path: string = this.path(w.relativePath);
        for (const p of [path,`${path}-pending`]) {
          if (!(await fileIo.access(p))) { continue; } const stat: fileIo.Stat = await fileIo.lstat(p);
          if (!stat.isFile() || stat.isSymbolicLink()) { throw new ParsedFailure('CleanupType','asset'); } await fileIo.unlink(p);
        }
      } catch (error) { failure = error instanceof ParsedFailure ? error.category : 'PhysicalCleanupPending'; }
      await this.ledger.finishAssetCleanup(id,failure); return failure.length === 0;
    });
  }
}
