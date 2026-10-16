export enum DocumentParseFormat { Pdf = 'PDF', Docx = 'DOCX', Pptx = 'PPTX', Xlsx = 'XLSX' }
export enum DocumentCredentialStatus { Missing = '未配置', Configured = '已配置', Unavailable = '安全存储不可用' }
export enum DocumentPreflightStatus { Blocked = '待预检或预检阻止', Passed = '身份预检通过' }
export enum DocumentParseStage {
  Saved = '原件已保存', Allocation = '申请上传中', Uncertain = '提交结果不确定，待核对',
  LeaseReady = '上传地址已安全保存', Uploading = '上传中', UploadUnknown = '上传结果未知，请查询',
  Waiting = '等待文件', Pending = '排队中', Converting = '转换中', Running = '服务解析中',
  Done = '服务已完成，未接收', RemoteFailed = '服务失败', Downloading = '接收结果中',
  Received = '结果已接收，待结构校验', Paused = '本机暂停', Failed = '本机失败'
}
export enum DocumentRemoteState { Unobserved = '', Waiting = 'waiting-file', Pending = 'pending', Converting = 'converting', Running = 'running', Done = 'done', Failed = 'failed' }
export class DocumentParseBudget {
  static readonly originalBytes: number = 20 * 1024 * 1024;
  static readonly batchFiles: number = 3;
  static readonly batchBytes: number = 40 * 1024 * 1024;
  static readonly originalsTotal: number = 100 * 1024 * 1024;
  static readonly resultBytes: number = 30 * 1024 * 1024;
  static readonly resultsTotal: number = 200 * 1024 * 1024;
  static readonly pdfPages: number = 50;
  static readonly requestMs: number = 120000;
  static readonly localMs: number = 120000;
  static readonly pollMs: number = 900000;
  static readonly pollCount: number = 90;
  static readonly jsonBytes: number = 1024 * 1024;
  static readonly jsonDepth: number = 16;
  static readonly jsonTokens: number = 4096;
  static readonly stringBytes: number = 16384;
  static readonly directoryBytes: number = 2 * 1024 * 1024;
  static readonly directoryEntries: number = 4096;
  static readonly resultLeaseMs: number = 600000;
  static readonly uploadLeaseMs: number = 86400000;
  static readonly policy: string = 'mineru-nonsensitive-free-v1';
  static readonly parameters: string = 'vlm-table-formula-ch-noocr-v1';
}
export class DocumentParseFailure extends Error {
  category: string;
  stage: string;
  serviceCode: string;
  constructor(category: string, stage: string, serviceCode: string = '') {
    super(`${category} · ${stage}${serviceCode.length > 0 ? ' · ' + serviceCode : ''}`);
    this.category = category; this.stage = stage; this.serviceCode = serviceCode;
  }
}
export class DocumentParseCancellation {
  invalid: boolean = false;
  reason: string = '';
  deadline: number = Date.now() + DocumentParseBudget.localMs;
  check(): void {
    if (this.invalid) { throw new DocumentParseFailure('已暂停或世代失效', '本机动作'); }
    if (Date.now() >= this.deadline) { throw new DocumentParseFailure('时间预算耗尽', '本机动作'); }
  }
}
export class DocumentParseConfig {
  enabled: boolean = false;
  credentialRevision: number = 0;
  engine: string = 'MinerU 精准';
  mode: string = 'vlm';
}
export class DocumentSelectedFile { uri: string = ''; title: string = ''; bytes: number = -1; }
export class DocumentFileSelection { canceled: boolean = true; files: DocumentSelectedFile[] = []; }
export class DocumentOriginal {
  id: string = ''; assetId: string = ''; title: string = ''; hash: string = ''; bytes: number = 0;
  format: DocumentParseFormat = DocumentParseFormat.Pdf; version: number = 1;
  preflight: DocumentPreflightStatus = DocumentPreflightStatus.Blocked; pages: number = 0;
  preflightReason: string = ''; savedAt: number = 0;
}
export class DocumentTestAcknowledgement {
  fullFile: boolean = false; embeddedImages: boolean = false; nonSensitive: boolean = false;
  privacyUnknown: boolean = false; freeEligible: boolean = false;
}
export class DocumentParseGrant {
  id: string = ''; originalId: string = ''; hash: string = ''; version: number = 0;
  format: DocumentParseFormat = DocumentParseFormat.Pdf; credentialRevision: number = 0;
  policy: string = DocumentParseBudget.policy; parameters: string = DocumentParseBudget.parameters;
  acknowledgement: DocumentTestAcknowledgement = new DocumentTestAcknowledgement();
  issuedAt: number = 0; revoked: boolean = false;
}
export class DocumentParseTask {
  id: string = ''; originalId: string = ''; dataId: string = ''; batchId: string = ''; grantId: string = '';
  hash: string = ''; version: number = 0; credentialRevision: number = 0;
  stage: DocumentParseStage = DocumentParseStage.Saved;
  checkpoint: DocumentParseStage = DocumentParseStage.Saved;
  remote: DocumentRemoteState = DocumentRemoteState.Unobserved;
  epoch: number = 0; queries: number = 0; windowStart: number = 0;
  uploaded: boolean = false; uploadAttempted: boolean = false;
  recoveryUploadUsed: boolean = false; uploadRequestStarted: boolean = false;
  uploadBytes: number = 0; downloadBytes: number = 0; downloadTotal: number = 0;
  lastQueryAt: number = 0; lastAction: string = ''; failureStage: string = ''; failureCode: string = '';
  uploadLease: string = ''; resultLease: string = ''; failure: string = '';
  extractedPages: number = 0; totalPages: number = 0;
}
export class DocumentRemoteOccupancy {
  taskId: string = ''; dataId: string = ''; batchId: string = ''; credentialRevision: number = 0;
  lastState: DocumentRemoteState = DocumentRemoteState.Unobserved; terminalObserved: boolean = false;
  retired: boolean = false;
}
export class DocumentLeaseBinding {
  id: string = ''; taskId: string = ''; hash: string = ''; version: number = 0;
  credentialRevision: number = 0; purpose: string = ''; issuedAt: number = 0; expiresAt: number = 0;
  remoteExpiry: string = 'UNKNOWN';
}
export class DocumentParseResultEnvelope {
  assetId: string = ''; taskId: string = ''; dataId: string = ''; originalHash: string = ''; version: number = 0;
  bytes: number = 0; hash: string = ''; receivedAt: number = 0;
  status: string = 'UNVALIDATED'; completeTransport: boolean = false; signature: boolean = false;
}
export class DocumentParseCleanup {
  id: string = ''; assets: string[] = []; leases: string[] = []; originalBytes: number = 0;
  resultBytes: number = 0; failure: string = '';
}
export class DocumentParseUsage { originalBytes: number = 0; resultBytes: number = 0; originalTemp: number = 0; resultTemp: number = 0; }
export class DocumentParseSnapshot {
  config: DocumentParseConfig = new DocumentParseConfig(); originals: DocumentOriginal[] = [];
  grants: DocumentParseGrant[] = []; tasks: DocumentParseTask[] = []; results: DocumentParseResultEnvelope[] = [];
  cleanup: DocumentParseCleanup[] = []; occupancy: DocumentRemoteOccupancy = new DocumentRemoteOccupancy();
}
export class DocumentParseViewState {
  snapshot: DocumentParseSnapshot = new DocumentParseSnapshot();
  credential: DocumentCredentialStatus = DocumentCredentialStatus.Missing;
  message: string = ''; busy: boolean = false; inputEpoch: number = 0;
  resultDirectory: string = '';
  limitation: string = 'PDF / DOCX / PPTX / XLSX 仅转发；产物结构、原生位置、索引均未验证';
}
export class DocumentAllocationReceipt { batchId: string = ''; leaseId: string = ''; }
export class DocumentInspection {
  batchId: string = ''; dataId: string = ''; state: DocumentRemoteState = DocumentRemoteState.Unobserved;
  extractedPages: number = 0; totalPages: number = 0; resultLease: string = '';
}
export class DocumentParseAction {
  original: DocumentOriginal = new DocumentOriginal(); task: DocumentParseTask = new DocumentParseTask();
  grant: DocumentParseGrant = new DocumentParseGrant(); cancel: DocumentParseCancellation = new DocumentParseCancellation();
  onAllocation: (batchId: string) => Promise<void> = async (_batchId: string): Promise<void> => { throw new DocumentParseFailure('申请身份持久化回调缺失', '申请'); };
  onUploadStarting: () => Promise<void> = async (): Promise<void> => { throw new DocumentParseFailure('上传持久化回调缺失', '原件PUT'); };
  onProgress: () => void = (): void => {};
}
export interface DocumentParseStateListener { changed(): void; }

export function documentUtf8Bytes(text: string): number {
  let count: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      const next: number = text.charCodeAt(++i);
      if (!(next >= 0xDC00 && next <= 0xDFFF)) { throw new DocumentParseFailure('非法Unicode', '输入'); }
      count += 4;
    } else {
      if (c >= 0xDC00 && c <= 0xDFFF) { throw new DocumentParseFailure('非法Unicode', '输入'); }
      count += c < 128 ? 1 : c < 2048 ? 2 : 3;
    }
  }
  return count;
}
export function documentValidateToken(input: string): void {
  if (input.length === 0 || documentUtf8Bytes(input) > 1024) { throw new DocumentParseFailure('凭据长度非法', '设置'); }
  for (let i: number = 0; i < input.length; i++) {
    const c: number = input.charCodeAt(i);
    if (c <= 32 || c === 127 || c === 0x2028 || c === 0x2029) { throw new DocumentParseFailure('凭据包含认证头非法字符', '设置'); }
  }
}

export function documentCopySnapshot(source: DocumentParseSnapshot): DocumentParseSnapshot {
  const s: DocumentParseSnapshot = new DocumentParseSnapshot(); s.config.enabled = source.config.enabled; s.config.credentialRevision = source.config.credentialRevision;
  for (const o of source.originals) {
    const copy: DocumentOriginal = new DocumentOriginal(); copy.id = o.id; copy.assetId = o.assetId; copy.title = o.title; copy.hash = o.hash; copy.bytes = o.bytes;
    copy.format = o.format; copy.version = o.version; copy.preflight = o.preflight; copy.pages = o.pages; copy.preflightReason = o.preflightReason; copy.savedAt = o.savedAt; s.originals.push(copy);
  }
  for (const g of source.grants) {
    const copy: DocumentParseGrant = new DocumentParseGrant(); copy.id = g.id; copy.originalId = g.originalId; copy.hash = g.hash; copy.version = g.version; copy.format = g.format;
    copy.credentialRevision = g.credentialRevision; copy.policy = g.policy; copy.parameters = g.parameters; copy.issuedAt = g.issuedAt; copy.revoked = g.revoked;
    copy.acknowledgement.fullFile = g.acknowledgement.fullFile; copy.acknowledgement.embeddedImages = g.acknowledgement.embeddedImages;
    copy.acknowledgement.nonSensitive = g.acknowledgement.nonSensitive; copy.acknowledgement.privacyUnknown = g.acknowledgement.privacyUnknown; copy.acknowledgement.freeEligible = g.acknowledgement.freeEligible; s.grants.push(copy);
  }
  for (const t of source.tasks) {
    const copy: DocumentParseTask = new DocumentParseTask(); copy.id = t.id; copy.originalId = t.originalId; copy.dataId = t.dataId; copy.batchId = t.batchId; copy.grantId = t.grantId;
    copy.hash = t.hash; copy.version = t.version; copy.credentialRevision = t.credentialRevision; copy.stage = t.stage; copy.checkpoint = t.checkpoint; copy.remote = t.remote;
    copy.epoch = t.epoch; copy.queries = t.queries; copy.windowStart = t.windowStart; copy.uploaded = t.uploaded; copy.uploadAttempted = t.uploadAttempted;
    copy.recoveryUploadUsed = t.recoveryUploadUsed; copy.uploadRequestStarted = t.uploadRequestStarted;
    copy.uploadBytes = t.uploadBytes; copy.downloadBytes = t.downloadBytes; copy.downloadTotal = t.downloadTotal;
    copy.lastQueryAt = t.lastQueryAt; copy.lastAction = t.lastAction; copy.failureStage = t.failureStage; copy.failureCode = t.failureCode;
    copy.uploadLease = t.uploadLease; copy.resultLease = t.resultLease; copy.failure = t.failure; copy.extractedPages = t.extractedPages; copy.totalPages = t.totalPages; s.tasks.push(copy);
  }
  for (const r of source.results) {
    const copy: DocumentParseResultEnvelope = new DocumentParseResultEnvelope(); copy.assetId = r.assetId; copy.taskId = r.taskId; copy.dataId = r.dataId; copy.originalHash = r.originalHash;
    copy.version = r.version; copy.bytes = r.bytes; copy.hash = r.hash; copy.receivedAt = r.receivedAt; copy.status = r.status; copy.completeTransport = r.completeTransport; copy.signature = r.signature; s.results.push(copy);
  }
  for (const c of source.cleanup) {
    const copy: DocumentParseCleanup = new DocumentParseCleanup(); copy.id = c.id; copy.assets = c.assets.slice(); copy.leases = c.leases.slice(); copy.originalBytes = c.originalBytes; copy.resultBytes = c.resultBytes; copy.failure = c.failure; s.cleanup.push(copy);
  }
  s.occupancy.taskId = source.occupancy.taskId; s.occupancy.dataId = source.occupancy.dataId; s.occupancy.batchId = source.occupancy.batchId;
  s.occupancy.credentialRevision = source.occupancy.credentialRevision; s.occupancy.lastState = source.occupancy.lastState; s.occupancy.terminalObserved = source.occupancy.terminalObserved;
  s.occupancy.retired = source.occupancy.retired; return s;
}
