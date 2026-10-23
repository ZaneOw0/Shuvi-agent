import { image } from '@kit.ImageKit';
import { PdfPageAdapter } from '../infra/PdfPageAdapter';
import { PdfSourceBinding, PdfLocator, KnowledgeCancellation, PdfContentNode, PdfBox, PdfMappingTier, PdfTableCell } from '../domain/PdfKnowledgeModels';
import { KnowledgeOperationSession } from '../application/KnowledgeOperationSession';
import { PdfSourceSession } from '../infra/PdfSourceSession';
import { Theme } from '../../components/Theme';

@Component
export struct PdfSourceView {
  adapter: PdfPageAdapter | undefined = undefined;
  session: PdfSourceSession | undefined = undefined;
  binding: PdfSourceBinding = new PdfSourceBinding();
  locator: PdfLocator = new PdfLocator();
  onBack: () => void = (): void => {};
  onOpened: () => Promise<void> = async (): Promise<void> => {};
  @State pixels: image.PixelMap | undefined = undefined;
  @State pageIndex0: number = 0;
  @State message: string = '定位待核验；仅手动翻阅真正原件';
  @State busy: boolean = false;
  @State nodes: PdfContentNode[] = []; @State nodeOffset: number = 0; @State structureOpen: boolean = false;
  @State imagePixels: image.PixelMap | undefined = undefined; @State highlights: PdfBox[] = []; @State pageRatio: number = 0.707;
  @State selected: PdfContentNode | undefined = undefined;
  @State cells: PdfTableCell[] = []; @State cellOffset: number = 0; @State textOffset: number = 0;
  @State selectedCell: PdfTableCell | undefined = undefined; @State cellTextOffset: number = 0;
  private operations: KnowledgeOperationSession = new KnowledgeOperationSession();
  aboutToAppear(): void { this.open(); }
  aboutToDisappear(): void { this.operations.stop(); if (this.adapter !== undefined) { if (this.session !== undefined) { this.session.release(this.adapter); } else { this.adapter.close().catch((): void => { this.message = '原件释放待确认'; }); } } }
  private async open(): Promise<void> {
    this.busy = true; const cancel = this.operations.begin();
    try {
      await this.adapter?.openOriginal(this.binding,cancel); await this.onOpened(); this.operations.current(cancel); this.pageIndex0 = 0; this.refreshNodes(0);
      const node: PdfContentNode | undefined = this.adapter?.snapshot?.nodes.find((item: PdfContentNode): boolean => (this.adapter?.nodeIds ?? []).indexOf(item.id) >= 0); this.selected = node;
      if (node !== undefined && this.adapter !== undefined) { const checked: PdfLocator = await this.adapter.mapping(this.locator,node); if (checked.tier !== PdfMappingTier.Unknown) { this.pageIndex0 = checked.candidatePhysicalPageIndex0; this.message = checked.tier; } }
      if ((this.adapter?.reviewedPages1.length ?? 0) > 0) { this.pageIndex0 = (this.adapter?.reviewedPages1[0] ?? 1)-1; this.message = `已核原页 ${this.adapter?.reviewedPages1.join('、')}；未升级区域坐标`; }
      this.operations.current(cancel); this.operations.end(cancel); await this.render(this.pageIndex0);
    }
    catch { this.message = '真正原件核对不可用，未使用抽取文本或服务 PDF 替代'; }
    finally { this.operations.end(cancel); this.busy = false; }
  }
  private async render(page: number): Promise<void> {
    if (this.adapter === undefined) { this.message = '原件预览能力不可用'; return; }
    this.busy = true; const cancel = this.operations.begin();
    try { const pixels = await this.adapter.renderPage(page,cancel); const info: image.ImageInfo = await pixels.getImageInfo(); const regions = this.selected === undefined ? [] : await this.adapter.regions(this.selected,page); this.operations.current(cancel); this.pixels = pixels; this.pageRatio = info.size.width/info.size.height; this.pageIndex0 = page; this.highlights = regions; }
    catch { this.message = '原页加载失败，未伪造定位'; }
    finally { this.operations.end(cancel); this.busy = false; }
  }
  private refreshNodes(offset: number): void { this.nodeOffset = offset; this.nodes = this.adapter?.snapshot?.nodes.slice(offset,offset+12) ?? []; }
  private async showImage(member: string): Promise<void> { this.busy = true; const cancel = this.operations.begin(); try { const pixels = await this.adapter?.renderImage(member,cancel); this.operations.current(cancel); this.imagePixels = pixels; } catch { this.message = '图片资产核对失败，原件保留'; } finally { this.operations.end(cancel); this.busy = false; } }
  private async selectNode(node: PdfContentNode): Promise<void> {
    if (this.busy) { return; } const cancel = this.operations.begin(); this.busy = true;
    try { const locator = node.locators[0] ?? new PdfLocator(); locator.originalHash = this.binding.originalHash; locator.originalVersion = this.binding.originalVersion; locator.providerPageIndex0 = node.pageIndex0; const checked = await this.adapter?.mapping(locator,node); this.operations.current(cancel);
      this.selected = node; this.selectedCell = undefined; this.cellOffset = 0; this.textOffset = 0; this.cells = node.table?.cells.slice(0,12) ?? []; this.message = checked?.tier ?? PdfMappingTier.Unknown;
      await this.render(checked !== undefined && checked.tier !== PdfMappingTier.Unknown ? checked.candidatePhysicalPageIndex0 : this.pageIndex0);
    } catch { this.message = '节点读取已取消或释放待确认'; } finally { this.operations.end(cancel); this.busy = false; }
  }
  private pageCells(delta: number): void { this.cellOffset = Math.max(0,this.cellOffset+delta*12); this.cells = this.selected?.table?.cells.slice(this.cellOffset,this.cellOffset+12) ?? []; }
  build() {
    Column({ space: 12 }) {
      Button('‹ 返回').id('r2-source-back').constraintSize({ minHeight: 44 }).onClick(this.onBack)
      Text(this.message).id('r2-source-status').fontSize(14).fontColor(Theme.amber).width('100%')
      Text(`真正原件：${this.pageIndex0+1}/${this.binding.originalPages} · 服务候选页 ${this.locator.providerPageIndex0+1}`).fontSize(13).width('100%')
      if (this.pixels !== undefined) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.pixels).width('100%').height('100%').objectFit(ImageFit.Fill)
          ForEach(this.highlights,(box: PdfBox): void => {
            Column().width(`${(box.right-box.left)*100}%`).height(`${(box.bottom-box.top)*100}%`).position({ x: `${box.left*100}%`,y: `${box.top*100}%` }).border({ width: 2,color: '#C06812' }).backgroundColor('#30F5B642')
          },(box: PdfBox): string => `${box.left}:${box.top}:${box.right}:${box.bottom}`)
        }.id('r2-source-page-canvas').width('100%').aspectRatio(this.pageRatio)
      }
      Row({ space: 12 }) {
        Button('上一页').id('r2-source-prev').enabled(!this.busy && this.pageIndex0 > 0).constraintSize({ minHeight: 44 }).onClick((): void => { this.render(this.pageIndex0-1); })
        Button('下一页').id('r2-source-next').enabled(!this.busy && this.pageIndex0+1 < this.binding.originalPages).constraintSize({ minHeight: 44 }).onClick((): void => { this.render(this.pageIndex0+1); })
      }
      Button(this.structureOpen ? '收起结构' : '结构与图片核对').id('r2-source-structure').onClick((): void => { this.structureOpen = !this.structureOpen; })
      if (this.structureOpen) {
        ForEach(this.nodes,(node: PdfContentNode): void => {
          Text(`${node.id} · ${node.kind} · 服务候选页 ${node.pageIndex0+1}`).fontSize(12).width('100%')
          Button(this.selected?.id === node.id ? '当前节点' : '选择节点').id(`r2-source-node-${node.id}`).enabled(!this.busy).onClick((): void => { this.selectNode(node); })
          if (node.table !== undefined) { Text(`表格 ${node.table.rows} × ${node.table.columns} · cells ${node.table.cells.length}`).fontSize(12) }
          ForEach(node.assetIds,(member: string): void => { Button(`核对图片 ${member}`).id(`r2-asset-${node.id}-${member}`).enabled(!this.busy).onClick((): void => { this.showImage(member); }) },(member: string): string => member)
        },(node: PdfContentNode): string => node.id)
        if (this.selected !== undefined) {
          Text(`${this.selected.id} · ${this.selected.kind}`).id('r2-source-selected').fontSize(14)
          Text(this.selected.rawLatex.length > 0 ? this.selected.rawLatex.slice(this.textOffset,this.textOffset+1024) : this.selected.text.slice(this.textOffset,this.textOffset+1024)).id('r2-source-node-raw').fontSize(13).width('100%')
          Row() { Button('前段').enabled(this.textOffset > 0).onClick((): void => { this.textOffset = Math.max(0,this.textOffset-1024); }); Button('后段').enabled(this.textOffset+1024 < Math.max(this.selected.rawLatex.length,this.selected.text.length)).onClick((): void => { this.textOffset += 1024; }) }
          ForEach(this.cells,(cell: PdfTableCell): void => { Column() { Text(`r${cell.row+1} c${cell.column+1} · rowspan ${cell.rowSpan} colspan ${cell.columnSpan}\n${cell.text.slice(0,128)}`).id(`r2-source-cell-${cell.id}`).fontSize(13).width('100%'); Button('单元格原文').id(`r2-source-cell-detail-${cell.id}`).onClick((): void => { this.selectedCell = cell; this.cellTextOffset = 0; }) } },(cell: PdfTableCell): string => cell.id)
          if (this.selectedCell !== undefined) { Text(this.selectedCell.text.slice(this.cellTextOffset,this.cellTextOffset+1024)).id('r2-source-cell-raw').fontSize(13).width('100%'); Row() { Button('前段单元格').enabled(this.cellTextOffset > 0).onClick((): void => { this.cellTextOffset = Math.max(0,this.cellTextOffset-1024); }); Button('后段单元格').enabled(this.cellTextOffset+1024 < this.selectedCell.text.length).onClick((): void => { this.cellTextOffset += 1024; }) } }
          Row() { Button('上组单元格').id('r2-source-cells-prev').enabled(this.cellOffset > 0).onClick((): void => { this.pageCells(-1); }); Button('下组单元格').id('r2-source-cells-next').enabled(this.cellOffset+12 < (this.selected.table?.cells.length ?? 0)).onClick((): void => { this.pageCells(1); }) }
        }
        Row() { Button('上组结构').enabled(this.nodeOffset > 0).onClick((): void => { this.refreshNodes(Math.max(0,this.nodeOffset-12)); }); Button('下组结构').enabled(this.nodeOffset+12 < (this.adapter?.snapshot?.nodes.length ?? 0)).onClick((): void => { this.refreshNodes(this.nodeOffset+12); }) }
        if (this.imagePixels !== undefined) { Image(this.imagePixels).width('100%').height(320).objectFit(ImageFit.Contain) }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
