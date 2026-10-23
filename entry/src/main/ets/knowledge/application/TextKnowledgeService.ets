import { TextSelectionPort, TextAssetPort, TextProcessingPort, TextRepositoryPort, TextStateListener } from '../domain/TextKnowledgePorts';
import {
  TextViewState, TextFailure, TextBudget, TextDocument, TextOriginal, TextJob, TextStage, TextScreen,
  TextCancellation, TextSelection, TextSelectedFile, TextProcessed, TextQueryInput, TextDetail, TextHit, TextSourceRange, TextSearchResult,
  TextHistory, TextReferenceState, TextChannel
} from '../domain/TextKnowledgeModels';
import { validateProcessedBounded } from '../pipeline/StructuredChunker';

export class TextKnowledgeService {
  state: TextViewState = new TextViewState();
  private selection: TextSelectionPort;
  private assets: TextAssetPort;
  private processor: TextProcessingPort;
  private repository: TextRepositoryPort;
  private listeners: TextStateListener[] = [];
  private sequence: number = 0;
  private activeCancel: TextCancellation | undefined = undefined;
  private activeJob: TextJob | undefined = undefined;
  private batchCanceled: boolean = false;
  private closing: boolean = false;
  private detailEpoch: number = 0;
  private queryEpoch: number = 0;
  private indexTimer: number = -1;
  private beforeCleanup: (() => Promise<void>) | undefined;
  attachBeforeCleanup(action: () => Promise<void>): void { this.beforeCleanup = action; }
  private unifiedImport: (() => Promise<void>) | undefined;
  attachUnifiedImport(action: () => Promise<void>): void { this.unifiedImport = action; }
  constructor(selection: TextSelectionPort, assets: TextAssetPort, processor: TextProcessingPort, repository: TextRepositoryPort) {
    this.selection = selection; this.assets = assets; this.processor = processor; this.repository = repository;
  }
  subscribe(listener: TextStateListener): void { this.listeners.push(listener); }
  unsubscribe(listener: TextStateListener): void { this.listeners = this.listeners.filter((entry: TextStateListener): boolean => entry !== listener); }
  private emit(): void { for (const listener of this.listeners) { listener.changed(); } }
  private id(prefix: string): string { this.sequence++; return `${prefix}-${Date.now()}-${this.sequence}-${Math.floor(Math.random() * 1000000000)}`; }
  private message(error: Object): string {
    return error instanceof TextFailure ? `${error.category} / ${error.stage}：${error.message}` : '本机操作失败，已保存资料与旧索引保留';
  }
  async initialize(deferRecovery: boolean = false): Promise<void> {
    await this.repository.open();
    if (this.beforeCleanup !== undefined) {
      const beforeCleanup: (() => Promise<void>) | undefined = this.beforeCleanup;
      try { if (beforeCleanup !== undefined) { await beforeCleanup(); } }
      catch { this.state.message = '统一引用保护未就绪，已暂停旧资产清理；资料保留'; await this.refresh(); this.emit(); return; }
    }
    if (deferRecovery) { await this.refresh(); } else { await this.recoverLocal(); }
  }
  async recoverLocal(): Promise<void> {
    await this.repository.reconcile(); await this.retryCleanup();
    try { await this.assets.reconcile(await this.repository.assetIds()); }
    catch { this.state.message = '启动资产对账未完成，可重试；已有资料保留'; }
    await this.refresh();
  }
  async close(): Promise<void> {
    this.closing = true; this.queryEpoch++; await this.cancel();
    while (this.state.busy || this.state.searching) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 20); });
    }
    await this.repository.close();
  }
  private startDeadline(cancel: TextCancellation): void {
    this.stopDeadline();
    this.indexTimer = setTimeout((): void => {
      if (this.activeCancel === cancel) {
        cancel.invalid = true;
        if (this.activeJob === undefined) { this.state.message = 'TIMEOUT：原件读取/保存超过 60 秒，未发布'; this.emit(); return; }
        this.activeJob.stage = TextStage.Failed;
        this.activeJob.cancelGeneration++; this.activeJob.failure = 'TIMEOUT：索引超过 60 秒，原件与旧索引保留';
        this.repository.checkpoint(this.activeJob).then((): void => { this.refresh(); }, (): void => {
          this.state.message = '超时检查点保存失败，原件保留，下次启动对账'; this.emit();
        });
      }
    }, Math.max(1, cancel.deadline - Date.now()));
  }
  private stopDeadline(): void { if (this.indexTimer >= 0) { clearTimeout(this.indexTimer); this.indexTimer = -1; } }
  viewState(): TextViewState {
    const view: TextViewState = new TextViewState();
    view.screen = this.state.screen; view.previousScreen = this.state.previousScreen;
    view.documents = this.state.documents.slice(); view.jobs = this.state.jobs.slice(); view.selectedIds = this.state.selectedIds.slice();
    view.question = this.state.question; view.includeArchived = this.state.includeArchived;
    view.busy = this.state.busy; view.searching = this.state.searching; view.message = this.state.message;
    view.channel = this.state.channel; view.result = this.state.result; view.detail = this.state.detail;
    view.history = this.state.history.slice(); view.historyOffset = this.state.historyOffset; view.cleanupCount = this.state.cleanupCount;
    return view;
  }
  private async refresh(): Promise<void> {
    this.state.documents = await this.repository.list(); this.state.jobs = await this.repository.jobs();
    this.state.channel = this.repository.channel(); this.state.cleanupCount = (await this.repository.cleanups()).length; this.emit();
  }
  questionChanged(question: string): void { this.state.question = question; this.emit(); }
  navigate(screen: TextScreen): void { this.state.screen = screen; this.emit(); }
  back(): boolean {
    if (this.state.screen === TextScreen.Documents) { return false; }
    this.state.screen = this.state.screen === TextScreen.Detail ? this.state.previousScreen :
      (this.state.screen === TextScreen.Record ? TextScreen.History : TextScreen.Documents);
    this.emit(); return true;
  }
  async importFiles(): Promise<void> {
    const unifiedImport: (() => Promise<void>) | undefined = this.unifiedImport;
    if (unifiedImport !== undefined) { await unifiedImport(); return; }
    if (this.state.busy || this.closing) { return; }
    this.batchCanceled = false;
    this.state.busy = true; this.state.message = ''; this.emit();
    try {
      if ((await this.repository.cleanups()).length > 0) { throw new TextFailure('CLEANUP', 'import', '有待清理资产，请先重试清理再新增资料'); }
      const selection: TextSelection = await this.selection.select();
      if (selection.canceled || selection.files.length === 0) { this.state.message = '已取消选择，未新增资料'; return; }
      if (selection.files.length > TextBudget.batchFiles) { throw new TextFailure('BUDGET', 'batch', '单批最多 10 个文件'); }
      let batchBytes: number = 0;
      for (const file of selection.files) {
        if (file.bytes > 0) { batchBytes += file.bytes; }
      }
      if (batchBytes > TextBudget.batchBytes) { throw new TextFailure('BUDGET', 'batch', '单批原件超过 5 MiB，整批拒绝'); }
      const outcomes: string[] = [];
      let actualBatchBytes: number = 0;
      for (const file of selection.files) {
        if (this.batchCanceled || this.closing) { outcomes.push(`${file.name}：批次已暂停，未开始读取`); continue; }
        try {
          if (!new RegExp('\\.(txt|md)$', 'i').test(file.name)) { throw new TextFailure('FORMAT', 'import', '本轮仅启用 txt/md'); }
          if (file.bytes < 1 || file.bytes > TextBudget.fileBytes) { throw new TextFailure('BUDGET', 'import', '文件元信息不可用、为空或超过 1 MiB'); }
          const cancel: TextCancellation = new TextCancellation(); cancel.deadline = Date.now() + TextBudget.indexMs; this.activeCancel = cancel;
          this.startDeadline(cancel);
          const original: TextOriginal = await this.assets.saveOriginal(file, this.id('original'), cancel);
          actualBatchBytes += original.bytes;
          if (actualBatchBytes > TextBudget.batchBytes) { await this.assets.remove([original.assetId]); throw new TextFailure('BUDGET', 'batch', '真实原件总字节超过 5 MiB'); }
          const duplicate = await this.repository.findHash(original.hash);
          if (duplicate !== undefined) {
            await this.assets.remove([original.assetId]); this.stopDeadline(); this.activeCancel = undefined;
            outcomes.push(`${file.name}：原件已存在，未重复入库`); continue;
          }
          const usage = await this.repository.usage();
          if (usage.documents >= TextBudget.documents || usage.originalBytes + original.bytes > TextBudget.originalBytes) {
            await this.assets.remove([original.assetId]);
            throw new TextFailure('BUDGET', 'import', '资料库超过 100 篇或原件 20 MiB，未删除旧资料');
          }
          if (file.name.length > 256) { await this.assets.remove([original.assetId]); throw new TextFailure('TITLE', 'import', '原文件名超过 256 字符'); }
          const doc: TextDocument = new TextDocument(); doc.id = this.id('document'); doc.title = file.name;
          doc.format = file.format; doc.original = original; doc.createdAt = Date.now(); doc.updatedAt = doc.createdAt;
          const job: TextJob = this.newJob(doc); this.activeJob = job;
          try { await this.repository.add(doc, job); }
          catch (error) {
            await this.assets.remove([original.assetId]);
            if (error instanceof Error) { throw error; }
            throw new TextFailure('RDB', 'import', '文档记录保存失败，未新增资料');
          }
          await this.refresh(); await this.process(doc, job, cancel, false);
          outcomes.push(`${file.name}：${job.stage}${job.failure.length > 0 ? '，' + job.failure : ''}`);
        } catch (error) { outcomes.push(`${file.name}：${this.message(error)}`); }
        this.stopDeadline(); this.activeCancel = undefined; this.activeJob = undefined;
      }
      this.state.message = outcomes.join('\n');
    } catch (error) { this.state.message = this.message(error); }
    finally { this.stopDeadline(); this.state.busy = false; this.activeCancel = undefined; this.activeJob = undefined; await this.refresh(); }
  }
  private newJob(doc: TextDocument): TextJob {
    const job: TextJob = new TextJob(); job.id = this.id('job'); job.documentId = doc.id;
    job.generation = this.id('generation'); job.startedAt = Date.now(); return job;
  }
  private async process(doc: TextDocument, job: TextJob, cancel: TextCancellation, rebuild: boolean): Promise<void> {
    try {
      let output: TextProcessed;
      if (rebuild && doc.activeGeneration.length > 0) {
        const snapshot = await this.assets.readSnapshot(`${doc.activeGeneration}-snapshot`);
        output = await this.processor.rebuild(snapshot, job.generation, cancel);
      } else {
        const bytes: Uint8Array = await this.assets.readOriginal(doc.original, cancel);
        output = await this.processor.process(bytes, doc, job.generation, cancel);
      }
      await validateProcessedBounded(output, doc, job.generation); cancel.check();
      doc.warnings = Array.from(new Set<string>(output.snapshot.warnings));
      await this.assets.saveSnapshot(output.snapshot); cancel.check();
      job.stage = TextStage.Normalized; job.checkpoint = TextStage.Normalized;
      await this.repository.checkpoint(job); await this.refresh();
      await this.repository.reconcile(false); await this.retryCleanup();
      const usage = await this.repository.usage();
      if (usage.activeChunks - doc.chunkCount + output.chunks.length > TextBudget.activeChunks) {
        throw new TextFailure('BUDGET', 'index', '活动块超过 10000，旧索引未替换');
      }
      await this.repository.prepare(doc, job, output.chunks); cancel.check();
      job.stage = TextStage.Prepared; job.checkpoint = TextStage.Prepared;
      await this.repository.checkpoint(job); await this.refresh(); cancel.check();
      if (!(await this.repository.publish(doc, job, output.chunks.length))) { throw new TextFailure('STALE', 'publish', '任务失效或文档已删除，未发布'); }
      job.stage = TextStage.Ready; this.stopDeadline();
      await this.repository.reconcile(false); await this.retryCleanup();
      if (output.snapshot.warnings.length > 0) { this.state.message = output.snapshot.warnings.join('\n'); }
    } catch (error) {
      if (job.stage !== TextStage.Failed) { job.stage = cancel.invalid ? TextStage.Paused : TextStage.Failed; job.failure = this.message(error); }
      await this.repository.checkpoint(job);
    }
  }
  async search(): Promise<void> {
    if (this.state.searching || this.closing) { return; }
    this.state.searching = true; this.state.message = ''; this.emit();
    const epoch: number = ++this.queryEpoch;
    let timer: number = -1;
    try {
      const cancel: TextCancellation = new TextCancellation(); cancel.deadline = Date.now() + TextBudget.searchMs;
      const timeout: Promise<TextSearchResult> = new Promise<TextSearchResult>((_resolve: (result: TextSearchResult) => void, reject: (error: Object) => void): void => {
        timer = setTimeout((): void => { cancel.invalid = true; reject(new TextFailure('TIMEOUT', 'query', '检索超过 10 秒，旧结果保留')); }, Math.max(1, cancel.deadline - Date.now()));
      });
      const result: TextSearchResult = await Promise.race<TextSearchResult>([this.retrieve(this.state.question, this.state.includeArchived, cancel), timeout]);
      cancel.check(); if (epoch !== this.queryEpoch || this.closing) { return; }
      if (timer >= 0) { clearTimeout(timer); timer = -1; }
      this.state.result = result;
      this.state.message = result.hits.length === 0 ? '知识库中没有相关内容' : 'L0 · 本机关键词结果，未生成回答';
      const history: TextHistory = new TextHistory(); history.id = this.id('query'); history.createdAt = Date.now(); history.result = result;
      try { await this.repository.saveHistory(history); }
      catch { this.state.message += '\n历史保存失败，本次检索结果仍可见，请重试保存'; }
    } catch (error) { this.state.message = this.message(error); }
    finally { if (timer >= 0) { clearTimeout(timer); } this.state.searching = false; this.emit(); }
  }
  private async retrieve(question: string, includeArchived: boolean, cancel: TextCancellation): Promise<TextSearchResult> {
    const input: TextQueryInput = await this.processor.prepareQuery(question, cancel);
    cancel.check(); return this.repository.search(input, includeArchived, cancel);
  }
  async openDocument(id: string): Promise<void> {
    const epoch: number = ++this.detailEpoch;
    try {
      const doc = await this.repository.get(id);
      if (doc === undefined) { throw new TextFailure('DELETED', 'detail', '原文档已删除'); }
      const bytes: Uint8Array = await this.assets.readOriginal(doc.original, new TextCancellation());
      const detail: TextDetail = new TextDetail(); detail.title = doc.title;
      detail.originalText = (await this.processor.decode(bytes, new TextCancellation())).originalText;
      if (epoch !== this.detailEpoch || this.closing || await this.repository.get(id) === undefined) { return; }
      detail.note = `原件 v${doc.version} · SHA256 ${doc.original.hash} · 原文 UTF-16，不是字节偏移`;
      this.state.detail = detail; this.state.previousScreen = this.state.screen; this.state.screen = TextScreen.Detail; this.emit();
    } catch (error) { this.state.message = this.message(error); this.emit(); }
  }
  async openHit(hit: TextHit): Promise<void> {
    try { await this.openHitChecked(hit); }
    catch (error) { this.state.message = this.message(error); this.emit(); }
  }
  private async openHitChecked(hit: TextHit): Promise<void> {
    const doc = await this.repository.get(hit.documentId);
    if (doc === undefined || doc.version !== hit.documentVersion || doc.original.hash !== hit.originalHash || doc.activeGeneration !== hit.generation) {
      const detail: TextDetail = new TextDetail(); detail.title = hit.title; detail.excerpts = [hit.text]; detail.ranges = hit.ranges;
      detail.note = doc === undefined ? TextReferenceState.Deleted : TextReferenceState.Old;
      this.state.detail = detail; this.state.previousScreen = this.state.screen; this.state.screen = TextScreen.Detail; this.emit(); return;
    }
    await this.openDocument(hit.documentId);
    if (this.state.screen === TextScreen.Detail) {
      this.state.detail.ranges = hit.ranges;
      this.state.detail.excerpts = hit.ranges.map((range: TextSourceRange): string => this.state.detail.originalText.slice(range.originalStart, range.originalEnd)); this.emit();
    }
  }
  setIncludeArchived(include: boolean): void { this.state.includeArchived = include; this.emit(); }
  selectDocument(id: string, selected: boolean): void {
    this.state.selectedIds = this.state.selectedIds.filter((entry: string): boolean => entry !== id);
    if (selected) { this.state.selectedIds.push(id); } this.emit();
  }
  async rename(id: string, title: string): Promise<void> {
    try {
      if (title.trim().length === 0 || title.length > 256) { throw new TextFailure('TITLE', 'rename', '标题须为 1–256 个字符'); }
      await this.repository.rename(id, title.trim()); this.state.message = '展示标题已更新，原件与身份未变';
    } catch (error) { this.state.message = this.message(error); } await this.refresh();
  }
  async setArchived(id: string, archived: boolean): Promise<void> {
    try { await this.repository.archive(id, archived); this.state.message = archived ? '已在本机归档' : '已恢复归档标记，索引状态未变'; }
    catch (error) { this.state.message = this.message(error); } await this.refresh();
  }
  async rebuild(id: string): Promise<void> {
    if (this.state.busy || this.closing) { return; }
    this.state.busy = true; this.emit();
    try {
      if ((await this.repository.cleanups()).length > 0) { throw new TextFailure('CLEANUP', 'rebuild', '请先重试待清理任务，未覆盖旧索引'); }
      const doc = await this.repository.get(id); if (doc === undefined) { throw new TextFailure('DELETED', 'rebuild', '文档已删除'); }
      const job: TextJob = this.newJob(doc); const cancel: TextCancellation = new TextCancellation();
      cancel.deadline = Date.now() + TextBudget.indexMs; this.activeJob = job; this.activeCancel = cancel;
      this.startDeadline(cancel);
      await this.repository.start(job); await this.process(doc, job, cancel, doc.activeGeneration.length > 0);
      this.state.message = `重建${job.stage}${job.failure.length > 0 ? '：' + job.failure : ''}`;
    } catch (error) { this.state.message = this.message(error); }
    finally {
      this.stopDeadline(); this.state.busy = false; this.activeJob = undefined; this.activeCancel = undefined;
      await this.repository.reconcile(false); await this.retryCleanup(); await this.refresh();
    }
  }
  async deleteDocuments(ids: string[], confirmed: boolean): Promise<void> {
    if (!confirmed || ids.length === 0) { return; }
    try {
      if (this.activeJob !== undefined && ids.indexOf(this.activeJob.documentId) >= 0 && this.activeCancel !== undefined) {
        await this.cancel();
      }
      await this.repository.deleteDocuments(ids); this.state.selectedIds = [];
      this.detailEpoch++;
      this.state.detail = new TextDetail();
      if (this.state.screen === TextScreen.Detail) { this.state.screen = TextScreen.Documents; }
      await this.retryCleanup(); this.state.message = `已删除 ${ids.length} 篇本机资料；历史文本快照保留${this.state.cleanupCount > 0 ? '，文件待清理' : ''}`;
    } catch (error) { this.state.message = this.message(error); } await this.refresh();
  }
  async purge(confirmed: boolean): Promise<void> {
    if (!confirmed) { return; }
    await this.deleteDocuments((await this.repository.list()).map((doc: TextDocument): string => doc.id), true);
  }
  async retryCleanup(): Promise<void> {
    for (const cleanup of await this.repository.cleanups()) {
      try {
        const docs: TextDocument[] = await this.repository.list();
        const activeIds: string[] = [];
        for (const doc of docs) {
          activeIds.push(doc.original.assetId);
          if (doc.activeGeneration.length > 0) { activeIds.push(`${doc.activeGeneration}-snapshot`); }
        }
        if (cleanup.assetIds.some((id: string): boolean => activeIds.indexOf(id) >= 0)) {
          throw new TextFailure('ACTIVE', 'cleanup', '拒绝清理活动原件/快照');
        }
        await this.assets.remove(cleanup.assetIds); await this.repository.finishCleanup(cleanup.id, '');
      }
      catch { await this.repository.finishCleanup(cleanup.id, '本机文件/索引清理失败，可重试'); }
    }
    this.state.cleanupCount = (await this.repository.cleanups()).length;
    this.emit();
  }
  async cancel(): Promise<void> {
    this.batchCanceled = true;
    if (this.activeCancel !== undefined) { this.activeCancel.invalid = true; }
    this.stopDeadline();
    if (this.activeJob !== undefined && this.activeJob.stage !== TextStage.Ready) {
      this.activeJob.cancelGeneration++; this.activeJob.stage = TextStage.Paused;
      this.activeJob.failure = '用户已暂停，原件与旧活动索引保留'; await this.repository.checkpoint(this.activeJob);
    }
    this.state.message = '已暂停后续处理；当前 CPU 任务可能仍在退出，迟到结果不会发布'; await this.refresh();
  }
  async resume(id: string): Promise<void> {
    if (this.state.busy || this.closing) { return; }
    if ((await this.repository.cleanups()).length > 0) { this.state.message = '有待清理资产，请先重试清理'; this.emit(); return; }
    const doc = await this.repository.get(id); if (doc === undefined) { this.state.message = '文档已删除，不能恢复'; this.emit(); return; }
    const previous = (await this.repository.jobs()).find((job: TextJob): boolean => job.documentId === id);
    if (previous === undefined) { this.state.message = '没有未完成任务'; this.emit(); return; }
    this.state.busy = true; this.emit();
    const job: TextJob = this.newJob(doc); const cancel: TextCancellation = new TextCancellation(); cancel.deadline = Date.now() + TextBudget.indexMs;
    this.activeJob = job; this.activeCancel = cancel; this.startDeadline(cancel);
    try {
      if (previous.checkpoint === TextStage.Normalized || previous.checkpoint === TextStage.Prepared) {
        const snapshot = await this.assets.readSnapshot(`${previous.generation}-snapshot`);
        await this.repository.start(job); await this.repository.reconcile(false); await this.retryCleanup();
        const output: TextProcessed = await this.processor.rebuild(snapshot, job.generation, cancel);
        await validateProcessedBounded(output, doc, job.generation); cancel.check(); await this.assets.saveSnapshot(output.snapshot);
        doc.warnings = Array.from(new Set<string>(output.snapshot.warnings));
        job.stage = TextStage.Normalized; job.checkpoint = TextStage.Normalized; await this.repository.checkpoint(job);
        const usage = await this.repository.usage();
        if (usage.activeChunks - doc.chunkCount + output.chunks.length > TextBudget.activeChunks) { throw new TextFailure('BUDGET', 'resume', '活动块超过 10000'); }
        await this.repository.prepare(doc, job, output.chunks); cancel.check(); job.stage = TextStage.Prepared; job.checkpoint = TextStage.Prepared;
        await this.repository.checkpoint(job); cancel.check();
        if (!(await this.repository.publish(doc, job, output.chunks.length))) { throw new TextFailure('STALE', 'resume', '恢复结果已失效'); }
        job.stage = TextStage.Ready;
      } else { await this.repository.start(job); await this.process(doc, job, cancel, doc.activeGeneration.length > 0); }
      this.state.message = `恢复${job.stage}`;
    } catch (error) { job.stage = cancel.invalid ? TextStage.Paused : TextStage.Failed; job.failure = this.message(error); await this.repository.checkpoint(job); }
    finally {
      this.stopDeadline(); this.state.busy = false; this.activeCancel = undefined; this.activeJob = undefined;
      // Do not startup-reconcile while other foreground work is running.
      await this.repository.reconcile(false); await this.retryCleanup(); await this.refresh();
    }
  }
  async loadHistory(more: boolean): Promise<void> {
    try {
      const offset: number = more ? this.state.historyOffset : 0;
      const records: TextHistory[] = await this.repository.history(offset, TextBudget.historyPage);
      this.state.history = records;
      this.state.historyOffset = offset + records.length; this.state.screen = TextScreen.History;
      this.state.message = records.length === 0 ? '没有更多历史' : '';
    } catch (error) { this.state.message = this.message(error); } this.emit();
  }
  openHistory(record: TextHistory): void { this.state.result = record.result; this.state.screen = TextScreen.Record; this.emit(); }
  async previousHistoryPage(): Promise<void> {
    try {
      const offset: number = Math.max(0, this.state.historyOffset - this.state.history.length - TextBudget.historyPage);
      this.state.history = await this.repository.history(offset, TextBudget.historyPage);
      this.state.historyOffset = offset + this.state.history.length;
    } catch (error) { this.state.message = this.message(error); } this.emit();
  }
  async retrySaveHistory(): Promise<void> {
    if (this.state.result.channel === TextChannel.Unavailable || this.state.result.input.fullQuestion.length === 0) { return; }
    const history: TextHistory = new TextHistory(); history.id = this.id('query'); history.createdAt = Date.now(); history.result = this.state.result;
    try { await this.repository.saveHistory(history); this.state.message = '历史已保存'; }
    catch { this.state.message = '历史保存失败，检索结果保留'; } this.emit();
  }
}
