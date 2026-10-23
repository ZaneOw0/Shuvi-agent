import { KnowledgeSourceProtectionPort } from '../domain/KnowledgePorts';
import {
  DocumentCredentialStatus, DocumentParseViewState, DocumentParseStateListener, DocumentParseFailure, documentValidateToken,
  DocumentParseCancellation, DocumentOriginal, DocumentFileSelection, DocumentParseGrant, DocumentTestAcknowledgement,
  DocumentParseAction, DocumentParseTask, DocumentParseStage, DocumentRemoteState, DocumentRemoteOccupancy,
   DocumentParseBudget, DocumentAllocationReceipt, DocumentInspection, DocumentParseResultEnvelope, DocumentParseCleanup, DocumentParseUsage, documentCopySnapshot, DocumentPreflightStatus, DocumentParseFormat, DocumentImageEvidence, DocumentSelectedFile, ImageParsePermit, documentCopyFailure, ParseFailureKind, DocxParsePermit
} from '../domain/DocumentParseModels';
import { MineruCredentialPort, DocumentParseRepositoryPort, DocumentSelectionPort, DocumentAssetPort, DocumentPreflightPort, MineruTaskPort, DocumentParseClockPort, DocumentImageResultSourcePort } from '../domain/DocumentParsePorts';
import { documentBudgetCheck, documentUsage, documentAcknowledged, documentSubmitReason, documentGrantMatches, documentRemoteTerminal, documentSafeId, documentHashValid, documentIsImage, documentSuffix, imagePermitInputId, imagePermitPolicy } from '../pipeline/DocumentParsePolicy';
import { parseFailureSummary, parseDetailedFailure, parseSanitizedReason } from '../pipeline/ParseFailurePolicy';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';

export class DocumentParseService implements DocumentImageResultSourcePort {
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
  private retireArmed: boolean = false;
  private sourceProtection: KnowledgeSourceProtectionPort | undefined = undefined;
  private capacity: ((bytes: number) => Promise<void>) | undefined = undefined;
  private scope: KnowledgeStorageScope;
  attachLocalCapacity(check: (bytes: number) => Promise<void>): void { this.capacity = check; }
  attachSourceProtection(protection: KnowledgeSourceProtectionPort): void { this.sourceProtection = protection; }
  async withReceivedResult<T>(resultId: string, action: (original: DocumentOriginal, result: DocumentParseResultEnvelope, task: DocumentParseTask) => Promise<T>): Promise<T> {
    const protection: KnowledgeSourceProtectionPort | undefined = this.sourceProtection;
    if (protection === undefined) { throw new DocumentParseFailure('原件保护不可用','统一本机消费'); }
    const result: DocumentParseResultEnvelope | undefined = this.state.snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.assetId === resultId);
    const task: DocumentParseTask | undefined = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === result?.taskId);
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === task?.originalId);
    if (original === undefined || result === undefined || task === undefined) { throw new DocumentParseFailure('已收来源不存在','统一本机消费'); }
    return protection.withSource<T>(original.id,async (): Promise<T> => {
      if (this.state.busy || !this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === original.id && o.hash === original.hash && o.version === original.version) ||
        !result.completeTransport || !result.signature || result.originalHash !== original.hash || result.version !== original.version || task.hash !== original.hash || task.version !== original.version || result.dataId !== task.dataId ||
        this.state.snapshot.cleanup.some((c: DocumentParseCleanup): boolean => c.assets.indexOf(original.assetId) >= 0 || c.assets.indexOf(result.assetId) >= 0)) { throw new DocumentParseFailure('来源变化或待清理','统一本机消费'); }
      return action(original,result,task);
    });
  }
  async withImageOriginal<T>(originalId: string, action: () => Promise<T>): Promise<T> {
    const protection = this.sourceProtection;
    if (protection === undefined) { throw new DocumentParseFailure('原件保护不可用','图片本机核验'); }
    return protection.withSource<T>(originalId,async (): Promise<T> => {
      if (!this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === originalId && documentIsImage(o.format))) { throw new DocumentParseFailure('图片原件已变化','图片本机核验'); }
      return action();
    });
  }
  async withDocxOriginal<T>(originalId: string, action: () => Promise<T>): Promise<T> {
    const protection: KnowledgeSourceProtectionPort | undefined = this.sourceProtection;
    if (protection === undefined) { throw new DocumentParseFailure('原件保护不可用','DOCX本机动作'); }
    return protection.withSource<T>(originalId,async (): Promise<T> => {
      if (!this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === originalId && o.format === DocumentParseFormat.Docx)) { throw new DocumentParseFailure('DOCX原件已变化','DOCX本机动作'); }
      return action();
    });
  }
  attachRemote(network: MineruTaskPort, clock: DocumentParseClockPort): void { this.network = network; this.clock = clock; }
  attachLocal(selection: DocumentSelectionPort, assets: DocumentAssetPort, preflight: DocumentPreflightPort): void {
    this.selection = selection; this.assets = assets; this.preflight = preflight;
  }
  constructor(credential: MineruCredentialPort, repository: DocumentParseRepositoryPort, scope: KnowledgeStorageScope = KnowledgeStorageScope.production()) {
    this.credential = credential; this.repository = repository; this.scope = scope;
  }
  async acceptDiagnosticFailure(owner: string, originalId: string, failure: DocumentParseFailure): Promise<void> {
    this.scope.requireTestOwner(owner);
    const original = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    if (this.state.busy || original === undefined || !documentIsImage(original.format)) { throw new DocumentParseFailure('隔离图片原件未准备','diagnostic'); }
    const grant: DocumentParseGrant = new DocumentParseGrant(); grant.id = 'diagnostic-grant-'+Date.now(); grant.originalId = originalId; grant.hash = original.hash; grant.version = original.version; grant.format = original.format; grant.revoked = true;
    const task: DocumentParseTask = new DocumentParseTask(); task.id = 'diagnostic-task-'+Date.now(); task.originalId = originalId; task.dataId = task.id; task.grantId = grant.id; task.hash = original.hash; task.version = original.version; task.stage = DocumentParseStage.Paused;
    task.failureDetail = documentCopyFailure(failure.detail); task.failureStage = failure.detail.stage; task.failureCode = failure.serviceCode; task.failure = parseFailureSummary(task.failureDetail); task.lastAction = '隔离合成错误；真实请求0';
    this.state.snapshot.grants.push(grant); this.state.snapshot.tasks.push(task); await this.repository.save(this.state.snapshot); this.state.message = task.failure; this.emit();
  }
  subscribe(listener: DocumentParseStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: DocumentParseStateListener): void { this.listeners = this.listeners.filter((item: DocumentParseStateListener): boolean => item !== listener); }
  async recordImageEvidence(evidence: DocumentImageEvidence): Promise<void> {
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === evidence.originalId);
    if (this.state.busy || original === undefined || original.assetId !== evidence.assetId || original.hash !== evidence.hash || original.version !== evidence.version ||
      !documentIsImage(original.format) || !evidence.staticContainer || evidence.frames > 1 || evidence.width < 1 || evidence.height < 1 || evidence.width*evidence.height > 20000000 || evidence.orientation < 0 || evidence.orientation > 8 || ['image/jpeg','image/png','image/webp'].indexOf(evidence.mime) < 0) { throw new DocumentParseFailure('图片原件证据不当前','图片登记'); }
    const prior: DocumentImageEvidence[] = this.state.snapshot.imageEvidence;
    this.state.snapshot.imageEvidence = prior.filter((item: DocumentImageEvidence): boolean => item.originalId !== evidence.originalId).concat([evidence]);
    const previousFormat: DocumentParseFormat = original.format; const previousPreflight: DocumentPreflightStatus = original.preflight; const previousReason: string = original.preflightReason;
    original.format = evidence.mime === 'image/jpeg' ? DocumentParseFormat.Jpeg : evidence.mime === 'image/png' ? DocumentParseFormat.Png : DocumentParseFormat.Webp;
    original.preflight = DocumentPreflightStatus.Passed; original.preflightReason = '基本编码/尺寸合格；预览与方向可未知';
    try { await this.repository.save(this.state.snapshot); } catch { this.state.snapshot.imageEvidence = prior; original.format = previousFormat; original.preflight = previousPreflight; original.preflightReason = previousReason; throw new DocumentParseFailure('图片证据保存失败','图片登记'); } this.emit();
  }
  async assignImageVersion(originalId: string, version: number): Promise<DocumentOriginal> {
    const original = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    if (this.state.busy || original === undefined || !documentIsImage(original.format) || !Number.isSafeInteger(version) || version < 1 || this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.originalId === originalId) || this.state.snapshot.imageEvidence.some((e: DocumentImageEvidence): boolean => e.originalId === originalId)) { throw new DocumentParseFailure('图片版本登记状态非法','图片换版'); }
    const previous: number = original.version; original.version = version;
    try { await this.repository.save(this.state.snapshot); } catch { original.version = previous; throw new DocumentParseFailure('图片版本登记失败','图片换版'); } this.emit(); return original;
  }
  async assignDocxVersion(originalId: string, version: number): Promise<DocumentOriginal> {
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    if (this.state.busy || original === undefined || original.format !== DocumentParseFormat.Docx || !Number.isSafeInteger(version) || version < 1 || this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.originalId === originalId) || this.state.snapshot.docxPermits.some((p: DocxParsePermit): boolean => p.originalId === originalId)) { throw new DocumentParseFailure('DOCX版本登记不当前','换版'); }
    const prior: number = original.version; original.version = version; try { await this.repository.save(this.state.snapshot); } catch { original.version = prior; throw new DocumentParseFailure('DOCX版本保存失败','换版'); } return original;
  }
  private emit(): void { this.state.inputEpoch++; for (const listener of this.listeners) { listener.changed(); } }
  capabilitySummary(): string { return '四格式仅原件准备与转发；服务产物结构/原生定位未验证，不索引，不提供完整PDF预览或高亮'; }
  async initialize(): Promise<void> {
    await this.repository.open(); this.state.snapshot = await this.repository.load();
    this.state.credential = await this.credential.status();
    for (const grant of this.state.snapshot.grants) { if (grant.format===DocumentParseFormat.Docx && !this.state.snapshot.tasks.some((t: DocumentParseTask): boolean=>t.grantId===grant.id && t.originalId===grant.originalId)) { grant.revoked=true; } }
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
    view.credential = this.state.credential; view.message = this.state.message; view.busy = this.state.busy; view.inputEpoch = this.state.inputEpoch; view.resultDirectory = this.state.resultDirectory; return view;
  }
  clearInput(): void { this.emit(); }
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
  async prepare(imagesOnly: boolean = false, docxOnly: boolean = false): Promise<void> {
    if (this.state.busy || this.selection === undefined || this.assets === undefined || this.preflight === undefined) { return; }
    this.state.busy = true; const cancel: DocumentParseCancellation = new DocumentParseCancellation(); this.localCancel = cancel;
    try {
      const selected: DocumentFileSelection = docxOnly && this.selection.selectDocx !== undefined ? await this.selection.selectDocx() : imagesOnly && this.selection.selectImages !== undefined ? await this.selection.selectImages() : await this.selection.select(); cancel.check();
      if (docxOnly && selected.files.some((file: DocumentSelectedFile): boolean => documentSuffix(file.title) !== DocumentParseFormat.Docx)) { throw new DocumentParseFailure('DOCX入口只接受.docx','选择'); }
      if (imagesOnly && selected.files.some((file: DocumentSelectedFile): boolean => !documentIsImage(documentSuffix(file.title)))) { throw new DocumentParseFailure('图片入口不接受其他格式','选择'); }
      if (selected.canceled) { return; }
      let batchBytes: number = 0;
      for (const file of selected.files) {
        if (this.state.snapshot.cleanup.length > 0) { throw new DocumentParseFailure('有资产待清理，先完成安全清理', '准备'); }
        if (file.bytes < 1) { throw new DocumentParseFailure('无法在复制前核定本机原件大小', '准备'); }
        batchBytes += file.bytes;
      }
      for (const file of selected.files) {
        documentBudgetCheck(file.bytes, selected.files.length, batchBytes, documentUsage(this.state.snapshot));
        const localCapacity: ((bytes: number) => Promise<void>) | undefined = this.capacity;
        if (localCapacity !== undefined) { await localCapacity(file.bytes); cancel.check(); }
        const id: string = this.clock === undefined ? `m2-${Date.now()}-${this.state.snapshot.originals.length}` : this.clock.id();
        const pending: DocumentParseCleanup = new DocumentParseCleanup(); pending.id = `cleanup-${id}-copy`;
        pending.assets = [`original-${id}`, `part-${id}`]; pending.originalBytes = file.bytes;
        this.state.snapshot.cleanup.push(pending); await this.repository.save(this.state.snapshot); cancel.check();
        const original: DocumentOriginal = await this.assets.save(file, id, cancel); cancel.check();
        if (!documentIsImage(original.format) && this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.hash === original.hash)) {
          await this.retryCleanup(); this.state.message = '原字节摘要重复，已有副本保留'; continue;
        }
        this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== pending.id);
        this.state.snapshot.originals.push(original);
        try { await this.repository.save(this.state.snapshot); }
        catch {
          this.state.snapshot.originals = this.state.snapshot.originals.filter((o: DocumentOriginal): boolean => o.id !== original.id);
          const protection: KnowledgeSourceProtectionPort | undefined = this.sourceProtection;
          if (protection !== undefined) { await protection.withSource<void>(original.id,async (): Promise<void> => { await protection.assertCleanup([original.assetId]); await this.assets?.remove([original.assetId]); }); }
          throw new DocumentParseFailure('原件登记失败，清理由持久意图继续保护', '持久化');
        }
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
  async confirmImage(originalId: string, fullFile: boolean, free: boolean): Promise<void> {
    if (this.state.busy) { return; }
    const o = this.state.snapshot.originals.find((row: DocumentOriginal): boolean => row.id === originalId);
    if (o === undefined || !documentIsImage(o.format) || !fullFile || !free || o.preflight !== DocumentPreflightStatus.Passed || this.state.credential !== DocumentCredentialStatus.Configured) { throw new DocumentParseFailure('当前图片/完整外发/免费或安全凭据未确认','图片许可'); }
    const input: string = imagePermitInputId(o);
    const prior = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.testInputId === input);
    if (prior !== undefined && (prior.originalId !== o.id || prior.hash !== o.hash || prior.version !== o.version)) { throw new DocumentParseFailure('本图许可已绑定原身份，不新建任务','图片许可'); }
    if (prior !== undefined && prior.taskId.length > 0 && !this.state.snapshot.tasks.some((task: DocumentParseTask): boolean => task.id === prior.taskId && task.credentialRevision === this.state.snapshot.config.credentialRevision)) { throw new DocumentParseFailure('原任务凭据或本机身份已变，仅可核对占用','图片许可'); }
    const p: ImageParsePermit = prior ?? new ImageParsePermit(); p.originalId = o.id; p.hash = o.hash; p.version = o.version; p.actualFormat = o.format; p.testInputId = input; p.fullFile = fullFile; p.freeEligible = free;
    const g: DocumentParseGrant = new DocumentParseGrant(); g.id = 'image-grant-'+this.requireClock().id(); g.originalId = o.id; g.hash = o.hash; g.version = o.version; g.format = o.format; g.credentialRevision = this.state.snapshot.config.credentialRevision;
    g.policy = imagePermitPolicy(p); g.parameters = ImageParsePermit.parameters; g.acknowledgement.fullFile = fullFile; g.acknowledgement.freeEligible = free; g.issuedAt = Date.now();
    for (const grant of this.state.snapshot.grants) { if (grant.originalId === o.id) { grant.revoked = true; } }
    if (prior === undefined) { this.state.snapshot.imagePermits.push(p); } this.state.snapshot.grants.push(g);
    try { await this.repository.save(this.state.snapshot); } catch { g.revoked = true; throw new DocumentParseFailure('本轮许可未保存','图片许可'); } this.emit();
  }
  async confirmDocx(originalId: string, fullFile: boolean, free: boolean): Promise<void> {
    if (this.state.busy) { throw new DocumentParseFailure('动作进行中','DOCX许可'); }
    const o: DocumentOriginal | undefined = this.state.snapshot.originals.find((row: DocumentOriginal): boolean => row.id === originalId);
    if (o === undefined || o.format !== DocumentParseFormat.Docx || o.preflight !== DocumentPreflightStatus.Passed || !fullFile || !free || this.state.credential !== DocumentCredentialStatus.Configured) { throw new DocumentParseFailure('当前DOCX/完整原件/免费或安全凭据未确认','DOCX许可'); }
    const prior: DocxParsePermit | undefined = this.state.snapshot.docxPermits.find((p: DocxParsePermit): boolean => p.originalId === originalId);
    if (prior !== undefined && (prior.hash !== o.hash || prior.version !== o.version || prior.actualFormat !== o.format || prior.credentialRevision !== this.state.snapshot.config.credentialRevision && (prior.taskId.length > 0 || prior.usage.allocation > 0))) { throw new DocumentParseFailure('原DOCX任务身份或凭据已变，只可核对原任务','DOCX许可'); }
    const p: DocxParsePermit = prior ?? new DocxParsePermit(); p.originalId = o.id; p.hash = o.hash; p.version = o.version; p.actualFormat = o.format; p.credentialRevision = this.state.snapshot.config.credentialRevision; p.fullFile = fullFile; p.freeEligible = free;
    const g: DocumentParseGrant = new DocumentParseGrant(); g.id = 'docx-grant-'+this.requireClock().id(); g.originalId = o.id; g.hash = o.hash; g.version = o.version; g.format = o.format; g.credentialRevision = p.credentialRevision; g.policy = DocxParsePermit.policy; g.parameters = DocxParsePermit.parameters; g.issuedAt = Date.now(); g.acknowledgement.fullFile = fullFile; g.acknowledgement.freeEligible = free;
    for (const grant of this.state.snapshot.grants) { if (grant.originalId === originalId) { grant.revoked = true; } }
    if (prior === undefined) { this.state.snapshot.docxPermits.push(p); } this.state.snapshot.grants.push(g);
    try { await this.repository.save(this.state.snapshot); } catch { g.revoked = true; throw new DocumentParseFailure('DOCX许可持久化失败','DOCX许可'); } this.emit();
  }
  private async consumeDocx(action: DocumentParseAction, purpose: string, recovery: boolean=false): Promise<void> {
    if (action.original.format !== DocumentParseFormat.Docx) { return; }
    const p: DocxParsePermit | undefined = this.state.snapshot.docxPermits.find((permit: DocxParsePermit): boolean => permit.originalId === action.original.id);
    if (p === undefined || p.hash !== action.original.hash || p.version !== action.original.version || p.actualFormat !== DocumentParseFormat.Docx || p.credentialRevision !== action.task.credentialRevision || p.parameters !== action.grant.parameters || !p.fullFile || !p.freeEligible || p.stoppedReason.length > 0 || !documentGrantMatches(action.original,action.grant,this.state.snapshot.config.credentialRevision) || p.taskId.length > 0 && p.taskId !== action.task.id) { throw new DocumentParseFailure('DOCX许可或原任务不当前','请求计数'); }
    if (purpose === 'POST') { if (p.usage.allocation >= 1) { throw new DocumentParseFailure('DOCX已申请，禁止重建','请求计数'); } p.usage.allocation++; p.taskId = action.task.id; }
    else if (purpose === 'PUT') { if (p.usage.put >= 2 || p.usage.put>=1 && !recovery) { throw new DocumentParseFailure('DOCX补传需明确恢复且最多一次','请求计数'); } p.usage.put++; }
    else if (purpose === 'QUERY') { if (p.usage.query >= 90) { throw new DocumentParseFailure('DOCX累计查询已达90次','请求计数'); } p.usage.query++; }
    else if (purpose === 'ZIP') { if (p.usage.download >= (recovery?3:1)) { throw new DocumentParseFailure('DOCX结果包重取需明确恢复，最多三次接收尝试','请求计数'); } p.usage.download++; }
    else { throw new DocumentParseFailure('请求用途未知','请求计数'); }
    action.task.usage = p.usage; await this.repository.save(this.state.snapshot); this.check(action);
  }
  private async consumeImage(action: DocumentParseAction, purpose: string, recovery: boolean=false): Promise<void> {
    await this.consumeDocx(action,purpose,recovery);
    if (!documentIsImage(action.original.format)) { return; }
    const p = this.state.snapshot.imagePermits.find((permit: ImageParsePermit): boolean => permit.originalId === action.original.id && permit.hash === action.original.hash && permit.version === action.original.version && permit.fullFile && permit.freeEligible);
    if (p === undefined || p.actualFormat !== action.original.format || p.testInputId !== imagePermitInputId(action.original) || action.grant.policy !== imagePermitPolicy(p) || !documentGrantMatches(action.original,action.grant,this.state.snapshot.config.credentialRevision) || p.taskId.length > 0 && p.taskId !== action.task.id) { throw new DocumentParseFailure('图片许可身份不符','请求计数'); }
    if (purpose === 'POST') { if (p.usage.allocation >= 1) { throw new DocumentParseFailure('本件申请额度已消费','请求计数'); } p.usage.allocation++; p.taskId = action.task.id; }
    else if (purpose === 'PUT') { if (p.usage.put >= (imagePermitPolicy(p)===ImageParsePermit.productionPolicy?2:1) || p.usage.put>=1 && !recovery) { throw new DocumentParseFailure('图片补传需明确恢复且最多一次','请求计数'); } p.usage.put++; }
    else if (purpose === 'QUERY') { if (p.usage.query >= 90) { throw new DocumentParseFailure('本件累计查询90次已用完','请求计数'); } p.usage.query++; }
    else if (purpose === 'ZIP') { if (p.usage.download >= (recovery && imagePermitPolicy(p)===ImageParsePermit.productionPolicy?3:1)) { throw new DocumentParseFailure('图片结果包重取需明确恢复，最多三次接收尝试','请求计数'); } p.usage.download++; }
    action.task.usage = p.usage; await this.repository.save(this.state.snapshot); this.check(action);
  }
  async saveToken(input: string, replace: boolean): Promise<void> {
    if (this.state.busy) { input = ''; this.state.message = '当前有动作进行中，本次保存未执行'; this.emit(); return; }
    this.state.busy = true; this.state.message = '正在保存安全凭据…'; this.emit();
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
      const saved: DocumentCredentialStatus = await this.credential.save(input, replace);
      if (saved !== DocumentCredentialStatus.Configured) { throw new DocumentParseFailure('安全存储状态未确认，未显示保存成功', '保存后属性确认'); }
      this.state.credential = saved; this.state.message = '凭据已安全保存；未验证有效性或免费资格';
    } catch (error) {
      this.state.message = error instanceof DocumentParseFailure ? error.message : '安全配置失败，未使用明文替代';
      await this.refreshCredentialAfterFailure();
    } finally { input = ''; this.state.busy = false; this.clearInput(); }
  }
  private async refreshCredentialAfterFailure(): Promise<void> {
    try { this.state.credential = await this.credential.status(); }
    catch { this.state.credential = DocumentCredentialStatus.Unavailable; this.state.message += '；配置状态刷新失败'; }
  }
  async removeToken(): Promise<void> {
    if (this.state.busy) { this.state.message = '当前有动作进行中，本次删除未执行'; this.emit(); return; }
    this.state.busy = true; this.state.message = '正在删除安全凭据…'; this.emit();
    try {
      this.pauseImmediate();
      this.state.snapshot.config.enabled = false;
      for (const grant of this.state.snapshot.grants) { grant.revoked = true; }
      this.state.snapshot.config.credentialRevision++; this.queueInvalidLeases(); await this.repository.save(this.state.snapshot); await this.retryCleanup();
      const removed: DocumentCredentialStatus = await this.credential.remove();
      if (removed !== DocumentCredentialStatus.Missing) { throw new DocumentParseFailure('凭据删除未确认', '删除后属性确认'); }
      this.state.credential = removed; this.state.message = '凭据已删除；远端任务与数据可能仍保留';
    } catch (error) {
      this.state.message = error instanceof DocumentParseFailure ? error.message : '安全凭据删除失败，状态未冒称成功';
      await this.refreshCredentialAfterFailure();
    }
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
    action.cancel.deadline = Date.now() + DocumentParseBudget.pollMs;
    let lastProgress: number = 0;
    action.onProgress = (): void => {
      if (action.cancel.invalid || this.activeAction !== action) { return; }
      const now: number = Date.now();
      if (now - lastProgress >= 250) { lastProgress = now; this.emit(); }
    };
    this.activeAction = action; return action;
  }
  private check(action: DocumentParseAction): void {
    action.cancel.check();
    if (!this.state.snapshot.config.enabled || this.state.credential !== DocumentCredentialStatus.Configured ||
      !this.state.snapshot.tasks.some((task: DocumentParseTask): boolean => task.id === action.task.id) ||
      !this.state.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === action.original.id && o.hash === action.task.hash && o.version === action.task.version) ||
      !documentGrantMatches(action.original, action.grant, this.state.snapshot.config.credentialRevision)) {
      action.cancel.reason = 'INVALIDATED'; action.cancel.invalid = true; throw new DocumentParseFailure('任务/授权/凭据世代失效', '解析');
    }
  }
  private async checkpoint(action: DocumentParseAction, stage: DocumentParseStage): Promise<void> {
    this.check(action); action.task.stage = stage; action.task.checkpoint = stage;
    action.task.lastAction = stage; this.state.message = stage;
    await this.repository.save(this.state.snapshot); this.check(action); this.emit();
  }
  private async uploadOriginal(action: DocumentParseAction, recovery: boolean): Promise<void> {
    this.check(action);
    if (action.task.uploadLease.length === 0) { throw new DocumentParseFailure('原上传租约缺失，不申请新批次', '上传前复核'); }
    if (recovery && action.task.recoveryUploadUsed) { throw new DocumentParseFailure('同对象补传机会已用，停止待核对', '上传前复核'); }
    const priorAttempt: boolean = action.task.uploadAttempted;
    action.task.lastAction = '复核原件与原上传租约'; this.state.message = action.task.lastAction; this.emit();
    action.onUploadStarting = async (): Promise<void> => {
      this.check(action);
      const original: DocumentOriginal = action.original;
      if (original.hash !== action.task.hash || original.version !== action.task.version || original.preflight !== DocumentPreflightStatus.Passed || original.bytes < 1 || original.bytes > DocumentParseBudget.originalBytes ||
        original.format === DocumentParseFormat.Pdf && (original.pages < 1 || original.pages > DocumentParseBudget.pdfPages)) { throw new DocumentParseFailure('原件身份或预算已变', '上传前复核'); }
      if (recovery && (action.task.remote !== DocumentRemoteState.Waiting || action.task.recoveryUploadUsed)) { throw new DocumentParseFailure('本次未确认waiting-file或补传已用', '上传前复核'); }
      // Durable intent precedes SDK fetch. Crash at this boundary is conservative, never an automatic retry.
      if (recovery) { action.task.recoveryUploadUsed = true; }
      await this.consumeImage(action,'PUT',recovery);
      action.task.uploadAttempted = true; action.task.uploadRequestStarted = false; action.task.uploadBytes = 0;
      await this.checkpoint(action, DocumentParseStage.Uploading);
    };
    try { await this.requireNetwork().upload(action); this.check(action); }
    catch (error) {
      if (action.task.uploadRequestStarted || priorAttempt) { action.task.stage = DocumentParseStage.UploadUnknown; }
      if (error instanceof DocumentParseFailure) { throw error; }
      throw new DocumentParseFailure('上传结果未知，原身份保留', '原件PUT');
    }
    action.task.uploaded = true; await this.checkpoint(action, DocumentParseStage.Waiting);
    await this.requireNetwork().removeLeases([action.task.uploadLease]); action.task.uploadLease = ''; await this.repository.save(this.state.snapshot);
  }
  private async recordFailure(action: DocumentParseAction, error: Object): Promise<void> {
    if (!this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.id === action.task.id)) { return; }
    if (action.cancel.invalid && action.cancel.reason !== 'TIMEOUT' && action.cancel.reason !== 'INVALIDATED') { return; }
    const failure: DocumentParseFailure = error instanceof DocumentParseFailure ? error : new DocumentParseFailure('动作失败，远端状态未核实', action.task.lastAction);
    if (action.task.stage !== DocumentParseStage.UploadUnknown && action.task.stage !== DocumentParseStage.Received && action.task.stage !== DocumentParseStage.RemoteFailed && action.task.stage !== DocumentParseStage.Uncertain && action.task.stage !== DocumentParseStage.Failed) { action.task.stage = DocumentParseStage.Paused; }
    action.task.failureDetail = documentCopyFailure(failure.detail);
    action.task.failureDetail.stage = (failure.detail.stage || failure.stage).slice(0,100);
    if (action.task.failureDetail.sanitizedReason.length === 0) { action.task.failureDetail.sanitizedReason = parseSanitizedReason(failure.category); }
    action.task.failureDetail.outcomeUnknown = action.task.failureDetail.outcomeUnknown || action.task.stage === DocumentParseStage.UploadUnknown || action.task.stage === DocumentParseStage.Uncertain;
    action.task.failure = parseFailureSummary(action.task.failureDetail); action.task.failureStage = action.task.failureDetail.stage; action.task.failureCode = failure.serviceCode;
    const permit = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.taskId === action.task.id);
    const docxPermit: DocxParsePermit | undefined = this.state.snapshot.docxPermits.find((p: DocxParsePermit): boolean => p.taskId === action.task.id);
    if (docxPermit !== undefined && [ParseFailureKind.Auth,ParseFailureKind.Quota,ParseFailureKind.RateLimit,ParseFailureKind.Service].indexOf(action.task.failureDetail.kind) >= 0) { docxPermit.stoppedReason = parseSanitizedReason(action.task.failureDetail.sanitizedReason || action.task.failureDetail.kind); }
    if (permit !== undefined && ([ParseFailureKind.Auth,ParseFailureKind.Quota,ParseFailureKind.RateLimit,ParseFailureKind.Service].indexOf(action.task.failureDetail.kind) >= 0 || action.task.failureDetail.kind === ParseFailureKind.Unknown && (action.task.failureDetail.sdkCode.length > 0 || action.task.failureDetail.httpStatus > 0 || ['协议','控制响应','请求前'].indexOf(action.task.failureDetail.stage) >= 0))) { permit.stoppedReason = `revision=${action.task.credentialRevision};`+parseSanitizedReason(action.task.failureDetail.kind+' '+action.task.failureDetail.sanitizedReason).slice(0,260); }
    this.state.message = action.task.failure;
    try { await this.repository.save(this.state.snapshot); }
    catch { this.state.message = `${failure.message}；检查点写入失败，远端占用保留，禁止新提交`; }
  }
  async submit(originalId: string): Promise<void> {
    if (this.state.busy) { return; }
    const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === originalId);
    const grant: DocumentParseGrant | undefined = this.state.snapshot.grants.find((g: DocumentParseGrant): boolean => g.originalId === originalId && !g.revoked);
    if (original === undefined || grant === undefined || this.submitReason(original).length > 0 || this.network === undefined || this.clock === undefined) {
      this.state.message = original === undefined ? '原件不存在' : this.submitReason(original) || '未完成逐文件确认或能力不可用'; this.emit(); return;
    }
    if (this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.originalId === originalId)) { this.state.message = '已有任务，请查询该身份，不重复申请'; this.emit(); return; }
    this.state.busy = true; this.state.message = '正在复核本件测试原件'; this.emit();
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
      await this.consumeImage(action,'POST');
      const receipt: DocumentAllocationReceipt = await this.requireNetwork().allocate(action); this.check(action);
      if (!documentSafeId(receipt.batchId) || !receipt.leaseId.startsWith('lease-')) { throw new DocumentParseFailure('申请身份非法', '申请'); }
      task.batchId = receipt.batchId; task.uploadLease = receipt.leaseId; this.state.snapshot.occupancy.batchId = receipt.batchId;
      await this.checkpoint(action, DocumentParseStage.LeaseReady);
      await this.uploadOriginal(action, false);
      await this.poll(action);
    } catch (error) {
      if ((!action.cancel.invalid || action.cancel.reason === 'TIMEOUT' || action.cancel.reason === 'INVALIDATED') && this.state.snapshot.tasks.some((t: DocumentParseTask): boolean => t.id === task.id)) {
        if (allocatedRequest && task.batchId.length === 0) { task.stage = DocumentParseStage.Uncertain; }
        else if (!allocatedRequest) { this.state.snapshot.occupancy = new DocumentRemoteOccupancy(); task.stage = DocumentParseStage.Failed; }
        else if (task.stage !== DocumentParseStage.UploadUnknown && task.stage !== DocumentParseStage.Received) { task.stage = DocumentParseStage.Paused; }
        await this.recordFailure(action, error);
      }
    } finally { this.activeAction = undefined; this.state.busy = false; this.emit(); }
  }
  private async poll(action: DocumentParseAction, recovery: boolean = false): Promise<void> {
    const clock: DocumentParseClockPort = this.requireClock(); let delay: number = recovery ? 0 : 5000; let sessionQueries: number = 0;
    while (sessionQueries < DocumentParseBudget.pollCount && clock.now() - action.task.windowStart < DocumentParseBudget.pollMs) {
      this.check(action); if (delay > 0) { await clock.sleep(delay); } this.check(action);
      if (clock.now() - action.task.windowStart + DocumentParseBudget.requestMs > 900000) { break; }
      sessionQueries++; action.task.queries++; action.task.lastAction = 'Query同一批次'; this.state.message = action.task.lastAction;
      await this.repository.save(this.state.snapshot); this.check(action); this.emit();
      await this.consumeImage(action,'QUERY');
      const inspected: DocumentInspection = await this.requireNetwork().inspect(action); this.check(action);
      if (inspected.batchId !== action.task.batchId || inspected.dataId !== action.task.dataId || inspected.state === DocumentRemoteState.Unobserved) { throw new DocumentParseFailure('查询身份或状态不符', '查询'); }
      action.task.lastQueryAt = clock.now(); action.task.remote = inspected.state; action.task.extractedPages = inspected.extractedPages; action.task.totalPages = inspected.totalPages;
      const slot: DocumentRemoteOccupancy = this.state.snapshot.occupancy;
      if (slot.taskId === action.task.id) { slot.lastState = inspected.state; slot.terminalObserved = documentRemoteTerminal(inspected.state); }
      if (inspected.state === DocumentRemoteState.Failed) {
        action.task.failureDetail = documentCopyFailure(inspected.failureDetail);
        if (action.task.failureDetail.stage.length === 0) { action.task.failureDetail = parseDetailedFailure(ParseFailureKind.Service,'云解析','服务报告failed，未提供明确原因').detail; }
        action.task.failure = parseFailureSummary(action.task.failureDetail); action.task.failureStage = action.task.failureDetail.stage; action.task.failureCode = action.task.failureDetail.providerCode;
        const permit = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.taskId === action.task.id);
        if (permit !== undefined && action.task.failureDetail.kind !== ParseFailureKind.Format) { permit.stoppedReason = `revision=${action.task.credentialRevision};`+parseSanitizedReason(action.task.failureDetail.kind+' '+action.task.failureDetail.sanitizedReason).slice(0,260); }
        await this.checkpoint(action, DocumentParseStage.RemoteFailed);
        await this.requireNetwork().removeLeases([action.task.uploadLease, action.task.resultLease]); action.task.uploadLease = ''; action.task.resultLease = '';
        await this.repository.save(this.state.snapshot); return;
      }
      if (inspected.state === DocumentRemoteState.Waiting && !action.task.uploaded && recovery) {
        if (documentIsImage(action.original.format) && !imagePermitInputId(action.original).startsWith('image-')) { await this.checkpoint(action,DocumentParseStage.Paused); this.state.message = '旧测试许可禁止补传，原任务保留'; this.emit(); return; }
        await this.checkpoint(action, DocumentParseStage.Waiting);
        await this.assets?.verify(action.original, action.cancel); this.check(action);
        await this.uploadOriginal(action, action.task.uploadAttempted);
        recovery = false;
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
        await this.consumeImage(action,'ZIP',recovery);
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
    for (const grant of this.state.snapshot.grants) { if (grant.format===DocumentParseFormat.Docx && !this.state.snapshot.tasks.some((t: DocumentParseTask): boolean=>t.grantId===grant.id && t.originalId===grant.originalId)) { grant.revoked=true; } }
    this.assets?.cancelLocal(); this.preflight?.cancelLocal();
    if (this.localCancel !== undefined) { this.localCancel.invalid = true; }
    if (this.activeAction !== undefined) {
      this.activeAction.cancel.reason = 'PAUSE'; this.activeAction.cancel.invalid = true; this.activeAction.task.epoch++;
      if (this.activeAction.task.stage !== DocumentParseStage.Received && this.activeAction.task.stage !== DocumentParseStage.RemoteFailed) {
        this.activeAction.task.stage = this.activeAction.task.batchId.length === 0 ? DocumentParseStage.Uncertain : this.activeAction.task.stage === DocumentParseStage.Uploading ? DocumentParseStage.UploadUnknown : DocumentParseStage.Paused;
      }
      this.activeAction.task.lastAction = '本机暂停，远端可能继续';
    }
    if (this.tombstoneCancel !== undefined) { this.tombstoneCancel.invalid = true; }
    this.retireArmed = false;
    this.network?.pause(); this.credential.clearTransient(); this.clearInput();
  }
  async pause(): Promise<void> {
    this.pauseImmediate(); try { await this.repository.save(this.state.snapshot); this.state.message = '已停本机动作，远端可能继续；未释放未知占用'; }
    catch { this.state.message = '暂停检查点保存失败，远端占用仍保留'; } this.emit();
  }
  async close(): Promise<void> { await this.pause(); if (this.sourceProtection!==undefined) { await this.sourceProtection.withSource<void>('',async (): Promise<void>=>{}); } await this.repository.close(); this.listeners = []; }
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
    if (original.hash !== task.hash || original.version !== task.version || this.state.snapshot.occupancy.taskId !== task.id) { this.state.message = '原件或远端占用身份不符，停止'; this.emit(); return; }
    this.state.busy = true; task.grantId = grant.id; task.epoch++; task.windowStart = this.requireClock().now(); task.failure = ''; task.failureStage = ''; task.failureCode = '';
    task.lastAction = '正在查询原批次，不申请新任务'; this.state.message = task.lastAction; this.emit();
    const action: DocumentParseAction = this.action(task, original, grant);
    try { await this.repository.save(this.state.snapshot); this.check(action); await this.retryCleanup(); this.check(action); await this.poll(action, true); }
    catch (error) {
      await this.recordFailure(action, error);
    } finally { this.activeAction = undefined; this.state.busy = false; this.emit(); }
  }
  async deleteOriginal(originalId: string): Promise<void> {
    const protection: KnowledgeSourceProtectionPort | undefined = this.sourceProtection;
    if (protection === undefined) { this.state.message = '知识库引用保护不可用，解析副本未删除'; this.emit(); return; }
    try {
      await protection.withSource<void>(originalId, async (): Promise<void> => {
        const original: DocumentOriginal | undefined = this.state.snapshot.originals.find((item: DocumentOriginal): boolean => item.id === originalId);
        if (original === undefined) { return; }
        const taskIds: string[] = this.state.snapshot.tasks.filter((task: DocumentParseTask): boolean => task.originalId === originalId).map((task: DocumentParseTask): string => task.id);
        const assets: string[] = [original.assetId].concat(this.state.snapshot.results.filter((result: DocumentParseResultEnvelope): boolean => taskIds.indexOf(result.taskId) >= 0).map((result: DocumentParseResultEnvelope): string => result.assetId));
        await protection.assertDeletable(originalId, assets); await this.deleteOriginalGuarded(originalId);
      });
      await this.retryCleanup();
    } catch { this.state.message = '解析副本仍由知识库或检查点引用，或保护状态待核；未删除，请先在知识库处理引用'; this.emit(); }
  }
  private async deleteOriginalGuarded(originalId: string): Promise<void> {
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
    const oldImageEvidence: DocumentImageEvidence[] = this.state.snapshot.imageEvidence;
    this.state.snapshot.imageEvidence = oldImageEvidence.filter((e: DocumentImageEvidence): boolean => e.originalId !== originalId);
    this.state.snapshot.tasks = oldTasks.filter((t: DocumentParseTask): boolean => t.originalId !== originalId);
    this.state.snapshot.grants = oldGrants.filter((g: DocumentParseGrant): boolean => g.originalId !== originalId);
    this.state.snapshot.results = oldResults.filter((r: DocumentParseResultEnvelope): boolean => results.indexOf(r) < 0);
    this.state.snapshot.cleanup.push(cleanup);
    try {
      await this.repository.save(this.state.snapshot);
    } catch {
      this.state.snapshot.originals = oldOriginals; this.state.snapshot.tasks = oldTasks; this.state.snapshot.grants = oldGrants; this.state.snapshot.results = oldResults;
      this.state.snapshot.imageEvidence = oldImageEvidence;
      this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== cleanup.id);
      this.state.message = '本机逻辑删除失败，副本保留；本机动作已停止'; this.emit(); return;
    }
    this.state.message = '仅删除本机解析副本；远端数据可能保留，未决占用不解除'; this.emit();
  }
  async retryCleanup(): Promise<void> {
    if (this.assets === undefined) { return; }
    for (const cleanup of this.state.snapshot.cleanup.slice()) {
      try {
        const protection: KnowledgeSourceProtectionPort | undefined = this.sourceProtection;
        if (protection === undefined) { throw new DocumentParseFailure('知识库引用保护不可用，清理暂停', '清理'); }
        await protection.withSource<void>('', async (): Promise<void> => {
          await protection.assertCleanup(cleanup.assets);
          await this.assets?.remove(cleanup.assets); await this.network?.removeLeases(cleanup.leases);
          this.state.snapshot.cleanup = this.state.snapshot.cleanup.filter((c: DocumentParseCleanup): boolean => c.id !== cleanup.id);
          await this.repository.save(this.state.snapshot);
        });
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
    this.retireArmed = false;
    try {
      const permit = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.taskId === slot.taskId);
      if (permit !== undefined) {
        if (permit.usage.query >= 90) { throw new DocumentParseFailure('本件累计查询90次已消费','占用查询'); }
        permit.usage.query++; action.original.format = permit.actualFormat; action.grant.policy = imagePermitPolicy(permit);
        action.original.id = permit.originalId; action.original.hash = permit.hash; action.original.version = permit.version;
        action.task.originalId = permit.originalId; action.task.hash = permit.hash; action.task.version = permit.version;
        const source = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === permit.originalId);
        action.original.bytes = source?.bytes ?? 0;
        action.grant.id = 'occupancy-'+slot.taskId; action.grant.originalId = permit.originalId; action.grant.hash = permit.hash; action.grant.version = permit.version;
        action.grant.format = permit.actualFormat; action.grant.credentialRevision = slot.credentialRevision; action.grant.issuedAt = Date.now();
        action.grant.parameters = ImageParsePermit.parameters; action.grant.acknowledgement.fullFile = permit.fullFile; action.grant.acknowledgement.freeEligible = permit.freeEligible;
        const stored = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === slot.taskId);
        if (stored !== undefined) { stored.queries++; stored.usage = permit.usage; }
        await this.repository.save(this.state.snapshot);
      }
      const docxPermit: DocxParsePermit | undefined = this.state.snapshot.docxPermits.find((p: DocxParsePermit): boolean => p.taskId === slot.taskId);
      if (docxPermit !== undefined) {
        const source: DocumentOriginal | undefined = this.state.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === docxPermit.originalId);
        const grant: DocumentParseGrant | undefined = this.state.snapshot.grants.find((g: DocumentParseGrant): boolean => g.originalId === docxPermit.originalId && !g.revoked);
        if (source === undefined || grant === undefined || !documentGrantMatches(source,grant,this.state.snapshot.config.credentialRevision) || docxPermit.credentialRevision !== slot.credentialRevision || docxPermit.usage.query >= 90) { throw new DocumentParseFailure('DOCX原件/当前同意或累计查询资格不足，保留原占用','占用查询'); }
        action.original = source; action.grant = grant; action.task.originalId = source.id; action.task.hash = source.hash; action.task.version = source.version;
        docxPermit.usage.query++; const stored: DocumentParseTask | undefined = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === slot.taskId);
        if (stored !== undefined) { stored.queries++; stored.usage = docxPermit.usage; } await this.repository.save(this.state.snapshot);
      }
      const inspected: DocumentInspection = await this.requireNetwork().inspect(action); action.cancel.check();
      if (inspected.batchId !== slot.batchId || inspected.dataId !== slot.dataId) { throw new DocumentParseFailure('占用复核身份不符', '查询'); }
      if (inspected.state === DocumentRemoteState.Failed) {
        const permit = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.taskId === slot.taskId);
        const stored = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === slot.taskId);
        if (stored !== undefined) { stored.failureDetail = documentCopyFailure(inspected.failureDetail); stored.failure = parseFailureSummary(stored.failureDetail); stored.failureStage = stored.failureDetail.stage; stored.failureCode = stored.failureDetail.providerCode; }
        if (permit !== undefined && inspected.failureDetail.kind !== ParseFailureKind.Format) { permit.stoppedReason = `revision=${this.state.snapshot.config.credentialRevision};`+parseSanitizedReason(inspected.failureDetail.kind+' '+inspected.failureDetail.sanitizedReason).slice(0,260); }
      }
      slot.lastState = inspected.state; slot.terminalObserved = documentRemoteTerminal(inspected.state);
      this.retireArmed = !slot.terminalObserved && inspected.state === DocumentRemoteState.Waiting && this.occupancyRetireEligible(slot);
      await this.repository.save(this.state.snapshot); await this.requireNetwork().removeLeases([inspected.resultLease]);
      this.state.message = slot.terminalObserved ? '已观察原任务终态；不表示云端数据删除'
        : this.retireArmed ? '远端仍为 waiting-file（文件从未送达）；可停止本机跟踪或继续等待' : '原任务仍未终态，占用保留';
    } catch (error) {
      this.retireArmed = false; this.state.message = error instanceof DocumentParseFailure ? error.message : '原任务无法复核，占用仍保留';
      if (error instanceof DocumentParseFailure && [ParseFailureKind.Auth,ParseFailureKind.Quota,ParseFailureKind.RateLimit].indexOf(error.detail.kind) >= 0) {
        const permit = this.state.snapshot.imagePermits.find((p: ImageParsePermit): boolean => p.taskId === slot.taskId);
        if (permit !== undefined) { permit.stoppedReason = `revision=${this.state.snapshot.config.credentialRevision};`+parseSanitizedReason(error.detail.kind+' '+error.detail.sanitizedReason).slice(0,260); try { await this.repository.save(this.state.snapshot); } catch { this.state.message += '；账户停止检查点未保存'; } }
      }
    }
    finally { this.tombstoneCancel = undefined; this.state.busy = false; this.emit(); }
  }
  private occupancyRetireEligible(slot: DocumentRemoteOccupancy): boolean {
    if (this.state.snapshot.docxPermits.some((p: DocxParsePermit): boolean => p.taskId === slot.taskId)) { return false; }
    if (this.state.snapshot.imagePermits.some((p: ImageParsePermit): boolean => p.taskId === slot.taskId)) { return false; }
    if (slot.retired) { return false; }
    const task: DocumentParseTask | undefined = this.state.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === slot.taskId);
    if (task === undefined) { return true; }
    return !task.uploaded && task.stage !== DocumentParseStage.Uploading;
  }
  canRetireOccupancy(): boolean {
    const slot: DocumentRemoteOccupancy = this.state.snapshot.occupancy;
    return this.retireArmed && slot.taskId.length > 0 && !slot.terminalObserved && slot.lastState === DocumentRemoteState.Waiting && this.occupancyRetireEligible(slot);
  }
  dismissRetireOccupancy(): void {
    if (!this.retireArmed) { return; }
    this.retireArmed = false; this.state.message = '继续保留占用跟踪；未申请新批次'; this.emit();
  }
  async retireOccupancy(confirmed: boolean): Promise<void> {
    if (this.state.busy || !confirmed || !this.canRetireOccupancy()) { this.state.message = '停止跟踪须在核对确认远端仍等待文件后再确认'; this.emit(); return; }
    const slot: DocumentRemoteOccupancy = this.state.snapshot.occupancy; this.retireArmed = false; slot.retired = true;
    try {
      await this.repository.save(this.state.snapshot);
      this.state.message = '已停止本机跟踪先前占用；不表示云端删除或取消，远端记录可能仍保留';
    } catch { slot.retired = false; this.state.message = '停止跟踪写入失败，占用保留'; }
    this.emit();
  }
}
