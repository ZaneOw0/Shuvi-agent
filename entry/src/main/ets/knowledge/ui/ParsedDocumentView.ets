import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { ParsedDocumentImportAdapter } from '../infra/ParsedDocumentImportAdapter';
import { ParsedDocumentRecord, ParsedBlock, ParsedInline, ParsedImageOccurrence, ParsedTextChunk, ParsedImageAsset, ParsedFailure } from '../domain/ParsedDocumentModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentOriginal, DocumentParseResultEnvelope, DocumentParseFormat, DocumentParseTask, DocumentTestAcknowledgement, DocumentParseStateListener, DocumentParseStage } from '../domain/DocumentParseModels';
import { UnifiedProcessingJob } from '../domain/UnifiedKnowledgeModels';
import { processingStageName, processingStateName, processingCanRetry, processingCurrentJobs, processingDocumentStatus, processingFailureText } from '../pipeline/UnifiedProcessingPresentation';
import { Theme } from '../../components/Theme';
import { ParsedDocumentLifecycle } from '../application/KnowledgeLifecycleService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';

class ParsedLibraryItem {
  id: string = ''; documentId: string = ''; originalId: string = ''; title: string = ''; status: string = '';
}

@Component
export struct ParsedDocumentView {
  lifecycle: ParsedDocumentLifecycle | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  onRetryProcessing: () => void=(): void=>{};
  service: ParsedDocumentIngestionService | undefined = undefined;
  imports: ParsedDocumentImportAdapter | undefined = undefined;
  parse: DocumentParseService | undefined = undefined;
  @Prop opening: boolean = false;
  @Prop entryFailure: string = '';
  onRetry: () => void = (): void => {};
  onBack: () => void = (): void => {};
  onParseTasks: () => void = (): void => {};
  initialDocument: string = '';
  onNavigate: () => void = (): void => {};
  private filterController: TextInputController = new TextInputController();
  @State processingExpanded: boolean=false;
  @State processingJobs: UnifiedProcessingJob[]=[];
  @State retryJobId: string='';
  @State processingBusy: boolean=false;
  @State contentLoading: boolean=false;
  @State contentGeneration: string='';
  private openSequence: number=0;
  @State importOpen: boolean = false;
  @State detailsOpen: boolean = false;
  @State selectedOriginal: string = '';
  @State library: ParsedLibraryItem[] = [];
  @State filterText: string = '';
  @State includeArchived: boolean = false;
  @State documents: ParsedDocumentRecord[] = [];
  @State originals: DocumentOriginal[] = [];
  @State tasks: DocumentParseTask[] = [];
  @State results: DocumentParseResultEnvelope[] = [];
  @State blocks: ParsedBlock[] = [];
  @State occurrences: ParsedImageOccurrence[] = [];
  @State images: ParsedImageAsset[] = [];
  @State parsedEngine: string = '';
  @State title: string = '';
  @State identityText: string = '';
  @State coverageText: string = '';
  @State taskStage: string = 'Idle';
  @State message: string = '';
  @State localBusy: boolean = false;
  @State page: number = 0;
  @State blockCount: number = 0;
  @State question: string = '';
  @State directText: string = '';
  @State parseConsent: string = '';
  @State fullFile: boolean = false;
  @State freeEligible: boolean = false;
  @State previewPath: string = '';
  @State previewId: string = '';
  @State occurrencePage: number = 0;
  @State occurrenceCount: number = 0;
  @State imagePage: number = 0;
  @State imageCount: number = 0;
  @State deleteId: string='';
  @State retiredIds: string[]=[];
  @State selectedDocument: string='';
  @State unknownIds: string[]=[];
  @State releaseId: string='';
  @State retireId: string='';
  private alive: boolean = false;
  private boundService: ParsedDocumentIngestionService | undefined;
  private boundParse: DocumentParseService | undefined;
  private resourceListener: () => void=(): void=> { this.refreshResources().catch((): void=> { this.message='资源追踪读取未完成，可重试'; }); };
  private async refreshResources(): Promise<void> { const ids=await this.lifecycle?.unknownResources() ?? []; const jobs=await this.queue?.jobs() ?? []; if (this.alive) { this.unknownIds=ids; this.processingJobs=jobs; this.refreshLibrary(); } }
  private listener: () => void = (): void => { this.refreshView(); };
  private parseListener: ParsedViewParseListener = new ParsedViewParseListener((): void => { this.refreshView(); });
  bindServices(): void {
    if (!this.alive) { return; }
    if (this.boundService !== this.service) { this.boundService?.unsubscribe(this.listener); this.boundService = this.service; this.boundService?.subscribe(this.listener); }
    if (this.boundParse !== this.parse) { this.boundParse?.unsubscribe(this.parseListener); this.boundParse = this.parse; this.boundParse?.subscribe(this.parseListener); }
    this.refreshView();
  }
  aboutToAppear(): void { this.alive = true; this.queue?.subscribe(this.resourceListener); this.bindServices(); this.reload(); this.refreshResources().catch((): void=> { this.message='处理进度读取未完成，可重试打开资料'; }); if (this.initialDocument.length > 0) { this.open(this.initialDocument); } }
  aboutToDisappear(): void { this.openSequence++; this.alive = false; this.queue?.unsubscribe(this.resourceListener); this.boundService?.unsubscribe(this.listener); this.boundParse?.unsubscribe(this.parseListener); this.boundService?.closePreview().catch((): void => {}); this.boundService = undefined; this.boundParse = undefined; this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; }
  private refreshView(): void {
    if (!this.alive || this.service === undefined) { return; }
    const state = this.service.state; this.documents = state.documents.slice(); const matches: boolean=state.document.documentKey===this.selectedDocument && this.selectedDocument.length>0; if (matches) { this.title = state.document.title; this.contentGeneration=state.document.generation; } this.taskStage = state.stage; this.parsedEngine = state.document.engine;
    if (matches && (state.stage === 'Failed' || state.stage === 'Paused')) { this.message = state.message; } const visibleBlocks: ParsedBlock[] = (matches ? state.document.blocks ?? [] : []).filter((b: ParsedBlock): boolean => b.evidenceType !== 'SourceContextOnly' || b.kind === 'Unknown' || b.kind === 'Formula' || b.kind === 'Image' || b.inlines.some((r: ParsedInline): boolean => r.kind !== 'Text')); this.blockCount = visibleBlocks.length;
    this.blocks = visibleBlocks.slice(this.page*12,this.page*12+12);
    this.occurrenceCount = matches?state.document.occurrences.length:0; this.imageCount = matches?state.document.images.length:0;
    this.occurrences = matches?state.document.occurrences.slice(this.occurrencePage*12,this.occurrencePage*12+12):[]; this.images = matches?state.document.images.slice(this.imagePage*12,this.imagePage*12+12):[];
    this.identityText = `${state.document.engine} · ${state.document.parser_signature}\n${state.document.source_hash}`;
    this.coverageText = `产物 ${state.document.coverage.selectedOutput.state} · 原生定位 ${state.document.coverage.nativeLocation.state} · 图片 ${state.document.coverage.imageRecovery.recovered}/${state.document.coverage.imageRecovery.expected} · 增强 ${state.enhancement}`;
    const parse = this.parse?.viewState().snapshot; this.originals = parse?.originals.filter((o: DocumentOriginal): boolean => [DocumentParseFormat.Pdf,DocumentParseFormat.Docx,DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(o.format) >= 0) ?? [];
    this.results = parse?.results.slice() ?? []; this.tasks = parse?.tasks.slice() ?? [];
    this.refreshLibrary();
  }
  private refreshLibrary(): void {
    const rows: ParsedLibraryItem[] = [];
    for (const d of this.documents) {
      if (d.tombstone || !this.includeArchived && d.archived) { continue; }
      const item: ParsedLibraryItem = new ParsedLibraryItem(); item.id = d.id; item.documentId = d.id; item.originalId = this.originals.find((o: DocumentOriginal): boolean => o.id === d.legacyId)?.id ?? ''; item.title = d.title; item.status = processingDocumentStatus(this.processingJobs,d);
      if (d.namespace === 'Image' && item.originalId.length > 0 && !d.archived) { const task: DocumentParseTask | undefined = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === item.originalId); if (task?.stage !== DocumentParseStage.Received) { item.status = processingDocumentStatus(this.processingJobs,d)+' · '+(task?.stage ?? '未解析图片文字'); } } rows.push(item);
    }
    for (const o of this.originals) {
      if (this.documents.some((d: ParsedDocumentRecord): boolean => d.legacyId === o.id)) { continue; }
      const item: ParsedLibraryItem = new ParsedLibraryItem(); item.id = o.id; item.originalId = o.id; item.title = o.title;
      const task = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id);
      item.status = task?.stage === DocumentParseStage.Received ? '待入库' : task?.stage ?? '待解析'; rows.push(item);
    }
    this.library = rows.filter((item: ParsedLibraryItem): boolean => item.title.toLowerCase().includes(this.filterText.trim().toLowerCase()));
  }
  private async openItem(item: ParsedLibraryItem): Promise<void> {
    this.filterController.stopEditing(); this.onNavigate();
    this.selectedOriginal = item.originalId; this.detailsOpen = false; this.message = ''; this.parseConsent = '';
    if (item.documentId.length > 0) { await this.open(item.documentId); }
    else { this.selectedDocument = ''; this.title = item.title; this.blocks = []; this.images = []; this.occurrences = []; this.blockCount = 0; }
  }
  private backToList(): void {
    if (this.localBusy) { return; }
    this.openSequence++; this.contentLoading=false; this.retryJobId=''; this.clearContent(); this.onNavigate();
    this.service?.closePreview().catch((): void => {}); this.selectedDocument = ''; this.selectedOriginal = ''; this.parseConsent = ''; this.previewPath = ''; this.detailsOpen = false; this.message = ''; this.reload();
  }
  private selectedRecord(): ParsedDocumentRecord | undefined { return this.documents.find((d: ParsedDocumentRecord): boolean => d.id === this.selectedDocument); }
  private selectedResult(): DocumentParseResultEnvelope | undefined {
    const task = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    return this.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === task?.id);
  }
  private parseUsage(): string {
    const task: DocumentParseTask | undefined = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    if (task === undefined) { return ''; }
    if (this.originals.some((o: DocumentOriginal): boolean => o.id === this.selectedOriginal && o.format === DocumentParseFormat.Pdf)) { return `本文件记录：累计查询 ${task.queries} 次 · ${task.uploaded ? '上传已确认' : '上传未确认'} · ${task.stage === DocumentParseStage.Received ? '结果已接收' : task.stage}`; }
    return `本文件请求记录：申请 ${task.usage.allocation} / 上传 ${task.usage.put} / 查询 ${task.usage.query} / 下载 ${task.usage.download}`;
  }
  private selectedStatus(): string {
    if (this.selectedDocument.length > 0 && this.parsedEngine === 'MinerU') { return '解析完成'; }
    const task = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    return task?.failure || task?.stage || '文件已保存在本机，可开始解析';
  }
  private async removeSelected(): Promise<void> {
    try {
      if (this.selectedDocument.length > 0) { await this.service?.closePreview(); await this.lifecycle?.deleteDocument(this.selectedDocument, true); }
      if (this.selectedOriginal.length > 0) { await this.parse?.deleteOriginal(this.selectedOriginal); }
      this.backToList();
    } catch { this.message = '文件仍被使用，删除未完成，请稍后重试'; }
  }
  private async saveSelected(): Promise<void> {
    const result = this.selectedResult(); if (result === undefined) { return; }
    if (!await this.consume(result.assetId)) { return; } const record = this.service?.state.document;
    if (record !== undefined && record.documentKey.length > 0) { this.selectedDocument = record.documentKey; }

  }
  private async reload(): Promise<void> { try { await this.service?.refresh(); this.unknownIds=await this.lifecycle?.unknownResources() ?? []; this.refreshView(); } catch { this.message = '统一仓储读取失败，未当作空库'; } }
  private async retryLocal(): Promise<void> { try { await this.service?.retryLocal(); this.refreshView(); } catch { this.message = '已存快照尚不完整；请重新选择已收结果执行本机处理，未重新解析或外发'; } }
  private async select(kind: string): Promise<void> {
    if (this.localBusy) { return; } this.localBusy = true; let failure: string = '';
    try {
      if (kind === 'Text') { await this.imports?.importText(); }
      else { const parse = this.parse; if (parse !== undefined) { const old: string[] = parse.viewState().snapshot.originals.map((o: DocumentOriginal): string => o.id); await parse.prepare(kind === 'Image',kind === 'Docx'); if (kind === 'Image') { for (const o of parse.viewState().snapshot.originals) { if (old.indexOf(o.id)<0 && [DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(o.format) >= 0) { await this.imports?.preserveImage(parse,o); } } } } }
      this.page = 0; this.importOpen = false; await this.reload();
      await this.refreshResources(); const notice: string = this.parse?.viewState().message ?? ''; if (notice.includes('失败') || notice.includes('不足') || notice.includes('超限')) { this.message = notice; }
    } catch (error) { failure = error instanceof Error ? error.message : '本机导入失败，原件保留'; }
    finally { this.localBusy = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  private async consume(id: string, rebuild: boolean = false): Promise<boolean> {
    if (this.localBusy || this.parse === undefined || this.imports === undefined) { return false; } this.localBusy = true;
    let failure: string = '';
    try { await this.imports.consume(this.parse,id,rebuild); this.page = 0; }
    catch (error) { failure = error instanceof Error ? error.message : '本机产物处理失败'; }
    finally { this.localBusy = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
    return failure.length === 0;
  }
  private clearContent(): void { this.blocks=[]; this.images=[]; this.occurrences=[]; this.blockCount=0; this.imageCount=0; this.occurrenceCount=0; this.previewPath=''; this.previewId=''; this.contentGeneration=''; }
  private async open(id: string): Promise<void> {
    const sequence: number=++this.openSequence; this.contentLoading=true; this.clearContent(); this.page=0; this.imagePage=0; this.occurrencePage=0;
    this.directText=''; this.question=''; this.message=''; this.retryJobId=''; this.processingExpanded=false; this.selectedDocument=id; this.title=this.selectedRecord()?.title ?? '';
    try {
      await this.service?.open(id); if (sequence!==this.openSequence) { return; }
      if (this.service?.state.document.documentKey!==id) { throw new Error('SelectedDocumentChanged'); }
      this.selectedOriginal=this.originals.find((o: DocumentOriginal): boolean=>o.id===this.selectedRecord()?.legacyId)?.id ?? '';
      this.retiredIds=await this.lifecycle?.retired(id) ?? []; if (sequence!==this.openSequence) { return; } this.refreshView();
    } catch { if (sequence===this.openSequence) { this.clearContent(); this.message='当前文件内容读取失败，原件保留，请重试打开内容'; } }
    finally { if (sequence===this.openSequence) { this.contentLoading=false; } }
  }
  private selectedJobs(): UnifiedProcessingJob[] { const record=this.selectedRecord(); const jobs=record===undefined?[]:processingCurrentJobs(this.processingJobs,record); return this.processingExpanded?jobs:jobs.slice(0,5); }
  private selectedJobCount(): number { const record=this.selectedRecord(); return record===undefined?0:processingCurrentJobs(this.processingJobs,record).length; }
  private selectedProcessingStatus(): string { const record=this.selectedRecord(); return record===undefined?'':processingDocumentStatus(this.processingJobs,record); }
  private async retryProcessingJob(): Promise<void> {
    if (this.processingBusy || this.queue===undefined) { return; }
    const id: string=this.retryJobId; this.processingBusy=true;
    try { const current=(await this.queue.jobs()).find((j: UnifiedProcessingJob): boolean=>j.id===id && j.documentKey===this.selectedDocument); if (current===undefined || !processingCanRetry(current)) { throw new Error('JobChanged'); } await this.queue.retry(id,true); this.retryJobId=''; this.message='仅此任务已重新排队，成功进度会核验复用；若处理已暂停或设置关闭，请先恢复对应设置。'; await this.refreshResources(); }
    catch { this.message='此任务未能重新排队，请核对当前文件和处理设置后重试'; }
    finally { this.processingBusy=false; }
  }
  private parseInterrupted(): boolean { const t=this.tasks.find((j: DocumentParseTask): boolean=>j.originalId===this.selectedOriginal); return t!==undefined && t.stage!==DocumentParseStage.Received; }
  private async resumeParse(): Promise<void> {
    if (this.parse===undefined || this.localBusy) { return; } const task=this.tasks.find((t: DocumentParseTask): boolean=>t.originalId===this.selectedOriginal); if (task===undefined) { return; }
    this.localBusy=true; this.parseConsent=''; let phase: string='云任务核对'; let failure: string='';
    try {
      await this.parse.resume(task.id,true); const snapshot=this.parse.viewState().snapshot;
      const result=snapshot.results.find((r: DocumentParseResultEnvelope): boolean=>r.taskId===task.id && r.originalHash===task.hash && r.version===task.version);
      if (result!==undefined && this.imports!==undefined) { phase='本机入库'; await this.imports.consume(this.parse,result.assetId); this.page=0; this.selectedDocument=this.service?.state.document.documentKey ?? ''; this.message='原云任务结果已接收并完成本机入库'; }
      else { this.message=this.parse.viewState().message; } await this.reload(); await this.refreshResources();
    }
    catch (error) { const reason: string=error instanceof ParsedFailure?error.category+' / '+error.stage:'处理尚未完成'; failure=phase==='本机入库'?'云结果已接收，本机入库中断；可重试保存到知识库。原因：'+reason:'原云任务核对未完成，身份与原件保留。原因：'+reason; this.message=failure; }
    finally { this.localBusy=false; this.refreshView(); if (failure.length>0) { this.message=failure; } }
  }
  private async archive(id: string, archived: boolean): Promise<void> { try { await this.lifecycle?.archive(id,archived); await this.reload(); this.message=this.lifecycle?.message ?? ''; } catch { this.message='归档状态未确认，资料保留'; } }
  private async deleteCurrent(): Promise<void> { const id=this.deleteId; this.deleteId=''; try { await this.service?.closePreview(); this.previewPath=''; await this.lifecycle?.deleteDocument(id,true); await this.reload(); this.blocks=[]; this.images=[]; this.occurrences=[]; this.message=this.lifecycle?.message ?? ''; } catch { this.message='删除或清理未完成；按持久状态保留重试'; } }
  private async cleanup(): Promise<void> { try { await this.lifecycle?.cleanup(); this.message=this.lifecycle?.message || '本机清理已处理；未知文件未删除'; } catch { this.message='资源释放或清理仍待重试'; } }
  private async retire(id: string): Promise<void> { try { await this.lifecycle?.retire(this.selectedDocument,id,true); this.retiredIds=await this.lifecycle?.retired(this.selectedDocument) ?? []; this.message='旧代文件已按引用/租约退役；历史文本保留'; } catch { this.message='旧代仍活动或被读取，未清理'; } }
  private async releaseUnknown(): Promise<void> { const id=this.releaseId; this.releaseId=''; try { await this.lifecycle?.releaseUnknown(id,true); this.unknownIds=await this.lifecycle?.unknownResources() ?? []; this.message=this.lifecycle?.message ?? ''; } catch { this.message='本机持有仍未释放，可重试；未确认云端状态'; } }
  private pageBy(delta: number): void { this.page = Math.max(0,Math.min(Math.max(0,Math.ceil(this.blockCount/12)-1),this.page+delta)); this.refreshView(); }
  private searchLocal(): void {
    const q: string = this.question.trim(); this.directText = q.length === 0 ? '' : this.service?.state.chunks.filter((c: ParsedTextChunk): boolean => c.text.includes(q)).map((c: ParsedTextChunk): string => `${c.evidence} · ${c.blockId || c.occurrenceId}\n${c.text}`).join('\n\n') || '当前文档没有正文/OCR字面命中';
  }
  private async preview(id: string): Promise<void> { try { this.previewPath = await this.service?.previewImage(id) ?? ''; this.previewId = id; } catch { this.previewPath = ''; this.message = '图片缺失或读回不一致，未打开'; } }
  private async requestParse(): Promise<void> {
    if (this.localBusy) { return; }
    const parse = this.parse; const o: DocumentOriginal | undefined = this.originals.find((row: DocumentOriginal): boolean => row.id === this.parseConsent);
    if (parse === undefined || o === undefined || !this.fullFile || !this.freeEligible) { return; }
    this.localBusy = true; this.message = ''; this.parseConsent = '';
    const current = parse.viewState().snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
    let failure: string = '';
    try {
      if (o.format === DocumentParseFormat.Docx) { await parse.confirmDocx(o.id,true,true); }
      else if (o.format !== DocumentParseFormat.Pdf) { await this.imports?.preserveImage(parse,o); await parse.confirmImage(o.id,true,true); }
      else { const a: DocumentTestAcknowledgement = new DocumentTestAcknowledgement(); a.fullFile = true; a.embeddedImages = true; a.nonSensitive = true; a.privacyUnknown = true; a.freeEligible = true; await parse.confirm(o.id,a); }
      await parse.setEnabled(true); if (current === undefined) { await parse.submit(o.id); } else { await parse.resume(current.id,true); }
      const snapshot = parse.viewState().snapshot; const completed: DocumentParseTask | undefined = snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
      const result: DocumentParseResultEnvelope | undefined = snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === completed?.id && r.originalHash === o.hash && r.version === o.version);
      if (result !== undefined) { await this.imports?.consume(parse,result.assetId); this.selectedDocument = this.service?.state.document.documentKey ?? ''; }
    } catch (error) { failure = error instanceof Error ? error.message : '解析请求未完成'; }
    finally { this.localBusy = false; this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button('返回').id('upd-back').enabled(!this.localBusy).onClick((): void => { if (this.selectedDocument.length > 0 || this.selectedOriginal.length > 0) { this.backToList(); } else { this.onBack(); } })
        Text(this.selectedDocument.length > 0 || this.selectedOriginal.length > 0 ? '资料详情' : '我的资料').fontSize(22).fontWeight(FontWeight.Medium).layoutWeight(1)
      }.width('100%')
      if (this.entryFailure.length > 0 || this.message.length > 0) { Text(this.entryFailure || this.message).id('upd-status').fontSize(14).width('100%') }
      if (this.contentLoading) { LoadingProgress().width(28).height(28); Text('正在读取当前文件…').id('upd-content-loading') }
      if (this.localBusy || (this.service?.state.busy ?? false)) { LoadingProgress().width(28).height(28); Text('正在处理，请稍候…').fontSize(14); Button('暂停处理').id('upd-processing-pause').onClick((): void => { this.service?.pause(); this.parse?.pause(); }) }
      if (this.entryFailure.length > 0 || this.service === undefined) { Button('重试打开').id('upd-retry-open').onClick(this.onRetry) }
      if (this.selectedDocument.length === 0 && this.selectedOriginal.length === 0) {
        Button('＋ 导入文件').id('upd-import').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.localBusy && this.service !== undefined).onClick((): void => { this.importOpen = !this.importOpen; })
        if (this.importOpen) {
          Text('选择文件类型').fontSize(16).width('100%')
          Button('文本文档（TXT / Markdown）').id('upd-select-text').width('100%').enabled(!this.localBusy).onClick((): void => { this.select('Text'); })
          Button('PDF 文档').id('upd-select-pdf').width('100%').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Pdf'); })
          Button('图片（JPG / PNG / WebP）').id('upd-select-image').width('100%').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Image'); })
          Button('Word 文档（DOCX）').id('upd-select-docx').width('100%').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Docx'); })
          Button('取消').onClick((): void => { this.importOpen = false; })
        }
        TextInput({ text: this.filterText, placeholder: '按文件名查找资料', controller: this.filterController }).id('upd-library-filter').onChange((v: string): void => { this.filterText = v; this.refreshLibrary(); })
        Row() {
          Button(this.includeArchived ? '隐藏归档' : '查看归档').id('upd-library-archived').onClick((): void => { this.includeArchived = !this.includeArchived; this.refreshLibrary(); })
          Button('解析设置').id('upd-parse-tasks').onClick(this.onParseTasks)
        }.width('100%')
        if (this.library.length === 0) { Text(this.filterText.length > 0 ? '没有找到这份资料' : '还没有资料，点击上方导入文件').fontSize(15).fontColor(Theme.muted).padding(20) }
        ForEach(this.library, (item: ParsedLibraryItem) => {
          Column({ space: 8 }) {
            Text(item.title).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
            Text(item.status + '  ›').fontSize(13).fontColor(Theme.muted).width('100%')
          }.id('upd-file-' + item.id).width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(10).alignItems(HorizontalAlign.Start).onClick((): void => { this.openItem(item); })
        }, (item: ParsedLibraryItem): string => item.id+'|'+item.status)
      } else {
        Text(this.title).fontSize(20).fontWeight(FontWeight.Medium).width('100%')
        if (this.selectedOriginal.length > 0) {
          Text(this.selectedStatus()).id('upd-file-status').fontSize(14).width('100%')
          if (this.selectedResult() !== undefined && (this.selectedDocument.length === 0 || this.parsedEngine !== 'MinerU')) {
            Button('保存到知识库').id('upd-save-result').enabled(!this.localBusy).onClick((): void => { this.saveSelected(); })
          } else if (this.selectedResult() === undefined && !this.parseInterrupted()) {
            Button('解析文件').id('upd-parse-selected').enabled(!this.localBusy).onClick((): void => { this.parseConsent = this.selectedOriginal; })
          }
        }
        if (this.parseInterrupted()) {
          Text('云端上传/解析尚未完成，原件与上次任务保留。').fontSize(13).width('100%')
          Button('核对并恢复原云任务').id('upd-resume-parse').enabled(!this.localBusy).onClick((): void=> { this.parseConsent='resume'; })
        }
        if (this.parseConsent === 'resume') {
          Text('确认仍使用先前同一账号。先查询原任务；服务明确仍待文件时，核验同一原件与租约后最多补传一次。失败结果包最多显式重取两次；可能产生流量或费用，不新建解析任务。').fontSize(13).width('100%')
          Button('确认恢复原任务').id('upd-confirm-resume-parse').onClick((): void=> { this.resumeParse(); })
          Button('取消').onClick((): void=> { this.parseConsent=''; })
        } else if (this.parseConsent.length > 0) {
          Text('解析将把这份完整文件（含图片及元数据）发送给 MinerU。请确认文件不含敏感信息，且当前账号具有本件免费解析资格；服务可能留存文件。').fontSize(14).width('100%')
          Button('同意发送并确认免费解析').id('upd-confirm-parse').enabled(!this.localBusy).onClick((): void => { this.fullFile = true; this.freeEligible = true; this.requestParse(); })
          Button('取消').onClick((): void => { this.parseConsent = ''; })
        }
        if (this.selectedDocument.length > 0) {
          Text(this.selectedProcessingStatus()).id('upd-processing-status').fontSize(14).width('100%')
          Text(this.selectedOriginal.length>0 && this.parsedEngine!=='MinerU' && this.blocks.length===0?'原图已保存，尚无解析正文/OCR；图片描述与向量处理见下方任务。':'本机正文/OCR可检索；未完成的向量任务完成后才可语义召回。').fontSize(12).fontColor(Theme.muted).width('100%')
          ForEach(this.selectedJobs(),(job: UnifiedProcessingJob)=> {
            Column({space:6}) {
              Text(`${processingStageName(job.stage)} · ${processingStateName(job.state)} · ${job.completed}/${job.expected}`).fontSize(13).width('100%')
              if (job.failure.length>0) { Text(processingFailureText(job)).fontSize(13).width('100%') }
              if (processingCanRetry(job)) { Button('重试'+processingStageName(job.stage)).id('upd-retry-job-'+job.id).enabled(!this.processingBusy).onClick((): void=> { this.retryJobId=job.id; }) }
              if (this.retryJobId===job.id) {
                Text('仅重新排队上述任务，已成功且身份一致的进度会复用。结果未知的请求可能重复计费。').fontSize(13).width('100%')
                Button('接受可能费用，重试此任务').id('upd-retry-job-confirm').enabled(!this.processingBusy).onClick((): void=> { this.retryProcessingJob(); })
                Button('取消').onClick((): void=> { this.retryJobId=''; })
              }
            }.width('100%')
          },(job: UnifiedProcessingJob): string=>job.id+'|'+job.state+'|'+String(job.completed)+'|'+job.failure)
          if (this.selectedJobCount()>5) { Button(this.processingExpanded?'收起处理任务':`查看全部处理任务（${this.selectedJobCount()}）`).id('upd-processing-expand').onClick((): void=> { this.processingExpanded=!this.processingExpanded; }) }
          if (!this.contentLoading && this.blocks.length===0 && this.message.length>0) { Button('重试打开内容').id('upd-content-retry').onClick((): void=> { this.open(this.selectedDocument); }) }
          ForEach(this.blocks, (b: ParsedBlock) => {
            Column({ space: 5 }) {
              if (b.evidenceType !== 'SourceContextOnly' && b.text.length > 0 && b.inlines.length === 0) { Text(b.text).fontSize(16).copyOption(CopyOptions.LocalDevice).width('100%') }
              if (b.kind === 'Formula') { Text(b.formula.text || b.formula.latex || b.formula.unsupportedReason).width('100%') }
              if (b.limitation.length > 0) { Text(b.limitation).fontSize(13).fontColor(Theme.muted).width('100%') }
              ForEach(b.inlines, (r: ParsedInline) => { if (r.kind !== 'Text' || b.evidenceType !== 'SourceContextOnly') { Text(r.kind === 'Text' ? r.text : r.kind === 'Formula' ? r.formula.text || r.formula.latex || r.formula.unsupportedReason : r.kind === 'Image' ? '〔图片〕' : r.limitation).fontSize(16).width('100%') } }, (r: ParsedInline): string => this.selectedDocument+'|'+this.contentGeneration+'|'+b.id+'|'+r.id)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (b: ParsedBlock): string => this.selectedDocument+'|'+this.contentGeneration+'|'+b.id)
          if (this.blockCount > 12) {
            Row() { Button('上一页').enabled(this.page > 0).onClick((): void => { this.pageBy(-1); }); Text(`${this.page + 1} / ${Math.ceil(this.blockCount / 12)}`).layoutWeight(1); Button('下一页').enabled((this.page + 1) * 12 < this.blockCount).onClick((): void => { this.pageBy(1); }) }.width('100%')
          }
          ForEach(this.images, (a: ParsedImageAsset) => {
            Column() {
              Button(a.state === 'Ready' ? '查看图片' : '图片暂不可用').id('upd-preview-' + a.id).enabled(a.state === 'Ready').onClick((): void => { this.preview(a.id); })
              if (this.previewId === a.id && this.previewPath.length > 0) { Image(this.previewPath).objectFit(ImageFit.Contain).width('100%').height(220).onError((): void => { this.message = '图片暂时无法预览'; }) }
            }.width('100%')
          }, (a: ParsedImageAsset): string => this.selectedDocument+'|'+this.contentGeneration+'|'+a.id)
          if (this.imageCount > 12) { Row() { Button('上一组图片').enabled(this.imagePage > 0).onClick((): void => { this.imagePage--; this.refreshView(); }); Button('下一组图片').enabled((this.imagePage + 1) * 12 < this.imageCount).onClick((): void => { this.imagePage++; this.refreshView(); }) } }
          Button(this.selectedRecord()?.archived ? '恢复资料' : '归档资料').id('upd-archive-selected').enabled(!this.localBusy).onClick((): void => { this.archive(this.selectedDocument, !(this.selectedRecord()?.archived ?? false)); })
        }
        Button(this.detailsOpen ? '收起处理详情' : '处理详情').id('upd-details-toggle').onClick((): void => { this.detailsOpen = !this.detailsOpen; })
        if (this.detailsOpen) {
          if (this.selectedOriginal.length > 0) { Text(this.parseUsage()).id('upd-parse-usage').fontSize(12).width('100%') }
          if (this.selectedDocument.length > 0) { Text(this.coverageText).fontSize(12).width('100%'); Text(this.identityText).fontSize(11).wordBreak(WordBreak.BREAK_ALL).width('100%') }
          if (this.selectedResult() !== undefined) { Button('从已接收结果重新入库').id('upd-rebuild-selected').enabled(!this.localBusy).onClick((): void => { this.consume(this.selectedResult()?.assetId ?? '', true); }) }
          if (this.taskStage === 'Failed' || this.taskStage === 'Paused') { Button('重试保存内容').id('upd-retry-local').onClick((): void => { this.retryLocal(); }) }
          Button('暂停自动处理').id('upd-queue-pause').onClick((): void => { this.queue?.pause(); })
          Button('继续自动处理').id('upd-queue-resume').onClick((): void => { this.queue?.resume(); })
          Button('重试文件清理').id('upd-cleanup-retry').onClick((): void => { this.cleanup(); })
        }
        Button('删除资料').id('upd-delete-selected').enabled(!this.localBusy).onClick((): void => { this.deleteId = 'selected'; })
        if (this.deleteId.length > 0) {
          Text('删除这份资料及其本机解析内容？共享图片仍由其他资料保留。').fontSize(14).width('100%')
          Button('确认删除').id('upd-delete-confirm').onClick((): void => { this.deleteId = ''; this.removeSelected(); })
          Button('取消').onClick((): void => { this.deleteId = ''; })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 20 })
  }
}
class ParsedViewParseListener implements DocumentParseStateListener {
  private callback: () => void;
  constructor(callback: () => void) { this.callback = callback; }
  changed(): void { this.callback(); }
}
