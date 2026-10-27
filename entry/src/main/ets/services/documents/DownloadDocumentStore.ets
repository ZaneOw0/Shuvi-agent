import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import picker from '@ohos.file.picker';
import fileUri from '@ohos.file.fileuri';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import relationalStore from '@ohos.data.relationalStore';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { DataBoundary } from '@harmony_agent/agent-contracts';
import {
  DocumentWriteRequest, LocalDocumentResult, LocalDocumentStore, LocalDocumentError, OhosDocumentBlobStore,
  RdbDocumentCatalog, SystemNativeDocumentDigest, SystemNativeClock, SystemNativeCapabilityProbe,
  NativeDocumentTools, OhosNativeDocumentToolSet, NativeGrantVerifierPort, NativeExecutionEnvironmentPort,
  NativeCancellationResolverPort, NativeCancellationSignalPort, documentTextBytes, LOCAL_DOCUMENT_MAX_BYTES
} from '@harmony_agent/native-tools';

export class DownloadLocation {
  savedToDownloads: boolean = false;
  storageLocation: string = 'Shuvi 应用私有文档（尚未保存到 Download）';
  fileUri: string = '';
}

/** Keep version/operation evidence private; publish the named file during the authorized Native dispatch. */
export class DownloadDocumentStore extends LocalDocumentStore {
  private readonly context: common.Context;
  private readonly fileDigest: SystemNativeDocumentDigest;
  private readonly bundleName: string;
  private readonly directoryUri: string;
  private readonly directoryPath: string;
  private directoryReady?: Promise<void>;

  constructor(context: common.Context, scope: string, catalog: RdbDocumentCatalog, blobs: OhosDocumentBlobStore,
    digest: SystemNativeDocumentDigest, clock: SystemNativeClock) {
    const bundle: string = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name;
    super(scope, catalog, blobs, digest, clock, digest.digest('download-documents-v1|' + blobs.directory + '|' + bundle));
    this.context = context; this.fileDigest = digest; this.bundleName = bundle;
    this.directoryUri = 'file://docs/storage/Users/currentUser/Download/' + bundle;
    this.directoryPath = new fileUri.FileUri(this.directoryUri).path;
  }

  private filePath(name: string): string {
    // Public downloads are case-insensitive. Keep the filename a single portable component.
    if (!name || name !== name.trim() || name.length > 120 || /[\/\\:*?"<>|\x00-\x1f\x7f]/.test(name) ||
      !/\.(md|txt)$/i.test(name)) throw new LocalDocumentError('DOCUMENT_INVALID_NAME');
    return this.directoryPath + '/' + name;
  }

  private checkCancelled(signal: NativeCancellationSignalPort): void {
    if (signal.isCancellationRequested()) throw new LocalDocumentError('DOCUMENT_CANCELLED');
  }

  private async initializeDirectory(): Promise<void> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const uris: string[] = await new picker.DocumentViewPicker(this.context).save(options);
    if (uris.length !== 1 || new fileUri.FileUri(uris[0]).path.replace(/\/+$/, '') !== this.directoryPath) {
      throw new LocalDocumentError('DOCUMENT_DOWNLOAD_UNAVAILABLE');
    }
    const stat: fs.Stat = fs.lstatSync(this.directoryPath);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_UNAVAILABLE');
  }

  private async ensureDirectory(): Promise<void> {
    if (this.directoryReady === undefined) this.directoryReady = this.initializeDirectory();
    try { await this.directoryReady; } catch (error) {
      this.recordFailure('prepare_directory', error, false);
      this.directoryReady = undefined; throw new LocalDocumentError('DOCUMENT_DOWNLOAD_UNAVAILABLE');
    }
  }

  private recordFailure(stage: string, error: BusinessError, committed: boolean): void {
    const code: number = Number.isSafeInteger(error?.code) ? error.code : 0;
    hilog.error(0x0000, 'ShuviDocuments', 'Download stage %{public}s failed, code %{public}d, privateCommitted %{public}s',
      stage, code, String(committed));
    // Record only the stage and numeric OS error, never document text, paths or credentials.
    let file: fs.File | undefined = undefined;
    try {
      const record: string = JSON.stringify({ stage: stage, code: code, privateCommitted: committed, at: new Date().toISOString() });
      file = fs.openSync(this.context.filesDir + '/document-download-last-error.json',
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | fs.OpenMode.NOFOLLOW);
      fs.writeSync(file.fd, record);
    } catch { /* Diagnostics must not replace the original failure. */ }
    finally { if (file !== undefined) { try { fs.closeSync(file.fd); } catch { /* Preserve the failure. */ } } }
  }

  private async publicDigest(path: string): Promise<string | undefined> {
    if (!fs.accessSync(path)) return undefined;
    const stat: fs.Stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 0 || stat.size > LOCAL_DOCUMENT_MAX_BYTES) {
      throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
    }
    const file: fs.File = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const size: number = (await fs.stat(file.fd)).size;
      if (size !== stat.size) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      const bytes: Uint8Array = new Uint8Array(size);
      let offset: number = 0;
      while (offset < size) {
        const chunk: ArrayBuffer = new ArrayBuffer(size - offset);
        const count: number = await fs.read(file.fd, chunk);
        if (count <= 0) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
        bytes.set(new Uint8Array(chunk).subarray(0, count), offset); offset += count;
      }
      if ((await fs.stat(file.fd)).size !== size) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      const text: string = size === 0 ? '' : new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decodeToString(bytes);
      return this.fileDigest.digest(text);
    } finally { await fs.close(file.fd); }
  }

  async location(value: LocalDocumentResult): Promise<DownloadLocation> {
    const location: DownloadLocation = new DownloadLocation();
    const digest: string | undefined = await this.publicDigest(this.filePath(value.fileName));
    if (digest === undefined) return location;
    if (digest !== value.contentDigest) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
    location.savedToDownloads = true;
    location.storageLocation = 'Download/' + this.bundleName + '/' + value.fileName;
    location.fileUri = this.directoryUri + '/' + encodeURIComponent(value.fileName);
    return location;
  }

  async read(documentId: string, signal: NativeCancellationSignalPort): Promise<LocalDocumentResult> {
    const value: LocalDocumentResult = await super.read(documentId, signal);
    await this.location(value); this.checkCancelled(signal); return value;
  }

  async write(request: DocumentWriteRequest, signal: NativeCancellationSignalPort): Promise<LocalDocumentResult> {
    const command: DocumentWriteRequest = JSON.parse(JSON.stringify(request)) as DocumentWriteRequest;
    this.checkCancelled(signal); await this.ensureDirectory(); this.checkCancelled(signal);
    const prior = await super.operationStatus(command.operationId);
    if (prior.state === 'committed') {
      const replay: LocalDocumentResult = await super.write(command, signal);
      if (await this.publicDigest(this.filePath(replay.fileName)) !== replay.contentDigest) {
        throw new LocalDocumentError('DOCUMENT_DOWNLOAD_UNCERTAIN', true);
      }
      return replay;
    }
    let previous: LocalDocumentResult | undefined = undefined;
    if (command.action === 'update') {
      previous = await super.read(command.documentId, signal);
      if (previous.version !== command.expectedVersion) throw new LocalDocumentError('DOCUMENT_VERSION_CONFLICT');
    }
    const target: string = this.filePath(previous === undefined ? command.fileName : previous.fileName);
    const previousDigest: string | undefined = await this.publicDigest(target);
    if (previousDigest !== undefined && (previous === undefined || previousDigest !== previous.contentDigest)) {
      throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
    }
    this.checkCancelled(signal);
    if (documentTextBytes(command.content).byteLength > LOCAL_DOCUMENT_MAX_BYTES) throw new LocalDocumentError('DOCUMENT_TOO_LARGE');
    let stageFile: string = '';
    let stageOwned: boolean = false;
    let file: fs.File | undefined = undefined;
    let publishSource: fs.File | undefined = undefined;
    let publishTarget: fs.File | undefined = undefined;
    let privateCommitted: boolean = false;
    let stage: string = 'create_stage';
    try {
      this.checkCancelled(signal);
      // A regular file in the granted directory verifies create/write/sync before the private commit.
      stageFile = this.directoryPath + '/shuvi-pending-' + util.generateRandomUUID(false) + '.txt';
      if (fs.accessSync(stageFile)) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      file = await fs.open(stageFile, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      stageOwned = true; stage = 'write_stage';
      const bytes: Uint8Array = documentTextBytes(command.content);
      let written: number = 0;
      while (written < bytes.byteLength) {
        this.checkCancelled(signal);
        const count: number = await fs.write(file.fd, bytes.slice(written).buffer);
        if (count <= 0) throw new LocalDocumentError('DOCUMENT_SHORT_WRITE');
        written += count;
      }
      stage = 'sync_stage'; await fs.fsync(file.fd);
      stage = 'close_stage'; await fs.close(file.fd); file = undefined;
      stage = 'verify_stage';
      if (await this.publicDigest(stageFile) !== this.fileDigest.digest(command.content)) {
        throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      }
      this.checkCancelled(signal);
      stage = 'check_destination';
      if (await this.publicDigest(target) !== previousDigest) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      // Failures creating/writing the download stage must not increment the internal document version.
      stage = 'commit_private';
      const value: LocalDocumentResult = await super.write(command, signal); privateCommitted = true;
      this.checkCancelled(signal);
      stage = 'check_destination_after_commit';
      if (await this.publicDigest(target) !== previousDigest) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      // DOWNLOAD grants file access; rename of the public directory entry was denied on the phone (13900012).
      // Open the granted destination and copy via FDs. Public replacement is not an atomic rename.
      stage = 'open_publish_source';
      publishSource = await fs.open(stageFile, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      stage = 'open_publish_target';
      publishTarget = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
      stage = 'copy_to_target';
      await fs.copyFile(publishSource.fd, publishTarget.fd);
      stage = 'sync_target'; await fs.fsync(publishTarget.fd);
      stage = 'close_target'; await fs.close(publishTarget.fd); publishTarget = undefined;
      await fs.close(publishSource.fd); publishSource = undefined;
      stage = 'verify_published';
      if (await this.publicDigest(target) !== value.contentDigest) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_CONFLICT');
      this.checkCancelled(signal);
      try { await fs.unlink(this.context.filesDir + '/document-download-last-error.json'); } catch { /* No stale error is required. */ }
      hilog.info(0x0000, 'ShuviDocuments', 'Download copy and digest verification completed');
      return value;
    } catch (error) {
      this.recordFailure(stage, error, privateCommitted);
      if (privateCommitted) throw new LocalDocumentError('DOCUMENT_DOWNLOAD_UNCERTAIN', true);
      if (error instanceof LocalDocumentError) throw error;
      throw new LocalDocumentError('DOCUMENT_DOWNLOAD_SAVE_FAILED');
    } finally {
      if (file !== undefined) { try { await fs.close(file.fd); } catch { /* Preserve the original result. */ } }
      if (publishTarget !== undefined) { try { await fs.close(publishTarget.fd); } catch { /* Preserve diagnostic stage. */ } }
      if (publishSource !== undefined) { try { await fs.close(publishSource.fd); } catch { /* Preserve diagnostic stage. */ } }
      if (stageOwned && stageFile) { try { await fs.unlink(stageFile); } catch { /* Only this invocation's stage is eligible. */ } }
    }
  }
}

export async function createDownloadDocumentTools(context: common.Context, scope: string, database: relationalStore.RdbStore,
  grants: NativeGrantVerifierPort, environment: NativeExecutionEnvironmentPort,
  cancellations: NativeCancellationResolverPort): Promise<OhosNativeDocumentToolSet> {
  const digest: SystemNativeDocumentDigest = new SystemNativeDocumentDigest();
  const clock: SystemNativeClock = new SystemNativeClock();
  const catalog: RdbDocumentCatalog = new RdbDocumentCatalog(database, scope, digest); await catalog.initialize();
  const store: DownloadDocumentStore = new DownloadDocumentStore(context, scope, catalog,
    new OhosDocumentBlobStore(context.filesDir, scope), digest, clock);
  return new OhosNativeDocumentToolSet(store, new NativeDocumentTools(store, digest, clock,
    new SystemNativeCapabilityProbe(), environment, grants, cancellations, DataBoundary.DEVICE_ONLY));
}
