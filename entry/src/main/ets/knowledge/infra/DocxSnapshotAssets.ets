import { fileIo, WriteOptions } from '@kit.CoreFileKit';
import { DocxSnapshotAssetPort } from '../domain/DocxKnowledgePorts';
import { DocxSnapshot, DocxFailure, DocxLimits, docxId } from '../domain/DocxKnowledgeModels';
import { KnowledgeIdentityPort } from '../domain/KnowledgePorts';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { documentEnsureDirectory, documentReadRange } from './DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';
import { docxDecodeSnapshot, docxVerifySnapshot } from '../pipeline/DocxSnapshotCodec';

export class DocxSnapshotAssets implements DocxSnapshotAssetPort {
  private cleanupGuard: ((assets: string[], action: () => Promise<void>) => Promise<void>) | undefined;
  attachCleanupGuard(guard: (assets: string[], action: () => Promise<void>) => Promise<void>): void { this.cleanupGuard = guard; }
  private root: string; private temp: string; private identity: KnowledgeIdentityPort;
  constructor(filesDir: string, cacheDir: string, scope: KnowledgeStorageScope, identity: KnowledgeIdentityPort) { this.root = `${filesDir}/${scope.derivedDirectory}`; this.temp = `${cacheDir}/${scope.derivedDirectory}`; this.identity = identity; }
  private path(asset: string, temporary: boolean = false): string { if (!docxId(asset) || !asset.startsWith('snapshot-')) { throw new DocxFailure('SnapshotAssetIdentity','asset'); } return `${temporary ? this.temp : this.root}/docx/${asset}`; }
  private async bytes(path: string, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    const file: fileIo.File = await fileIo.open(path,fileIo.OpenMode.READ_ONLY|fileIo.OpenMode.NOFOLLOW);
    try { const stat: fileIo.Stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size < 1 || stat.size > DocxLimits.snapshot) { throw new DocxFailure('SnapshotReadBudget','asset'); } const bytes: Uint8Array = await documentReadRange(file.fd,0,stat.size); cancel.check(); return bytes; } finally { await fileIo.close(file); }
  }
  async save(snapshot: DocxSnapshot, cancel: KnowledgeCancellation): Promise<string> {
    const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(snapshot)); if (bytes.length > DocxLimits.snapshot) { throw new DocxFailure('SnapshotBytesBudget','asset'); }
    await docxVerifySnapshot(snapshot,this.identity,cancel); const asset: string = 'snapshot-'+snapshot.generation;
    for (const root of [this.root,this.temp]) { await documentEnsureDirectory(root); await documentEnsureDirectory(`${root}/docx`); }
    if (await fileIo.access(this.path(asset))) { const stored: Uint8Array = await this.read(asset,snapshot.hash,cancel); if (await this.identity.hash(stored) !== await this.identity.hash(bytes)) { throw new DocxFailure('SnapshotAssetConflict','asset'); } return asset; }
    const temporary: string = this.path(asset,true);
    if (!(await fileIo.access(temporary))) {
      const file: fileIo.File = await fileIo.open(temporary,fileIo.OpenMode.CREATE|fileIo.OpenMode.READ_WRITE|fileIo.OpenMode.NOFOLLOW);
      try {
        for (let at: number = 0; at < bytes.length;) {
          cancel.check(); const block: Uint8Array = bytes.slice(at,at+65536); const options: WriteOptions = { offset: at, length: block.length };
          const written: number = await fileIo.write(file.fd,block.buffer,options); if (written < 1 || written > block.length) { throw new DocxFailure('SnapshotWriteIncomplete','asset'); } at += written;
        } await fileIo.fsync(file.fd);
      } finally { await fileIo.close(file); }
    }
    const readback: Uint8Array = await this.bytes(temporary,cancel);
    if (await this.identity.hash(readback) !== await this.identity.hash(bytes)) { throw new DocxFailure('SnapshotStagingConflict','asset'); }
    cancel.check(); await fileIo.rename(temporary,this.path(asset)); return asset;
  }
  async read(asset: string, hash: string, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    const bytes: Uint8Array = await this.bytes(this.path(asset),cancel); const snapshot: DocxSnapshot = docxDecodeSnapshot(bytes,cancel);
    if (snapshot.hash !== hash || asset !== 'snapshot-'+snapshot.generation) { throw new DocxFailure('SnapshotAssetBinding','asset'); } await docxVerifySnapshot(snapshot,this.identity,cancel); return bytes;
  }
  async remove(asset: string): Promise<void> {
    const guard = this.cleanupGuard;
    if (guard !== undefined) { await guard([asset],async (): Promise<void> => { await this.removeOwned(asset); }); }
    else { await this.removeOwned(asset); }
  }
  private async removeOwned(asset: string): Promise<void> {
    for (const temporary of [false,true]) { const path: string = this.path(asset,temporary); if (!(await fileIo.access(path))) { continue; } const stat: fileIo.Stat = await fileIo.lstat(path); if (!stat.isFile() || stat.isSymbolicLink()) { throw new DocxFailure('SnapshotCleanupType','asset'); } await fileIo.unlink(path); }
  }
}
