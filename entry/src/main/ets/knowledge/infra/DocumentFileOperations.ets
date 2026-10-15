import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool } from '@kit.ArkTS';
import { DocumentOriginal, DocumentParseCancellation, DocumentParseBudget, DocumentParseFailure, DocumentParseFormat, DocumentPreflightStatus } from '../domain/DocumentParseModels';
import { documentSafeId, documentZipBoundary, documentOfficeIdentity, DocumentZipBoundary } from '../pipeline/DocumentParsePolicy';

export async function documentEnsureDirectory(root: string): Promise<void> {
  if (!(await fileIo.access(root))) { await fileIo.mkdir(root); }
  const stat: fileIo.Stat = await fileIo.lstat(root);
  if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new DocumentParseFailure('资产目录非法', '文件'); }
}
export function documentAssetPath(root: string, id: string): string {
  if (!documentSafeId(id) || !new RegExp('^(original|result|part)-[a-zA-Z0-9_-]+$').test(id)) { throw new DocumentParseFailure('资产身份非法', '文件'); }
  return `${root}/${id}`;
}
export async function documentReadRange(fd: number, offset: number, length: number): Promise<Uint8Array> {
  const bytes: Uint8Array = new Uint8Array(length); let read: number = 0;
  while (read < length) {
    const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, length - read));
    const options: ReadOptions = { offset: offset + read, length: buffer.byteLength };
    const n: number = await fileIo.read(fd, buffer, options);
    if (n < 1 || n > buffer.byteLength) { throw new DocumentParseFailure('文件截断', '读取'); }
    bytes.set(new Uint8Array(buffer, 0, n), read); read += n;
  }
  return bytes;
}
export function documentDigestHex(bytes: Uint8Array): string {
  let hash: string = ''; for (const byte of bytes) { hash += byte.toString(16).padStart(2, '0'); } return hash;
}
export function documentWorkerCheck(cancel: DocumentParseCancellation): void {
  cancel.check(); if (taskpool.Task.isCanceled()) { throw new DocumentParseFailure('本地任务取消', '文件'); }
}
export async function documentHashFile(path: string, maximum: number, cancel: DocumentParseCancellation): Promise<string> {
  const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    const before: fileIo.Stat = await fileIo.stat(file.fd);
    if (!before.isFile() || before.size < 1 || before.size > maximum) { throw new DocumentParseFailure('文件大小或身份非法', '摘要'); }
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    for (let offset: number = 0; offset < before.size; offset += 65536) {
      cancel.check(); const block: Uint8Array = await documentReadRange(file.fd, offset, Math.min(65536, before.size - offset));
      const blob: cryptoFramework.DataBlob = { data: block }; await md.update(blob);
    }
    const after: fileIo.Stat = await fileIo.stat(file.fd);
    const extra: ArrayBuffer = new ArrayBuffer(1); const options: ReadOptions = { offset: before.size, length: 1 };
    if (before.size !== after.size || before.mtime !== after.mtime || await fileIo.read(file.fd, extra, options) !== 0) { throw new DocumentParseFailure('文件读取期间变化', '摘要'); }
    cancel.check(); return documentDigestHex((await md.digest()).data);
  } finally { await fileIo.close(file); }
}
export async function documentContainerPreflight(path: string, original: DocumentOriginal): Promise<void> {
  const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  try {
    const head: Uint8Array = await documentReadRange(file.fd, 0, Math.min(original.bytes, 8));
    if (original.format === DocumentParseFormat.Pdf) {
      if (head.length < 8 || head[0] !== 37 || head[1] !== 80 || head[2] !== 68 || head[3] !== 70 || head[4] !== 45 || (head[5] !== 49 && head[5] !== 50) || head[6] !== 46 || head[7] < 48 || head[7] > 57) {
        throw new DocumentParseFailure('PDF签名与扩展名不符', '身份预检');
      }
      return;
    }
    const size: number = Math.min(65557, original.bytes);
    const tail: Uint8Array = await documentReadRange(file.fd, original.bytes - size, size);
    const boundary: DocumentZipBoundary = documentZipBoundary(head, tail, original.bytes);
    if (boundary.directoryBytes > DocumentParseBudget.directoryBytes || boundary.entries > 4096) { throw new DocumentParseFailure('OOXML目录超预算', '身份预检'); }
    const directory: Uint8Array = await documentReadRange(file.fd, boundary.directoryOffset, boundary.directoryBytes);
    documentOfficeIdentity(directory, boundary, original.format); original.preflight = DocumentPreflightStatus.Passed;
  } finally { await fileIo.close(file); }
}
