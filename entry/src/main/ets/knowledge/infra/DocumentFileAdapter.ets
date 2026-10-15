import { common } from '@kit.AbilityKit';
import { picker, fileIo, fileUri, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool } from '@kit.ArkTS';
import { DocumentAssetPort, DocumentSelectionPort } from '../domain/DocumentParsePorts';
import { DocumentFileSelection, DocumentSelectedFile, DocumentOriginal, DocumentParseCancellation,
  DocumentParseBudget, DocumentParseFailure, DocumentParseFormat, DocumentPreflightStatus,
  DocumentParseAction, DocumentParseUsage, DocumentParseResultEnvelope } from '../domain/DocumentParseModels';
import { MineruBoundedBytes } from '../pipeline/MineruProtocolCodec';
import { documentSuffix, documentZipBoundary } from '../pipeline/DocumentParsePolicy';
import { documentEnsureDirectory, documentAssetPath, documentReadRange, documentDigestHex, documentWorkerCheck, documentHashFile, documentContainerPreflight } from './DocumentFileOperations';

export const DOCUMENT_PARSE_DIRECTORY: string = 'knowledge_parse_v1';
@Concurrent
async function documentCopyWorker(uri: string, title: string, id: string, filesRoot: string, tempRoot: string): Promise<DocumentOriginal> {
  const cancel: DocumentParseCancellation = new DocumentParseCancellation();
  await documentEnsureDirectory(filesRoot); await documentEnsureDirectory(tempRoot);
  const target: string = documentAssetPath(filesRoot, `original-${id}`); const temporary: string = documentAssetPath(tempRoot, `part-${id}`);
  if (await fileIo.access(target) || await fileIo.access(temporary)) { throw new DocumentParseFailure('唯一身份已存在，拒绝覆盖', '保存'); }
  const source: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
  let output: fileIo.File | undefined = undefined;
  try {
    const before: fileIo.Stat = await fileIo.stat(source.fd);
    if (!before.isFile() || before.size < 1 || before.size > DocumentParseBudget.originalBytes) { throw new DocumentParseFailure('原件大小超限或非普通文件', '保存'); }
    output = await fileIo.open(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    for (let offset: number = 0; offset < before.size;) {
      documentWorkerCheck(cancel); const block: Uint8Array = await documentReadRange(source.fd, offset, Math.min(65536, before.size - offset));
      const blob: cryptoFramework.DataBlob = { data: block }; await md.update(blob);
      let written: number = 0;
      while (written < block.length) {
        const chunk: Uint8Array = block.slice(written); const options: WriteOptions = { offset: offset + written, length: chunk.length };
        const n: number = await fileIo.write(output.fd, chunk.buffer, options);
        if (n < 1 || n > chunk.length) { throw new DocumentParseFailure('副本写入不完整', '保存'); } written += n;
      }
      offset += block.length;
    }
    const after: fileIo.Stat = await fileIo.stat(source.fd); const extra: ArrayBuffer = new ArrayBuffer(1);
    const readExtra: ReadOptions = { offset: before.size, length: 1 };
    if (before.size !== after.size || before.mtime !== after.mtime || await fileIo.read(source.fd, extra, readExtra) !== 0) { throw new DocumentParseFailure('源件变化，未发布副本', '保存'); }
    await fileIo.fsync(output.fd); await fileIo.close(output); output = undefined;
    const original: DocumentOriginal = new DocumentOriginal(); original.id = id; original.assetId = `original-${id}`;
    original.title = title; original.bytes = before.size; original.hash = documentDigestHex((await md.digest()).data);
    if (await documentHashFile(temporary, DocumentParseBudget.originalBytes, cancel) !== original.hash) { throw new DocumentParseFailure('副本摘要不一致', '保存'); }
    try {
      original.format = documentSuffix(title); await documentContainerPreflight(temporary, original);
    } catch (error) { original.preflightReason = error instanceof DocumentParseFailure ? error.message : '身份预检失败'; }
    documentWorkerCheck(cancel); if (await fileIo.access(target)) { throw new DocumentParseFailure('发布目标已存在', '保存'); }
    await fileIo.rename(temporary, target); original.savedAt = Date.now(); return original;
  } catch (error) {
    if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('文件保存失败', '原件');
  } finally {
    if (output !== undefined) { await fileIo.close(output); } await fileIo.close(source);
    if (await fileIo.access(temporary)) { await fileIo.unlink(temporary); }
  }
}
export class DocumentFileAdapter implements DocumentAssetPort, DocumentSelectionPort {
  private context: common.Context; private root: string; private temp: string; private copying: boolean = false;
  private copyTask: taskpool.GenericsTask<[string, string, string, string, string], DocumentOriginal> | undefined = undefined;
  cancelLocal(): void { if (this.copyTask !== undefined) { try { taskpool.cancel(this.copyTask); } catch {} } }
  constructor(context: common.Context) { this.context = context; this.root = `${context.filesDir}/${DOCUMENT_PARSE_DIRECTORY}`; this.temp = `${context.cacheDir}/${DOCUMENT_PARSE_DIRECTORY}`; }
  async select(): Promise<DocumentFileSelection> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions(); options.maxSelectNumber = 3;
    options.selectMode = picker.DocumentSelectMode.FILE; options.fileSuffixFilters = ['复杂原件|.pdf,.docx,.pptx,.xlsx'];
    const selected: string[] = await new picker.DocumentViewPicker(this.context).select(options);
    const result: DocumentFileSelection = new DocumentFileSelection(); result.canceled = selected.length === 0;
    for (const uri of selected) {
      const file: DocumentSelectedFile = new DocumentSelectedFile(); file.uri = uri; const info: fileUri.FileUri = new fileUri.FileUri(uri); file.title = info.name;
      documentSuffix(file.title);
      try { file.bytes = info.isRemoteUri() ? -1 : (await fileIo.stat(uri)).size; } catch { file.bytes = -1; }
      result.files.push(file);
    }
    return result;
  }
  async save(file: DocumentSelectedFile, id: string, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    cancel.check(); if (this.copying) { throw new DocumentParseFailure('仍有复制任务', '原件'); } this.copying = true;
    try {
      this.copyTask = new taskpool.GenericsTask<[string, string, string, string, string], DocumentOriginal>(documentCopyWorker, file.uri, file.title, id, this.root, this.temp);
      const result: DocumentOriginal = await taskpool.execute<[string, string, string, string, string], DocumentOriginal>(this.copyTask);
      if (cancel.invalid || file.bytes >= 0 && file.bytes !== result.bytes) { await this.remove([result.assetId]); throw new DocumentParseFailure('选择后变化或本地动作取消', '原件'); }
      cancel.check(); return result;
    } finally { this.copying = false; this.copyTask = undefined; }
  }
  async verify(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<void> {
    const path: string = documentAssetPath(this.root, original.assetId);
    const stat: fileIo.Stat = await fileIo.lstat(path);
    if (stat.size !== original.bytes || stat.isSymbolicLink() || !stat.isFile() || await documentHashFile(path, DocumentParseBudget.originalBytes, cancel) !== original.hash) {
      throw new DocumentParseFailure('原件摘要或长度不符', '上传前复核');
    }
  }
  async resultSink(action: DocumentParseAction, usage: DocumentParseUsage): Promise<DocumentResultSink> {
    await documentEnsureDirectory(this.root); await documentEnsureDirectory(this.temp);
    if (usage.resultBytes + DocumentParseBudget.resultBytes > DocumentParseBudget.resultsTotal || usage.resultTemp > 0) { throw new DocumentParseFailure('结果磁盘预算不足', '下载'); }
    const sink: DocumentResultSink = new DocumentResultSink(this.root, this.temp, action); await sink.open(); return sink;
  }
  async remove(ids: string[]): Promise<void> {
    for (const id of ids) {
      const root: string = id.startsWith('part-') ? this.temp : this.root; const path: string = documentAssetPath(root, id);
      if (!(await fileIo.access(path))) { continue; }
      const stat: fileIo.Stat = await fileIo.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink()) { throw new DocumentParseFailure('拒绝非本轮普通资产清理', '清理'); }
      await fileIo.unlink(path);
    }
  }
}

export class DocumentResultSink {
  private root: string; private temp: string; private action: DocumentParseAction;
  private file: fileIo.File | undefined = undefined; private cap: MineruBoundedBytes = new MineruBoundedBytes();
  private md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); private tail: Promise<void> = Promise.resolve();
  private closed: boolean = false; private failed: boolean = false;
  private writing: boolean = false;
  constructor(root: string, temp: string, action: DocumentParseAction) { this.root = root; this.temp = temp; this.action = action; }
  private part(): string { return documentAssetPath(this.temp, `part-${this.action.task.id}`); }
  private target(): string { return documentAssetPath(this.root, `result-${this.action.task.id}`); }
  async open(): Promise<void> {
    this.action.cancel.check();
    if (await fileIo.access(this.part()) || await fileIo.access(this.target())) { throw new DocumentParseFailure('结果唯一身份已存在', '下载'); }
    this.file = await fileIo.open(this.part(), fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
  }
  actualBytes(): number { return this.cap.count; }
  async write(buffer: ArrayBuffer): Promise<void> {
    this.action.cancel.check(); if (this.closed || this.failed || this.writing) { throw new DocumentParseFailure('结果写队列已关闭或SDK未等待异步回调', '下载'); }
    this.writing = true;
    const offset: number = this.cap.count;
    // Reserve BEFORE enqueuing or copying a chunk; missing Content-Length never bypasses the hard cap.
    try { this.cap.reserve(buffer.byteLength, DocumentParseBudget.resultBytes); } catch (error) { this.writing = false; this.failed = true; if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('流预算超限', '下载'); }
    const data: Uint8Array = new Uint8Array(buffer);
    const operation: Promise<void> = this.tail.then(async (): Promise<void> => {
      this.action.cancel.check(); if (this.file === undefined || this.failed) { throw new DocumentParseFailure('下载写入句柄失效', '下载'); }
      for (let at: number = 0; at < data.length;) {
        this.action.cancel.check(); const block: Uint8Array = data.slice(at, at + 65536); let written: number = 0;
        while (written < block.length) {
          const rest: Uint8Array = block.slice(written); const options: WriteOptions = { offset: offset + at + written, length: rest.length };
          const n: number = await fileIo.write(this.file.fd, rest.buffer, options);
          if (n < 1 || n > rest.length) { throw new DocumentParseFailure('结果实际写入不完整', '下载'); } written += n;
        }
        const blob: cryptoFramework.DataBlob = { data: block }; await this.md.update(blob); at += block.length;
      }
    });
    this.tail = operation.then((): void => {}, (_error: Error): void => { this.failed = true; });
    try { await operation; } catch { this.failed = true; throw new DocumentParseFailure('结果写入失败', '下载'); }
    finally { this.writing = false; }
  }
  async finish(): Promise<DocumentParseResultEnvelope> {
    await this.tail; this.action.cancel.check();
    if (this.file === undefined || this.failed || this.cap.count < 22) { throw new DocumentParseFailure('结果传输未完整', '下载'); }
    const stat: fileIo.Stat = await fileIo.stat(this.file.fd);
    if (!stat.isFile() || stat.size !== this.cap.count) { throw new DocumentParseFailure('结果实长不符', '下载'); }
    const head: Uint8Array = await documentReadRange(this.file.fd, 0, 4); const count: number = Math.min(stat.size, 65557);
    const tail: Uint8Array = await documentReadRange(this.file.fd, stat.size - count, count); documentZipBoundary(head, tail, stat.size);
    await fileIo.fsync(this.file.fd); await fileIo.close(this.file); this.file = undefined;
    const hash: string = documentDigestHex((await this.md.digest()).data);
    if (await documentHashFile(this.part(), DocumentParseBudget.resultBytes, this.action.cancel) !== hash) { throw new DocumentParseFailure('隔离包读回摘要不符', '下载'); }
    this.action.cancel.check(); if (await fileIo.access(this.target())) { throw new DocumentParseFailure('结果发布目标冲突', '下载'); }
    await fileIo.rename(this.part(), this.target()); this.closed = true;
    const result: DocumentParseResultEnvelope = new DocumentParseResultEnvelope(); result.assetId = `result-${this.action.task.id}`;
    result.taskId = this.action.task.id; result.dataId = this.action.task.dataId; result.originalHash = this.action.task.hash; result.version = this.action.task.version;
    result.hash = hash; result.bytes = stat.size; result.receivedAt = Date.now(); result.completeTransport = true; result.signature = true; return result;
  }
  async abort(): Promise<void> {
    this.closed = true; this.failed = true; await this.tail;
    if (this.file !== undefined) { await fileIo.close(this.file); this.file = undefined; }
    if (await fileIo.access(this.part())) { await fileIo.unlink(this.part()); }
  }
}
