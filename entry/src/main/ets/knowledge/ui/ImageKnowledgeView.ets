import { Theme } from '../../components/Theme';
import { ImageKnowledgeService } from '../application/ImageKnowledgeService';
import { ParsedDocumentIngestionService } from '../application/ParsedDocumentIngestionService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { UnifiedImageRecord, UnifiedEffectiveAnnotation } from '../domain/UnifiedKnowledgeModels';

@Component
export struct ImageKnowledgeView {
  @Prop initialOccurrence: string='';
  service: ImageKnowledgeService | undefined=undefined;
  previewService: ParsedDocumentIngestionService | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  onBack: () => void=(): void=>{};
  @State editing: boolean = false;
  @State records: UnifiedImageRecord[]=[];
  @State selected: UnifiedImageRecord=new UnifiedImageRecord();
  @State annotation: UnifiedEffectiveAnnotation=new UnifiedEffectiveAnnotation();
  @State descriptionInput: string='';
  @State tagsInput: string='';
  @State previewPath: string='';
  @State message: string='';
  @State parents: string='';
  @State page: number=0;
  @State total: number=0;
  @State sourceCurrent: boolean=true;
  private listener: () => void=(): void=> { this.refresh(); };
  aboutToAppear(): void { this.queue?.subscribe(this.listener); this.refresh().then(async (): Promise<void>=> { if (this.initialOccurrence.length>0) { const record=(await this.service?.records() ?? []).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===this.initialOccurrence); if (record!==undefined) { await this.open(record); } } }).catch((): void=> { this.message='图片来源读取失败'; }); }
  aboutToDisappear(): void { this.queue?.unsubscribe(this.listener); this.previewService?.closePreview().catch((): void=>{}); }
  private async refresh(): Promise<void> { try { const rows=await this.service?.records() ?? []; this.total=rows.length; this.records=rows.slice(this.page*12,this.page*12+12); if (this.selected.occurrenceId.length>0) { const current=rows.find((r: UnifiedImageRecord): boolean=>r.occurrenceId===this.selected.occurrenceId); this.sourceCurrent=current!==undefined && current.effectiveId===this.selected.effectiveId; if (!this.sourceCurrent) { this.previewPath=''; await this.previewService?.closePreview(); this.message='此来源已换版、归档或删除；保留当时文字，重新选择当前来源'; } } } catch { this.message='图片知识读取失败，未当空库'; } }
  private async open(record: UnifiedImageRecord): Promise<void> {
    this.selected=record; this.sourceCurrent=true; this.editing=false;
    try { this.annotation=await this.service?.effective(record) ?? new UnifiedEffectiveAnnotation(); this.descriptionInput=this.annotation.description; this.tagsInput=this.annotation.tags.join('\n');
      const rows=await this.service?.records() ?? []; this.parents=rows.filter((r: UnifiedImageRecord): boolean=>r.imageHash===record.imageHash && r.effectiveId===record.effectiveId).map((r: UnifiedImageRecord): string=>r.title).join('\n');
      this.previewPath=await this.previewService?.previewImage(record.assetId) ?? ''; this.message='';
    } catch { this.previewPath=''; this.message='当前图片缺失/读回失败，原文OCR与标注保留'; }
  }
  private async save(deleted: boolean=false): Promise<void> {
    try { await this.service?.edit(this.selected.occurrenceId,this.descriptionInput,this.tagsInput.split('\n').filter((t: string): boolean=>t.trim().length>0),deleted); await this.refresh(); const current=(await this.service?.records() ?? []).find((r: UnifiedImageRecord): boolean=>r.occurrenceId===this.selected.occurrenceId); if (current!==undefined) { await this.open(current); } this.message='描述与标签已保存'; this.editing=false; }
    catch { this.message='标注保存失败或版本变化，未覆盖已有修正'; }
  }
  build() {
    Column({space:12}) {
      Row() { Button('返回').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-image-back').onClick(this.onBack); Text('图片详情').fontColor(Theme.ink).fontSize(20).layoutWeight(1) }.width('100%')
      Text(this.message).fontColor(Theme.ink).id('upd-image-status').fontSize(13).width('100%')
      if (this.selected.occurrenceId.length === 0) {
      Row() { Button('上一页').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(this.page>0).onClick((): void=> { this.page--; this.refresh(); }); Button('下一页').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled((this.page+1)*12<this.total).onClick((): void=> { this.page++; this.refresh(); }) }.width('100%')
      ForEach(this.records,(r: UnifiedImageRecord)=> { Button(`${r.title} · ${r.effectiveId==='None'?'待标注':'已标注'}`).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-image-detail-'+r.occurrenceId).width('100%').onClick((): void=> { this.open(r); }) },(r: UnifiedImageRecord): string=>r.occurrenceId)
      }
      if (this.selected.occurrenceId.length>0) {
        if (this.previewPath.length>0) { Image(this.previewPath).objectFit(ImageFit.Contain).width('100%').height(260).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line }) }
        Text(this.parents).fontColor(Theme.ink).fontSize(12).width('100%')
        Text('图片文字').fontColor(Theme.ink).fontSize(15).width('100%'); Text(this.selected.ocr || '未识别到文字').fontColor(Theme.ink).width('100%')
        if (this.selected.caption.length > 0) { Text(this.selected.caption).fontColor(Theme.ink).fontSize(14).width('100%') }
        if (this.annotation.description.length > 0) { Text('图片描述').fontColor(Theme.ink).fontSize(15).width('100%'); Text(this.annotation.description).fontColor(Theme.ink).lineHeight(26).width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(16) }
        if (this.annotation.tags.length > 0) { Text(this.annotation.tags.join(' · ')).fontColor(Theme.ink).fontSize(14).fontColor(Theme.accent).lineHeight(24).width('100%').padding(14).backgroundColor(Theme.soft).borderRadius(14) }
        Button(this.editing ? '取消编辑' : '编辑描述与标签').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-image-edit').enabled(this.sourceCurrent).onClick((): void => { this.editing = !this.editing; })
        if (this.editing) {
        TextArea({text:this.descriptionInput,placeholder:'描述，可删空'}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('upd-image-description').maxLength(4000).onChange((v: string): void=> { this.descriptionInput=v; })
        TextArea({text:this.tagsInput,placeholder:'每行一个标签；移除行即删除标签'}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('upd-image-tags').maxLength(3000).onChange((v: string): void=> { this.tagsInput=v; })
        Button('保存修正').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-image-save').enabled(this.sourceCurrent).onClick((): void=> { this.save(); })
        Button('删除描述与标签').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('upd-image-delete-annotation').enabled(this.sourceCurrent).onClick((): void=> { this.save(true); })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:20})
  }
}
