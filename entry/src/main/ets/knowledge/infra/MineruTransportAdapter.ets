import { rcp } from '@kit.RemoteCommunicationKit';
import { util } from '@kit.ArkTS';
import { fileIo, ReadOptions } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MineruTaskPort } from '../domain/DocumentParsePorts';
import { DocumentParseAction, DocumentParseBudget, DocumentParseFailure, DocumentAllocationReceipt,
  DocumentInspection, DocumentLeaseBinding, DocumentParseUsage, DocumentParseResultEnvelope, ParseFailureKind, ImageParsePermit } from '../domain/DocumentParseModels';
import { MineruCredentialStore } from './MineruCredentialStore';
import { DocumentFileAdapter, DocumentResultSink } from './DocumentFileAdapter';
import { documentAssetPath, documentDigestHex } from './DocumentFileOperations';
import { MINERU_ALLOCATION_ENDPOINT, MINERU_QUERY_ENDPOINT, mineruValidateDestination, mineruAllocationPayload,
  mineruDecodeAllocation, mineruDecodeInspection, MineruAllocationDTO, MineruInspectionDTO, MineruBoundedBytes, mineruHttpStatus } from '../pipeline/MineruProtocolCodec';
import { documentSafeId, documentIsImage, documentGrantMatches } from '../pipeline/DocumentParsePolicy';
import { parseSdkFailure, parseDetailedFailure, parseHttpFailure } from '../pipeline/ParseFailurePolicy';

function mineruSafeSession(): rcp.Session {
  const timeout: rcp.Timeout = { connectMs: 30000, transferMs: 120000, inactivityMs: 30000 };
  const transfer: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeout };
  const trace: rcp.TracingConfiguration = { verbose: false, collectTimeInfo: false, plaintextInException: false };
  const configuration: rcp.Configuration = { transfer: transfer, tracing: trace };
  const cache: rcp.CacheControl = { noCache: true, noStore: true, keepCache: false };
  const session: rcp.SessionConfiguration = { requestConfiguration: configuration, cacheControl: cache };
  return rcp.createSession(session);
}
function mineruTransportFailure(error: BusinessError, stage: string): DocumentParseFailure {
  if (error instanceof DocumentParseFailure) { return error; }
  const code: string = typeof error?.code === 'number' && Number.isSafeInteger(error.code) ? `${error.code}` : '';
  const failure = parseDetailedFailure(ParseFailureKind.Artifact,stage,'本机文件或资源处理失败'); failure.detail.sdkCode = code; return failure;
}
function mineruPropagateCallbackFailure(failure: DocumentParseFailure | undefined): void {
  if (failure instanceof DocumentParseFailure) { throw failure; }
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
// RCP substitutes a default Content-Type when the header is absent; a single space suppresses it so the
// presigned upload URL keeps its signature (the MinerU contract requires the raw PUT without Content-Type).
const MINERU_UPLOAD_NO_CONTENT_TYPE: string = ' ';
export class MineruUploadReader implements rcp.ReadFile {
  private file: fileIo.File; private action: DocumentParseAction; private offset: number = 0; private size: number;
  private md: cryptoFramework.Md = cryptoFramework.createMd('SHA256'); private reading: boolean = false;
  constructor(file: fileIo.File, action: DocumentParseAction) { this.file = file; this.action = action; this.size = action.original.bytes; }
  async read(buffer: ArrayBuffer): Promise<number> {
    if (this.reading) { throw new DocumentParseFailure('SDK上传读取回调未串行', '原件PUT'); }
    this.reading = true;
    try {
    this.action.cancel.check();
    if (this.offset >= this.size) { return 0; }
    if (buffer.byteLength === 0) { throw new DocumentParseFailure('SDK上传读取缓冲为空', '原件PUT'); }
    const length: number = Math.min(buffer.byteLength, this.size - this.offset); let supplied: number = 0;
    // Fill the requested range, including short file reads; never signal a premature EOF.
    while (supplied < length) {
      this.action.cancel.check(); const block: ArrayBuffer = new ArrayBuffer(Math.min(65536, length - supplied));
      const options: ReadOptions = { offset: this.offset, length: block.byteLength }; const n: number = await fileIo.read(this.file.fd, block, options);
      if (n < 1 || n > block.byteLength) { throw new DocumentParseFailure('上传读取不完整', '原件PUT'); }
      this.action.cancel.check(); const bytes: Uint8Array = new Uint8Array(block, 0, n);
      const blob: cryptoFramework.DataBlob = { data: bytes }; await this.md.update(blob); this.action.cancel.check();
      new Uint8Array(buffer).set(bytes, supplied); this.offset += n; supplied += n;
      this.action.task.uploadBytes = this.offset; this.action.onProgress();
    }
    return supplied;
    } finally { this.reading = false; }
  }
  async validate(): Promise<void> {
    const stat: fileIo.Stat = await fileIo.stat(this.file.fd);
    const extra: ArrayBuffer = new ArrayBuffer(1); const options: ReadOptions = { offset: this.size, length: 1 };
    if (!stat.isFile() || this.offset !== this.size || stat.size !== this.size || await fileIo.read(this.file.fd, extra, options) !== 0 || documentDigestHex((await this.md.digest()).data) !== this.action.original.hash) {
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
    if (documentIsImage(action.original.format) && action.original.bytes === 0 && (!authenticated || request.method !== 'GET')) { throw new DocumentParseFailure('缺原件仅允许复核原批次','请求前'); }
    if (documentIsImage(action.original.format) && ([ImageParsePermit.policy,ImageParsePermit.productionPolicy].indexOf(action.grant.policy) < 0 || action.grant.parameters !== ImageParsePermit.parameters || action.grant.revoked || action.grant.originalId !== action.original.id || action.grant.hash !== action.original.hash || action.grant.version !== action.original.version || action.grant.format !== action.original.format || action.grant.credentialRevision !== action.task.credentialRevision || action.task.originalId !== action.original.id || action.task.hash !== action.original.hash || action.task.version !== action.original.version || !action.grant.acknowledgement.fullFile || !action.grant.acknowledgement.freeEligible || action.grant.issuedAt < 1 || action.original.bytes > 0 && !documentGrantMatches(action.original,action.grant,action.task.credentialRevision))) { throw new DocumentParseFailure('当前图片许可身份或参数不符','请求前'); }
    action.cancel.check(); const session: rcp.Session = mineruSafeSession(); this.sessions.push(session);
    let complete: boolean = false; let timer: number = -1; let requestActive: boolean = true; let status: number = 0;
    let callbackTail: Promise<void> = Promise.resolve(); let callbackFailure: DocumentParseFailure | undefined = undefined;
    const handler: rcp.HttpEventsHandler = { onDataEnd: (): void => { complete = true; },
      onStatusCodeReceive: (code: number): void => { status = code; if (code >= 300 && code < 400) { session.cancel(request); } },
      onHeaderReceive: (headers: rcp.ResponseHeaders): void => {
        if (!authenticated && request.method === 'GET') {
          const length: string | string[] | undefined = headers['content-length'];
          if (typeof length === 'string' && new RegExp('^[0-9]{1,12}$').test(length) && Number(length) > 0 && Number(length) <= DocumentParseBudget.resultBytes) {
            action.task.downloadTotal = Number(length); action.onProgress();
          }
        }
      } };
    const tracing: rcp.TracingConfiguration = { verbose: false, collectTimeInfo: false, plaintextInException: false, httpEventsHandler: handler };
    const timeoutConfig: rcp.Timeout = { connectMs: 30000, transferMs: 120000, inactivityMs: 30000 };
    const transferConfig: rcp.TransferConfiguration = { autoRedirect: false, timeout: timeoutConfig };
    const config: rcp.Configuration = { tracing: tracing, transfer: transferConfig }; request.configuration = config;
    request.destination = (buffer: ArrayBuffer): Promise<void> => {
      const operation: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
        if (!requestActive) { throw new DocumentParseFailure('迟到数据未接收', '传输'); } action.cancel.check(); await incoming(buffer);
      });
       callbackTail = operation.then((): void => {}, (error: Error): void => {
         if (error instanceof DocumentParseFailure && error.detail.kind !== ParseFailureKind.Unknown) { callbackFailure = error; }
         else { callbackFailure = parseDetailedFailure(ParseFailureKind.Artifact,error instanceof DocumentParseFailure ? error.stage : '接收',error instanceof DocumentParseFailure ? error.category : '本机响应写入失败，已收阶段保留'); }
       });
      return operation;
    };
    try {
      if (request.method === 'PUT') { await action.onUploadStarting(); action.cancel.check(); }
      const timeout: Promise<rcp.Response> = new Promise<rcp.Response>((_resolve: (response: rcp.Response) => void, reject: (error: Object) => void): void => {
        timer = setTimeout((): void => { action.cancel.reason = 'TIMEOUT'; action.cancel.invalid = true; requestActive = false; const failure = parseDetailedFailure(ParseFailureKind.Network,request.method === 'PUT' ? '原件PUT' : '传输','请求总墙钟超时'); failure.detail.outcomeUnknown = request.method === 'PUT' || request.method === 'POST'; reject(failure); session.cancel(request); }, Math.min(DocumentParseBudget.requestMs, Math.max(1, action.cancel.deadline - Date.now())));
      });
      const work: Promise<rcp.Response> = authenticated ? this.credential.authenticatedFetch(request, session, (): void => {
        if (!requestActive) { throw new DocumentParseFailure('请求世代失效', '认证'); } action.cancel.check();
      }) : Promise.resolve().then((): Promise<rcp.Response> => {
        action.cancel.check();
        if (request.method === 'PUT') { action.task.uploadRequestStarted = true; action.task.lastAction = 'SDK PUT 已调用，等待响应'; action.onProgress(); }
        return session.fetch(request);
      }).catch((error: BusinessError | DocumentParseFailure): rcp.Response => {
        if (error instanceof DocumentParseFailure) { throw error; }
        throw parseSdkFailure(typeof error?.code === 'number' ? error.code : undefined,request.method === 'PUT' ? '原件PUT' : '结果GET',request.method === 'PUT');
      });
      const settled: Promise<rcp.Response> = work.then(async (response: rcp.Response): Promise<rcp.Response> => {
        await callbackTail; if (callbackFailure !== undefined) { throw callbackFailure; } return response;
      });
      const response: rcp.Response = await Promise.race<rcp.Response>([settled, timeout]);
      action.cancel.check(); mineruHttpStatus(response.statusCode, response.headers['retry-after']);
      // An empty PUT response need not yield a body event. fetch settlement plus 200 and exact source validation are required.
      if (request.method === 'PUT' && response.statusCode !== 200) { throw new DocumentParseFailure('上传HTTP未确认', '原件PUT', `${response.statusCode}`); }
      if (request.method !== 'PUT' && !complete) { throw new DocumentParseFailure('传输结束未经确认', '传输'); }
      return response;
    } catch (error) {
      session.cancel(request); await callbackTail;
      mineruPropagateCallbackFailure(callbackFailure);
      if (status >= 300 && status < 400) { throw parseHttpFailure(status,undefined); }
      if (error instanceof DocumentParseFailure) {
        if (error.detail.httpStatus > 0) { error.detail.stage = request.method === 'POST' ? '申请POST' : request.method === 'PUT' ? '原件PUT' : authenticated ? '原批次查询GET' : '结果ZIP GET'; error.stage = error.detail.stage; }
        throw error;
      }
      throw parseDetailedFailure(ParseFailureKind.Unknown,'传输','请求未完成，原因未确定');
    }
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
    await this.uploadOriginalBytes(action).catch((error: BusinessError): void => { throw mineruTransportFailure(error, action.task.uploadRequestStarted ? '原件PUT' : '上传前复核'); });
  }
  private async uploadOriginalBytes(action: DocumentParseAction): Promise<void> {
    await this.assets.verify(action.original, action.cancel);
    const binding: DocumentLeaseBinding = mineruBinding(action, 'UPLOAD', action.task.uploadLease);
    await this.credential.withLease(binding, async (address: string): Promise<void> => {
      mineruValidateDestination(address, 'UPLOAD'); action.cancel.check();
      const file: fileIo.File = await fileIo.open(documentAssetPath(this.filesRoot, action.original.assetId), fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
      try {
        const reader: MineruUploadReader = new MineruUploadReader(file, action);
        const request: rcp.Request = new rcp.Request(address, 'PUT'); request.content = new rcp.UploadFromFile(reader);
        const headers: rcp.RequestHeaders = { 'content-length': `${action.original.bytes}`, 'content-type': MINERU_UPLOAD_NO_CONTENT_TYPE }; request.headers = headers;
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
     inspection.state = dto.state; inspection.extractedPages = dto.extractedPages; inspection.totalPages = dto.totalPages; inspection.failureDetail = dto.failureDetail;
    if (dto.resultAddress.length > 0 && action.task.hash.length > 0) {
      const binding: DocumentLeaseBinding = mineruBinding(action, 'RESULT', `lease-${action.task.id}-result-${action.task.epoch}-${action.task.queries}`);
      await this.credential.sealLease(binding, dto.resultAddress); inspection.resultLease = binding.id;
    } action.cancel.check(); return inspection;
  }
  async receive(action: DocumentParseAction, usage: DocumentParseUsage): Promise<DocumentParseResultEnvelope> {
    action.task.downloadBytes = 0; action.task.downloadTotal = 0; action.onProgress();
    const sink: DocumentResultSink = await this.assets.resultSink(action, usage);
    try {
      const binding: DocumentLeaseBinding = mineruBinding(action, 'RESULT', action.task.resultLease);
      await this.credential.withLease(binding, async (address: string): Promise<void> => {
        mineruValidateDestination(address, 'RESULT');
        const request: rcp.Request = new rcp.Request(address, 'GET');
        const incoming: rcp.IncomingDataCallback = async (buffer: ArrayBuffer): Promise<void> => { await sink.write(buffer); };
        const response: rcp.Response = await this.fetch(request, false, action, incoming);
        await sink.waitForWrites();
        const length: string | string[] | undefined = response.headers['content-length'];
        if (length !== undefined && (typeof length !== 'string' || !new RegExp('^[0-9]{1,12}$').test(length) || Number(length) !== sink.actualBytes())) { throw new DocumentParseFailure('结果HTTP长度不符', '接收'); }
      });
      return await sink.finish();
    } catch (error) { await sink.abort(); if (error instanceof DocumentParseFailure) { throw error; } throw parseDetailedFailure(ParseFailureKind.Artifact,'接收','本机结果保存失败，云完成状态保留'); }
  }
  async removeLeases(ids: string[]): Promise<void> { await this.credential.removeLeases(ids); }
  async reconcileLeases(keepIds: string[]): Promise<void> { await this.credential.reconcileLeases(keepIds); }
}
