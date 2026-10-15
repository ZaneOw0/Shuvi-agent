import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { MineruTaskPort } from '../domain/DocumentParsePorts';
import { DocumentParseAction, DocumentParseBudget, DocumentParseFailure, DocumentAllocationReceipt,
  DocumentInspection, DocumentLeaseBinding, DocumentParseUsage, DocumentParseResultEnvelope } from '../domain/DocumentParseModels';
import { MineruCredentialStore } from './MineruCredentialStore';
import { DocumentFileAdapter, DocumentResultSink } from './DocumentFileAdapter';
import { documentAssetPath, documentDigestHex } from './DocumentFileOperations';
import { MINERU_ALLOCATION_ENDPOINT, MINERU_QUERY_ENDPOINT, mineruValidateDestination, mineruAllocationPayload,
  mineruDecodeAllocation, mineruDecodeInspection, MineruAllocationDTO, MineruInspectionDTO, MineruBoundedBytes, mineruHttpStatus } from '../pipeline/MineruProtocolCodec';
import { documentSafeId } from '../pipeline/DocumentParsePolicy';

function mineruSafeSession(): rcp.Session {
  const timeout: rcp.Timeout = { connectMs: 30000, transferMs: 120000, inactivityMs: 30000 };
  const transfer: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeout };
  const trace: rcp.TracingConfiguration = { verbose: false, collectTimeInfo: false, plaintextInException: false };
  const configuration: rcp.Configuration = { transfer: transfer, tracing: trace };
  const cache: rcp.CacheControl = { noCache: true, noStore: true, keepCache: false };
  const session: rcp.SessionConfiguration = { requestConfiguration: configuration, cacheControl: cache };
  return rcp.createSession(session);
}
function mineruBinding(action: DocumentParseAction, purpose: string, id: string): DocumentLeaseBinding {
  const binding: DocumentLeaseBinding = new DocumentLeaseBinding(); binding.id = id; binding.taskId = action.task.id;
  binding.hash = action.task.hash; binding.version = action.task.version; binding.credentialRevision = action.task.credentialRevision;
  binding.purpose = purpose; binding.issuedAt = Date.now();
  binding.expiresAt = binding.issuedAt + (purpose === 'UPLOAD' ? DocumentParseBudget.uploadLeaseMs : DocumentParseBudget.resultLeaseMs);
  return binding;
}
function mineruEarlierUploadExpiry(address: string, binding: DocumentLeaseBinding): void {
  const queryAt: number = address.indexOf('?'); if (queryAt < 0) { return; }
  const pairs: string[] = address.slice(queryAt + 1).split('&');
  const seen: string[] = [];
  for (const pair of pairs) {
    const at: number = pair.indexOf('='); const key: string = pair.slice(0, at);
    if (key !== 'Expires') { continue; }
    if (seen.indexOf(key) >= 0) { throw new DocumentParseFailure('签名期限字段重复', '租约'); } seen.push(key);
    const raw: string = pair.slice(at + 1);
    if (!new RegExp('^[0-9]{1,12}$').test(raw)) { throw new DocumentParseFailure('签名期限不可校验', '租约'); }
    const expires: number = Number(raw) * 1000;
    if (!Number.isSafeInteger(expires) || expires <= Date.now()) { throw new DocumentParseFailure('上传租约已失效', '租约'); }
    binding.expiresAt = Math.min(binding.expiresAt, expires); binding.remoteExpiry = `${expires}`;
  }
}
class MineruUploadReader implements rcp.ReadFile {
  private file: fileIo.File; private action: DocumentParseAction; private offset: number = 0; private size: number;
  private md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); private reading: boolean = false;
  constructor(file: fileIo.File, action: DocumentParseAction) { this.file = file; this.action = action; this.size = action.original.bytes; }
  async read(buffer: ArrayBuffer): Promise<number> {
    if (this.reading) { throw new DocumentParseFailure('SDK上传读取回调未串行', '原件PUT'); }
    this.reading = true;
    try {
    this.action.cancel.check();
    if (this.offset >= this.size) { return 0; }
    const length: number = Math.min(buffer.byteLength, 65536, this.size - this.offset);
    const options: ReadOptions = { offset: this.offset, length: length }; const n: number = await fileIo.read(this.file.fd, buffer, options);
    if (n < 1 || n > length) { throw new DocumentParseFailure('上传读取不完整', '原件PUT'); }
    this.action.cancel.check(); const blob: cryptoFramework.DataBlob = { data: new Uint8Array(buffer, 0, n) };
    await this.md.update(blob); this.offset += n; return n;
    } finally { this.reading = false; }
  }
  async validate(): Promise<void> {
    const stat: fileIo.Stat = await fileIo.stat(this.file.fd);
    if (this.offset !== this.size || stat.size !== this.size || documentDigestHex((await this.md.digest()).data) !== this.action.original.hash) {
      throw new DocumentParseFailure('上传实际字节摘要不符', '原件PUT');
    }
    this.action.cancel.check();
  }
}
export class MineruTransportAdapter implements MineruTaskPort {
  private credential: MineruCredentialStore; private assets: DocumentFileAdapter; private filesRoot: string;
  private sessions: rcp.Session[] = [];
  constructor(credential: MineruCredentialStore, assets: DocumentFileAdapter, filesDir: string) {
    this.credential = credential; this.assets = assets; this.filesRoot = `${filesDir}/knowledge_parse_v1`;
  }
  pause(): void { for (const session of this.sessions) { session.cancel(); session.close(); } this.sessions = []; this.credential.clearTransient(); }
  private async fetch(request: rcp.Request, authenticated: boolean, action: DocumentParseAction, incoming: rcp.IncomingDataCallback): Promise<rcp.Response> {
    action.cancel.check(); const session: rcp.Session = mineruSafeSession(); this.sessions.push(session);
    let complete: boolean = false; let timer: number = -1; let requestActive: boolean = true;
    const handler: rcp.HttpEventsHandler = { onDataEnd: (): void => { complete = true; },
      onStatusCodeReceive: (code: number): void => { if (code >= 300 && code < 400) { session.cancel(request); } } };
    const tracing: rcp.TracingConfiguration = { verbose: false, collectTimeInfo: false, plaintextInException: false, httpEventsHandler: handler };
    const timeoutConfig: rcp.Timeout = { connectMs: 30000, transferMs: 120000, inactivityMs: 30000 };
    const transferConfig: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeoutConfig };
    const config: rcp.Configuration = { tracing: tracing, transfer: transferConfig }; request.configuration = config; request.destination = incoming;
    try {
      const timeout: Promise<rcp.Response> = new Promise<rcp.Response>((_resolve: (response: rcp.Response) => void, reject: (error: Object) => void): void => {
        timer = setTimeout((): void => { action.cancel.invalid = true; session.cancel(request); reject(new DocumentParseFailure('请求总墙钟超时', '传输')); }, 120000);
      });
      const work: Promise<rcp.Response> = authenticated ? this.credential.authenticatedFetch(request, session, (): void => {
        if (!requestActive) { throw new DocumentParseFailure('请求世代失效', '认证'); } action.cancel.check();
      }) : session.fetch(request);
      const response: rcp.Response = await Promise.race<rcp.Response>([work, timeout]);
      action.cancel.check(); mineruHttpStatus(response.statusCode, response.headers['retry-after']);
      if (!complete) { throw new DocumentParseFailure('传输结束未经确认', '传输'); }
      return response;
    } catch (error) { session.cancel(request); if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('网络或TLS失败', '传输'); }
    finally {
      requestActive = false; clearTimeout(timer); request.headers = undefined; request.destination = undefined; request.content = undefined;
      session.close(); this.sessions = this.sessions.filter((s: rcp.Session): boolean => s !== session);
    }
  }
  private async control(request: rcp.Request, action: DocumentParseAction): Promise<string> {
    const chunks: Uint8Array[] = []; const cap: MineruBoundedBytes = new MineruBoundedBytes();
    const incoming: rcp.IncomingDataCallback = (buffer: ArrayBuffer): void => {
      action.cancel.check(); cap.reserve(buffer.byteLength, DocumentParseBudget.jsonBytes); chunks.push(new Uint8Array(buffer).slice());
    };
    await this.fetch(request, true, action, incoming); const bytes: Uint8Array = new Uint8Array(cap.count); let offset: number = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
  }
  async allocate(action: DocumentParseAction): Promise<DocumentAllocationReceipt> {
    mineruValidateDestination(MINERU_ALLOCATION_ENDPOINT, 'CONTROL');
    const request: rcp.Request = new rcp.Request(MINERU_ALLOCATION_ENDPOINT, 'POST'); request.content = mineruAllocationPayload(action.task.dataId, action.original.format);
    const dto: MineruAllocationDTO = mineruDecodeAllocation(await this.control(request, action)); action.cancel.check();
    await action.onAllocation(dto.batchId); action.cancel.check();
    mineruValidateDestination(dto.uploadAddress, 'UPLOAD');
    const binding: DocumentLeaseBinding = mineruBinding(action, 'UPLOAD', `lease-${action.task.id}-upload`);
    mineruEarlierUploadExpiry(dto.uploadAddress, binding); await this.credential.sealLease(binding, dto.uploadAddress); action.cancel.check();
    const receipt: DocumentAllocationReceipt = new DocumentAllocationReceipt(); receipt.batchId = dto.batchId; receipt.leaseId = binding.id; return receipt;
  }
  async upload(action: DocumentParseAction): Promise<void> {
    await this.assets.verify(action.original, action.cancel);
    const binding: DocumentLeaseBinding = mineruBinding(action, 'UPLOAD', action.task.uploadLease);
    await this.credential.withLease(binding, async (address: string): Promise<void> => {
      mineruValidateDestination(address, 'UPLOAD'); action.cancel.check();
      const file: fileIo.File = await fileIo.open(documentAssetPath(this.filesRoot, action.original.assetId), fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      try {
        const reader: MineruUploadReader = new MineruUploadReader(file, action);
        const request: rcp.Request = new rcp.Request(address, 'PUT'); request.content = new rcp.UploadFromFile(reader);
        const cap: MineruBoundedBytes = new MineruBoundedBytes(); const discard: rcp.IncomingDataCallback = (bytes: ArrayBuffer): void => { action.cancel.check(); cap.reserve(bytes.byteLength, DocumentParseBudget.jsonBytes); };
        await this.fetch(request, false, action, discard); await reader.validate();
      } finally { await fileIo.close(file); }
    });
  }
  async inspect(action: DocumentParseAction): Promise<DocumentInspection> {
    if (!documentSafeId(action.task.batchId)) { throw new DocumentParseFailure('无安全批次身份，停止待核对', '查询'); }
    const request: rcp.Request = new rcp.Request(MINERU_QUERY_ENDPOINT + action.task.batchId, 'GET');
    const dto: MineruInspectionDTO = mineruDecodeInspection(await this.control(request, action), action.task.batchId, action.task.dataId);
    const inspection: DocumentInspection = new DocumentInspection(); inspection.batchId = dto.batchId; inspection.dataId = dto.dataId;
    inspection.state = dto.state; inspection.extractedPages = dto.extractedPages; inspection.totalPages = dto.totalPages;
    if (dto.resultAddress.length > 0 && action.task.hash.length > 0) {
      const binding: DocumentLeaseBinding = mineruBinding(action, 'RESULT', `lease-${action.task.id}-result-${action.task.epoch}-${action.task.queries}`);
      await this.credential.sealLease(binding, dto.resultAddress); inspection.resultLease = binding.id;
    } action.cancel.check(); return inspection;
  }
  async receive(action: DocumentParseAction, usage: DocumentParseUsage): Promise<DocumentParseResultEnvelope> {
    const sink: DocumentResultSink = await this.assets.resultSink(action, usage);
    try {
      const binding: DocumentLeaseBinding = mineruBinding(action, 'RESULT', action.task.resultLease);
      await this.credential.withLease(binding, async (address: string): Promise<void> => {
        mineruValidateDestination(address, 'RESULT');
        const request: rcp.Request = new rcp.Request(address, 'GET');
        const incoming: rcp.IncomingDataCallback = async (buffer: ArrayBuffer): Promise<void> => { await sink.write(buffer); };
        const response: rcp.Response = await this.fetch(request, false, action, incoming);
        const length: string | string[] | undefined = response.headers['content-length'];
        if (length !== undefined && (typeof length !== 'string' || !new RegExp('^[0-9]{1,12}$').test(length) || Number(length) !== sink.actualBytes())) { throw new DocumentParseFailure('结果HTTP长度不符', '接收'); }
      });
      return await sink.finish();
    } catch (error) { await sink.abort(); if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('隔离包接收失败', '接收'); }
  }
  async removeLeases(ids: string[]): Promise<void> { await this.credential.removeLeases(ids); }
  async reconcileLeases(keepIds: string[]): Promise<void> { await this.credential.reconcileLeases(keepIds); }
}
