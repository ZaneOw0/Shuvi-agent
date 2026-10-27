import { preferences } from '@kit.ArkData';
import { AppIcon } from '../../components/AppIcon';
import { FeatureRow } from '../../components/FeaturePages';
import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { ParsedDocumentImportAdapter } from '../infra/ParsedDocumentImportAdapter';
import { ParsedDocumentRecord, ParsedBlock, ParsedInline, ParsedImageOccurrence, ParsedTextChunk, ParsedImageAsset, ParsedAssetPreview, ParsedFailure } from '../domain/ParsedDocumentModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentOriginal, DocumentParseResultEnvelope, DocumentParseFormat, DocumentParseTask, DocumentTestAcknowledgement, DocumentParseStateListener, DocumentParseStage } from '../domain/DocumentParseModels';
import { UnifiedProcessingJob } from '../domain/UnifiedKnowledgeModels';
import { processingStageName, processingJobStateName, processingCanRetry, processingCurrentJobs, processingDocumentStatus, processingFailureText } from '../pipeline/UnifiedProcessingPresentation';
import { Theme } from '../../components/Theme';
import { ParsedDocumentLifecycle } from '../application/KnowledgeLifecycleService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { PdfJsRuntime } from '../infra/PdfJsRuntime';
import { documentAssetPath } from '../infra/DocumentFileOperations';
import { DocumentParseCancellation } from '../domain/DocumentParseModels';

class ParsedLibraryItem {
  id: string = ''; documentId: string = ''; originalId: string = ''; title: string = '';
  status: string = ''; category: string = ''; namespace: string = ''; savedAt: number = 0;
}

class ParsedLibraryFolder {
  name: string = ''; count: number = 0;
}

const LIBRARY_COLLECTION: string = 'shuvi_knowledge_library_v1';
const LIBRARY_SEEN_KEY: string = 'seen';

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
  initialImportOpen: boolean = false;
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
  @State sortMode: string = 'time';
  @State viewMode: string = 'list';
  @State folder: string = '';
  @State libraryPage: number = 0;
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
  @State contentOpen: boolean = false;
  @State imagesOpen: boolean = false;
  @State imagesLoading: boolean = false;
  @State imagePreviews: ParsedAssetPreview[] = [];
  @State fullscreenOpen: boolean = false;
  @State fullscreenPaths: string[] = [];
  @State fullscreenIndex: number = 0;
  @State confirmOpen: boolean = false;
  @State confirmAction: string = '';
  @State confirmTitle: string = '';
  @State confirmMessage: string = '';
  @State confirmLabel: string = '确定';
  @State confirmDanger: boolean = false;
  private seenTimes: Map<string, number> = new Map<string, number>();
  private seenLoaded: boolean = false;
  private seenSaving: boolean = false;
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
  aboutToAppear(): void {
    this.importOpen = this.initialImportOpen; this.alive = true; this.queue?.subscribe(this.resourceListener); this.bindServices();
    this.reload(); this.loadSeenTimes().catch((): void => {});
    this.refreshResources().catch((): void=> { this.message='处理进度读取未完成，可重试打开资料'; });
    if (this.initialDocument.length > 0) { this.open(this.initialDocument); }
  }
  aboutToDisappear(): void { this.openSequence++; this.alive = false; this.queue?.unsubscribe(this.resourceListener); this.boundService?.unsubscribe(this.listener); this.boundParse?.unsubscribe(this.parseListener); this.boundService?.closePreview().catch((): void => {}); this.boundService = undefined; this.boundParse = undefined; this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; }
  private async loadSeenTimes(): Promise<void> {
    if (this.seenLoaded) { return; }
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) { return; }
      const store: preferences.Preferences = await preferences.getPreferences(context, LIBRARY_COLLECTION);
      const raw: preferences.ValueType = await store.get(LIBRARY_SEEN_KEY, '');
      if (typeof raw === 'string') { this.parseSeenTimes(raw); }
    } catch { return; }
    this.seenLoaded = true;
    this.refreshLibrary();
  }
  private parseSeenTimes(raw: string): void {
    const rows: string[] = raw.split('\n');
    for (const row of rows) {
      const at: number = row.indexOf('|');
      if (at <= 0) { continue; }
      const id: string = row.slice(0, at); const time: number = Number(row.slice(at + 1));
      if (id.length > 0 && id.length <= 180 && Number.isSafeInteger(time) && time > 0) { this.seenTimes.set(id, time); }
    }
  }
  private rememberSeen(): void {
    let changed: boolean = false;
    const now: number = Date.now();
    for (const item of this.library) {
      if (item.id.length > 0 && !this.seenTimes.has(item.id)) { this.seenTimes.set(item.id, now); changed = true; }
    }
    if (!changed || this.seenSaving) { return; }
    this.seenSaving = true;
    this.persistSeenTimes().catch((): void => { this.seenSaving = false; });
  }
  private async persistSeenTimes(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) { return; }
      const rows: string[] = [];
      this.seenTimes.forEach((time: number, id: string): void => { rows.push(id + '|' + String(time)); });
      const store: preferences.Preferences = await preferences.getPreferences(context, LIBRARY_COLLECTION);
      await store.put(LIBRARY_SEEN_KEY, rows.join('\n'));
      await store.flush();
    } finally { this.seenSaving = false; }
  }
  private refreshView(): void {
    if (!this.alive || this.service === undefined) { return; }
    const state = this.service.state; this.documents = state.documents.slice(); const matches: boolean=state.document.documentKey===this.selectedDocument && this.selectedDocument.length>0; if (matches) { this.title = state.document.title; this.contentGeneration=state.document.generation; } this.taskStage = state.stage; this.parsedEngine = state.document.engine;
    if (matches && (state.stage === 'Failed' || state.stage === 'Paused')) { this.message = state.message; } const visibleBlocks: ParsedBlock[] = (matches ? state.document.blocks ?? [] : []).filter((b: ParsedBlock): boolean => b.evidenceType !== 'SourceContextOnly' || b.kind === 'Unknown' || b.kind === 'Formula' || b.kind === 'Image' || b.inlines.some((r: ParsedInline): boolean => r.kind !== 'Text')); this.blockCount = visibleBlocks.length;
    this.blocks = visibleBlocks.slice(this.page*12,this.page*12+12);
    this.occurrenceCount = matches?state.document.occurrences.length:0; this.imageCount = matches?state.document.images.length:0;
    this.occurrences = matches?state.document.occurrences.slice(this.occurrencePage*12,this.occurrencePage*12+12):[]; this.images = matches?state.document.images.slice(this.imagePage*9,this.imagePage*9+9):[];
    this.identityText = `${state.document.engine} · ${state.document.parser_signature}\n${state.document.source_hash}`;
    this.coverageText = `产物 ${state.document.coverage.selectedOutput.state} · 原生定位 ${state.document.coverage.nativeLocation.state} · 图片 ${state.document.coverage.imageRecovery.recovered}/${state.document.coverage.imageRecovery.expected} · 增强 ${state.enhancement}`;
    const parseState=this.parse?.viewState();
    if (this.localBusy && parseState!==undefined && parseState.message.length>0) { this.message=parseState.message; }
    const parse = parseState?.snapshot; this.originals = parse?.originals.filter((o: DocumentOriginal): boolean => [DocumentParseFormat.Pdf,DocumentParseFormat.Docx,DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(o.format) >= 0) ?? [];
    this.results = parse?.results.slice() ?? []; this.tasks = parse?.tasks.slice() ?? [];
    this.refreshLibrary();
  }
  private categoryOf(title: string, namespace: string): string {
    const ns: string = namespace.replace('Legacy:', '');
    const dot: number = title.lastIndexOf('.');
    const ext: string = dot >= 0 ? title.slice(dot + 1).toLowerCase() : '';
    if (ns === 'Image' || ['jpg','jpeg','png','webp','gif','bmp','heic'].indexOf(ext) >= 0) { return '图片'; }
    if (ns === 'Pdf' || ext === 'pdf') { return 'PDF 文档'; }
    if (ns === 'Docx' || ext === 'docx' || ext === 'doc') { return 'Word 文档'; }
    if (ns === 'Text' || ext === 'txt' || ext === 'md' || ext === 'markdown') { return '文本笔记'; }
    if (ext === 'xlsx' || ext === 'xls' || ext === 'csv') { return '表格'; }
    if (ext === 'pptx' || ext === 'ppt') { return '演示文稿'; }
    return '其他资料';
  }
  private refreshLibrary(): void {
    const rows: ParsedLibraryItem[] = [];
    const documents: ParsedDocumentRecord[] = this.documents;
    const originals: DocumentOriginal[] = this.originals;
    const includeArchived: boolean = this.includeArchived;
    const jobs: UnifiedProcessingJob[] = this.processingJobs;
    const tasks: DocumentParseTask[] = this.tasks;
    for (const d of documents) {
      if (d.tombstone || !includeArchived && d.archived) { continue; }
      const original: DocumentOriginal | undefined = originals.find((o: DocumentOriginal): boolean => o.id === d.legacyId);
      const item: ParsedLibraryItem = new ParsedLibraryItem(); item.id = d.id; item.documentId = d.id; item.originalId = original?.id ?? ''; item.title = d.title; item.namespace = d.namespace;
      item.category = this.categoryOf(d.title, d.namespace); item.savedAt = original?.savedAt ?? 0; item.status = processingDocumentStatus(jobs,d);
      if (d.namespace === 'Image' && item.originalId.length > 0 && !d.archived) { const task: DocumentParseTask | undefined = tasks.find((t: DocumentParseTask): boolean => t.originalId === item.originalId); if (task?.stage !== DocumentParseStage.Received) { item.status = processingDocumentStatus(jobs,d)+' · '+(task?.stage ?? '未解析图片文字'); } }
      rows.push(item);
    }
    for (const o of originals) {
      if (documents.some((d: ParsedDocumentRecord): boolean => d.legacyId === o.id)) { continue; }
      const item: ParsedLibraryItem = new ParsedLibraryItem(); item.id = o.id; item.originalId = o.id; item.title = o.title; item.namespace = '';
      item.category = this.categoryOf(o.title, ''); item.savedAt = o.savedAt;
      const task = tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id);
      item.status = task?.stage === DocumentParseStage.Received ? '待入库' : task?.stage ?? (o.format===DocumentParseFormat.Pdf && o.preflightReason.length>0?'PDF预检未通过':'待解析'); rows.push(item);
    }
    const matched: ParsedLibraryItem[] = rows.filter((item: ParsedLibraryItem): boolean => item.title.toLowerCase().includes(this.filterText.trim().toLowerCase()));
    if (this.sortMode === 'name') {
      matched.sort((a: ParsedLibraryItem, b: ParsedLibraryItem): number => a.title.localeCompare(b.title, 'zh-Hans-CN'));
    } else {
      matched.sort((a: ParsedLibraryItem, b: ParsedLibraryItem): number => this.itemTime(b) - this.itemTime(a));
    }
    this.library = matched;
    if (this.libraryPage * this.libraryPageSize() >= this.library.length) { this.libraryPage = Math.max(0, Math.ceil(this.library.length / this.libraryPageSize()) - 1); }
    this.rememberSeen();
  }
  private itemTime(item: ParsedLibraryItem): number {
    if (item.savedAt > 0) { return item.savedAt; }
    const seen: number | undefined = this.seenTimes.get(item.id);
    return seen ?? 0;
  }
  private libraryPageSize(): number { return this.viewMode === 'folders' && this.folder.length === 0 ? 6 : 8; }
  private libraryRows(): ParsedLibraryItem[] {
    if (this.folder.length === 0) { return this.library; }
    return this.library.filter((item: ParsedLibraryItem): boolean => item.category === this.folder);
  }
  private libraryPageCount(): number { return Math.max(1, Math.ceil(this.libraryRows().length / this.libraryPageSize())); }
  private visibleLibrary(): ParsedLibraryItem[] { return this.libraryRows().slice(this.libraryPage * this.libraryPageSize(), this.libraryPage * this.libraryPageSize() + this.libraryPageSize()); }
  private libraryFolders(): ParsedLibraryFolder[] {
    const folders: ParsedLibraryFolder[] = [];
    for (const item of this.library) {
      const found: ParsedLibraryFolder | undefined = folders.find((row: ParsedLibraryFolder): boolean => row.name === item.category);
      if (found === undefined) { const folder: ParsedLibraryFolder = new ParsedLibraryFolder(); folder.name = item.category; folder.count = 1; folders.push(folder); }
      else { found.count++; }
    }
    folders.sort((a: ParsedLibraryFolder, b: ParsedLibraryFolder): number => b.count - a.count || a.name.localeCompare(b.name, 'zh-Hans-CN'));
    return folders;
  }
  private folderIcon(category: string): Resource {
    if (category === '图片') { return $r('app.media.chat_book'); }
    if (category === 'PDF 文档' || category === 'Word 文档' || category === '文本笔记') { return $r('app.media.ui_document'); }
    if (category === '表格' || category === '演示文稿') { return $r('app.media.chat_grid'); }
    return $r('app.media.ui_folder');
  }
  private fileIcon(item: ParsedLibraryItem): Resource { return this.folderIcon(item.category); }
  private pad2(value: number): string { return value < 10 ? '0' + String(value) : String(value); }
  private timeText(item: ParsedLibraryItem): string {
    const time: number = this.itemTime(item);
    if (time <= 0) { return ''; }
    const date: Date = new Date(time); const now: Date = new Date();
    if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()) {
      return `今天 ${this.pad2(date.getHours())}:${this.pad2(date.getMinutes())}`;
    }
    return `${date.getFullYear()}-${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`;
  }
  private openFolder(name: string): void { this.folder = name; this.libraryPage = 0; }
  private setSort(mode: string): void { this.sortMode = mode; this.libraryPage = 0; this.refreshLibrary(); }
  private setView(mode: string): void { this.viewMode = mode; this.folder = ''; this.libraryPage = 0; }
  private libraryBy(delta: number): void { this.libraryPage = Math.max(0, Math.min(this.libraryPageCount() - 1, this.libraryPage + delta)); }
  private async openItem(item: ParsedLibraryItem): Promise<void> {
    this.filterController.stopEditing(); this.onNavigate();
    this.selectedOriginal = item.originalId; this.detailsOpen = false; this.message = ''; this.parseConsent = ''; this.contentOpen = false; this.imagesOpen = false; this.imagePreviews = []; this.fullscreenPaths = []; this.fullscreenOpen = false;
    if (item.documentId.length > 0) { await this.open(item.documentId); }
    else { this.selectedDocument = ''; this.title = item.title; this.blocks = []; this.images = []; this.occurrences = []; this.blockCount = 0; }
  }
  private backToList(): void {
    if (this.localBusy) { return; }
    this.openSequence++; this.contentLoading=false; this.retryJobId=''; this.clearContent(); this.onNavigate();
    this.service?.closePreview().catch((): void => {}); this.selectedDocument = ''; this.selectedOriginal = ''; this.parseConsent = ''; this.previewPath = ''; this.detailsOpen = false; this.message = ''; this.contentOpen = false; this.imagesOpen = false; this.imagePreviews = []; this.fullscreenPaths = []; this.fullscreenOpen = false; this.reload();
  }
  private selectedRecord(): ParsedDocumentRecord | undefined { return this.documents.find((d: ParsedDocumentRecord): boolean => d.id === this.selectedDocument); }
  private selectedResult(): DocumentParseResultEnvelope | undefined {
    const task = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    return this.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === task?.id);
  }
  private selectedOriginalRow(): DocumentOriginal | undefined { return this.originals.find((o: DocumentOriginal): boolean => o.id === this.selectedOriginal); }
  private parseUsage(): string {
    const task: DocumentParseTask | undefined = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    if (task === undefined) { return ''; }
    if (task.stage === DocumentParseStage.Received) { return '云端解析已完成，内容已接收并保存在本机。'; }
    if (task.stage === DocumentParseStage.RemoteFailed) { return '云端解析没有完成。原件和之前的进度仍保留，可稍后重试。'; }
    return `云端解析正在处理：${task.stage}。应用会自动检查进度，无需一直停留在此页。`;
  }
  private coverageSummary(): string {
    const document = this.service?.state.document;
    if (document === undefined || document.generation.length === 0) { return ''; }
    const parts: string[] = [];
    const state: string = document.coverage.selectedOutput.state;
    parts.push(state === 'Complete' ? '正文提取完整' : state === 'Partial' ? '正文只提取到一部分' : '正文提取状态待确认');
    const expected: number = document.coverage.imageRecovery.expected;
    if (expected > 0) { parts.push(`可查看图片 ${document.coverage.imageRecovery.recovered}/${expected} 张`); }
    if (document.warnings.length > 0) { parts.push('有 ' + String(document.warnings.length) + ' 条处理提醒'); }
    return parts.join(' · ');
  }
  private displayText(text: string): string {
    let out: string = text;
    out = out.replace(/<\/(td|th)>/gi, ' · ');
    out = out.replace(/<\/(tr|p|div|li|h[1-6])>/gi, '\n');
    out = out.replace(/<br\s*\/?>/gi, '\n');
    out = out.replace(/<[^>]+>/g, '');
    out = out.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
    out = out.replace(/^#{1,6}\s+/gm, '');
    out = out.replace(/\*\*([^*]+)\*\*/g, '$1');
    out = out.replace(/^\s*\*([^*\n]+)\*\s*$/gm, '$1');
    out = out.replace(/^\s*[-*+]\s+/gm, '• ');
    out = out.replace(/\\-/g, '-');
    out = out.replace(/[ \t]+\n/g, '\n');
    out = out.replace(/\n{3,}/g, '\n\n');
    return out.trim();
  }
  private selectedStatus(): string {
    if (this.selectedDocument.length > 0 && this.parsedEngine === 'MinerU') { return '内容已整理，可阅读与搜索'; }
    if (this.selectedDocument.length > 0) { return '内容已保存在本机'; }
    const task = this.tasks.find((t: DocumentParseTask): boolean => t.originalId === this.selectedOriginal);
    const original: DocumentOriginal | undefined=this.originals.find((o: DocumentOriginal): boolean=>o.id===this.selectedOriginal);
    if (task===undefined && original?.format===DocumentParseFormat.Pdf && original.preflightReason.length>0) { return original.preflightReason; }
    if (task?.failure !== undefined && task.failure.length > 0) { return '上次处理没有完成，可查看处理状态后重试'; }
    if (task?.stage === DocumentParseStage.Received) { return '结果已接收，等待整理入库'; }
    if (task?.stage === DocumentParseStage.RemoteFailed) { return '云端处理没有完成，可以稍后重试'; }
    return task?.stage || '文件已保存在本机，可开始解析';
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
  private async retryLocal(): Promise<void> { try { await this.service?.retryLocal(); this.refreshView(); } catch { this.message = '已存内容尚不完整；请重新选择已接收结果执行本机整理，未重新解析或外发'; } }
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
  private clearContent(): void { this.blocks=[]; this.images=[]; this.occurrences=[]; this.blockCount=0; this.imageCount=0; this.occurrenceCount=0; this.previewPath=''; this.previewId=''; this.contentGeneration=''; this.imagePreviews=[]; this.fullscreenPaths=[]; }
  private async open(id: string): Promise<void> {
    const sequence: number=++this.openSequence; this.contentLoading=true; this.clearContent(); this.page=0; this.imagePage=0; this.occurrencePage=0;
    this.directText=''; this.question=''; this.message=''; this.retryJobId=''; this.processingExpanded=false; this.selectedDocument=id; this.title=this.selectedRecord()?.title ?? '';
    try {
      await this.service?.open(id); if (sequence!==this.openSequence) { return; }
      if (this.service?.state.document.documentKey!==id) { throw new Error('SelectedDocumentChanged'); }
      this.selectedOriginal=this.originals.find((o: DocumentOriginal): boolean=>o.id===this.selectedRecord()?.legacyId)?.id ?? '';
      this.retiredIds=await this.lifecycle?.retired(id) ?? []; if (sequence!==this.openSequence) { return; } this.refreshView();
      if (this.images.length > 0 && this.blocks.length === 0) { this.imagesOpen = true; await this.loadImagePreviews(); }
    } catch { if (sequence===this.openSequence) { this.clearContent(); this.message='当前文件内容读取失败，原件保留，请重试打开内容'; } }
    finally { if (sequence===this.openSequence) { this.contentLoading=false; } }
  }
  private selectedJobs(): UnifiedProcessingJob[] { const record=this.selectedRecord(); const jobs=record===undefined?[]:processingCurrentJobs(this.processingJobs,record); return this.processingExpanded?jobs:jobs.filter((j: UnifiedProcessingJob): boolean=>j.state!=='Complete').slice(0,3); }
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
    this.localBusy=true; this.parseConsent=''; let phase: string='云端任务核对'; let failure: string='';
    try {
      await this.parse.resume(task.id,true); const snapshot=this.parse.viewState().snapshot;
      const result=snapshot.results.find((r: DocumentParseResultEnvelope): boolean=>r.taskId===task.id && r.originalHash===task.hash && r.version===task.version);
      if (result!==undefined && this.imports!==undefined) { phase='本机入库'; await this.imports.consume(this.parse,result.assetId); this.page=0; this.selectedDocument=this.service?.state.document.documentKey ?? ''; this.message='原云端结果已接收并完成本机整理'; }
      else { this.message=this.parse.viewState().message; } await this.reload(); await this.refreshResources();
    }
    catch (error) { const reason: string=error instanceof ParsedFailure?error.category+' / '+error.stage:'处理尚未完成'; failure=phase==='本机入库'?'云结果已接收，本机入库中断；可重试保存到知识库。原因：'+reason:'原云端任务核对未完成，身份与原件保留。原因：'+reason; this.message=failure; }
    finally { this.localBusy=false; this.refreshView(); if (failure.length>0) { this.message=failure; } }
  }
  private archive(id: string, archived: boolean): void {
    this.lifecycle?.archive(id,archived).then(async (): Promise<void> => { await this.reload(); this.message=this.lifecycle?.message ?? ''; }).catch((): void => { this.message='归档状态未确认，资料保留'; });
  }
  private async deleteCurrent(): Promise<void> {
    const id: string = this.deleteId.length > 0 && this.deleteId !== 'selected' ? this.deleteId : this.selectedDocument;
    this.deleteId='';
    try {
      await this.service?.closePreview(); this.previewPath='';
      await this.lifecycle?.deleteDocument(id,true); await this.reload(); this.blocks=[]; this.images=[]; this.occurrences=[]; this.message=this.lifecycle?.message ?? '';
    } catch { this.message='删除或清理未完成；按持久状态保留重试'; }
  }
  private async deleteSelected(): Promise<void> {
    this.deleteId = 'selected';
    await this.removeSelected();
  }
  private async cleanup(): Promise<void> { try { await this.lifecycle?.cleanup(); this.message=this.lifecycle?.message || '本机清理已处理；未知文件未删除'; } catch { this.message='资源释放或清理仍待重试'; } }
  private async retire(id: string): Promise<void> { try { await this.lifecycle?.retire(this.selectedDocument,id,true); this.retiredIds=await this.lifecycle?.retired(this.selectedDocument) ?? []; this.message='旧版本文件已清理；历史文本保留'; } catch { this.message='旧版本仍在使用，暂未清理'; } }
  private async releaseUnknown(): Promise<void> { const id=this.releaseId; this.releaseId=''; try { await this.lifecycle?.releaseUnknown(id,true); this.unknownIds=await this.lifecycle?.unknownResources() ?? []; this.message=this.lifecycle?.message ?? ''; } catch { this.message='本机文件仍未释放，可重试；未确认云端状态'; } }
  private pageBy(delta: number): void { this.page = Math.max(0,Math.min(Math.max(0,Math.ceil(this.blockCount/12)-1),this.page+delta)); this.refreshView(); }
  private searchLocal(): void {
    const q: string = this.question.trim(); this.directText = q.length === 0 ? '' : this.service?.state.chunks.filter((c: ParsedTextChunk): boolean => c.text.includes(q)).map((c: ParsedTextChunk): string => `${c.evidence} · ${c.blockId || c.occurrenceId}\n${c.text}`).join('\n\n') || '当前文档没有正文/OCR字面命中';
  }
  private async preview(id: string): Promise<void> {
    try {
      this.previewPath = await this.service?.previewImage(id) ?? '';
      this.previewId = id;
      const ready: ParsedImageAsset[] = this.images.filter((a: ParsedImageAsset): boolean => a.state === 'Ready');
      this.fullscreenPaths = ready.map((a: ParsedImageAsset): string => a.id === id ? this.previewPath : '').filter((p: string): boolean => p.length > 0);
      this.fullscreenIndex = 0; this.fullscreenOpen = this.previewPath.length > 0;
    } catch { this.previewPath = ''; this.message = '图片缺失或读回不一致，未打开'; }
  }
  private previewPathFor(assetId: string): string {
    const found: ParsedAssetPreview | undefined = this.imagePreviews.find((p: ParsedAssetPreview): boolean => p.assetId === assetId);
    return found?.path ?? '';
  }
  private readyImages(): ParsedImageAsset[] { return this.images.filter((a: ParsedImageAsset): boolean => a.state === 'Ready'); }
  private async loadImagePreviews(): Promise<void> {
    const ready: ParsedImageAsset[] = this.readyImages();
    this.imagesLoading = true;
    try {
      if (ready.length === 0) { this.imagePreviews = []; await this.service?.closePreview(); return; }
      this.imagePreviews = await this.service?.previewImages(ready.map((a: ParsedImageAsset): string => a.id)) ?? [];
    } catch { this.imagePreviews = []; this.message = '部分图片暂时无法预览，原文与标注仍保留'; }
    finally { this.imagesLoading = false; }
  }
  private async toggleImages(): Promise<void> {
    this.imagesOpen = !this.imagesOpen;
    if (!this.imagesOpen) { this.imagePreviews = []; await this.service?.closePreview(); return; }
    await this.loadImagePreviews();
  }
  private async imagePageBy(delta: number): Promise<void> {
    this.imagePage = Math.max(0, Math.min(Math.max(0, Math.ceil(this.imageCount / 9) - 1), this.imagePage + delta));
    this.refreshView();
    if (this.imagesOpen) { await this.loadImagePreviews(); }
  }
  private openImageFullscreen(assetId: string): void {
    const ready: ParsedImageAsset[] = this.readyImages();
    const at: number = ready.findIndex((a: ParsedImageAsset): boolean => a.id === assetId);
    const paths: string[] = [];
    for (const image of ready) { const path: string = this.previewPathFor(image.id); if (path.length > 0) { paths.push(path); } }
    if (paths.length === 0) { this.message = '图片暂时无法打开'; return; }
    this.fullscreenPaths = paths;
    this.fullscreenIndex = Math.max(0, Math.min(paths.length - 1, at));
    this.fullscreenOpen = true;
  }
  private fullscreenBy(delta: number): void { this.fullscreenIndex = Math.max(0, Math.min(this.fullscreenPaths.length - 1, this.fullscreenIndex + delta)); }
  private askConfirm(action: string, title: string, message: string, label: string, danger: boolean): void {
    this.confirmAction = action; this.confirmTitle = title; this.confirmMessage = message; this.confirmLabel = label; this.confirmDanger = danger; this.confirmOpen = true;
  }
  private closeConfirm(): void { this.confirmOpen = false; this.confirmAction = ''; }
  private runConfirm(): void {
    const action: string = this.confirmAction;
    this.confirmOpen = false; this.confirmAction = '';
    if (action === 'archive') { const archived: boolean = this.selectedRecord()?.archived ?? false; this.archive(this.selectedDocument, !archived); return; }
    if (action === 'delete') { this.deleteSelected().catch((): void => { this.message = '删除未完成，资料保留'; }); return; }
    if (action === 'cleanup') { this.cleanup().catch((): void => { this.message = '清理未完成，可重试'; }); return; }
    if (action === 'retire') { this.retire(this.retireId).catch((): void => { this.message = '旧版本清理未完成'; }); return; }
    if (action === 'release') { this.releaseUnknown().catch((): void => { this.message = '释放未完成，可重试'; }); return; }
  }
  private async previewPdfOriginal(): Promise<void> {
    if (this.localBusy || this.parse===undefined) { return; } const context=this.getUIContext().getHostContext(); if (context===undefined) { return; }
    this.localBusy=true;
    try { await this.parse.withPdfOriginal<void>(this.selectedOriginal,async (original: DocumentOriginal): Promise<void>=> { await PdfJsRuntime.shared.preview(documentAssetPath(context.filesDir+'/knowledge_parse_v1',original.assetId),original,new DocumentParseCancellation()); }); }
    catch (error) { this.message=error instanceof Error?error.message:'PDF原件预览未完成'; }
    finally { this.localBusy=false; }
  }
  private async retryPdfPreflight(): Promise<void> {
    if (this.localBusy || this.parse===undefined) { return; }
    this.localBusy=true; this.message='正在本机复核PDF页数；未发送请求';
    try { await this.parse.retryPdfPreflight(this.selectedOriginal); this.message=this.parse.viewState().message; }
    catch (error) { this.message=error instanceof Error?error.message:'PDF本机预检未完成，未发送请求'; }
    finally { this.localBusy=false; this.refreshView(); }
  }
  private async requestParse(): Promise<void> {
    if (this.localBusy) { return; }
    const parse = this.parse; const o: DocumentOriginal | undefined = this.originals.find((row: DocumentOriginal): boolean => row.id === this.parseConsent);
    if (parse === undefined || o === undefined || !this.fullFile || !this.freeEligible) { return; }
    this.localBusy = true; this.message = ''; this.parseConsent = '';
    const current = parse.viewState().snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
    let failure: string = '';
    try {
      if (o.format===DocumentParseFormat.Pdf && current===undefined) { await parse.retryPdfPreflight(o.id); }
      if (o.format === DocumentParseFormat.Docx) { await parse.confirmDocx(o.id,true,true); }
      else if (o.format !== DocumentParseFormat.Pdf) { await this.imports?.preserveImage(parse,o); await parse.confirmImage(o.id,true,true); }
      else { const a: DocumentTestAcknowledgement = new DocumentTestAcknowledgement(); a.fullFile = true; a.embeddedImages = true; a.nonSensitive = true; a.privacyUnknown = true; a.freeEligible = true; await parse.confirm(o.id,a); }
      await parse.setEnabled(true); if (current === undefined) { await parse.submit(o.id); } else { await parse.resume(current.id,true); }
      const snapshot = parse.viewState().snapshot; const completed: DocumentParseTask | undefined = snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
      const result: DocumentParseResultEnvelope | undefined = snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === completed?.id && r.originalHash === o.hash && r.version === o.version);
      if (result !== undefined) { await this.imports?.consume(parse,result.assetId); this.selectedDocument = this.service?.state.document.documentKey ?? ''; }
      this.message=parse.viewState().message;
    } catch (error) { failure = error instanceof Error ? error.message : '解析请求未完成'; }
    finally { this.localBusy = false; this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  build() {
    Stack() {
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          Button({ type: ButtonType.Circle }) {
            Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
          }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('upd-back').enabled(!this.localBusy)
            .accessibilityText('返回')
            .onClick((): void => { if (this.selectedDocument.length > 0 || this.selectedOriginal.length > 0) { this.backToList(); } else { this.onBack(); } })
          Column({ space: 3 }) {
            Text(this.selectedDocument.length > 0 || this.selectedOriginal.length > 0 ? '资料详情' : '我的资料').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
            Text(this.selectedDocument.length > 0 || this.selectedOriginal.length > 0 ? '保存在本机 · 未同步' : `${this.library.length} 份资料 · 保存在本机`).fontColor(Theme.muted).fontSize(12).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')
        if (this.entryFailure.length > 0 || this.message.length > 0) {
          Row({ space: 8 }) {
            AppIcon({ source: $r('app.media.chat_info'), size: 18 })
            Text(this.entryFailure || this.message).fontColor(Theme.ink).id('upd-status').fontSize(13).lineHeight(21).layoutWeight(1)
          }.width('100%').padding(12).backgroundColor(Theme.warning).borderRadius(14).border({ width: 1, color: Theme.warningLine })
        }
        if (this.contentLoading) { Row({ space: 10 }) { LoadingProgress().width(22).height(22).color(Theme.accent); Text('正在读取当前文件…').fontColor(Theme.ink).id('upd-content-loading').fontSize(14) } }
        if (this.localBusy || (this.service?.state.busy ?? false)) {
          Row({ space: 10 }) {
            LoadingProgress().width(22).height(22).color(Theme.accent)
            Text('正在处理，请稍候…').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
            Button('暂停处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-processing-pause').onClick((): void => { this.service?.pause(); this.parse?.pause(); })
          }.width('100%').padding(12).backgroundColor(Theme.surface).borderRadius(14).border({ width: 1, color: Theme.line })
        }
        if (this.selectedDocument.length === 0 && this.selectedOriginal.length === 0) {
          this.libraryView()
        } else {
          this.detailView()
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
        .bindContentCover(this.fullscreenOpen, this.fullscreenViewer, {
          modalTransition: ModalTransition.DEFAULT,
          onWillDismiss: (action: DismissContentCoverAction): void => { this.fullscreenOpen = false; action.dismiss(); }
        })
    }.width('100%')
      .bindContentCover(this.confirmOpen, this.confirmSheet, {
        modalTransition: ModalTransition.DEFAULT,
        onWillDismiss: (action: DismissContentCoverAction): void => { this.confirmOpen = false; this.confirmAction = ''; action.dismiss(); }
      })
  }
  @Builder
  libraryView() {
    Column({ space: 12 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          AppIcon({ source: $r('app.media.ui_import'), size: 18 })
          Text(this.importOpen ? '收起导入选项' : '导入新资料').fontColor(this.importOpen ? Theme.accent : Color.White).fontSize(14).fontWeight(FontWeight.Medium)
        }.padding({ left: 18, right: 18, top: 12, bottom: 12 })
      }.id('upd-import').width('100%').backgroundColor(this.importOpen ? Theme.soft : Theme.accent).borderRadius(14)
        .constraintSize({ minHeight: 48 }).enabled(!this.localBusy && this.service !== undefined)
        .onClick((): void => { this.importOpen = !this.importOpen; })
      if (this.importOpen) {
        Column({ space: 10 }) {
          Row() { Text('选择资料类型').fontColor(Theme.ink).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1); Button('取消').fontSize(13).fontColor(Theme.muted).backgroundColor(Color.Transparent).onClick((): void => { this.importOpen = false; }) }.width('100%')
          FeatureRow({ title: '文本文档', description: 'TXT / Markdown · 本机解析', icon: $r('app.media.ui_document'), id: 'upd-select-text', available: !this.localBusy, onOpen: (): void => { this.select('Text'); } })
          FeatureRow({ title: 'PDF 文档', description: '解析正文与内嵌图片', icon: $r('app.media.chat_book'), id: 'upd-select-pdf', available: !this.localBusy && this.parse !== undefined, onOpen: (): void => { this.select('Pdf'); } })
          FeatureRow({ title: '图片', description: 'JPG / PNG / WebP · 图片与文字', icon: $r('app.media.chat_book'), id: 'upd-select-image', available: !this.localBusy && this.parse !== undefined, onOpen: (): void => { this.select('Image'); } })
          FeatureRow({ title: 'Word 文档', description: 'DOCX · 正文与内嵌图片', icon: $r('app.media.ui_document'), id: 'upd-select-docx', available: !this.localBusy && this.parse !== undefined, onOpen: (): void => { this.select('Docx'); } })
        }.width('100%')
      }
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          AppIcon({ source: $r('app.media.ui_search'), size: 18 })
          TextInput({ text: this.filterText, placeholder: '按文件名查找资料', controller: this.filterController }).fontColor(Theme.ink).backgroundColor(Color.Transparent).fontSize(15).layoutWeight(1).id('upd-library-filter')
            .onChange((v: string): void => { this.filterText = v; this.libraryPage = 0; this.refreshLibrary(); })
        }.width('100%').padding({ left: 12, right: 12 }).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line })
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Button('最近导入').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1)
              .backgroundColor(this.sortMode === 'time' ? Theme.accent : Theme.soft).fontColor(this.sortMode === 'time' ? Color.White : Theme.accent)
              .onClick((): void => { this.setSort('time'); })
            Button('按名称').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1)
              .backgroundColor(this.sortMode === 'name' ? Theme.accent : Theme.soft).fontColor(this.sortMode === 'name' ? Color.White : Theme.accent)
              .onClick((): void => { this.setSort('name'); })
            Button(this.viewMode === 'folders' ? '分类中' : '分类').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1)
              .backgroundColor(this.viewMode === 'folders' ? Theme.accent : Theme.soft).fontColor(this.viewMode === 'folders' ? Color.White : Theme.accent)
              .onClick((): void => { this.setView(this.viewMode === 'folders' ? 'list' : 'folders'); })
          }.width('100%')
          Row() {
            Button(this.includeArchived ? '隐藏归档' : '查看归档').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 14, right: 14 }).id('upd-library-archived')
              .backgroundColor(this.includeArchived ? Theme.accent : Theme.soft).fontColor(this.includeArchived ? Color.White : Theme.accent)
              .onClick((): void => { this.includeArchived = !this.includeArchived; this.libraryPage = 0; this.refreshLibrary(); })
            Blank()
            Button('解析设置').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 14, right: 14 }).fontColor(Theme.accent).backgroundColor(Theme.soft).id('upd-parse-tasks').onClick(this.onParseTasks)
          }.width('100%')
        }.width('100%')
      }.width('100%').padding(14).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
      if (this.library.length === 0) {
        Column({ space: 12 }) {
          Stack() { AppIcon({ source: $r('app.media.ui_folder'), size: 26 }) }.width(56).height(56).backgroundColor(Theme.soft).borderRadius(18)
          Text(this.filterText.length > 0 ? '没有找到这份资料' : '还没有资料').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium)
          Text(this.filterText.length > 0 ? '换个关键词试试，或查看归档资料。' : '导入第一份资料，之后就能在这里阅读与搜索。').fontColor(Theme.muted).fontSize(13).textAlign(TextAlign.Center)
        }.width('100%').padding({ top: 26, bottom: 26 }).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      } else if (this.viewMode === 'folders' && this.folder.length === 0) {
        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
          ForEach(this.libraryFolders(), (item: ParsedLibraryFolder) => {
            Button({ type: ButtonType.Normal }) {
              Column({ space: 10 }) {
                Row() {
                  Stack() { AppIcon({ source: this.folderIcon(item.name), size: 24 }) }.width(44).height(44).backgroundColor(Theme.soft).borderRadius(14)
                  Blank()
                  Text(String(item.count)).fontSize(12).fontColor(Theme.accent).padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(10)
                }.width('100%')
                Text(item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).width('100%').textAlign(TextAlign.Start)
                Text('打开文件夹').fontSize(12).fontColor(Theme.muted).width('100%').textAlign(TextAlign.Start)
              }.width('100%').padding(14).alignItems(HorizontalAlign.Start)
            }.width('44%').margin({ right: '2%', bottom: 10 }).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
              .accessibilityText(`${item.name}，${item.count} 份资料`).onClick((): void => { this.openFolder(item.name); })
          }, (item: ParsedLibraryFolder): string => item.name)
        }.width('100%')
      } else {
        if (this.folder.length > 0) {
          Row({ space: 8 }) {
            Button('‹ 全部分类').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12 }).onClick((): void => { this.folder = ''; this.libraryPage = 0; })
            Text(this.folder).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
            Text(`${this.libraryRows().length} 份`).fontSize(12).fontColor(Theme.muted)
          }.width('100%')
        }
        ForEach(this.visibleLibrary(), (item: ParsedLibraryItem) => {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 12 }) {
              Stack() { AppIcon({ source: this.fileIcon(item), size: 22 }) }.width(44).height(44).backgroundColor(Theme.soft).borderRadius(14)
              Column({ space: 5 }) {
                Text(item.title).fontColor(Theme.ink).fontSize(16).fontWeight(FontWeight.Medium).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.status).fontColor(Theme.muted).fontSize(12).lineHeight(19).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                Row({ space: 8 }) {
                  Text(item.category).fontSize(11).fontColor(Theme.accent).padding({ left: 8, right: 8, top: 3, bottom: 3 }).backgroundColor(Theme.soft).borderRadius(8)
                  if (this.timeText(item).length > 0) { Text(this.timeText(item)).fontSize(11).fontColor(Theme.muted) }
                }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              AppIcon({ source: $r('app.media.ui_chevron_right'), size: 18 })
            }.width('100%').padding(14)
          }.id('upd-file-' + item.id).width('100%').backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
            .accessibilityText(item.title + '，' + item.category + '，' + item.status).accessibilityGroup(true)
            .onClick((): void => { this.openItem(item); })
        }, (item: ParsedLibraryItem): string => item.id + '|' + item.status)
        if (this.libraryRows().length > this.libraryPageSize()) {
          Row({ space: 10 }) {
            Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.libraryPage > 0).onClick((): void => { this.libraryBy(-1); })
            Text(`${this.libraryPage + 1} / ${this.libraryPageCount()}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.libraryPage + 1 < this.libraryPageCount()).onClick((): void => { this.libraryBy(1); })
          }.width('100%')
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  detailView() {
    Column({ space: 14 }) {
      if (this.selectedOriginal.length > 0) {
        Column({ space: 10 }) {
          Text(this.selectedStatus()).fontColor(Theme.ink).id('upd-file-status').fontSize(14).width('100%')
          if (this.originals.some((o: DocumentOriginal): boolean=>o.id===this.selectedOriginal && o.format===DocumentParseFormat.Pdf)) {
            Button('查看PDF原件').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({minHeight:44}).width('100%').id('upd-preview-pdf-original').enabled(!this.localBusy).onClick((): void=> { this.previewPdfOriginal(); })
          }
          if (this.originals.some((o: DocumentOriginal): boolean=>o.id===this.selectedOriginal && o.format===DocumentParseFormat.Pdf) && !this.tasks.some((t: DocumentParseTask): boolean=>t.originalId===this.selectedOriginal)) {
            Button('仅重试本机PDF预检（不发送）').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-retry-pdf-preflight').enabled(!this.localBusy).onClick((): void=> { this.retryPdfPreflight(); })
          }
          if (this.selectedResult() !== undefined && (this.selectedDocument.length === 0 || this.parsedEngine !== 'MinerU')) {
            Button('保存到知识库').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-save-result').enabled(!this.localBusy).onClick((): void => { this.saveSelected(); })
          } else if (this.selectedResult() === undefined && !this.parseInterrupted()) {
            Button('解析这份文件').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-parse-selected').enabled(!this.localBusy).onClick((): void => { this.parseConsent = this.selectedOriginal; })
          }
        }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
      }
      if (this.parseInterrupted()) {
        Column({ space: 10 }) {
          Text('云端处理还没结束，原件和上次进度已保留。').fontColor(Theme.ink).fontSize(13).width('100%')
          Button('核对并继续原任务').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-resume-parse').enabled(!this.localBusy).onClick((): void=> { this.parseConsent='resume'; })
        }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
      }
      if (this.parseConsent === 'resume') {
        Column({ space: 10 }) {
          Text('继续使用当前账号查看原任务。只有在服务明确仍需要文件时，才会对同一份原件补传一次；可能产生流量或费用，不会新建任务。').fontColor(Theme.ink).fontSize(13).lineHeight(21).width('100%')
          Row({ space: 10 }) {
            Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void=> { this.parseConsent=''; })
            Button('继续').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-confirm-resume-parse').onClick((): void=> { this.resumeParse(); })
          }.width('100%')
        }.width('100%').padding(16).backgroundColor(Theme.warning).borderRadius(16).border({ width: 1, color: Theme.warningLine })
      } else if (this.parseConsent.length > 0) {
        Column({ space: 10 }) {
          Text('这份文件会发送到云端解析服务，请确认不含敏感信息，并确认本次有免费解析资格。').fontColor(Theme.ink).fontSize(13).lineHeight(21).width('100%')
          Row({ space: 10 }) {
            Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.parseConsent = ''; })
            Button('同意发送并解析').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-confirm-parse').enabled(!this.localBusy).onClick((): void => { this.fullFile = true; this.freeEligible = true; this.requestParse(); })
          }.width('100%')
        }.width('100%').padding(16).backgroundColor(Theme.warning).borderRadius(16).border({ width: 1, color: Theme.warningLine })
      }
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Text('内容预览').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
          if (this.blockCount > 0) { Text(`${this.blockCount} 段`).fontSize(12).fontColor(Theme.muted) }
          if (this.contentOpen) { Button('收起').fontSize(12).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 36 }).padding({ left: 10, right: 10 }).onClick((): void => { this.contentOpen = false; }) }
        }.width('100%')
        if (this.blockCount === 0 && !this.contentLoading) {
          Text(this.imageCount > 0 ? '这份资料包含 ' + String(this.imageCount) + ' 张图片，可在下方展开查看。' : '当前文件暂无正文，可查看处理状态或图片。').fontColor(Theme.muted).fontSize(14).lineHeight(22).width('100%')
        }
        ForEach((this.contentOpen ? this.blocks : this.blocks.slice(0, 3)), (b: ParsedBlock) => {
          Column({ space: 5 }) {
            if (b.evidenceType !== 'SourceContextOnly' && b.text.length > 0 && b.inlines.length === 0) { Text(this.displayText(b.text)).fontColor(Theme.ink).lineHeight(27).fontSize(16).maxLines(this.contentOpen ? 1000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.LocalDevice).width('100%') }
            if (b.kind === 'Formula') { Text(b.formula.text || b.formula.latex || b.formula.unsupportedReason).fontColor(Theme.ink).width('100%') }
            if (b.limitation.length > 0) { Text(b.limitation).fontColor(Theme.muted).fontSize(13).width('100%') }
            ForEach(b.inlines, (r: ParsedInline) => { if (r.kind !== 'Text' || b.evidenceType !== 'SourceContextOnly') { Text(r.kind === 'Text' ? this.displayText(r.text) : r.kind === 'Formula' ? r.formula.text || r.formula.latex || r.formula.unsupportedReason : r.kind === 'Image' ? '〔图片〕' : r.limitation).fontColor(Theme.ink).fontSize(16).maxLines(this.contentOpen ? 1000 : 4).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%') } }, (r: ParsedInline): string => this.selectedDocument+'|'+this.contentGeneration+'|'+b.id+'|'+r.id)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }, (b: ParsedBlock): string => this.selectedDocument+'|'+this.contentGeneration+'|'+b.id)
        if (this.blockCount > 3) {
          Button(this.contentOpen ? '收起全文' : `阅读全文（${this.blockCount} 段）`).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').onClick((): void => { this.contentOpen = !this.contentOpen; })
        }
        if (this.contentOpen && this.blockCount > 12) {
          Row({ space: 10 }) {
            Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.page > 0).onClick((): void => { this.pageBy(-1); })
            Text(`${this.page + 1} / ${Math.ceil(this.blockCount / 12)}`).fontColor(Theme.ink).fontSize(13).layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled((this.page + 1) * 12 < this.blockCount).onClick((): void => { this.pageBy(1); })
          }.width('100%')
        }
        if (!this.contentLoading && this.blocks.length===0 && this.message.length>0) { Button('重试打开内容').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-content-retry').onClick((): void=> { this.open(this.selectedDocument); }) }
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      if (this.imageCount > 0) {
        Column({ space: 12 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              Text('文件中的图片').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
              Text(`${this.imageCount} 张`).fontSize(12).fontColor(Theme.muted)
              Text(this.imagesOpen ? '收起' : '展开').fontSize(12).fontColor(Theme.accent)
            }.width('100%').padding({ top: 2, bottom: 2 })
          }.width('100%').backgroundColor(Color.Transparent).id('upd-images-toggle').onClick((): void => { this.toggleImages().catch((): void => { this.message = '图片预览打开未完成'; }); })
          if (this.imagesOpen) {
            if (this.imagesLoading) { Row({ space: 10 }) { LoadingProgress().width(20).height(20).color(Theme.accent); Text('正在准备图片预览…').fontSize(13).fontColor(Theme.muted) } }
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.images, (a: ParsedImageAsset) => {
                Stack() {
                  if (a.state === 'Ready' && this.previewPathFor(a.id).length > 0) {
                    Image(this.previewPathFor(a.id)).objectFit(ImageFit.Contain).width('100%').height('100%')
                  } else {
                    Column({ space: 6 }) {
                      AppIcon({ source: $r('app.media.chat_book'), size: 20 })
                      Text(a.state === 'Ready' ? '无法预览' : '暂不可用').fontSize(10).fontColor(Theme.muted)
                    }.justifyContent(FlexAlign.Center).width('100%').height('100%')
                  }
                }.width('31%').aspectRatio(1).margin({ right: '2%', bottom: 8 }).backgroundColor(Theme.soft).borderRadius(12).clip(true)
                  .id('upd-preview-' + a.id).accessibilityText('图片预览').onClick((): void => { this.openImageFullscreen(a.id); })
              }, (a: ParsedImageAsset): string => this.selectedDocument+'|'+this.contentGeneration+'|'+a.id)
            }.width('100%')
            if (this.imageCount > 9) {
              Row({ space: 10 }) {
                Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.imagePage > 0).onClick((): void => { this.imagePageBy(-1); })
                Text(`${this.imagePage + 1} / ${Math.ceil(this.imageCount / 9)}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
                Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled((this.imagePage + 1) * 9 < this.imageCount).onClick((): void => { this.imagePageBy(1); })
              }.width('100%')
            }
          }
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      }
      if (this.selectedDocument.length > 0) {
        Column({ space: 12 }) {
          Text('处理状态').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
          Text(this.selectedProcessingStatus()).fontSize(12).fontColor(Theme.muted).lineHeight(19).width('100%')
          Text(this.selectedOriginal.length>0 && this.parsedEngine!=='MinerU' && this.blocks.length===0?'原图已保存，还没有可检索的文字。图片描述与检索准备可在下方任务中查看。':'正文和图片文字已可搜索；完成检索准备后，还能按意思找到相关内容。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          ForEach(this.selectedJobs(),(job: UnifiedProcessingJob)=> {
            Column({space:6}) {
              Text(`${processingStageName(job.stage)} · ${processingJobStateName(job)} · ${job.completed}/${job.expected}`).fontColor(Theme.ink).fontSize(13).width('100%')
              if (processingFailureText(job).length>0) { Text(processingFailureText(job)).fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%') }
              if (processingCanRetry(job)) { Button('重试' + processingStageName(job.stage)).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-retry-job-'+job.id).enabled(!this.processingBusy).onClick((): void=> { this.retryJobId=job.id; }) }
              if (this.retryJobId===job.id) {
                Text('仅重新排队这一项任务，已成功的进度会复用。结果未知的请求可能重复计费。').fontColor(Theme.ink).fontSize(12).lineHeight(20).width('100%')
                Row({ space: 10 }) {
                  Button('取消').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void=> { this.retryJobId=''; })
                  Button('接受可能费用，重试').fontSize(13).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-retry-job-confirm').enabled(!this.processingBusy).onClick((): void=> { this.retryProcessingJob(); })
                }.width('100%')
              }
            }.width('100%').padding(14).backgroundColor(Theme.inputSurface).borderRadius(14).border({ width: 1, color: Theme.line })
          },(job: UnifiedProcessingJob): string=>job.id+'|'+job.state+'|'+String(job.completed)+'|'+job.failure)
          if (this.selectedJobCount()>0 && (this.processingExpanded || this.selectedJobCount()>this.selectedJobs().length)) { Button(this.processingExpanded?'收起处理任务':`查看全部处理任务（${this.selectedJobCount()}）`).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-processing-expand').onClick((): void=> { this.processingExpanded=!this.processingExpanded; }) }
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      }
      Column({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 10 }) {
            Text('处理说明').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
            Text(this.detailsOpen ? '收起' : '查看').fontSize(12).fontColor(Theme.accent)
          }.width('100%')
        }.width('100%').backgroundColor(Color.Transparent).id('upd-details-toggle').onClick((): void => { this.detailsOpen = !this.detailsOpen; })
        if (this.detailsOpen) {
          Text('这些信息用来解释这份资料是怎么变成可搜索内容的；不会显示内部编号，也不会重新上传原件。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          if (this.parseUsage().length > 0) { Text(this.parseUsage()).fontColor(Theme.ink).id('upd-parse-usage').fontSize(13).lineHeight(21).width('100%') }
          if (this.coverageSummary().length > 0) { Text(this.coverageSummary()).fontColor(Theme.ink).fontSize(13).lineHeight(21).width('100%') }
          if (this.selectedResult() !== undefined) { Button('重新整理已接收内容').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-rebuild-selected').enabled(!this.localBusy).onClick((): void => { this.consume(this.selectedResult()?.assetId ?? '', true); }) }
          if (this.taskStage === 'Failed' || this.taskStage === 'Paused') { Button('重试保存内容').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-retry-local').onClick((): void => { this.retryLocal(); }) }
          Row({ space: 10 }) {
            Button('暂停自动处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-queue-pause').onClick((): void => { this.queue?.pause(); })
            Button('继续自动处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).id('upd-queue-resume').onClick((): void => { this.queue?.resume(); })
          }.width('100%')
          Button('释放未使用的本机文件').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-cleanup-retry').onClick((): void => { this.askConfirm('cleanup', '清理本机临时文件？', '只会清理本机可释放的临时文件，不会删除你的资料，也不会影响云端。', '开始清理', false); })
        }
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      if (this.selectedDocument.length > 0 || this.selectedOriginal.length > 0) {
        Column({ space: 10 }) {
          if (this.selectedDocument.length > 0) {
            Button((this.selectedRecord()?.archived ? '恢复这份资料' : '归档这份资料')).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-archive-selected').enabled(!this.localBusy).onClick((): void => {
              const archived: boolean = this.selectedRecord()?.archived ?? false;
              if (archived) { this.archive(this.selectedDocument, false); }
              else { this.askConfirm('archive', '归档这份资料？', '归档后它不会出现在默认列表中，但资料、正文和图片都会保留，可随时恢复。', '归档', false); }
            })
          }
          Button('删除这份资料').fontSize(14).fontColor(Theme.danger).backgroundColor(Theme.warning).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-delete-selected').enabled(!this.localBusy).onClick((): void => {
            this.askConfirm('delete', '确定删除这份资料？', '会删除本机保存的正文、图片与解析内容；共享图片仍由其他资料保留。此操作无法撤销。', '删除资料', true);
          })
        }.width('100%').padding(14).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  confirmSheet() {
    Column() {
      Column({ space: 14 }) {
        Text(this.confirmTitle).fontColor(Theme.ink).fontSize(19).fontWeight(FontWeight.Medium).width('100%')
        Text(this.confirmMessage).fontColor(Theme.muted).fontSize(14).lineHeight(22).width('100%')
        Row({ space: 10 }) {
          Button('取消').fontSize(14).fontColor(Theme.ink).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 46 }).layoutWeight(1).onClick((): void => { this.closeConfirm(); })
          if (this.confirmAction === 'delete') {
            Button(this.confirmLabel).fontSize(14).fontColor(Color.White).backgroundColor(Theme.danger).borderRadius(12).constraintSize({ minHeight: 46 }).layoutWeight(1).id('upd-delete-confirm').onClick((): void => { this.runConfirm(); })
          } else {
            Button(this.confirmLabel).fontSize(14).fontColor(Color.White).backgroundColor(this.confirmDanger ? Theme.danger : Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).layoutWeight(1).id('upd-confirm-action').onClick((): void => { this.runConfirm(); })
          }
        }.width('100%')
      }.width('100%').padding(22).backgroundColor(Theme.surface).borderRadius(22).border({ width: 1, color: Theme.line })
    }.width('100%').height('100%').padding(24).justifyContent(FlexAlign.Center).backgroundColor('#66000000')
  }
  @Builder
  fullscreenViewer() {
    Column() {
      Row({ space: 10 }) {
        Text(`第 ${this.fullscreenIndex + 1} / ${this.fullscreenPaths.length} 张`).fontColor(Color.White).fontSize(14).layoutWeight(1)
        Button('关闭').fontSize(14).fontColor(Color.White).backgroundColor('#33FFFFFF').borderRadius(12).constraintSize({ minHeight: 44 }).id('upd-image-fullscreen-close').onClick((): void => { this.fullscreenOpen = false; })
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
      Stack() {
        if (this.fullscreenPaths.length > this.fullscreenIndex) {
          Image(this.fullscreenPaths[this.fullscreenIndex]).objectFit(ImageFit.Contain).width('100%').height('100%')
        }
      }.layoutWeight(1).width('100%').onClick((): void => { this.fullscreenOpen = false; })
      Row({ space: 12 }) {
        Button('上一张').fontSize(14).fontColor(Color.White).backgroundColor('#33FFFFFF').borderRadius(12).constraintSize({ minHeight: 46 }).layoutWeight(1).enabled(this.fullscreenIndex > 0).onClick((): void => { this.fullscreenBy(-1); })
        Button('下一张').fontSize(14).fontColor(Color.White).backgroundColor('#33FFFFFF').borderRadius(12).constraintSize({ minHeight: 46 }).layoutWeight(1).enabled(this.fullscreenIndex + 1 < this.fullscreenPaths.length).onClick((): void => { this.fullscreenBy(1); })
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 20 })
    }.width('100%').height('100%').backgroundColor('#FF111111')
  }
}
class ParsedViewParseListener implements DocumentParseStateListener {
  private callback: () => void;
  constructor(callback: () => void) { this.callback = callback; }
  changed(): void { this.callback(); }
}
