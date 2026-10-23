import { KnowledgeHit, KnowledgeResultSegment, KnowledgeResultRange, KnowledgeMatchKind, KnowledgeReferenceState, KnowledgeSourceKind } from '../domain/KnowledgeSearchModels';
import { PdfPageReferenceState } from '../domain/PdfLocalModels';
import { knowledgeSegments } from '../pipeline/KnowledgeMatchPolicy';
import { Theme } from '../../components/Theme';
import { UnifiedSearchCard, UnifiedSearchReason, UnifiedSearchParent } from '../domain/UnifiedQueryModels';

interface KnowledgeResultCardOptions {
  id: string;
  hit: KnowledgeHit;
  onOpenHit: (hit: KnowledgeHit) => void;
}

interface UnifiedKnowledgeResultCardOptions {
  id: string;
  card: UnifiedSearchCard;
  onOpen: (card: UnifiedSearchCard) => void;
}

function knowledgeResultLabel(hit: KnowledgeHit): string {
  return hit.match.kind === KnowledgeMatchKind.Direct ? '词条直接命中' : hit.match.kind === KnowledgeMatchKind.Similar ? '相似结果' : '旧结果 · 未分类';
}

function knowledgeResultPageLabel(hit: KnowledgeHit): string {
  if (hit.sourceKind === KnowledgeSourceKind.Docx) {
    const l = hit.locator.docx;
    return l === undefined ? 'DOCX原生来源未核' : `${l.part} · 段落 ${l.paragraph+1}`+(l.cell === undefined ? '' : ` · 行 ${l.cell.row+1} 列 ${l.cell.column+1} 合并 ${l.cell.rowSpan}×${l.cell.columnSpan}`);
  }
  if (hit.sourceKind === KnowledgeSourceKind.Image) {
    const locator = hit.locator.image;
    return locator === undefined ? '图片来源未核验' : `${hit.actualFormat} 原图 · 段落 ${locator.paragraph} · UTF16 ${locator.start}–${locator.end} · 无框核对`;
  }
  if (hit.sourceKind !== KnowledgeSourceKind.Pdf) { return '文本来源'; }
  if (hit.pages.state === PdfPageReferenceState.Conflict) { return '原页证据冲突 · 页码待核对'; }
  const pages: string = hit.pages.physicalPages1Based.join('、');
  return pages.length === 0 ? '原 PDF 页码待核对' : `原 PDF 第 ${pages}/${hit.pages.originalPages} 页${hit.pages.state === PdfPageReferenceState.Verified ? '' : ' · 部分片段页码待核对'}`;
}

function knowledgeResultCanOpen(hit: KnowledgeHit): boolean {
  return hit.referenceState === KnowledgeReferenceState.Current && (hit.sourceKind !== KnowledgeSourceKind.Pdf || hit.pages.state === PdfPageReferenceState.Verified);
}

function unifiedResultSegments(reason: UnifiedSearchReason): KnowledgeResultSegment[] {
  const hit: KnowledgeHit = new KnowledgeHit(); hit.text = reason.text;
  if (reason.route === 'BodyDirect' || reason.route === 'OcrDirect') {
    hit.match.kind = KnowledgeMatchKind.Direct;
    for (const source of reason.ranges) {
      const range: KnowledgeResultRange = new KnowledgeResultRange(); range.start = source.start; range.end = source.end; hit.match.ranges.push(range);
    }
  }
  return knowledgeSegments(hit);
}

@Builder
export function KnowledgeResultCard($$: KnowledgeResultCardOptions) {
  Column({ space: 8 }) {
    Text(`${$$.hit.sourceKind === KnowledgeSourceKind.Image ? $$.hit.actualFormat : $$.hit.sourceKind} · ${$$.hit.title}`).fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
    Text(knowledgeResultLabel($$.hit)).fontColor(Theme.muted).fontSize(12).width('100%')
    Text() {
      ForEach(knowledgeSegments($$.hit), (segment: KnowledgeResultSegment): void => {
        Span(segment.text).fontColor(segment.matched ? Theme.accent : Theme.ink).fontWeight(segment.matched ? FontWeight.Bold : FontWeight.Normal)
      }, (segment: KnowledgeResultSegment): string => segment.id)
    }.fontSize(14).width('100%').textAlign(TextAlign.Start)
    Text(knowledgeResultPageLabel($$.hit)).fontColor(Theme.muted).fontSize(13).width('100%')
    if ($$.hit.match.compatibility) { Text('旧历史兼容重建 · 按保存输入').fontColor(Theme.muted).fontSize(12).width('100%') }
    if ($$.hit.referenceState !== KnowledgeReferenceState.Current) { Text('来源已失效或为旧版本 · 仅保留快照').fontColor(Theme.muted).fontSize(12).width('100%') }
    Button('查看来源').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .id('knowledge-source-' + $$.hit.chunkId).enabled(knowledgeResultCanOpen($$.hit))
      .onClick((): void => { if (knowledgeResultCanOpen($$.hit)) { $$.onOpenHit($$.hit); } })
  }.width('100%').padding(12).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line }).id($$.id)
}

@Builder
export function UnifiedKnowledgeResultCard($$: UnifiedKnowledgeResultCardOptions) {
  Column({ space: 7 }) {
    Text(`${$$.card.kind === 'Image' ? '图片' : '正文'} · ${$$.card.title}`).fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
    if (!$$.card.current) { Text('来源为旧版或已失效').fontColor(Theme.ink).fontSize(12).width('100%') }
    ForEach($$.card.reasons, (r: UnifiedSearchReason): void => {
      Column({ space: 4 }) {
        Text(r.route === 'BodyDirect' ? '正文直接命中' : r.route === 'OcrDirect' ? 'OCR直接命中' : r.route === 'Tag' ? '本机标签' : r.route === 'Vector' ? '语义相关' : r.route).fontColor(Theme.muted).fontSize(12).width('100%')
        Text() {
          ForEach(unifiedResultSegments(r), (s: KnowledgeResultSegment): void => {
            Span(s.text).fontColor(s.matched ? Theme.accent : Theme.ink).fontWeight(s.matched ? FontWeight.Bold : FontWeight.Normal)
          }, (s: KnowledgeResultSegment): string => s.id)
        }.fontSize(14).maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.width('100%')
    }, (r: UnifiedSearchReason): string => r.id)
    ForEach($$.card.parents, (p: UnifiedSearchParent): void => {
      Text('来源：' + p.title).fontColor(Theme.muted).fontSize(11).width('100%')
    }, (p: UnifiedSearchParent): string => p.documentKey + '|' + p.generation + '|' + p.occurrenceId)
    Button('查看来源').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .id('upd-card-source-' + $$.card.key).enabled($$.card.current && $$.card.kind !== 'Legacy')
      .onClick((): void => { $$.onOpen($$.card); })
  }.width('100%').padding(12).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line }).alignItems(HorizontalAlign.Start).id($$.id)
}
