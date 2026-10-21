import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { ParsedDocumentImportAdapter } from '../infra/ParsedDocumentImportAdapter';
import { ParsedDocumentRecord, ParsedBlock, ParsedInline, ParsedImageOccurrence, ParsedTextChunk, ParsedImageAsset } from '../domain/ParsedDocumentModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { DocumentOriginal, DocumentParseResultEnvelope, DocumentParseFormat, DocumentParseTask, DocumentTestAcknowledgement, DocumentParseStateListener } from '../domain/DocumentParseModels';
import { Theme } from '../../components/Theme';
import { ParsedDocumentLifecycle } from '../application/KnowledgeLifecycleService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';

@Component
export struct ParsedDocumentView {
  lifecycle: ParsedDocumentLifecycle | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  onRetryProcessing: () => void=(): void=>{};
  @Prop @Watch('bindServices') service: ParsedDocumentIngestionService | undefined = undefined;
  @Prop imports: ParsedDocumentImportAdapter | undefined = undefined;
  @Prop @Watch('bindServices') parse: DocumentParseService | undefined = undefined;
  @Prop opening: boolean = false;
  @Prop entryFailure: string = '';
  onRetry: () => void = (): void => {};
  onBack: () => void = (): void => {};
  onParseTasks: () => void = (): void => {};
  @State documents: ParsedDocumentRecord[] = [];
  @State originals: DocumentOriginal[] = [];
  @State results: DocumentParseResultEnvelope[] = [];
  @State blocks: ParsedBlock[] = [];
  @State occurrences: ParsedImageOccurrence[] = [];
  @State images: ParsedImageAsset[] = [];
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
  private async refreshResources(): Promise<void> { const ids=await this.lifecycle?.unknownResources() ?? []; if (this.alive) { this.unknownIds=ids; } }
  private listener: () => void = (): void => { this.refreshView(); };
  private parseListener: ParsedViewParseListener = new ParsedViewParseListener((): void => { this.refreshView(); });
  bindServices(): void {
    if (!this.alive) { return; }
    if (this.boundService !== this.service) { this.boundService?.unsubscribe(this.listener); this.boundService = this.service; this.boundService?.subscribe(this.listener); }
    if (this.boundParse !== this.parse) { this.boundParse?.unsubscribe(this.parseListener); this.boundParse = this.parse; this.boundParse?.subscribe(this.parseListener); }
    this.refreshView();
  }
  aboutToAppear(): void { this.alive = true; this.queue?.subscribe(this.resourceListener); this.bindServices(); this.reload(); }
  aboutToDisappear(): void { this.alive = false; this.queue?.unsubscribe(this.resourceListener); this.boundService?.unsubscribe(this.listener); this.boundParse?.unsubscribe(this.parseListener); this.boundService?.closePreview().catch((): void => {}); this.boundService = undefined; this.boundParse = undefined; this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; }
  private refreshView(): void {
    if (!this.alive || this.service === undefined) { return; }
    const state = this.service.state; this.documents = state.documents.slice(); this.title = state.document.title; this.taskStage = state.stage;
    this.message = state.message; this.blockCount = state.document.blocks?.length ?? 0;
    this.blocks = state.document.blocks?.slice(this.page*12,this.page*12+12) ?? [];
    this.occurrenceCount = state.document.occurrences.length; this.imageCount = state.document.images.length;
    this.occurrences = state.document.occurrences.slice(this.occurrencePage*12,this.occurrencePage*12+12); this.images = state.document.images.slice(this.imagePage*12,this.imagePage*12+12);
    this.identityText = `${state.document.engine} · ${state.document.parser_signature}\n${state.document.source_hash}`;
    this.coverageText = `产物 ${state.document.coverage.selectedOutput.state} · 原生定位 ${state.document.coverage.nativeLocation.state} · 图片 ${state.document.coverage.imageRecovery.recovered}/${state.document.coverage.imageRecovery.expected} · 增强 ${state.enhancement}`;
    const parse = this.parse?.viewState().snapshot; this.originals = parse?.originals.filter((o: DocumentOriginal): boolean => [DocumentParseFormat.Pdf,DocumentParseFormat.Docx,DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(o.format) >= 0) ?? [];
    this.results = parse?.results.slice() ?? [];
  }
  private async reload(): Promise<void> { try { await this.service?.refresh(); this.unknownIds=await this.lifecycle?.unknownResources() ?? []; this.refreshView(); } catch { this.message = '统一仓储读取失败，未当作空库'; } }
  private async retryLocal(): Promise<void> { try { await this.service?.retryLocal(); this.refreshView(); } catch { this.message = '已存快照尚不完整；请重新选择已收结果执行本机处理，未重新解析或外发'; } }
  private async select(kind: string): Promise<void> {
    if (this.localBusy) { return; } this.localBusy = true; let failure: string = '';
    try {
      if (kind === 'Text') { await this.imports?.importText(); }
      else { const parse = this.parse; if (parse !== undefined) { const old: string[] = parse.viewState().snapshot.originals.map((o: DocumentOriginal): string => o.id); await parse.prepare(kind === 'Image',kind === 'Docx'); if (kind === 'Image') { for (const o of parse.viewState().snapshot.originals) { if (old.indexOf(o.id)<0 && [DocumentParseFormat.Jpeg,DocumentParseFormat.Png,DocumentParseFormat.Webp].indexOf(o.format) >= 0) { await this.imports?.preserveImage(parse,o); } } } } }
      this.page = 0; await this.reload();
    } catch (error) { failure = error instanceof Error ? error.message : '本机导入失败，原件保留'; }
    finally { this.localBusy = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  private async consume(id: string, rebuild: boolean = false): Promise<void> {
    if (this.localBusy || this.parse === undefined || this.imports === undefined) { return; } this.localBusy = true;
    let failure: string = '';
    try { await this.imports.consume(this.parse,id,rebuild); this.page = 0; }
    catch (error) { failure = error instanceof Error ? error.message : '本机产物处理失败'; }
    finally { this.localBusy = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  private async open(id: string): Promise<void> { try { this.page = 0; this.selectedDocument=id; await this.service?.open(id); this.retiredIds=await this.lifecycle?.retired(id) ?? []; this.refreshView(); } catch { this.message = '当前快照不可读；可重试，原件保留'; } }
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
    const parse = this.parse; const o: DocumentOriginal | undefined = this.originals.find((row: DocumentOriginal): boolean => row.id === this.parseConsent);
    if (parse === undefined || o === undefined || !this.fullFile || !this.freeEligible) { return; }
    const current = parse.viewState().snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
    let failure: string = '';
    try {
      if (o.format === DocumentParseFormat.Docx) { await parse.confirmDocx(o.id,true,true); }
      else if (o.format !== DocumentParseFormat.Pdf) { await this.imports?.preserveImage(parse,o); await parse.confirmImage(o.id,true,true); }
      else { const a: DocumentTestAcknowledgement = new DocumentTestAcknowledgement(); a.fullFile = true; a.embeddedImages = true; a.nonSensitive = true; a.privacyUnknown = true; a.freeEligible = true; await parse.confirm(o.id,a); }
      await parse.setEnabled(true); if (current === undefined) { await parse.submit(o.id); } else { await parse.resume(current.id,true); }
      const snapshot = parse.viewState().snapshot; const completed: DocumentParseTask | undefined = snapshot.tasks.find((t: DocumentParseTask): boolean => t.originalId === o.id && t.hash === o.hash && t.version === o.version);
      const result: DocumentParseResultEnvelope | undefined = snapshot.results.find((r: DocumentParseResultEnvelope): boolean => r.taskId === completed?.id && r.originalHash === o.hash && r.version === o.version);
      if (result !== undefined) { await this.imports?.consume(parse,result.assetId); }
    } catch (error) { failure = error instanceof Error ? error.message : '解析请求未完成'; }
    finally { this.parseConsent = ''; this.fullFile = false; this.freeEligible = false; this.refreshView(); if (failure.length > 0) { this.message = failure; } }
  }
  build() {
    Column({ space: 12 }) {
      Row() { Button('返回').id('upd-back').onClick(this.onBack); Text('统一资料').fontSize(20).fontWeight(FontWeight.Medium).layoutWeight(1) }.width('100%')
      Text(this.entryFailure || this.message || this.taskStage).id('upd-status').fontSize(13).width('100%').fontColor(Theme.muted)
      if (this.opening || this.localBusy || (this.service?.state.busy ?? false)) { LoadingProgress().width(28).height(28) }
      if (this.entryFailure.length > 0 || this.service === undefined) { Button('重试打开').id('upd-retry-open').enabled(!this.opening).onClick(this.onRetry) }
      if (this.taskStage==='Failed' || this.taskStage==='Paused') { Button('重试已存发布').id('upd-retry-local').onClick((): void => { this.retryLocal(); }) }
      Row({ space: 8 }) {
        Button('TXT / MD').id('upd-select-text').enabled(!this.localBusy && this.service !== undefined).onClick((): void => { this.select('Text'); })
        Button('PDF').id('upd-select-pdf').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Pdf'); })
        Button('图片').id('upd-select-image').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Image'); })
        Button('DOCX').id('upd-select-docx').enabled(!this.localBusy && this.parse !== undefined).onClick((): void => { this.select('Docx'); })
      }.width('100%')
      Button('解析设置 / 任务').id('upd-parse-tasks').onClick(this.onParseTasks)
      Row() { Button('暂停当前本机处理').id('upd-ingest-pause').onClick((): void=> { this.service?.pause(); }); Button('恢复增强/初始化').id('upd-processing-retry').onClick(this.onRetryProcessing) }.width('100%')
      Row() { Button('暂停自动增强').id('upd-queue-pause').onClick((): void=> { this.queue?.pause(); }); Button('恢复自动增强').id('upd-queue-resume').onClick((): void=> { this.queue?.resume(); }) }.width('100%')
      Button('重试本机释放 / 清理').id('upd-cleanup-retry').onClick((): void=> { this.cleanup(); })
      ForEach(this.originals, (o: DocumentOriginal) => {
        Row() { Text(o.title).layoutWeight(1); Button('解析').id('upd-parse-'+o.id).onClick((): void => { this.parseConsent = o.id; this.fullFile = false; this.freeEligible = false; }) }.width('100%')
      }, (o: DocumentOriginal): string => o.id)
      if (this.parseConsent.length > 0) {
        Text('接收方 MinerU；完整原件（含隐藏内容/元数据/图片）。可能留存；只在本人确认本件非敏感且当前免费资格有效时发送。').fontSize(13).width('100%')
        Row() { Text('确认完整文件、非敏感和未知留存').layoutWeight(1); Toggle({ type: ToggleType.Checkbox, isOn: this.fullFile }).onChange((v: boolean): void => { this.fullFile = v; }) }.width('100%')
        Row() { Text('确认当前账号本件免费资格').layoutWeight(1); Toggle({ type: ToggleType.Checkbox, isOn: this.freeEligible }).onChange((v: boolean): void => { this.freeEligible = v; }) }.width('100%')
        Button('确认解析 / 恢复原任务').id('upd-confirm-parse').enabled(this.fullFile && this.freeEligible).onClick((): void => { this.requestParse(); })
      }
      ForEach(this.results, (r: DocumentParseResultEnvelope) => {
        Column() {
          Button(`保存解析内容 · ${r.assetId}`).id('upd-consume-'+r.assetId).enabled(!this.localBusy).onClick((): void => { this.consume(r.assetId); })
          Button('从已收包本机重建').id('upd-rebuild-'+r.assetId).enabled(!this.localBusy).onClick((): void => { this.consume(r.assetId,true); })
        }.width('100%')
      }, (r: DocumentParseResultEnvelope): string => r.assetId)
      ForEach(this.documents, (d: ParsedDocumentRecord) => {
        Column() {
          Button(`${d.title} · ${d.tombstone?'已删除':d.archived?'归档':'当前'}`).id('upd-document-'+d.id).enabled(!d.tombstone).width('100%').onClick((): void => { this.open(d.id); })
          if (!d.tombstone) { Row() { Button(d.archived?'恢复':'归档').id('upd-archive-'+d.id).onClick((): void=> { this.archive(d.id,!d.archived); }); Button('删除').id('upd-delete-'+d.id).onClick((): void=> { this.deleteId=d.id; }) }.width('100%') }
        }.width('100%')
      }, (d: ParsedDocumentRecord): string => d.id)
      if (this.deleteId.length>0) { Text('确认删除此父文档的统一正文与引用。共享图和其他来源保留；历史证据标失效，旧原件/ZIP由原owner持有，不替你清理旧库。').fontSize(13).width('100%'); Button('确认删除此文档').id('upd-delete-confirm').onClick((): void=> { this.deleteCurrent(); }); Button('取消').onClick((): void=> { this.deleteId=''; }) }
      ForEach(this.retiredIds,(id: string)=> { Button('清理旧代 · '+id).id('upd-retire-'+id).onClick((): void=> { this.retireId=id; }) },(id: string): string=>id)
      if (this.retireId.length>0) { Text('确认退役此旧解析代文件；历史文本证据保留，旧图像不另存副本。').fontSize(13); Button('确认退役旧代').id('upd-retire-confirm').onClick((): void=> { this.retire(this.retireId); this.retireId=''; }); Button('取消').onClick((): void=> { this.retireId=''; }) }
      ForEach(this.unknownIds,(id: string)=> { Button('已删文档 Unknown 持有 · '+id).id('upd-unknown-'+id).onClick((): void=> { this.releaseId=id; }) },(id: string): string=>id)
      if (this.releaseId.length>0) { Text('确认放弃此已删文档的本机结果追踪并释放文件持有。请求账本仍保留；这不等于远端取消或免计费。').fontSize(13); Button('确认仅释放本机持有').id('upd-unknown-release-confirm').onClick((): void=> { this.releaseUnknown(); }); Button('取消').onClick((): void=> { this.releaseId=''; }) }
      Text(this.title).fontSize(18).width('100%')
      Text(this.identityText).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
      Text(this.coverageText).fontSize(12).width('100%')
      Row() { Button('上一页').enabled(this.page>0).onClick((): void => { this.pageBy(-1); }); Text(`${this.page+1} / ${Math.max(1,Math.ceil(this.blockCount/12))}`).layoutWeight(1); Button('下一页').enabled((this.page+1)*12<this.blockCount).onClick((): void => { this.pageBy(1); }) }.width('100%')
      ForEach(this.blocks, (b: ParsedBlock) => {
        Column({ space: 5 }) {
          Text(`${b.order+1} · ${b.kind} · ${b.locator.precision} · ${b.evidenceType}`).fontSize(11).fontColor(Theme.muted).width('100%')
          if (b.text.length>0 && b.inlines.length===0) { Text(b.text).fontSize(15).copyOption(CopyOptions.LocalDevice).width('100%') }
          if (b.kind === 'Formula') { Text(b.formula.text || b.formula.latex || b.formula.unsupportedReason).width('100%') }
          if (b.limitation.length>0) { Text(b.limitation).fontSize(12).width('100%') }
          ForEach(b.inlines, (r: ParsedInline) => { Text(r.kind === 'Text' ? r.text : r.kind === 'Formula' ? r.formula.text || r.formula.latex || r.formula.unsupportedReason : r.kind === 'Image' ? '图片 · '+r.imageOccurrenceId : r.limitation).width('100%') }, (r: ParsedInline): string => r.id)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (b: ParsedBlock): string => b.id)
      ForEach(this.occurrences, (o: ParsedImageOccurrence) => {
        Column({ space: 5 }) {
          Text(`${o.provenance} · ${o.locator.precision} · ${o.blockId || '文件级未知位置'}`).fontSize(12).width('100%')
          Text(o.caption).fontSize(13).width('100%'); Text(o.ocr).fontSize(14).width('100%'); Text(o.limitation).fontSize(12).width('100%')
        }.width('100%')
      }, (o: ParsedImageOccurrence): string => o.id)
      if (this.occurrenceCount>12) {
        Row() { Button('上一组来源').enabled(this.occurrencePage>0).onClick((): void => { this.occurrencePage--; this.refreshView(); }); Button('下一组来源').enabled((this.occurrencePage+1)*12<this.occurrenceCount).onClick((): void => { this.occurrencePage++; this.refreshView(); }) }.width('100%')
      }
      ForEach(this.images, (a: ParsedImageAsset) => {
        Column({ space: 5 }) {
          Text(`${a.mime || '未知格式'} · ${a.state} · ${a.payloadHash}`).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
          Button('打开图片').id('upd-preview-'+a.id).enabled(a.state==='Ready').onClick((): void => { this.preview(a.id); })
          if (this.previewId===a.id && this.previewPath.length>0) { Image(this.previewPath).objectFit(ImageFit.Contain).width('100%').height(220).onError((): void => { this.message = '图片预览解码失败；原字节保留'; }) }
        }.width('100%')
      }, (a: ParsedImageAsset): string => a.id)
      if (this.imageCount>12) {
        Row() { Button('上一组图片').enabled(this.imagePage>0).onClick((): void => { this.imagePage--; this.refreshView(); }); Button('下一组图片').enabled((this.imagePage+1)*12<this.imageCount).onClick((): void => { this.imagePage++; this.refreshView(); }) }.width('100%')
      }
      TextInput({ text: this.question, placeholder: '当前文档正文 / OCR' }).id('upd-local-query').onChange((v: string): void => { this.question = v; })
      Button('查找正文 / OCR').id('upd-local-search').onClick((): void => { this.searchLocal(); })
      Text(this.directText).fontSize(14).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 20 })
  }
}
class ParsedViewParseListener implements DocumentParseStateListener {
  private callback: () => void;
  constructor(callback: () => void) { this.callback = callback; }
  changed(): void { this.callback(); }
}
