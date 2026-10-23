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
  private confirmDeleteAnnotation(): void {
    this.getUIContext().showAlertDialog({
      title: '删除描述与标签？',
      message: '只会删除这份图片的人工描述与标签，图片和图片文字会保留。此操作无法撤销。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.save(true); } }
    });
  }
  build() {
    Column({space:12}) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('upd-image-back').accessibilityText('返回').onClick(this.onBack)
        Column({ space: 3 }) {
          Text('图片详情').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('查看图片文字、描述与标签').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.message.length > 0) { Text(this.message).fontColor(Theme.ink).id('upd-image-status').fontSize(13).lineHeight(21).width('100%') }
      if (this.selected.occurrenceId.length === 0) {
        if (this.total > 12) {
          Row({ space: 10 }) {
            Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.page>0).onClick((): void=> { this.page--; this.refresh(); })
            Text(`${this.page + 1} / ${Math.ceil(this.total / 12)}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled((this.page+1)*12<this.total).onClick((): void=> { this.page++; this.refresh(); })
          }.width('100%')
        }
        ForEach(this.records,(r: UnifiedImageRecord)=> {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              Text(r.title).fontSize(15).fontColor(Theme.ink).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(r.effectiveId==='None'?'待标注':'已标注').fontSize(11).fontColor(r.effectiveId==='None'?Theme.muted:Theme.accent).padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(9)
            }.width('100%').padding(14)
          }.id('upd-image-detail-'+r.occurrenceId).width('100%').backgroundColor(Theme.surface).borderRadius(14).border({ width: 1, color: Theme.line }).onClick((): void=> { this.open(r); })
        },(r: UnifiedImageRecord): string=>r.occurrenceId)
      }
      if (this.selected.occurrenceId.length>0) {
        if (this.previewPath.length>0) { Image(this.previewPath).objectFit(ImageFit.Contain).width('100%').height(260).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line }) }
        if (this.parents.length > 0) { Text('来自：' + this.parents).fontColor(Theme.muted).fontSize(12).lineHeight(19).width('100%') }
        Column({ space: 8 }) {
          Text('图片文字').fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
          Text(this.selected.ocr || '未识别到文字').fontColor(Theme.ink).fontSize(14).lineHeight(23).width('100%')
          if (this.selected.caption.length > 0) { Text(this.selected.caption).fontColor(Theme.muted).fontSize(13).lineHeight(21).width('100%') }
        }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
        if (this.annotation.description.length > 0) { Text('图片描述').fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%'); Text(this.annotation.description).fontColor(Theme.ink).lineHeight(26).fontSize(14).width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(16) }
        if (this.annotation.tags.length > 0) { Text(this.annotation.tags.join(' · ')).fontColor(Theme.accent).fontSize(13).lineHeight(24).width('100%').padding(14).backgroundColor(Theme.soft).borderRadius(14) }
        Button(this.editing ? '取消编辑' : '编辑描述与标签').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-image-edit').enabled(this.sourceCurrent).onClick((): void => { this.editing = !this.editing; })
        if (this.editing) {
          TextArea({text:this.descriptionInput,placeholder:'描述，可以删空'}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('upd-image-description').maxLength(4000).onChange((v: string): void=> { this.descriptionInput=v; })
          TextArea({text:this.tagsInput,placeholder:'每行一个标签；移除一行即删除标签'}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('upd-image-tags').maxLength(3000).onChange((v: string): void=> { this.tagsInput=v; })
          Button('保存修正').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-image-save').enabled(this.sourceCurrent).onClick((): void=> { this.save(); })
          Button('删除描述与标签').fontSize(14).fontColor(Theme.danger).backgroundColor(Theme.warning).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-image-delete-annotation').enabled(this.sourceCurrent).onClick((): void=> { this.confirmDeleteAnnotation(); })
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:24})
  }
}
