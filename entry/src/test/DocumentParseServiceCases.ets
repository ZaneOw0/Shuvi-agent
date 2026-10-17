import { DocumentParseService } from '../main/ets/knowledge/application/DocumentParseService';
import {
  DocumentCredentialStatus, DocumentParseSnapshot, DocumentParseFailure, DocumentFileSelection, DocumentSelectedFile,
  DocumentOriginal, DocumentParseCancellation, DocumentParseAction, DocumentAllocationReceipt, DocumentInspection,
  DocumentParseUsage, DocumentParseResultEnvelope, DocumentRemoteState, DocumentParseStage, DocumentParseBudget, DocumentPreflightStatus, DocumentParseFormat,
  DocumentParseStateListener, DocumentParseViewState, DocumentParseTask, DocumentParseGrant
} from '../main/ets/knowledge/domain/DocumentParseModels';
import {
  MineruCredentialPort, DocumentParseRepositoryPort, DocumentAssetPort, DocumentSelectionPort, DocumentPreflightPort,
  MineruTaskPort, DocumentParseClockPort
} from '../main/ets/knowledge/domain/DocumentParsePorts';
import { documentUnitOriginal, documentUnitGrant } from './DocumentParseCases';
import { TextTestSession } from './TextServiceCases';
import { KnowledgeSourceProtectionPort } from '../main/ets/knowledge/domain/KnowledgePorts';

export interface DocumentServiceTestCase { name: string; run: () => Promise<void>; }
export function documentServiceCheck(ok: boolean): void { if (!ok) { throw new Error('M2 frozen business expectation failed'); } }
export class DocumentTestCredential implements MineruCredentialPort {
  configured: boolean = false; unavailable: boolean = false; saves: number = 0; clears: number = 0;
  statusThrows: boolean = false; writeFailure: boolean = false; returnedStatus: DocumentCredentialStatus = DocumentCredentialStatus.Configured;
  async status(): Promise<DocumentCredentialStatus> {
    if (this.statusThrows) { throw new Error('unit-nonsecret-refresh-detail'); }
    return this.unavailable ? DocumentCredentialStatus.Unavailable : this.configured ? DocumentCredentialStatus.Configured : DocumentCredentialStatus.Missing;
  }
  async save(input: string, replace: boolean): Promise<DocumentCredentialStatus> {
    this.saves++;
    if (this.writeFailure) { throw new DocumentParseFailure('安全存储权限不足', '凭据新增', '201'); }
    if (this.unavailable || this.configured !== replace) { throw new DocumentParseFailure('安全存储拒绝', '设置'); }
    this.configured = this.returnedStatus === DocumentCredentialStatus.Configured; return this.returnedStatus;
  }
  async remove(): Promise<DocumentCredentialStatus> {
    if (this.unavailable) { throw new DocumentParseFailure('安全存储拒绝', '设置'); }
    this.configured = false; return DocumentCredentialStatus.Missing;
  }
  clearTransient(): void { this.clears++; }
}
export class DocumentTestRepository implements DocumentParseRepositoryPort {
  data: DocumentParseSnapshot = new DocumentParseSnapshot(); fail: boolean = false; rawFailure: boolean = false;
  async open(): Promise<void> {}
  async load(): Promise<DocumentParseSnapshot> { return this.data; }
  async save(snapshot: DocumentParseSnapshot): Promise<void> {
    if (this.rawFailure) { throw new Error('unit-nonsecret-repository-detail'); }
    if (this.fail) { throw new DocumentParseFailure('持久化失败', '检查点'); }
    this.data = snapshot;
  }
  async close(): Promise<void> {}
}
export class DocumentTestSettingsSession {
  credential: DocumentTestCredential = new DocumentTestCredential();
  repository: DocumentTestRepository = new DocumentTestRepository();
  service: DocumentParseService = new DocumentParseService(this.credential, this.repository);
  constructor() { this.service.attachSourceProtection(new DocumentTestUnreferencedSources()); }
}
// An explicit injected M2-only boundary; never used by production assembly.
class DocumentTestUnreferencedSources implements KnowledgeSourceProtectionPort {
  async withSource<T>(_source: string, action: () => Promise<T>): Promise<T> { return action(); }
  async assertDeletable(_source: string, _assets: string[]): Promise<void> {}
  async assertCleanup(_assets: string[]): Promise<void> {}
}
class DocumentTestStateObserver implements DocumentParseStateListener {
  service: DocumentParseService; views: DocumentParseViewState[] = [];
  constructor(service: DocumentParseService) { this.service = service; }
  changed(): void { this.views.push(this.service.viewState()); }
}
export class DocumentTestAssets implements DocumentAssetPort, DocumentSelectionPort, DocumentPreflightPort {
  removed: string[] = []; saves: number = 0; failCleanup: boolean = false;
  selected: DocumentFileSelection = new DocumentFileSelection(); blocked: boolean = false; expirePreflight: boolean = false;
  async select(): Promise<DocumentFileSelection> { return this.selected; }
  async save(file: DocumentSelectedFile, id: string, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    this.saves++; const original: DocumentOriginal = documentUnitOriginal(); original.id = id; original.assetId = `original-${id}`;
    original.title = file.title; original.bytes = file.bytes;
    original.format = file.title.endsWith('.docx') ? DocumentParseFormat.Docx : file.title.endsWith('.pptx') ? DocumentParseFormat.Pptx : file.title.endsWith('.xlsx') ? DocumentParseFormat.Xlsx : DocumentParseFormat.Pdf;
    return original;
  }
  async verify(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<void> { cancel.check(); }
  async inspect(original: DocumentOriginal, cancel: DocumentParseCancellation): Promise<DocumentOriginal> {
    if (this.expirePreflight) { cancel.invalid = true; throw new DocumentParseFailure('预检取消', '单元端口'); }
    if (this.blocked) { original.preflight = DocumentPreflightStatus.Blocked; original.preflightReason = '单元端口预检不可用'; } return original;
  }
  async remove(ids: string[]): Promise<void> { if (this.failCleanup) { throw new DocumentParseFailure('磁盘清理失败', '测试'); } this.removed = this.removed.concat(ids); }
  cancelLocal(): void {}
}
export class DocumentTestClock implements DocumentParseClockPort {
  time: number = Date.now(); sequence: number = 0;
  now(): number { return this.time; }
  id(): string { return `unit-task-${++this.sequence}`; }
  async sleep(ms: number): Promise<void> { this.time += ms; }
}
export class DocumentTestNetwork implements MineruTaskPort {
  allocations: number = 0; uploads: number = 0; queries: number = 0; receives: number = 0; pauses: number = 0;
  mode: string = 'NORMAL'; states: DocumentRemoteState[] = [DocumentRemoteState.Waiting, DocumentRemoteState.Pending, DocumentRemoteState.Converting, DocumentRemoteState.Running, DocumentRemoteState.Done];
  events: string[] = [];
  onUpload: () => void = (): void => {};
  ordering: boolean = false; repository: DocumentTestRepository;
  onReceive: () => Promise<void> = async (): Promise<void> => {};
  constructor(repository: DocumentTestRepository) { this.repository = repository; }
  async allocate(action: DocumentParseAction): Promise<DocumentAllocationReceipt> {
    this.allocations++; documentServiceCheck(this.repository.data.occupancy.taskId === action.task.id && action.task.stage === DocumentParseStage.Allocation);
    if (this.mode === 'UNCERTAIN') { throw new DocumentParseFailure('响应未知', '申请'); }
    await action.onAllocation('unit-batch-1');
    const result: DocumentAllocationReceipt = new DocumentAllocationReceipt(); result.batchId = 'unit-batch-1'; result.leaseId = 'lease-unit-upload'; return result;
  }
  async upload(action: DocumentParseAction): Promise<void> {
    this.events.push('preflight');
    if (this.mode === 'UPLOAD_PREFLIGHT') { throw new DocumentParseFailure('租约已失效', '上传前复核'); }
    await action.onUploadStarting(); action.task.uploadRequestStarted = true; this.events.push('PUT'); this.onUpload();
    this.uploads++; this.ordering = this.repository.data.occupancy.batchId === 'unit-batch-1' && action.task.uploadAttempted && action.task.uploadLease === 'lease-unit-upload';
    if (this.mode === 'UPLOAD_TIMEOUT') { action.cancel.invalid = true; action.cancel.reason = 'TIMEOUT'; throw new DocumentParseFailure('请求总墙钟超时', '原件PUT'); }
    if (this.mode === 'UPLOAD_UNKNOWN') { throw new DocumentParseFailure('上传响应未知', 'PUT'); }
    action.cancel.check();
  }
  async inspect(action: DocumentParseAction): Promise<DocumentInspection> {
    this.queries++; this.events.push('QUERY');
    if (this.mode === '429' || this.mode === 'AUTH' || this.mode === 'EXPIRED') { throw new DocumentParseFailure(this.mode, '查询'); }
    const result: DocumentInspection = new DocumentInspection(); result.batchId = action.task.batchId; result.dataId = action.task.dataId;
    result.state = this.states[Math.min(this.queries - 1, this.states.length - 1)]; result.resultLease = result.state === DocumentRemoteState.Done ? 'lease-unit-result' : '';
    return result;
  }
  async receive(action: DocumentParseAction, usage: DocumentParseUsage): Promise<DocumentParseResultEnvelope> {
    this.receives++; await this.onReceive(); const result: DocumentParseResultEnvelope = new DocumentParseResultEnvelope();
    result.assetId = `result-${action.task.id}`; result.taskId = action.task.id; result.dataId = action.task.dataId;
    result.originalHash = action.task.hash; result.version = action.task.version; result.bytes = 100; result.hash = 'b'.repeat(64);
    result.signature = true; result.completeTransport = true; result.receivedAt = Date.now();
    if (this.mode === 'RESULT_LIMIT') { result.bytes = DocumentParseBudget.resultBytes + 1; }
    if (this.mode === 'RESULT_ID') { result.originalHash = 'c'.repeat(64); }
    if (this.mode === 'RESULT_PARTIAL') { result.completeTransport = false; }
    if (this.mode === 'RESULT_SCHEMA') { result.status = 'INDEXED'; }
    return result;
  }
  async removeLeases(ids: string[]): Promise<void> {}
  async reconcileLeases(keepIds: string[]): Promise<void> {}
  pause(): void { this.pauses++; }
}
export class DocumentTestPipelineSession extends DocumentTestSettingsSession {
  assets: DocumentTestAssets = new DocumentTestAssets(); clock: DocumentTestClock = new DocumentTestClock();
  network: DocumentTestNetwork = new DocumentTestNetwork(this.repository);
  async ready(): Promise<void> {
    this.service.attachLocal(this.assets, this.assets, this.assets); this.service.attachRemote(this.network, this.clock);
    this.credential.configured = true; await this.service.initialize();
    this.repository.data.config.enabled = true; this.repository.data.config.credentialRevision = 1;
    const original: DocumentOriginal = documentUnitOriginal(); this.repository.data.originals.push(original); this.repository.data.grants.push(documentUnitGrant(original));
  }
}
export function documentParseServiceCases(): DocumentServiceTestCase[] {
  const tests: DocumentServiceTestCase[] = [
    { name: '包登记事务失败不能公开接收成功或丢清理账本', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.states = [DocumentRemoteState.Done];
      s.network.onReceive = async (): Promise<void> => { s.repository.fail = true; };
      await s.service.submit('unit-original');
      documentServiceCheck(s.service.state.snapshot.results.length === 0 && s.service.state.snapshot.cleanup.length > 0 && s.service.state.snapshot.tasks[0].stage !== DocumentParseStage.Received);
    } },
    { name: '默认关闭且没有公共秘密', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize();
      documentServiceCheck(!s.service.state.snapshot.config.enabled && s.service.state.credential === DocumentCredentialStatus.Missing);
      documentServiceCheck(JSON.stringify(s.service.viewState()).indexOf('unit-nonsecret-input') < 0);
    } },
    { name: '保存更新删除真实状态与revision', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize();
      await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(s.service.state.credential === DocumentCredentialStatus.Configured && s.repository.data.config.credentialRevision === 1);
      await s.service.saveToken('unit-nonsecret-input-2', true);
      documentServiceCheck(s.repository.data.config.credentialRevision === 2);
      await s.service.removeToken(); documentServiceCheck(s.service.state.credential === DocumentCredentialStatus.Missing);
      documentServiceCheck(s.repository.data.config.credentialRevision === 3 && s.credential.clears >= 3);
      documentServiceCheck(JSON.stringify(s.service.state).indexOf('unit-nonsecret-input') < 0);
    } },
    { name: '锁定与存储拒绝不能假成功', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); s.credential.unavailable = true;
      await s.service.initialize(); await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(s.service.state.credential === DocumentCredentialStatus.Unavailable && s.service.state.message.length > 0);
      documentServiceCheck(!s.repository.data.config.enabled);
    } },
    { name: '认证头输入非法与UTF8长度拒绝', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize();
      for (const input of ['', 'a\r\nb', 'a\u0000b', '中'.repeat(342), 'x'.repeat(1025)]) {
        await s.service.saveToken(input, false); documentServiceCheck(s.credential.saves === 0);
      }
    } }
    , { name: '无同意每个门禁均零真实端口调用', run: async (): Promise<void> => {
      for (const mode of ['CLOSED', 'MISSING', 'GRANT', 'FREE', 'PRIVACY', 'PERSONAL', 'PREFLIGHT']) {
        const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready();
        if (mode === 'CLOSED') { s.repository.data.config.enabled = false; }
        if (mode === 'MISSING') { s.service.state.credential = DocumentCredentialStatus.Missing; }
        if (mode === 'GRANT') { s.repository.data.grants = []; }
        if (mode === 'FREE') { s.repository.data.grants[0].acknowledgement.freeEligible = false; }
        if (mode === 'PRIVACY') { s.repository.data.grants[0].acknowledgement.privacyUnknown = false; }
        if (mode === 'PERSONAL') { s.repository.data.grants[0].acknowledgement.nonSensitive = false; }
        if (mode === 'PREFLIGHT') { s.repository.data.originals[0].pages = 51; }
        await s.service.submit('unit-original');
        documentServiceCheck(s.network.allocations === 0 && s.network.uploads === 0 && s.network.queries === 0 && s.network.receives === 0);
      }
    } },
    { name: '申请checkpoint身份租约先落盘再PUT六阶段真实编排', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); await s.service.submit('unit-original');
      documentServiceCheck(s.network.allocations === 1 && s.network.uploads === 1 && s.network.ordering && s.network.queries === 5 && s.network.receives === 1);
      documentServiceCheck(s.repository.data.tasks[0].stage === DocumentParseStage.Received && s.repository.data.results[0].status === 'UNVALIDATED');
      documentServiceCheck(s.repository.data.occupancy.terminalObserved);
      await s.service.submit('unit-original'); documentServiceCheck(s.network.allocations === 1);
    } }
  ]; return tests.concat(documentTransferFixCases(), documentCredentialFeedbackCases(), documentRecoveryCases(), [
    { name: '仅本地准备四格式不外发且取消与PDF阻塞保留', run: async (): Promise<void> => {
      for (const suffix of ['pdf', 'docx', 'pptx', 'xlsx']) {
        const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.repository.data.originals = []; s.repository.data.grants = [];
        s.repository.data.config.enabled = false; s.assets.selected.canceled = false;
        const file: DocumentSelectedFile = new DocumentSelectedFile(); file.uri = 'unit-local-opaque'; file.title = 'unit-file.' + suffix; file.bytes = 100;
        s.assets.selected.files.push(file); s.assets.blocked = suffix === 'pdf'; await s.service.prepare();
        documentServiceCheck(s.repository.data.originals.length === 1 && s.network.allocations === 0 && s.repository.data.grants.length === 0);
        if (suffix === 'pdf') { documentServiceCheck(s.repository.data.originals[0].preflight === DocumentPreflightStatus.Blocked); }
        s.assets.selected.canceled = true; await s.service.prepare(); documentServiceCheck(s.assets.saves === 1);
      }
    } },
    { name: 'PDF页数预检取消已保存保真原件必须保留', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.repository.data.originals = []; s.repository.data.grants = [];
      s.assets.selected.canceled = false; s.assets.expirePreflight = true;
      const file: DocumentSelectedFile = new DocumentSelectedFile(); file.title = 'unit-file.pdf'; file.bytes = 100; s.assets.selected.files.push(file);
      await s.service.prepare(); documentServiceCheck(s.repository.data.originals.length === 1 && s.repository.data.originals[0].preflight === DocumentPreflightStatus.Blocked && s.assets.removed.length === 0 && s.network.allocations === 0);
    } },
    { name: '原件摘要判重与超预算不删除原资料', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.assets.selected.canceled = false;
      const file: DocumentSelectedFile = new DocumentSelectedFile(); file.title = 'unit-file.pdf'; file.bytes = 100; s.assets.selected.files.push(file);
      await s.service.prepare(); documentServiceCheck(s.repository.data.originals.length === 1 && s.assets.removed.length > 0);
      file.bytes = DocumentParseBudget.originalBytes + 1; await s.service.prepare(); documentServiceCheck(s.assets.saves === 1 && s.repository.data.originals[0].id === 'unit-original');
    } },
    { name: 'M1资料问题历史不被M2修改或索引包', run: async (): Promise<void> => {
      const m1: TextTestSession = new TextTestSession(); await m1.service.initialize(); await m1.service.importFiles();
      m1.service.questionChanged('关键词证据'); await m1.service.search();
      const before: string = JSON.stringify(m1.service.state); const records: string = JSON.stringify(m1.repository.records);
      const m2: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await m2.ready(); await m2.service.submit('unit-original');
      await m2.service.deleteOriginal('unit-original');
      documentServiceCheck(JSON.stringify(m1.service.state) === before && JSON.stringify(m1.repository.records) === records);
      documentServiceCheck(m2.network.receives === 1 && m1.repository.records.length === 1);
    } },
    { name: '四格式仅转发结构和定位均未验证', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready();
      documentServiceCheck(s.service.viewState().limitation.indexOf('均未验证') >= 0 && s.service.viewState().limitation.indexOf('XLSX') >= 0);
      documentServiceCheck(s.service.capabilitySummary().indexOf('不提供完整PDF预览或高亮') >= 0);
    } }
  ]);
}

function documentTransferFixCases(): DocumentServiceTestCase[] {
  return [
    { name: 'PUT本地预检失败不得记成真正请求已发出', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_PREFLIGHT';
      await s.service.submit('unit-original');
      documentServiceCheck(s.network.uploads === 0 && !s.repository.data.tasks[0].uploadAttempted && s.repository.data.tasks[0].failure.indexOf('租约') >= 0);
    } },
    { name: 'PUT超时失效仍必须记录阶段错误而非吞掉', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_TIMEOUT'; await s.service.submit('unit-original');
      documentServiceCheck(s.repository.data.tasks[0].stage === DocumentParseStage.UploadUnknown && s.repository.data.tasks[0].failure.indexOf('超时') >= 0 && !s.service.state.busy);
    } },
    { name: '旧已尝试任务先Query后同对象补传一次并持久化耗用', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      s.network.events = []; s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Waiting, DocumentRemoteState.Done];
      const t: DocumentParseTask = s.repository.data.tasks[0]; t.queries = 7; const id: string = t.id;
      await s.service.resume(id, true);
      documentServiceCheck(s.network.events[0] === 'QUERY' && s.network.uploads === 2 && s.network.allocations === 1 && t.recoveryUploadUsed && t.uploadAttempted && t.queries === 9);
      documentServiceCheck(t.stage === DocumentParseStage.Received && s.repository.data.results.length === 1 && t.id === id);
    } },
    { name: '补传未知后重开也不得再次补传或创建批次', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      s.network.states = [DocumentRemoteState.Waiting]; await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.uploads === 2 && s.repository.data.tasks[0].recoveryUploadUsed);
      await s.service.initialize(); await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.uploads === 2 && s.network.allocations === 1 && s.repository.data.tasks[0].failure.length > 0);
    } },
    { name: '旧租约失效不耗用网络补传且准确停止', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      s.network.mode = 'UPLOAD_PREFLIGHT'; s.network.states = [DocumentRemoteState.Waiting]; await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.uploads === 1 && !s.repository.data.tasks[0].recoveryUploadUsed && s.repository.data.tasks[0].failure.indexOf('租约') >= 0);
    } },
    { name: '前台清密码不使活动凭据失效但显式暂停仍清认证', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); const clears: number = s.credential.clears;
      s.network.onUpload = (): void => { s.service.clearInput(); };
      await s.service.submit('unit-original');
      documentServiceCheck(s.repository.data.results.length === 1 && s.credential.clears === clears && s.network.pauses === 0);
      await s.service.pause(); documentServiceCheck(s.credential.clears > clears && s.network.pauses > 0);
    } },
    { name: '任务动作忙态立即发布且Query保留次数及完成时间', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); const observer: DocumentTestStateObserver = new DocumentTestStateObserver(s.service); s.service.subscribe(observer);
      s.network.states = [DocumentRemoteState.Done]; await s.service.submit('unit-original');
      documentServiceCheck(observer.views.some((v: DocumentParseViewState): boolean => v.busy) && s.repository.data.tasks[0].lastQueryAt > 0);
      documentServiceCheck(s.service.viewState().snapshot.tasks[0].lastQueryAt === s.repository.data.tasks[0].lastQueryAt);
    } },
    { name: '原批次查询unknown与鉴权失败不补传不申请', run: async (): Promise<void> => {
      for (const mode of ['UNKNOWN', 'AUTH']) {
        const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
        s.network.mode = mode; s.network.states = [DocumentRemoteState.Unobserved]; await s.service.resume(s.repository.data.tasks[0].id, true);
        documentServiceCheck(s.network.uploads === 1 && s.network.allocations === 1 && !s.repository.data.tasks[0].recoveryUploadUsed && s.repository.data.tasks[0].failure.length > 0);
      }
    } },
    { name: '原件绑定改变拒绝旧任务恢复和补传', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      s.repository.data.originals[0].hash = 'c'.repeat(64); s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Waiting];
      await s.service.resume(s.repository.data.tasks[0].id, true); documentServiceCheck(s.network.queries === 0 && s.network.uploads === 1 && s.network.allocations === 1);
    } },
    { name: '补传持久化失败必须零第二次PUT', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      s.repository.fail = true; await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.uploads === 1 && s.network.allocations === 1 && s.repository.data.tasks[0].failure.length > 0 && !s.service.state.busy);
    } },
    { name: '已有批次上传前失败恢复Query后执行首次PUT不是补传', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_PREFLIGHT'; await s.service.submit('unit-original');
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Waiting, DocumentRemoteState.Done]; s.network.events = [];
      await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.events[0] === 'QUERY' && s.network.uploads === 1 && s.network.allocations === 1 && !s.repository.data.tasks[0].recoveryUploadUsed && s.repository.data.results.length === 1);
    } }
  ];
}

function documentCredentialFeedbackCases(): DocumentServiceTestCase[] {
  return [
    { name: '保存遇忙必须可见拒绝且不调用凭据', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize(); s.service.state.busy = true;
      const clears: number = s.credential.clears;
      const observer: DocumentTestStateObserver = new DocumentTestStateObserver(s.service); s.service.subscribe(observer);
      await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(s.credential.saves === 0 && s.service.state.busy && observer.views.length > 0 && s.service.state.message.indexOf('未执行') >= 0);
      documentServiceCheck(s.credential.clears === clears);
    } },
    { name: '保存开始发布忙态反馈结束发布确认状态并清输入', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize();
      const observer: DocumentTestStateObserver = new DocumentTestStateObserver(s.service); s.service.subscribe(observer);
      await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(observer.views.some((view: DocumentParseViewState): boolean => view.busy && view.message.indexOf('正在') >= 0));
      documentServiceCheck(!s.service.state.busy && s.service.state.credential === DocumentCredentialStatus.Configured && s.credential.clears > 0);
      documentServiceCheck(observer.views.every((view: DocumentParseViewState): boolean => JSON.stringify(view).indexOf('unit-nonsecret-input') < 0));
    } },
    { name: '写入失败后的刷新再失败仍发布原阶段code与不可用', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize();
      s.credential.writeFailure = true; s.credential.statusThrows = true;
      const observer: DocumentTestStateObserver = new DocumentTestStateObserver(s.service); s.service.subscribe(observer);
      let rejected: boolean = false;
      try { await s.service.saveToken('unit-nonsecret-input', false); } catch { rejected = true; }
      documentServiceCheck(!rejected);
      documentServiceCheck(!s.service.state.busy && s.service.state.credential === DocumentCredentialStatus.Unavailable && observer.views.length > 0);
      documentServiceCheck(s.service.state.message.indexOf('凭据新增') >= 0 && s.service.state.message.indexOf('201') >= 0 && s.service.state.message.indexOf('unit-nonsecret-refresh-detail') < 0);
    } },
    { name: '保存端口返回未确认状态不能显示已安全保存', run: async (): Promise<void> => {
      for (const status of [DocumentCredentialStatus.Missing, DocumentCredentialStatus.Unavailable]) {
        const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize(); s.credential.returnedStatus = status;
        await s.service.saveToken('unit-nonsecret-input', false);
        documentServiceCheck(s.service.state.credential !== DocumentCredentialStatus.Configured && s.service.state.message.indexOf('已安全保存') < 0 && s.service.state.message.length > 0);
      }
    } },
    { name: '撤销检查点失败可见且不进入Asset写入', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize(); s.repository.fail = true;
      await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(s.credential.saves === 0 && !s.service.state.busy && s.service.state.message.indexOf('持久化失败') >= 0);
    } },
    { name: '未知异常不回显原文且保存按钮最终解忙', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize(); s.repository.rawFailure = true; s.credential.statusThrows = true;
      await s.service.saveToken('unit-nonsecret-input', false);
      documentServiceCheck(s.credential.saves === 0 && !s.service.state.busy && s.service.state.credential === DocumentCredentialStatus.Unavailable && s.service.state.message.indexOf('unit-nonsecret') < 0);
    } },
    { name: '删除失败后刷新再失败同样有可见错误', run: async (): Promise<void> => {
      const s: DocumentTestSettingsSession = new DocumentTestSettingsSession(); await s.service.initialize(); s.credential.unavailable = true; s.credential.statusThrows = true;
      await s.service.removeToken();
      documentServiceCheck(!s.service.state.busy && s.service.state.credential === DocumentCredentialStatus.Unavailable && s.service.state.message.indexOf('安全存储拒绝') >= 0);
    } }
  ];
}

function documentRecoveryCases(): DocumentServiceTestCase[] {
  const tests: DocumentServiceTestCase[] = [
    { name: '公开视图整体快照修改不改变任务Grant', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); const view = s.service.viewState();
      view.snapshot.grants[0].acknowledgement.freeEligible = false; view.snapshot.originals[0].hash = 'c'.repeat(64);
      documentServiceCheck(s.repository.data.grants[0].acknowledgement.freeEligible && s.repository.data.originals[0].hash === 'a'.repeat(64));
    } },
    { name: '申请身份检查点失败零PUT且远端占用仍保留', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready();
      s.repository.fail = true; await s.service.submit('unit-original'); documentServiceCheck(s.network.allocations === 0 && s.network.uploads === 0);
    } },
    { name: '关闭解析晚到结果不发布默认不恢复网络', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.states = [DocumentRemoteState.Done];
      s.network.onReceive = async (): Promise<void> => { await s.service.setEnabled(false); };
      await s.service.submit('unit-original'); documentServiceCheck(s.repository.data.results.length === 0 && !s.repository.data.config.enabled && s.network.pauses > 0);
    } },
    { name: '背景暂停输入世代清理并阻止晚到发布', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.states = [DocumentRemoteState.Done];
      const before: number = s.service.state.inputEpoch;
      s.network.onReceive = async (): Promise<void> => { await s.service.pause(); };
      await s.service.submit('unit-original'); documentServiceCheck(s.repository.data.results.length === 0 && s.service.state.inputEpoch > before);
      const queries: number = s.network.queries; await s.service.initialize(); documentServiceCheck(s.network.queries === queries && s.repository.data.tasks[0].stage === DocumentParseStage.Paused);
    } },
    { name: '提交响应未知恢复不重提未知slot不释放', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UNCERTAIN';
      await s.service.submit('unit-original'); const id: string = s.repository.data.tasks[0].id;
      documentServiceCheck(s.repository.data.tasks[0].stage === DocumentParseStage.Uncertain && !s.repository.data.occupancy.terminalObserved);
      await s.service.resume(id, true); await s.service.submit('unit-original');
      documentServiceCheck(s.network.allocations === 1 && s.network.queries === 0);
      await s.service.deleteOriginal('unit-original');
      documentServiceCheck(s.repository.data.tasks.length === 0 && s.repository.data.originals.length === 0 && s.repository.data.occupancy.taskId === id);
      const tombstone: string = JSON.stringify(s.repository.data.occupancy);
      documentServiceCheck(tombstone.indexOf('unit-only.pdf') < 0 && tombstone.indexOf('a'.repeat(64)) < 0);
    } },
    { name: 'PUT结果未知仅Query已有身份不自动上传申请', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      documentServiceCheck(s.repository.data.tasks[0].stage === DocumentParseStage.UploadUnknown);
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Done];
      await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.allocations === 1 && s.network.uploads === 1 && s.network.queries === 1 && s.repository.data.results.length === 1);
    } },
    { name: '15分钟有界暂停仍保留未决slot', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.states = [DocumentRemoteState.Pending]; await s.service.submit('unit-original');
      documentServiceCheck(s.network.queries <= 90 && s.repository.data.tasks[0].stage === DocumentParseStage.Paused && !s.repository.data.occupancy.terminalObserved);
      await s.service.pause(); documentServiceCheck(s.repository.data.occupancy.taskId.length > 0 && s.network.pauses > 0);
    } },
    { name: '晚到包删除不能复活且清理失败可恢复', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.states = [DocumentRemoteState.Done];
      s.assets.failCleanup = true; s.network.onReceive = async (): Promise<void> => { await s.service.deleteOriginal('unit-original'); };
      await s.service.submit('unit-original');
      documentServiceCheck(s.repository.data.originals.length === 0 && s.repository.data.results.length === 0 && s.repository.data.cleanup.length > 0);
      s.assets.failCleanup = false; await s.service.retryCleanup(); await s.service.retryCleanup();
      documentServiceCheck(s.repository.data.cleanup.length === 0 && s.assets.removed.indexOf('original-unit') >= 0);
    } },
    { name: '凭据更新撤销Grant不同账号不自动Query', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      const id: string = s.repository.data.tasks[0].id; await s.service.saveToken('unit-nonsecret-replacement', true);
      await s.service.resume(id, false); documentServiceCheck(s.network.queries === 0 && !s.repository.data.config.enabled && s.repository.data.grants[0].revoked);
    } },
    { name: '已删未决tombstone需确认Query终态才释放', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      await s.service.deleteOriginal('unit-original'); documentServiceCheck(!s.repository.data.occupancy.terminalObserved);
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Failed];
      await s.service.inspectOccupancy(false); documentServiceCheck(s.network.queries === 0);
      await s.service.inspectOccupancy(true); documentServiceCheck(s.network.queries === 1 && s.repository.data.occupancy.terminalObserved);
    } },
    { name: '核对后远端仍等待文件经二次确认可停止本机跟踪', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      await s.service.deleteOriginal('unit-original');
      documentServiceCheck(!s.repository.data.occupancy.terminalObserved && !s.repository.data.occupancy.retired && !s.service.canRetireOccupancy());
      await s.service.retireOccupancy(true); documentServiceCheck(!s.repository.data.occupancy.retired);
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Waiting];
      await s.service.inspectOccupancy(true);
      documentServiceCheck(s.service.canRetireOccupancy() && s.repository.data.occupancy.lastState === DocumentRemoteState.Waiting);
      await s.service.retireOccupancy(false); documentServiceCheck(!s.repository.data.occupancy.retired);
      await s.service.retireOccupancy(true);
      documentServiceCheck(s.repository.data.occupancy.retired && s.service.state.message.indexOf('不表示云端删除') >= 0 && !s.service.canRetireOccupancy());
    } },
    { name: '停止跟踪仅限等待文件且提交门禁随停止跟踪解除', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = 'UPLOAD_UNKNOWN'; await s.service.submit('unit-original');
      await s.service.deleteOriginal('unit-original');
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Running]; await s.service.inspectOccupancy(true);
      documentServiceCheck(!s.service.canRetireOccupancy() && !s.repository.data.occupancy.retired);
      s.network.states = [DocumentRemoteState.Waiting]; await s.service.inspectOccupancy(true);
      documentServiceCheck(s.service.canRetireOccupancy());
      await s.service.retireOccupancy(true);
      const original: DocumentOriginal = documentUnitOriginal(); original.id = 'unit-original-2'; original.assetId = 'original-unit-2'; original.hash = 'c'.repeat(64);
      const grant: DocumentParseGrant = documentUnitGrant(original); grant.id = 'unit-grant-2';
      s.repository.data.originals.push(original); s.repository.data.grants.push(grant);
      documentServiceCheck(s.service.submitReason(original) === '');
    } }
  ];
  for (const failure of ['RESULT_LIMIT', 'RESULT_ID', 'RESULT_PARTIAL', 'RESULT_SCHEMA']) {
    tests.push({ name: '隔离包拒绝 ' + failure, run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = failure; s.network.states = [DocumentRemoteState.Done];
      await s.service.submit('unit-original'); documentServiceCheck(s.repository.data.results.length === 0 && s.repository.data.cleanup.length > 0 && s.repository.data.originals.length === 1);
    } });
  }
  for (const failure of ['429', 'AUTH', 'EXPIRED']) {
    tests.push({ name: '故障 ' + failure + ' 有界无自动重提', run: async (): Promise<void> => {
      const s: DocumentTestPipelineSession = new DocumentTestPipelineSession(); await s.ready(); s.network.mode = failure; await s.service.submit('unit-original');
      documentServiceCheck(s.network.allocations === 1 && s.network.uploads === 1 && s.network.queries === 1 && !s.repository.data.occupancy.terminalObserved);
      s.network.mode = 'NORMAL'; s.network.states = [DocumentRemoteState.Done]; await s.service.resume(s.repository.data.tasks[0].id, true);
      documentServiceCheck(s.network.allocations === 1 && s.network.uploads === 1 && s.repository.data.results.length === 1);
    } });
  } return tests;
}
