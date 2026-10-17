import { common } from '@kit.AbilityKit';
import { KnowledgeStorageScope } from '../domain/KnowledgeStorageScope';
import { KnowledgeStoreHost } from '../infra/KnowledgeStoreHost';
import { TextRdbRepository } from '../infra/TextRdbRepository';
import { ResidualDeferredHistoryRepository } from '../platformtests/ResidualHistoryFixture';
import { KnowledgeSearchService } from '../application/KnowledgeSearchService';
import { KnowledgePlatformIdentity } from '../infra/KnowledgeAssembly';
import { KnowledgeView } from './KnowledgeView';
import { TextViewState } from '../domain/TextKnowledgeModels';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KnowledgeHistoryCursor } from '../domain/KnowledgeSearchModels';
export class ResidualHistorySession {
  text: TextRdbRepository; pdf: ResidualDeferredHistoryRepository; search: KnowledgeSearchService;
  operation: Promise<void> | undefined; firstId: string = '';
  constructor(context: common.Context,scope: KnowledgeStorageScope) { const host = KnowledgeStoreHost.forContext(context,scope); this.text = new TextRdbRepository(context,host); this.pdf = new ResidualDeferredHistoryRepository(host); this.search = new KnowledgeSearchService(this.text,this.pdf,new KnowledgePlatformIdentity()); }
  async open(): Promise<void> { await this.text.open(); await this.pdf.open(); }
  async start(): Promise<void> { this.search.state.question = 'deferred local fixture'; this.operation = this.search.search(); await this.pdf.entered; this.firstId = this.search.state.historyId; }
  async settle(reject: boolean): Promise<void> { this.pdf.settle(reject); await this.operation; }
  async audit(): Promise<void> { const rows = (await this.pdf.history(new KnowledgeHistoryCursor(),20)).records; const once = rows.filter((row): boolean => row.id === this.firstId).length; const pass: boolean = !this.search.state.historyPending && once === 1; hilog.info(0x0001,'SHUVI_R2','%{public}s',`R2_RESIDUAL_HISTORY once=${once} pending=${this.search.state.historyPending ? 1 : 0} saves=${this.pdf.saves} requests=0`); if (!pass) { throw new Error('PendingHistoryNotRecovered'); } }
  async close(): Promise<void> { this.pdf.settle(false); await this.operation; await this.pdf.close(); await this.text.close(); }
}
@Component
export struct ResidualHistoryView {
  session: ResidualHistorySession | undefined = undefined;
  onBack: () => void = (): void => {};
  @State textState: TextViewState = new TextViewState(); @State openQuery: boolean = true; @State status: string = 'Ready';
  private async action(kind: string): Promise<void> { const session = this.session; if (session === undefined) { return; } try { if (kind === 'start') { await session.start(); } else if (kind === 'leave') { session.search.pause(); this.openQuery = false; } else if (kind === 'enter') { this.openQuery = true; } else if (kind === 'resolve' || kind === 'reject') { await session.settle(kind === 'reject'); } else { await session.audit(); } this.status = `PASS ${kind}`; } catch { this.status = `FAIL ${kind}`; } }
  build() {
    Column({ space: 10 }) {
      Text(this.status).id('r2-history-fixture-status')
      Row() { Button('开始延后写入').id('r2-history-fixture-start').onClick((): void => { this.action('start'); }); Button('模拟离页暂停').id('r2-history-fixture-leave').onClick((): void => { this.action('leave'); }); Button('重新进入').id('r2-history-fixture-enter').onClick((): void => { this.action('enter'); }) }
      Row() { Button('完成写入').id('r2-history-fixture-resolve').onClick((): void => { this.action('resolve'); }); Button('拒绝写入').id('r2-history-fixture-reject').onClick((): void => { this.action('reject'); }); Button('核一次历史').id('r2-history-fixture-audit').onClick((): void => { this.action('audit'); }) }
      Button('返回诊断').id('r2-history-fixture-back').onClick(this.onBack)
      if (this.openQuery) { KnowledgeView({ service: this.session?.search,textState: this.textState }) }
    }.width('100%')
  }
}
