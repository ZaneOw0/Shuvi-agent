import { DocxSourceSession } from '../infra/DocxSourceSession';
import { DocxNativeNode } from '../domain/DocxKnowledgeModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { KnowledgeResultSegment } from '../domain/KnowledgeSearchModels';

@Component
export struct DocxSourceView {
  session: DocxSourceSession | undefined = undefined; onBack: () => void = (): void => {};
  @State private rows: DocxNativeNode[] = []; @State private title: string = ''; @State private message: string = '';
  @State private address: string = ''; @State private pageLabel: string = ''; @State private segments: KnowledgeResultSegment[] = [];
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.update(); });
  private update(): void { const s: DocxSourceSession | undefined = this.session; this.rows = s?.nodes.slice() ?? []; this.title = s?.title ?? ''; this.message = s?.message ?? '来源服务不可用'; this.address = s?.address ?? ''; this.segments = s?.segments.slice() ?? []; this.pageLabel = `${(s?.page ?? 0)+1} / ${Math.max(1,Math.ceil((s?.total ?? 0)/8))}`; }
  aboutToAppear(): void { this.session?.subscribe(this.listener); this.update(); }
  aboutToDisappear(): void { this.session?.unsubscribe(this.listener); this.session?.close().catch((): void => {}); }
  build() {
    Column({ space: 12 }) {
      Button('返回').id('docx-source-back').onClick((): void => { this.session?.invalidate(); this.session?.close().catch((): void => {}); this.onBack(); })
      Text(this.title).fontSize(20)
      Text(this.message).width('100%')
      Text(this.address).width('100%')
      Text() { ForEach(this.segments,(segment: KnowledgeResultSegment) => { Span(segment.text).fontWeight(segment.matched ? FontWeight.Bold : FontWeight.Normal).fontColor(segment.matched ? '#965000' : '#222222') },(segment: KnowledgeResultSegment): string => segment.id) }.width('100%')
      ForEach(this.rows,(node: DocxNativeNode) => {
        Column({ space: 4 }) {
          Text(`${node.kind} · 段落 ${node.locator.paragraph+1}`+(node.locator.cell === undefined ? '' : ` · 行 ${node.locator.cell.row+1} 列 ${node.locator.cell.column+1} 合并 ${node.locator.cell.rowSpan}×${node.locator.cell.columnSpan}`)).fontSize(13)
          Text(node.text).width('100%').copyOption(CopyOptions.InApp)
        }.width('100%').alignItems(HorizontalAlign.Start)
      },(node: DocxNativeNode): string => node.id)
      Row({ space: 12 }) {
        Button('上一组').onClick((): void => { this.session?.turn(-1).catch((): void => { this.message = '来源读取失败，当前显示已失效'; this.session?.invalidate(); }); })
        Text(this.pageLabel)
        Button('下一组').onClick((): void => { this.session?.turn(1).catch((): void => { this.message = '来源读取失败，当前显示已失效'; this.session?.invalidate(); }); })
      }
      Button('重试释放').id('docx-source-release-retry').onClick((): void => { this.session?.close().catch((): void => {}); })
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
  }
}
