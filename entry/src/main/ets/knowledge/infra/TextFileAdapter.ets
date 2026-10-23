import { picker, fileIo, fileUri, ReadOptions, WriteOptions } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  TextAssetPort, TextSelectionPort
} from '../domain/TextKnowledgePorts';
import {
  TextBudget, TextFailure, TextCancellation, TextSelection, TextSelectedFile, TextFormat, TextOriginal, TextSnapshot
} from '../domain/TextKnowledgeModels';
import { textEncodeSnapshotTask, textDecodeSnapshotTask } from './TextProcessingAdapter';
import { KnowledgeStoreHost } from './KnowledgeStoreHost';

export const TEXT_USER_DIRECTORY: string = 'knowledge_user_v1';
export class TextFileAdapter implements TextSelectionPort, TextAssetPort {
  private context: common.Context;
  private root: string;
  private host: KnowledgeStoreHost;
  constructor(context: common.Context, host: KnowledgeStoreHost = KnowledgeStoreHost.forContext(context)) { this.context = context; this.root = `${context.filesDir}/${TEXT_USER_DIRECTORY}`; this.host = host; }

  async select(): Promise<TextSelection> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = TextBudget.batchFiles;
    options.selectMode = picker.DocumentSelectMode.FILE;
    options.fileSuffixFilters = ['文本（txt/md）|.txt,.md'];
    const selected: string[] = await new picker.DocumentViewPicker(this.context).select(options);
    const result: TextSelection = new TextSelection(); result.canceled = selected.length === 0;
    for (const uri of selected) {
      const item: TextSelectedFile = new TextSelectedFile(); item.uri = uri;
      const uriInfo: fileUri.FileUri = new fileUri.FileUri(uri);
      item.name = uriInfo.name;
      // Unsupported items are retained for per-file application errors.
      const suffix: string = item.name.toLowerCase();
      item.format = suffix.endsWith('.md') ? TextFormat.Markdown : TextFormat.Txt;
      try { item.bytes = uriInfo.isRemoteUri() ? -1 : (await fileIo.stat(uri)).size; }
      catch { item.bytes = -1; }
      result.files.push(item);
    }
    return result;
  }
  private path(assetId: string): string {
    if (!new RegExp('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,160}$').test(assetId)) {
      throw new TextFailure('PATH', 'asset', '拒绝不安全资产身份');
    }
    return `${this.root}/${assetId}`;
  }
  private async ensureRoot(): Promise<void> {
    if (!(await fileIo.access(this.root))) { await fileIo.mkdir(this.root); }
    const stat: fileIo.Stat = await fileIo.lstat(this.root);
    if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new TextFailure('PATH', 'asset', '用户资产目录非法'); }
  }
  private async readBytes(path: string, maximum: number, cancel: TextCancellation): Promise<Uint8Array> {
    cancel.check();
    const file: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      const before: fileIo.Stat = await fileIo.stat(file.fd);
      if (!before.isFile() || before.size < 1 || before.size > maximum) {
        throw new TextFailure('BUDGET', 'read', '文件非普通文件、为空或超过保护预算');
      }
      const bytes: Uint8Array = new Uint8Array(before.size);
      let total: number = 0;
      while (total < bytes.length) {
        cancel.check();
        const block: ArrayBuffer = new ArrayBuffer(Math.min(32768, bytes.length - total));
        const options: ReadOptions = { offset: total, length: block.byteLength };
        const actual: number = await fileIo.read(file.fd, block, options);
        if (actual <= 0 || actual > block.byteLength) { throw new TextFailure('IO', 'read', '原件读取长度不一致'); }
        bytes.set(new Uint8Array(block, 0, actual), total); total += actual;
      }
      const extra: ArrayBuffer = new ArrayBuffer(1);
      const extraOptions: ReadOptions = { offset: total, length: 1 };
      const after: fileIo.Stat = await fileIo.stat(file.fd);
      if (await fileIo.read(file.fd, extra, extraOptions) !== 0 || after.size !== before.size || after.mtime !== before.mtime) {
        throw new TextFailure('IO', 'read', '读取期间原件发生变化，未截断保存');
      }
      cancel.check(); return bytes;
    } finally { await fileIo.close(file); }
  }
  private async hash(bytes: Uint8Array): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    for (let i: number = 0; i < bytes.length; i += 32768) {
      const blob: cryptoFramework.DataBlob = { data: bytes.slice(i, i + 32768) }; await md.update(blob);
    }
    const result: cryptoFramework.DataBlob = await md.digest();
    let hash: string = '';
    for (const byte of result.data) { hash += byte.toString(16).padStart(2, '0'); }
    return hash;
  }
  private async writeNew(assetId: string, bytes: Uint8Array, cancel: TextCancellation): Promise<void> {
    await this.ensureRoot();
    const path: string = this.path(assetId); const temporary: string = this.path(`${assetId}-pending`);
    if (await fileIo.access(path)) { throw new TextFailure('IO', 'write', '资产身份已存在，拒绝覆盖'); }
    if (await fileIo.access(temporary)) { throw new TextFailure('IO', 'write', '临时资产已存在，拒绝覆盖'); }
    const file: fileIo.File = await fileIo.open(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.NOFOLLOW);
    try {
      let total: number = 0;
      while (total < bytes.length) {
        cancel.check(); const block: Uint8Array = bytes.slice(total, total + 32768);
        const options: WriteOptions = { offset: total, length: block.length };
        const actual: number = await fileIo.write(file.fd, block.buffer, options);
        if (actual < 1 || actual > block.length) { throw new TextFailure('IO', 'write', '资产写入长度非法'); }
        total += actual;
      }
      await fileIo.fsync(file.fd);
    } catch (error) {
      await fileIo.close(file);
      if (await fileIo.access(temporary)) { await fileIo.unlink(temporary); }
      if (error instanceof Error) { throw error; }
      throw new TextFailure('IO', 'write', '资产写入失败，未发布副本');
    }
    await fileIo.close(file);
    try {
      const copy: Uint8Array = await this.readBytes(temporary, Math.max(TextBudget.fileBytes, bytes.length), cancel);
      if (await this.hash(copy) !== await this.hash(bytes)) { throw new TextFailure('IO', 'write', '原字节副本摘要不一致'); }
      cancel.check(); await fileIo.rename(temporary, path);
    } catch (error) {
      if (await fileIo.access(temporary)) { await fileIo.unlink(temporary); }
      if (error instanceof Error) { throw error; }
      throw new TextFailure('IO', 'write', '副本校验或发布失败，原件未覆盖');
    }
  }
  async saveOriginal(file: TextSelectedFile, assetId: string, cancel: TextCancellation): Promise<TextOriginal> {
    const bytes: Uint8Array = await this.readBytes(file.uri, TextBudget.fileBytes, cancel);
    if (file.bytes >= 0 && file.bytes !== bytes.length) { throw new TextFailure('IO', 'read', '选择后文件大小发生变化'); }
    const original: TextOriginal = new TextOriginal(); original.assetId = assetId;
    original.hash = await this.hash(bytes); original.bytes = bytes.length;
    await this.writeNew(assetId, bytes, cancel); return original;
  }
  async readOriginal(original: TextOriginal, cancel: TextCancellation): Promise<Uint8Array> {
    await this.ensureRoot(); const path: string = this.path(original.assetId);
    const stat: fileIo.Stat = await fileIo.lstat(path);
    if (stat.isSymbolicLink()) { throw new TextFailure('PATH', 'read', '资产不得为符号链接'); }
    const bytes: Uint8Array = await this.readBytes(path, TextBudget.fileBytes, cancel);
    if (bytes.length !== original.bytes || await this.hash(bytes) !== original.hash) {
      throw new TextFailure('HASH', 'read', '原件副本校验失败，已有资料未覆盖');
    }
    return bytes;
  }
  async saveSnapshot(snapshot: TextSnapshot): Promise<void> {
    const bytes: Uint8Array = await textEncodeSnapshotTask(snapshot);
    await this.writeNew(snapshot.id, bytes, new TextCancellation());
  }
  async readSnapshot(snapshotId: string): Promise<TextSnapshot> {
    await this.ensureRoot();
    const path: string = this.path(snapshotId);
    if ((await fileIo.lstat(path)).isSymbolicLink()) { throw new TextFailure('PATH', 'snapshot', '快照不得为链接'); }
    const bytes: Uint8Array = await this.readBytes(path, TextBudget.snapshotBytes, new TextCancellation());
    const snapshot: TextSnapshot = await textDecodeSnapshotTask(bytes);
    if (snapshot.id !== snapshotId) { throw new TextFailure('SCHEMA', 'snapshot', '快照身份不一致'); }
    return snapshot;
  }
  async remove(assetIds: string[]): Promise<void> {
    await this.host.withUnifiedCleanup<void>('TextFileAdapter',assetIds,async (): Promise<void> => { await this.removeOwned(assetIds); });
  }
  private async removeOwned(assetIds: string[]): Promise<void> {
    await this.ensureRoot();
    for (const id of assetIds) {
      const path: string = this.path(id);
      if (!(await fileIo.access(path))) { continue; }
      const stat: fileIo.Stat = await fileIo.lstat(path);
      if (stat.isDirectory() || stat.isSymbolicLink()) { throw new TextFailure('PATH', 'cleanup', '拒绝递归/链接清理'); }
      await fileIo.unlink(path);
    }
  }
  async reconcile(keepIds: string[]): Promise<void> {
    keepIds = keepIds.concat(await this.host.unifiedHeldAssets('TextFileAdapter'));
    await this.ensureRoot();
    const names: string[] = await fileIo.listFile(this.root);
    for (const name of names) {
      // Only names generated by this implementation; unknown/user files stay untouched.
      if (new RegExp('^(original|generation)-[a-zA-Z0-9_-]+$').test(name) && keepIds.indexOf(name) < 0) {
        await this.remove([name]);
      }
    }
  }
}
