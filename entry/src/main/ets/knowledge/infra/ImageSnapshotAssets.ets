import { fileIo, WriteOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ImageSnapshotAssetPort } from '../domain/ImageKnowledgePorts';
import { ImageSnapshot, ImageKnowledgeFailure, imageIdentity, imageHash } from '../domain/ImageKnowledgeModels';
import { KnowledgeCancellation } from '../domain/PdfKnowledgeModels';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';
import { documentEnsureDirectory, documentHashFile, documentReadRange } from './DocumentFileOperations';
import { pdfCodecUtf8 } from '../pipeline/PdfSnapshotCodec';

async function imageSnapshotFileHash(bytes: Uint8Array): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); const blob: cryptoFramework.DataBlob = { data: bytes }; await md.update(blob);
  let hash: string = ''; for (const byte of (await md.digest()).data) { hash += byte.toString(16).padStart(2,'0'); } return hash;
}

export class ImageSnapshotAssets implements ImageSnapshotAssetPort {
  private cleanupGuard: ((assets: string[], action: () => Promise<void>) => Promise<void>) | undefined;
  attachCleanupGuard(guard: (assets: string[], action: () => Promise<void>) => Promise<void>): void { this.cleanupGuard = guard; }
  private root: string; private temp: string;
  constructor(filesDir: string, cacheDir: string, scope: KnowledgeStorageScope) { this.root = `${filesDir}/${scope.derivedDirectory}`; this.temp = `${cacheDir}/${scope.derivedDirectory}`; }
  private path(asset: string, temporary: boolean = false): string {
    if (!imageIdentity(asset) || !asset.startsWith('snapshot-')) { throw new ImageKnowledgeFailure('SnapshotAssetIdentity','image-asset'); }
    return `${temporary ? this.temp : this.root}/image/${asset}`;
  }
  async save(snapshot: ImageSnapshot, cancel: KnowledgeCancellation): Promise<string> {
    const asset: string = 'snapshot-'+snapshot.generation; const bytes: Uint8Array = pdfCodecUtf8(JSON.stringify(snapshot));
    if (bytes.length > 8388608 || !imageHash(snapshot.contentHash)) { throw new ImageKnowledgeFailure('SnapshotAssetBudget','image-asset'); }
    for (const root of [this.root,this.temp]) { await documentEnsureDirectory(root); await documentEnsureDirectory(`${root}/image`); }
    const target: string = this.path(asset); const part: string = this.path(asset,true);
    if (await fileIo.access(target)) { const stored = await this.read(asset,snapshot.contentHash,cancel); if (stored.length !== bytes.length || stored.some((byte: number,index: number): boolean => byte !== bytes[index])) { throw new ImageKnowledgeFailure('SnapshotAssetConflict','image-asset'); } return asset; }
    if (await fileIo.access(part)) {
      const stat = await fileIo.lstat(part); const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== bytes.length || await documentHashFile(part,8388608,hashCancel) !== await imageSnapshotFileHash(bytes)) { throw new ImageKnowledgeFailure('SnapshotStagingRequiresRecovery','image-asset'); }
      cancel.check(); await fileIo.rename(part,target); return asset;
    }
    const file = await fileIo.open(part,fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    try {
      for (let at: number = 0; at < bytes.length;) {
        cancel.check(); const block: Uint8Array = bytes.slice(at,Math.min(at+65536,bytes.length)); const options: WriteOptions = { offset: at, length: block.length };
        const written: number = await fileIo.write(file.fd,block.buffer,options); if (written < 1 || written > block.length) { throw new ImageKnowledgeFailure('SnapshotWriteIncomplete','image-asset'); } at += written;
      } await fileIo.fsync(file.fd);
    } finally { await fileIo.close(file); }
    const hashCancel: DocumentParseCancellation = new DocumentParseCancellation(); hashCancel.deadline = cancel.deadline;
    const hash: string = await documentHashFile(part,8388608,hashCancel);
    const expected: string = await imageSnapshotFileHash(bytes); if (hash !== expected) { throw new ImageKnowledgeFailure('SnapshotFileReadbackMismatch','image-asset'); }
    cancel.check(); await fileIo.rename(part,target); return asset;
  }
  async read(asset: string, _hash: string, cancel: KnowledgeCancellation): Promise<Uint8Array> {
    cancel.check(); const file = await fileIo.open(this.path(asset),fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try { const stat = await fileIo.stat(file.fd); if (!stat.isFile() || stat.size < 1 || stat.size > 8388608) { throw new ImageKnowledgeFailure('SnapshotReadBudget','image-asset'); } const bytes = await documentReadRange(file.fd,0,stat.size); cancel.check(); return bytes; } finally { await fileIo.close(file); }
  }
  async remove(asset: string): Promise<void> {
    const guard = this.cleanupGuard;
    if (guard !== undefined) { await guard([asset],async (): Promise<void> => { await this.removeOwned(asset); }); }
    else { await this.removeOwned(asset); }
  }
  private async removeOwned(asset: string): Promise<void> {
    for (const temporary of [false,true]) { const path: string = this.path(asset,temporary); if (!(await fileIo.access(path))) { continue; } const stat = await fileIo.lstat(path); if (!stat.isFile() || stat.isSymbolicLink()) { throw new ImageKnowledgeFailure('SnapshotCleanupType','image-asset'); } await fileIo.unlink(path); }
  }
}
