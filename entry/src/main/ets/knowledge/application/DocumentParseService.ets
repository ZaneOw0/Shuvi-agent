import {
  DocumentCredentialStatus, DocumentParseViewState, DocumentParseStateListener, DocumentParseFailure, documentValidateToken,
  DocumentParseCancellation, DocumentOriginal, DocumentFileSelection, DocumentParseGrant, DocumentTestAcknowledgement,
  DocumentParseAction, DocumentParseTask, DocumentParseStage, DocumentRemoteState, DocumentRemoteOccupancy,
  DocumentParseBudget, DocumentAllocationReceipt, DocumentInspection, DocumentParseResultEnvelope, DocumentParseCleanup, DocumentParseUsage, documentCopySnapshot, DocumentPreflightStatus
} from '../domain/DocumentParseModels';
import { MineruCredentialPort, DocumentParseRepositoryPort, DocumentSelectionPort, DocumentAssetPort, DocumentPreflightPort, MineruTaskPort, DocumentParseClockPort } from '../domain/DocumentParsePorts';
import { documentBudgetCheck, documentUsage, documentAcknowledged, documentSubmitReason, documentGrantMatches, documentRemoteTerminal, documentSafeId, documentHashValid } from '../pipeline/DocumentParsePolicy';

export class DocumentParseService {
  state: DocumentParseViewState = new DocumentParseViewState();
  private credential: MineruCredentialPort;
  private repository: DocumentParseRepositoryPort;
  private listeners: DocumentParseStateListener[] = [];
  private selection: DocumentSelectionPort | undefined = undefined;
  private assets: DocumentAssetPort | undefined = undefined;
  private preflight: DocumentPreflightPort | undefined = undefined;
  private localCancel: DocumentParseCancellation | undefined = undefined;
  private network: MineruTaskPort | undefined = undefined;
  private clock: DocumentParseClockPort | undefined = undefined;
  private activeAction: DocumentParseAction | undefined = undefined;
  private tombstoneCancel: DocumentParseCancellation | undefined = undefined;
  attachRemote(network: MineruTaskPort, clock: DocumentParseClockPort): void { this.network = network; this.clock = clock; }
  attachLocal(selection: DocumentSelectionPort, assets: DocumentAssetPort, preflight: DocumentPreflightPort): void {
    this.selection = selection; this.assets = assets; this.preflight = preflight;
  }
  constructor(credential: MineruCredentialPort, repository: DocumentParseRepositoryPort) {
    this.credential = credential; this.repository = repository;
  }
  subscribe(listener: DocumentParseStateListener): void { this.listeners.push(listener); }
  private emit(): void { this.state.inputEpoch++; for (const listener of this.listeners) { listener.changed(); } }
  capabilitySummary(): string { return '四格式仅原件准备与转发；服务产物结构/原生定位未验证，不索引，不提供完整PDF预览或高亮'; }
  async initialize(): Promise<void> {
    await this.repository.open(); this.state.snapshot = await this.repository.load();
    this.state.credential = await this.credential.status();
    for (const task of this.state.snapshot.tasks) {
      if (task.stage === DocumentParseStage.Allocation) { task.stage = DocumentParseStage.Uncertain; }
      else if (task.stage === DocumentParseStage.Uploading) { task.stage = DocumentParseStage.UploadUnknown; }
      else if (task.stage !== DocumentParseStage.Received && task.stage !== DocumentParseStage.RemoteFailed) { task.stage = DocumentParseStage.Paused; }
      task.epoch++;
    }
    await this.repository.save(this.state.snapshot); await this.retryCleanup();
    const keepLeases: string[] = [];
    for (const task of this.state.snapshot.tasks) { if (task.uploadLease.length > 0) { keepLeases.push(task.uploadLease); } if (task.resultLease.length > 0) { keepLeases.push(task.resultLease); } }
    try { await this.network?.reconcileLeases(keepLeases); }
    catch { this.state.message = '本轮租约对账失败；恢复需查询原批次，不明文降级'; }
    this.emit();
  }
  viewState(): DocumentParseViewState {
    const view: DocumentParseViewState = new DocumentParseViewState(); view.snapshot = documentCopySnapshot(this.state.snapshot);
    view.credential = this.state.credential; view.message = this.state.message; view.busy = this.state.busy; view.inputEpoch = this.state.inputEpoch; return view;
  }
  clearInput(): void { this.credential.clearTransient(); this.state.inputEpoch++; this.emit(); }
  async setEnabled(isOn: boolean): Promise<void> {
    if (!isOn) {
      this.pauseImmediate();
      if (this.localCancel !== undefined) { this.localCancel.invalid = true; }
      for (const grant of this.state.snapshot.grants) { grant.revoked = true; }
      this.clearInput();
    }
    this.state.snapshot.config.enabled = isOn;
    try { await this.repository.save(this.state.snapshot); this.state.message = isOn ? '仅启用门禁；仍须逐文件确认' : '解析关闭；远端任务可能继续'; }
    catch { this.state.snapshot.config.enabled = false; this.state.message = '配置持久化失败，后续外发阻止'; }
    this.emit();
  }
  submitReason(original: DocumentOriginal): string {
    const grant: DocumentParseGrant | undefined = this.state.snapshot.grants.find((g: DocumentParseGrant): boolean => g.originalId === original.id && !g.revoked);
    return documentSubmitReason(original, grant, this.state.snapshot, this.state.credential);
  }
  async prepare(): Promise<void> {
    if (this.state.busy || this.selection === undefined || this.assets === undefined || this.preflight === undefined) { return; }
    this.state.busy = true; const cancel: DocumentParseCancellation = new DocumentParseCancellation(); this.localCancel = cancel;
    try {
      const selected: DocumentFileSelection = await this.selection.select(); cancel.check();
      if (selected.canceled) { return; }
      let batchBytes: number = 0;
      for (const file of selected.files) {
        if (this.state.snapshot.cleanup.length > 0) { throw new DocumentParseFailure('有资产待清理，先完成安全清理', '准备'); }
        if (file.bytes < 1) { throw new DocumentParseFailure('无法在复制前核定本机原件大小', '准备'); }
        batchBytes += file.bytes;
      }
      for (const file of selected.files) {
        documentBudgetCheck(file.bytes, selected.files.length, batchBytes, documentUsage(this.state.snapshot));
        const id: string = this.clock === undefined ? `m2-${Date.now()}-${this.state.snapshot.originals.length}` : this.clock.id();
        const pending: DocumentParseCleanup = new DocumentParseCleanup(); pending.id = `cleanup-${id}-copy`;
        pending.assets = [`original-${id}`, `part-${id}`]; pending.originalBytes = file.bytes;
        this.state.snapshot.cleanup.push(pending); await this.repository.save(this.state.snapshot); cancel.check();
        const original: DocumentOriginal = await this.assets.save(file, id, cancel); cancel.check();
        if (this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.hash === original.hash)) {
          await this.retryCleanup(); this.state.message = '原字节摘要重复，已有副本保留'; continue;
        }
        this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== pending.id);
        this.state.snapshot.originals.push(original);
        try { await this.repository.save(this.state.snapshot); }
        catch { this.state.snapshot.originals = this.state.snapshot.originals.filter((o: DocumentOriginal): boolean => o.id !== original.id); await this.assets.remove([original.assetId]); throw new DocumentParseFailure('原件登记失败', '持久化'); }
        // Preserve original before PDFKit. Expired/blocked preflight cannot remove this durable copy.
        try { await this.preflight.inspect(original, cancel); }
        catch { original.preflight = DocumentPreflightStatus.Blocked; original.preflightReason = '页数预检中断，原件保留但不外发'; }
        await this.repository.save(this.state.snapshot);
        if (cancel.invalid || Date.now() >= cancel.deadline) { this.state.message = '原件保留；预检取消或时间耗尽，不外发'; break; }
        this.state.message = '原件已保存，未授权外发；预检状态不等于完整支持'; this.emit();
      }
    } catch (error) { this.state.message = error instanceof DocumentParseFailure ? error.message : '原件准备失败，已有资料保留'; await this.retryCleanup(); }
    finally { this.localCancel = undefined; this.state.busy = false; this.emit(); }
  }
  async confirm(originalId: string, acknowledgement: DocumentTestAcknowledgement): Promise<void> {
    if (this.state.busy) { return; }
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    if (original === undefined || !documentAcknowledged(acknowledgement) || this.state.credential !== DocumentCredentialStatus.Configured) { this.state.message = '各项确认未齐或安全凭据不可用；零外发'; this.emit(); return; }
    const grant: DocumentParseGrant = new DocumentParseGrant(); grant.id = `grant-${Date.now()}-${this.state.snapshot.grants.length}`;
    grant.originalId = original.id; grant.hash = original.hash; grant.version = original.version; grant.format = original.format;
    grant.credentialRevision = this.state.snapshot.config.credentialRevision; grant.issuedAt = Date.now(); grant.acknowledgement = acknowledgement;
    for (const prior of this.state.snapshot.grants) { if (prior.originalId === originalId) { prior.revoked = true; } }
    this.state.snapshot.grants.push(grant);
    try { await this.repository.save(this.state.snapshot); this.state.message = '仅确认本件非敏感免费测试；尚未发送'; }
    catch { grant.revoked = true; this.state.message = '确认记录保存失败，未授权外发'; }
    this.emit();
  }
  async saveToken(input: string, replace: boolean): Promise<void> {
    if (this.state.busy) { return; } this.state.busy = true;
    try {
      documentValidateToken(input);
      this.pauseImmediate();
      this.state.snapshot.config.enabled = false;
      for (const grant of this.state.snapshot.grants) { grant.revoked = true; }
      // Persist revocation before modifying Asset; a crash cannot reuse the old grant.
      this.state.snapshot.config.credentialRevision++;
      this.queueInvalidLeases();
      await this.repository.save(this.state.snapshot);
      await this.retryCleanup();
      this.state.credential = await this.credential.save(input, replace); this.state.message = '凭据已安全保存；未验证有效性或免费资格';
    } catch (error) {
      this.state.credential = await this.credential.status();
      this.state.message = error instanceof DocumentParseFailure ? error.message : '安全配置失败，未使用明文替代';
    } finally { input = ''; this.state.busy = false; this.clearInput(); }
  }
  async removeToken(): Promise<void> {
    if (this.state.busy) { return; } this.state.busy = true;
    try {
      this.pauseImmediate();
      this.state.snapshot.config.enabled = false;
      for (const grant of this.state.snapshot.grants) { grant.revoked = true; }
      this.state.snapshot.config.credentialRevision++; this.queueInvalidLeases(); await this.repository.save(this.state.snapshot); await this.retryCleanup();
      this.state.credential = await this.credential.remove(); this.state.message = '凭据已删除；远端任务与数据可能仍保留';
    } catch { this.state.credential = await this.credential.status(); this.state.message = '安全凭据删除失败，状态未冒称成功'; }
    finally { this.state.busy = false; this.clearInput(); }
  }
  private queueInvalidLeases(): void {
    for (const task of this.state.snapshot.tasks) {
      const c: DocumentParseCleanup = new DocumentParseCleanup(); c.id = `cleanup-${task.id}-leases-${this.state.snapshot.config.credentialRevision}`;
      if (task.uploadLease.length > 0) { c.leases.push(task.uploadLease); } if (task.resultLease.length > 0) { c.leases.push(task.resultLease); }
      if (c.leases.length > 0) { this.state.snapshot.cleanup.push(c); } task.uploadLease = ''; task.resultLease = '';
    }
  }
  private requireNetwork(): MineruTaskPort { if (this.network === undefined) { throw new DocumentParseFailure('传输能力不可用', '解析'); } return this.network; }
  private requireClock(): DocumentParseClockPort { if (this.clock === undefined) { throw new DocumentParseFailure('时间能力不可用', '解析'); } return this.clock; }
  private action(task: DocumentParseTask, original: DocumentOriginal, grant: DocumentParseGrant): DocumentParseAction {
    const action: DocumentParseAction = new DocumentParseAction(); action.task = task; action.original = original; action.grant = grant;
    action.cancel.deadline = Date.now() + DocumentParseBudget.pollMs; this.activeAction = action; return action;
  }
  private check(action: DocumentParseAction): void {
    action.cancel.check();
    if (!this.state.snapshot.config.enabled || this.state.credential !== DocumentCredentialStatus.Configured ||
      !this.state.snapshot.tasks.some((task: DocumentParseTask): boolean => task.id === action.task.id) ||
      !this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === action.original.id && o.hash === action.task.hash && o.version === action.task.version) ||
      !documentGrantMatches(action.original, action.grant, this.state.snapshot.config.credentialRevision)) {
      action.cancel.invalid = true; throw new DocumentParseFailure('任务/授权/凭据世代失效', '解析');
    }
  }
  private async checkpoint(action: DocumentParseAction, stage: DocumentParseStage): Promise<void> {
    this.check(action); action.task.stage = stage; action.task.checkpoint = stage;
    await this.repository.save(this.state.snapshot); this.check(action); this.emit();
  }
  async submit(originalId: string): Promise<void> {
    if (this.state.busy) { return; }
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    const grant: DocumentParseGrant | undefined = this.state.snapshot.grants.find((g: DocumentParseGrant): boolean => g.originalId === originalId && !g.revoked);
    if (original === undefined || grant === undefined || this.submitReason(original).length > 0 || this.network === undefined || this.clock === undefined) {
      this.state.message = original === undefined ? '原件不存在' : this.submitReason(original) || '未完成逐文件确认或能力不可用'; this.emit(); return;
    }
    if (this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.originalId === originalId)) { this.state.message = '已有任务，请查询该身份，不重复申请'; this.emit(); return; }
    this.state.busy = true;
    const task: DocumentParseTask = new DocumentParseTask(); task.id = this.requireClock().id(); task.dataId = task.id;
    task.originalId = original.id; task.hash = original.hash; task.version = original.version; task.grantId = grant.id;
    task.credentialRevision = grant.credentialRevision; task.windowStart = this.requireClock().now(); task.epoch = 1;
    this.state.snapshot.tasks.push(task); const action: DocumentParseAction = this.action(task, original, grant);
    this.state.snapshot.occupancy = new DocumentRemoteOccupancy(); this.state.snapshot.occupancy.taskId = task.id;
    this.state.snapshot.occupancy.dataId = task.dataId; this.state.snapshot.occupancy.credentialRevision = task.credentialRevision;
    let allocatedRequest: boolean = false;
    try {
      await this.assets?.verify(original, action.cancel); this.check(action);
      await this.checkpoint(action, DocumentParseStage.Allocation); allocatedRequest = true;
      action.onAllocation = async (batchId: string): Promise<void> => {
        this.check(action); if (!documentSafeId(batchId)) { throw new DocumentParseFailure('申请身份非法', '申请'); }
        task.batchId = batchId; this.state.snapshot.occupancy.batchId = batchId;
        await this.repository.save(this.state.snapshot); this.check(action);
      };
      const receipt: DocumentAllocationReceipt = await this.requireNetwork().allocate(action); this.check(action);
      if (!documentSafeId(receipt.batchId) || !receipt.leaseId.startsWith('lease-')) { throw new DocumentParseFailure('申请身份非法', '申请'); }
      task.batchId = receipt.batchId; task.uploadLease = receipt.leaseId; this.state.snapshot.occupancy.batchId = receipt.batchId;
      await this.checkpoint(action, DocumentParseStage.LeaseReady);
      task.uploadAttempted = true; await this.checkpoint(action, DocumentParseStage.Uploading);
      try { this.check(action); await this.requireNetwork().upload(action); this.check(action); }
      catch (error) {
        task.stage = DocumentParseStage.UploadUnknown;
        if (error instanceof DocumentParseFailure) { throw error; }
        throw new DocumentParseFailure('上传结果未知，原身份保留', '原件PUT');
      }
      task.uploaded = true; await this.checkpoint(action, DocumentParseStage.Waiting);
      await this.requireNetwork().removeLeases([task.uploadLease]); task.uploadLease = ''; await this.repository.save(this.state.snapshot);
      await this.poll(action);
    } catch (error) {
      if (!action.cancel.invalid && this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.id === task.id)) {
        if (allocatedRequest && task.batchId.length === 0) { task.stage = DocumentParseStage.Uncertain; }
        else if (!allocatedRequest) { this.state.snapshot.occupancy = new DocumentRemoteOccupancy(); task.stage = DocumentParseStage.Failed; }
        else if (task.stage !== DocumentParseStage.UploadUnknown && task.stage !== DocumentParseStage.Received) { task.stage = DocumentParseStage.Paused; }
        task.failure = error instanceof DocumentParseFailure ? error.message : '动作失败，远端状态未核实';
        try { await this.repository.save(this.state.snapshot); } catch { this.state.message = '检查点写入失败，远端占用保留，禁止新提交'; }
      }
    } finally { this.activeAction = undefined; this.state.busy = false; this.emit(); }
  }
  private async poll(action: DocumentParseAction): Promise<void> {
    const clock: DocumentParseClockPort = this.requireClock(); let delay: number = 5000;
    while (action.task.queries < 90 && clock.now() - action.task.windowStart < 900000) {
      this.check(action); await clock.sleep(delay); this.check(action);
      if (clock.now() - action.task.windowStart + DocumentParseBudget.requestMs > 900000) { break; }
      action.task.queries++; await this.repository.save(this.state.snapshot); this.check(action);
      const inspected: DocumentInspection = await this.requireNetwork().inspect(action); this.check(action);
      if (inspected.batchId !== action.task.batchId || inspected.dataId !== action.task.dataId || inspected.state === DocumentRemoteState.Unobserved) { throw new DocumentParseFailure('查询身份或状态不符', '查询'); }
      action.task.remote = inspected.state; action.task.extractedPages = inspected.extractedPages; action.task.totalPages = inspected.totalPages;
      const slot: DocumentRemoteOccupancy = this.state.snapshot.occupancy;
      if (slot.taskId === action.task.id) { slot.lastState = inspected.state; slot.terminalObserved = documentRemoteTerminal(inspected.state); }
      if (inspected.state === DocumentRemoteState.Failed) {
        await this.checkpoint(action, DocumentParseStage.RemoteFailed);
        await this.requireNetwork().removeLeases([action.task.uploadLease, action.task.resultLease]); action.task.uploadLease = ''; action.task.resultLease = '';
        await this.repository.save(this.state.snapshot); return;
      }
      if (inspected.state === DocumentRemoteState.Waiting && !action.task.uploadAttempted && action.task.uploadLease.length > 0) {
        await this.assets?.verify(action.original, action.cancel); this.check(action);
        action.task.uploadAttempted = true; await this.checkpoint(action, DocumentParseStage.Uploading);
        try { await this.requireNetwork().upload(action); this.check(action); }
        catch (error) {
          action.task.stage = DocumentParseStage.UploadUnknown;
          if (error instanceof DocumentParseFailure) { throw error; }
          throw new DocumentParseFailure('上传结果未知，原身份保留', '原件PUT');
        }
        action.task.uploaded = true; await this.checkpoint(action, DocumentParseStage.Waiting);
        await this.requireNetwork().removeLeases([action.task.uploadLease]); action.task.uploadLease = ''; await this.repository.save(this.state.snapshot);
      }
      if (inspected.state === DocumentRemoteState.Done) {
        await this.checkpoint(action, DocumentParseStage.Done);
        if (inspected.resultLease.length === 0) { throw new DocumentParseFailure('结果租约缺失', '接收'); }
        const previous: string = action.task.resultLease; action.task.resultLease = inspected.resultLease;
        await this.repository.save(this.state.snapshot); this.check(action); if (previous.length > 0 && previous !== inspected.resultLease) { await this.requireNetwork().removeLeases([previous]); }
        await this.checkpoint(action, DocumentParseStage.Downloading);
        if (this.state.snapshot.cleanup.length > 0) { throw new DocumentParseFailure('待清理资产仍占用空间，先重试清理', '接收'); }
        const pending: DocumentParseCleanup = new DocumentParseCleanup(); pending.id = `cleanup-${action.task.id}-result`;
        pending.assets = [`part-${action.task.id}`, `result-${action.task.id}`]; pending.resultBytes = DocumentParseBudget.resultBytes;
        this.state.snapshot.cleanup.push(pending); await this.repository.save(this.state.snapshot); this.check(action);
        // Own reservation is excluded from the receive call, but stays in the durable ledger until publication.
        const usage: DocumentParseUsage = documentUsage(this.state.snapshot); usage.resultBytes -= pending.resultBytes;
        const result: DocumentParseResultEnvelope = await this.requireNetwork().receive(action, usage);
        try { this.check(action); } catch { await this.retryCleanup(); throw new DocumentParseFailure('晚到包未发布', '接收'); }
        if (result.taskId !== action.task.id || result.dataId !== action.task.dataId || result.originalHash !== action.task.hash || result.version !== action.task.version ||
          result.bytes < 22 || result.bytes > DocumentParseBudget.resultBytes || !documentHashValid(result.hash) || !result.signature || !result.completeTransport || result.status !== 'UNVALIDATED') { throw new DocumentParseFailure('结果关联或传输校验失败', '接收'); }
        this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== pending.id);
        this.state.snapshot.results.push(result);
        try { await this.checkpoint(action, DocumentParseStage.Received); }
        catch (error) {
          this.state.snapshot.results = this.state.snapshot.results.filter((r: DocumentParseResultEnvelope): boolean => r.assetId !== result.assetId);
          this.state.snapshot.cleanup.push(pending); action.task.stage = DocumentParseStage.Paused;
          if (error instanceof DocumentParseFailure) { throw error; } throw new DocumentParseFailure('结果登记失败，未发布', '持久化');
        }
        await this.requireNetwork().removeLeases([action.task.resultLease, action.task.uploadLease]); action.task.resultLease = ''; action.task.uploadLease = '';
        await this.repository.save(this.state.snapshot); this.state.message = '结果已接收，待结构校验；不能检索或预览高亮'; return;
      }
      const stage: DocumentParseStage = inspected.state === DocumentRemoteState.Waiting ? DocumentParseStage.Waiting : inspected.state === DocumentRemoteState.Pending ? DocumentParseStage.Pending : inspected.state === DocumentRemoteState.Converting ? DocumentParseStage.Converting : DocumentParseStage.Running;
      await this.checkpoint(action, stage); delay = Math.min(30000, delay + 5000);
    }
    await this.checkpoint(action, DocumentParseStage.Paused); this.state.message = '前台等待窗口耗尽，云任务可能继续；可手动查询现有批次';
  }
  pauseImmediate(): void {
    this.assets?.cancelLocal(); this.preflight?.cancelLocal();
    if (this.localCancel !== undefined) { this.localCancel.invalid = true; }
    if (this.activeAction !== undefined) {
      this.activeAction.cancel.invalid = true; this.activeAction.task.epoch++;
      this.activeAction.task.stage = this.activeAction.task.batchId.length === 0 ? DocumentParseStage.Uncertain : this.activeAction.task.stage === DocumentParseStage.Uploading ? DocumentParseStage.UploadUnknown : DocumentParseStage.Paused;
    }
    if (this.tombstoneCancel !== undefined) { this.tombstoneCancel.invalid = true; }
    this.network?.pause(); this.clearInput();
  }
  async pause(): Promise<void> {
    this.pauseImmediate(); try { await this.repository.save(this.state.snapshot); this.state.message = '已停本机动作，远端可能继续；未释放未知占用'; }
    catch { this.state.message = '暂停检查点保存失败，远端占用仍保留'; } this.emit();
  }
  async close(): Promise<void> { await this.pause(); await this.repository.close(); this.listeners = []; }
  private pauseFailedResume(task: DocumentParseTask): void {
    if (task.stage !== DocumentParseStage.UploadUnknown && task.stage !== DocumentParseStage.Received) { task.stage = DocumentParseStage.Paused; }
  }
  async resume(taskId: string, sameAccountConfirmed: boolean): Promise<void> {
    if (this.state.busy || !sameAccountConfirmed || !this.state.snapshot.config.enabled || this.state.credential !== DocumentCredentialStatus.Configured) {
      this.state.message = '须启用解析并确认同账号继续先前同一测试任务；不会自动重提'; this.emit(); return;
    }
    const task: DocumentParseTask | undefined = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === taskId);
    if (task === undefined || task.stage === DocumentParseStage.Received || task.stage === DocumentParseStage.RemoteFailed) { return; }
    if (task.batchId.length === 0) { this.state.message = '申请身份未知，停止待人工核对；不重新申请'; this.emit(); return; }
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === task.originalId);
    const grant: DocumentParseGrant | undefined = this.state.snapshot.grants.find((g: DocumentParseGrant): boolean => g.originalId === task.originalId && !g.revoked);
    if (original === undefined || grant === undefined || !documentGrantMatches(original, grant, this.state.snapshot.config.credentialRevision) || task.credentialRevision !== this.state.snapshot.config.credentialRevision) {
      this.state.message = '原件/授权/凭据版本已变；仅允许单独确认复核旧远端占用，不假同账号'; this.emit(); return;
    }
    this.state.busy = true; task.grantId = grant.id; task.epoch++; task.queries = 0; task.windowStart = this.requireClock().now(); task.failure = '';
    const action: DocumentParseAction = this.action(task, original, grant);
    try { await this.repository.save(this.state.snapshot); this.check(action); await this.retryCleanup(); this.check(action); await this.poll(action); }
    catch (error) {
      if (!action.cancel.invalid) {
        this.pauseFailedResume(task);
        task.failure = error instanceof DocumentParseFailure ? error.message : '恢复失败，原身份保留';
        try { await this.repository.save(this.state.snapshot); } catch { this.state.message = '恢复检查点保存失败'; }
      }
    } finally { this.activeAction = undefined; this.state.busy = false; this.emit(); }
  }
  async deleteOriginal(originalId: string): Promise<void> {
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    if (original === undefined) { return; } this.pauseImmediate();
    const cleanup: DocumentParseCleanup = new DocumentParseCleanup(); cleanup.id = `cleanup-${original.id}-${Date.now()}`;
    cleanup.assets = [original.assetId]; cleanup.originalBytes = original.bytes;
    const tasks: DocumentParseTask[] = this.state.snapshot.tasks.filter((t: DocumentParseTask): boolean => t.originalId === originalId);
    for (const task of tasks) { cleanup.assets.push(`part-${task.id}`); if (task.uploadLease.length > 0) { cleanup.leases.push(task.uploadLease); } if (task.resultLease.length > 0) { cleanup.leases.push(task.resultLease); } }
    const results: DocumentParseResultEnvelope[] = this.state.snapshot.results.filter((r: DocumentParseResultEnvelope): boolean => tasks.some((t: DocumentParseTask): boolean => t.id === r.taskId));
    for (const result of results) { cleanup.assets.push(result.assetId); cleanup.resultBytes += result.bytes; }
    const oldOriginals: DocumentOriginal[] = this.state.snapshot.originals; const oldTasks: DocumentParseTask[] = this.state.snapshot.tasks;
    const oldGrants: DocumentParseGrant[] = this.state.snapshot.grants; const oldResults: DocumentParseResultEnvelope[] = this.state.snapshot.results;
    this.state.snapshot.originals = oldOriginals.filter((o: DocumentOriginal): boolean => o.id !== originalId);
    this.state.snapshot.tasks = oldTasks.filter((t: DocumentParseTask): boolean => t.originalId !== originalId);
    this.state.snapshot.grants = oldGrants.filter((g: DocumentParseGrant): boolean => g.originalId !== originalId);
    this.state.snapshot.results = oldResults.filter((r: DocumentParseResultEnvelope): boolean => results.indexOf(r) < 0);
    this.state.snapshot.cleanup.push(cleanup);
    try {
      await this.repository.save(this.state.snapshot);
    } catch {
      this.state.snapshot.originals = oldOriginals; this.state.snapshot.tasks = oldTasks; this.state.snapshot.grants = oldGrants; this.state.snapshot.results = oldResults;
      this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== cleanup.id);
      this.state.message = '本机逻辑删除失败，副本保留；本机动作已停止'; this.emit(); return;
    }
    await this.retryCleanup(); this.state.message = '仅删除本机解析副本；远端数据可能保留，未决占用不解除'; this.emit();
  }
  async retryCleanup(): Promise<void> {
    if (this.assets === undefined) { return; }
    for (const cleanup of this.state.snapshot.cleanup.slice()) {
      try {
        await this.assets.remove(cleanup.assets); await this.network?.removeLeases(cleanup.leases);
        this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== cleanup.id);
        await this.repository.save(this.state.snapshot);
      } catch { cleanup.failure = '本轮资产清理未完成，仍计磁盘占用';
        if (this.state.snapshot.cleanup.indexOf(cleanup) < 0) { this.state.snapshot.cleanup.push(cleanup); }
        try { await this.repository.save(this.state.snapshot); } catch { this.state.message = '清理记录持久化失败，禁止新增处理'; }
      }
    }
    this.emit();
  }
  async inspectOccupancy(confirmed: boolean): Promise<void> {
    if (this.state.busy || !confirmed || !this.state.snapshot.config.enabled || this.state.credential !== DocumentCredentialStatus.Configured) { this.state.message = '复核须确认同账号继续查询先前测试任务；未向云端发送文件'; this.emit(); return; }
    const slot: DocumentRemoteOccupancy = this.state.snapshot.occupancy;
    if (slot.terminalObserved || slot.taskId.length === 0) { return; }
    if (slot.batchId.length === 0) { this.state.message = '远端身份未知，不能查询或无证据解除占用'; this.emit(); return; }
    this.state.busy = true; const action: DocumentParseAction = new DocumentParseAction();
    action.task.id = slot.taskId; action.task.dataId = slot.dataId; action.task.batchId = slot.batchId; action.task.credentialRevision = slot.credentialRevision;
    action.cancel.deadline = Date.now() + 120000; this.tombstoneCancel = action.cancel;
    try {
      const inspected: DocumentInspection = await this.requireNetwork().inspect(action); action.cancel.check();
      if (inspected.batchId !== slot.batchId || inspected.dataId !== slot.dataId) { throw new DocumentParseFailure('占用复核身份不符', '查询'); }
      slot.lastState = inspected.state; slot.terminalObserved = documentRemoteTerminal(inspected.state);
      await this.repository.save(this.state.snapshot); await this.requireNetwork().removeLeases([inspected.resultLease]);
      this.state.message = slot.terminalObserved ? '已观察原任务终态；不表示云端数据删除' : '原任务仍未终态，占用保留';
    } catch (error) { this.state.message = error instanceof DocumentParseFailure ? error.message : '原任务无法复核，占用仍保留'; }
    finally { this.tombstoneCancel = undefined; this.state.busy = false; this.emit(); }
  }
}
