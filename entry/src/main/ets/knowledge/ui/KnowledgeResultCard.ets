import { KnowledgeHit, KnowledgeResultSegment, KnowledgeResultRange, KnowledgeMatchKind, KnowledgeReferenceState, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { PdfPageReferenceState } from '../domain/PdfLocalModels';
import { knowledgeSegments } from '../pipeline/KnowledgeMatchPolicy';
import { Theme } from '../../components/Theme';
import { UnifiedSearchCard, UnifiedSearchReason, UnifiedSearchParent } from '../domain/UnifiedQueryModels';

@Component
export struct KnowledgeResultCard {
  @Prop hit: KnowledgeHit = new KnowledgeHit();
  onOpenHit: (hit: KnowledgeHit) => void = (_hit: KnowledgeHit): void => {};
  private label(): string { return this.hit.match.kind === KnowledgeMatchKind.Direct ? '词条直接命中' : this.hit.match.kind === KnowledgeMatchKind.Similar ? '相似结果' : '旧结果 · 未分类'; }
  private pageLabel(): string {
    if (this.hit.sourceKind === KnowledgeSourceKind.Docx) { const l = this.hit.locator.docx; return l === undefined ? 'DOCX原生来源未核' : `${l.part} · 段落 ${l.paragraph+1}`+(l.cell === undefined ? '' : ` · 行 ${l.cell.row+1} 列 ${l.cell.column+1} 合并 ${l.cell.rowSpan}×${l.cell.columnSpan}`); }
    if (this.hit.sourceKind === KnowledgeSourceKind.Image) { const locator = this.hit.locator.image; return locator === undefined ? '图片来源未核验' : `${this.hit.actualFormat} 原图 · 段落 ${locator.paragraph} · UTF16 ${locator.start}–${locator.end} · 无框核对`; }
    if (this.hit.sourceKind !== KnowledgeSourceKind.Pdf) { return '文本来源'; }
    if (this.hit.pages.state === PdfPageReferenceState.Conflict) { return '原页证据冲突 · 页码待核对'; }
    const pages: string = this.hit.pages.physicalPages1Based.join('、');
    return pages.length === 0 ? '原 PDF 页码待核对' : `原 PDF 第 ${pages}/${this.hit.pages.originalPages} 页${this.hit.pages.state === PdfPageReferenceState.Verified ? '' : ' · 部分片段页码待核对'}`;
  }
  private canOpen(): boolean { return this.hit.referenceState === KnowledgeReferenceState.Current && (this.hit.sourceKind !== KnowledgeSourceKind.Pdf || this.hit.pages.state === PdfPageReferenceState.Verified); }
  build() {
    Column({ space: 8 }) {
      Text(`${this.hit.sourceKind === KnowledgeSourceKind.Image ? this.hit.actualFormat : this.hit.sourceKind} · ${this.hit.title}`).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
      Text(this.label()).fontSize(12).fontColor(Theme.muted).width('100%')
      Text() {
        ForEach(knowledgeSegments(this.hit),(segment: KnowledgeResultSegment): void => {
          Span(segment.text).fontColor(segment.matched ? '#965000' : Theme.ink).fontWeight(segment.matched ? FontWeight.Bold : FontWeight.Normal)
        },(segment: KnowledgeResultSegment): string => segment.id)
      }.fontSize(14).width('100%').textAlign(TextAlign.Start)
      Text(this.pageLabel()).fontSize(13).fontColor(Theme.muted).width('100%')
      if (this.hit.match.compatibility) { Text('旧历史兼容重建 · 按保存输入').fontSize(12).fontColor(Theme.muted).width('100%') }
      if (this.hit.referenceState !== KnowledgeReferenceState.Current) { Text('来源已失效或为旧版本 · 仅保留快照').fontSize(12).fontColor(Theme.muted).width('100%') }
      Button('查看来源').id('knowledge-source-'+this.hit.chunkId).enabled(this.canOpen()).onClick((): void => { if (this.canOpen()) { this.onOpenHit(this.hit); } })
    }.width('100%').padding(12).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface).borderRadius(8)
  }
}
@Component
export struct UnifiedKnowledgeResultCard {
  @Prop card: UnifiedSearchCard=new UnifiedSearchCard();
  onOpen: (card: UnifiedSearchCard) => void=(_card: UnifiedSearchCard): void=>{};
  private segments(reason: UnifiedSearchReason): KnowledgeResultSegment[] { const hit: KnowledgeHit=new KnowledgeHit(); hit.text=reason.text; if (reason.route==='BodyDirect' || reason.route==='OcrDirect') { hit.match.kind=KnowledgeMatchKind.Direct; for (const source of reason.ranges) { const range: KnowledgeResultRange=new KnowledgeResultRange(); range.start=source.start; range.end=source.end; hit.match.ranges.push(range); } } return knowledgeSegments(hit); }
  build() {
    Column({space:7}) {
      Text(`${this.card.kind==='Image'?'图片':'正文'} · ${this.card.title}`).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
      if (!this.card.current) { Text('来源为旧版或已失效').fontSize(12).width('100%') }
      ForEach(this.card.reasons,(r: UnifiedSearchReason)=> {
        Column({space:4}) {
          Text(r.route==='BodyDirect'?'正文直接命中':r.route==='OcrDirect'?'OCR直接命中':r.route==='Tag'?'本机标签':r.route==='Vector'?'语义相关':r.route).fontSize(12).fontColor(Theme.muted).width('100%')
          Text() { ForEach(this.segments(r),(s: KnowledgeResultSegment)=> { Span(s.text).fontColor(s.matched?'#965000':Theme.ink).fontWeight(s.matched?FontWeight.Bold:FontWeight.Normal) },(s: KnowledgeResultSegment): string=>s.id) }.fontSize(14).maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }.width('100%')
      },(r: UnifiedSearchReason): string=>r.id)
      ForEach(this.card.parents,(p: UnifiedSearchParent)=> { Text('来源：' + p.title).fontSize(11).fontColor(Theme.muted).width('100%') },(p: UnifiedSearchParent): string=>p.documentKey+'|'+p.generation+'|'+p.occurrenceId)
      Button('查看来源').id('upd-card-source-'+this.card.key).enabled(this.card.current && this.card.kind!=='Legacy').onClick((): void=> { this.onOpen(this.card); })
    }.width('100%').padding(12).backgroundColor(Theme.surface).borderRadius(8).alignItems(HorizontalAlign.Start)
  }
}
