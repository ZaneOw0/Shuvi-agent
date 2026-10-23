import { ParsedDocumentMigrationService } from '../application/ParsedDocumentMigrationService';
import { UnifiedProcessingQueue } from '../application/UnifiedProcessingQueue';
import { UnifiedVectorRepository } from '../infra/UnifiedVectorRepository';
import { ParsedMigrationInput, ParsedMigrationReceipt, ParsedUpgradeBatch } from '../domain/ParsedMigrationModels';

@Component
export struct KnowledgeMigrationView {
  migration: ParsedDocumentMigrationService | undefined=undefined;
  queue: UnifiedProcessingQueue | undefined=undefined;
  vectors: UnifiedVectorRepository | undefined=undefined;
  onBack: () => void=(): void=>{};
  @State rows: ParsedMigrationInput[]=[];
  @State selected: string[]=[];
  @State receipts: ParsedMigrationReceipt[]=[];
  @State receiptRows: ParsedMigrationReceipt[]=[];
  @State receiptPage: number=0;
  @State batchIds: string[]=[];
  @State upgradeIds: string[]=[];
  @State batchId: string='';
  @State denominator: number=0;
  @State message: string='';
  @State busy: boolean=false;
  @State page: number=0;
  @State total: number=0;
  @State upgrade: ParsedUpgradeBatch=new ParsedUpgradeBatch();
  @State costConsent: boolean=false;
  @State coverage: string='';
  private alive: boolean=false;
  private listener: () => void=(): void=> { this.update(); };
  aboutToAppear(): void { this.alive=true; this.migration?.subscribe(this.listener); this.queue?.subscribe(this.listener); this.refresh(); }
  aboutToDisappear(): void { this.alive=false; this.migration?.unsubscribe(this.listener); this.queue?.unsubscribe(this.listener); this.costConsent=false; }
  private update(): void { if (!this.alive) { return; } this.busy=this.migration?.busy ?? false; this.batchId=this.migration?.batch?.id ?? ''; this.denominator=this.migration?.batch?.inputs.length ?? 0; this.receipts=this.migration?.receipts.slice() ?? []; this.receiptRows=this.receipts.slice(this.receiptPage*12,this.receiptPage*12+12); this.message=this.migration?.message ?? this.message; this.readCoverage(); }
  private async refresh(): Promise<void> {
    try { const rows=await this.migration?.catalog() ?? []; if (!this.alive) { return; } this.total=rows.length; this.rows=rows.slice(this.page*12,this.page*12+12); this.batchIds=await this.migration?.batches() ?? []; this.upgradeIds=await this.queue?.upgradeBatchIds() ?? []; this.update(); }
    catch { this.message='旧资料目录读取失败，未当空库；没有执行迁移'; }
  }
  private toggle(key: string): void { this.selected=this.selected.indexOf(key)>=0?this.selected.filter((s: string): boolean=>s!==key):this.selected.concat([key]); this.upgrade=new ParsedUpgradeBatch(); this.costConsent=false; }
  private async freezeScope(): Promise<void> { try { await this.migration?.freeze(this.selected); this.upgrade=new ParsedUpgradeBatch(); this.update(); this.batchIds=await this.migration?.batches() ?? []; } catch { this.message='冻结范围失败；原件和旧活动资料未改'; } }
  private async run(): Promise<void> { try { if (this.batchId.length>0) { await this.migration?.run(this.batchId); } this.update(); } catch { this.message='本机迁移未完成；可从原冻结批次恢复'; } }
  private async load(id: string): Promise<void> { try { await this.migration?.load(id); this.upgrade=new ParsedUpgradeBatch(); this.update(); } catch { this.message='冻结批次不可读'; } }
  private async freezeUpgrade(): Promise<void> {
    try { const ids: string[]=this.receipts.filter((r: ParsedMigrationReceipt): boolean=>r.phase==='Committed').map((r: ParsedMigrationReceipt): string=>r.documentKey); this.upgrade=await this.queue?.freezeUpgrade(Array.from(new Set<string>(ids))) ?? new ParsedUpgradeBatch(); this.costConsent=false; this.message='历史云升级范围已冻结，尚未发送；请核费用后批准'; }
    catch { this.message='历史升级冻结失败；请先完成本机迁移并配置当前视觉/嵌入费用设置'; }
  }
  private async approve(): Promise<void> { if (!this.costConsent || this.upgrade.id.length===0) { return; } try { await this.queue?.approveUpgrade(this.upgrade.id,true); this.upgrade.approved=true; this.message='显式历史升级已排队；本机迁移本身没有发送'; } catch { this.message='升级范围/设置/图片标注版本已变，未批准发送；请重新冻结'; } finally { this.costConsent=false; } }
  private async loadUpgrade(id: string): Promise<void> { try { this.upgrade=await this.queue?.loadUpgrade(id) ?? new ParsedUpgradeBatch(); this.costConsent=false; this.message=this.upgrade.approved?'已载入先前明确批准的历史批次':'已载入未批准批次，未发送'; } catch { this.message='历史批次不可读，未发送'; } }
  private async pauseUpgrade(paused: boolean): Promise<void> { try { await this.queue?.pauseUpgrade(this.upgrade.id,paused); this.upgrade.paused=paused; this.message=paused?'已暂停后续历史升级请求，当前云请求可能继续':'历史升级恢复已保存'; } catch { this.message='历史升级状态保存失败或范围已变，未新发请求'; } }
  private async readCoverage(): Promise<void> { const lines: string[]=[]; try { for (const receipt of this.receiptRows.filter((r: ParsedMigrationReceipt): boolean=>r.phase==='Committed')) { const c=await this.vectors?.upgradeCoverage(receipt.documentKey); if (c!==undefined) { lines.push(`${receipt.inputKey} · 正文 ${c.body} · 图代理 ${c.imageReady}/${c.images} · 进行中 ${c.running} · 失败 ${c.failed}`); } } if (this.alive) { this.coverage=lines.join('\n'); } } catch { this.coverage='统一语义覆盖读回未确认；不混旧向量空间'; } }
  build() {
    Column({space:12}) {
      Row() { Button('返回').id('upd-migration-back').onClick(this.onBack); Text('资料迁移').fontSize(20).layoutWeight(1) }.width('100%')
      Text(this.message).id('upd-migration-status').fontSize(13).width('100%')
      Text('本机迁移').fontSize(18).width('100%')
      Text('仅读取旧快照与已收本机文件。不会发送图片/文本、重新解析或改写旧索引与向量。').fontSize(13).width('100%')
      Button('刷新旧资料目录').id('upd-migration-catalog').enabled(!this.busy).onClick((): void=> { this.refresh(); })
      Row() { Button('上一页').enabled(this.page>0).onClick((): void=> { this.page--; this.refresh(); }); Button('下一页').enabled((this.page+1)*12<this.total).onClick((): void=> { this.page++; this.refresh(); }) }.width('100%')
      ForEach(this.rows,(r: ParsedMigrationInput)=> {
        Row() { Checkbox().select(this.selected.indexOf(r.key)>=0).enabled(!this.busy).onChange((): void=> { this.toggle(r.key); }); Text(`${r.namespace} · ${r.title} · ${r.active}`).fontSize(13).layoutWeight(1) }.width('100%')
      },(r: ParsedMigrationInput): string=>r.key)
      Button(`冻结本机范围（${this.selected.length}）`).id('upd-migration-freeze').enabled(!this.busy && this.selected.length>0).onClick((): void=> { this.freezeScope(); })
      ForEach(this.batchIds,(id: string)=> { Button(id).enabled(!this.busy).onClick((): void=> { this.load(id); }) },(id: string): string=>id)
      Text(`冻结 ${this.denominator} · 完整 ${this.receipts.filter((r: ParsedMigrationReceipt): boolean=>r.state==='Complete').length} · 部分 ${this.receipts.filter((r: ParsedMigrationReceipt): boolean=>r.state==='Partial').length} · 失败 ${this.receipts.filter((r: ParsedMigrationReceipt): boolean=>r.state==='Failed').length}`).fontSize(13).width('100%')
      Row() { Button('开始 / 恢复本机迁移').id('upd-migration-run').enabled(!this.busy && this.batchId.length>0).onClick((): void=> { this.run(); }); Button('暂停本机迁移').id('upd-migration-pause').enabled(this.busy).onClick((): void=> { this.migration?.pause(); }) }.width('100%')
      Row() { Button('上一组回执').enabled(this.receiptPage>0).onClick((): void=> { this.receiptPage--; this.update(); }); Button('下一组回执').enabled((this.receiptPage+1)*12<this.receipts.length).onClick((): void=> { this.receiptPage++; this.update(); }) }.width('100%')
      ForEach(this.receiptRows,(r: ParsedMigrationReceipt)=> { Text(`${r.inputKey} · ${r.phase} · ${r.state}\n${r.failure}\n${r.warnings.join(' · ')}`).fontSize(12).width('100%') },(r: ParsedMigrationReceipt): string=>r.inputKey)
      Text('显式历史云升级').fontSize(18).width('100%')
      ForEach(this.upgradeIds,(id: string)=> { Button(id).id('upd-upgrade-load-'+id).onClick((): void=> { this.loadUpgrade(id); }) },(id: string): string=>id)
      Button('冻结已迁移历史升级范围').id('upd-upgrade-freeze').enabled(!this.busy && this.receipts.some((r: ParsedMigrationReceipt): boolean=>r.phase==='Committed')).onClick((): void=> { this.freezeUpgrade(); })
      if (this.upgrade.id.length>0) {
        Text(`${this.upgrade.targets.length} 文档 · 视觉设置/费用 r${this.upgrade.visionRevision}/${this.upgrade.visionCostRevision} · 嵌入设置/费用 r${this.upgrade.embeddingRevision}/${this.upgrade.embeddingCostRevision}`).fontSize(13).width('100%')
        Text('当前视觉接收方DeepSeek接收所列受管原图；当前嵌入服务接收正文/OCR与图描述+tags。可能收费，未知请求重试也可能收费。不自动扩大历史范围。').fontSize(13).width('100%')
        Row() { Checkbox().id('upd-upgrade-cost').select(this.costConsent).onChange((v: boolean): void=> { this.costConsent=v; }); Text('批准本冻结历史范围及可能费用').layoutWeight(1) }.width('100%')
        Button('批准并开始历史升级').id('upd-upgrade-approve').enabled(this.costConsent && !this.upgrade.approved).onClick((): void=> { this.approve(); })
        Row() { Button('暂停历史升级').id('upd-upgrade-pause').enabled(this.upgrade.approved).onClick((): void=> { this.pauseUpgrade(true); }); Button('恢复历史升级').id('upd-upgrade-resume').enabled(this.upgrade.approved).onClick((): void=> { this.pauseUpgrade(false); }) }.width('100%')
      }
      Text(this.coverage).id('upd-upgrade-coverage').fontSize(13).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({top:12,bottom:20})
  }
}
