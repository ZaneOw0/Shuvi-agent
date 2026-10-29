import { Theme } from '../../components/Theme';
import { EmbeddingService } from '../application/EmbeddingService';
import { EmbeddingCredentialStatus, EmbeddingDetectionStatus } from '../domain/EmbeddingModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedProcessingSettings } from '../domain/UnifiedKnowledgeModels';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';

/**
 * Semantic search settings: the fixed model, whether its key is saved (keys live in 我的 → API Key 管理) and the
 * automatic ingestion switch with its scope and cost consent.
 */
@Component
export struct EmbeddingSettingsView {
  unifiedSettings: UnifiedSettingsService | undefined=undefined;
  @State feedbackVisible: boolean = false;
  @State unifiedCost: boolean=false;
  @State unifiedBaseline: boolean=false;
  @State unifiedOn: boolean=false;
  @State unifiedNeedsConfirmation: boolean = false;
  @State unifiedSaving: boolean = false;
  @State busy: boolean = false;
  private unifiedRefreshEpoch: number = 0;
  private unifiedObservedBinding: string = '';
  private async refreshUnified(): Promise<void> {
    const epoch: number = ++this.unifiedRefreshEpoch;
    try {
      const settings: UnifiedProcessingSettings | undefined = await this.unifiedSettings?.setting('Embedding');
      const service: EmbeddingService | undefined = this.service;
      if (epoch !== this.unifiedRefreshEpoch || settings === undefined || service === undefined) return;
      const matches: boolean = settings.configBinding === embeddingConfigBinding(service.state.config) &&
        settings.credentialRevision === service.state.config.credentialRevision && !service.state.config.mutationPending;
      this.unifiedOn = settings.enabled && settings.baselineAccepted && matches;
      this.unifiedNeedsConfirmation = settings.configBinding.length > 0 && (!matches || settings.paused && !settings.baselineAccepted);
    } catch { if (epoch === this.unifiedRefreshEpoch) { this.unifiedOn = false; this.message = '自动入库设置读取失败'; this.feedbackVisible = true; } }
  }
  private async saveUnified(): Promise<void> {
    if (this.unifiedSaving || this.busy || this.unifiedSettings === undefined) return;
    this.feedbackVisible = true; this.unifiedSaving = true;
    try {
      await this.unifiedSettings.enableEmbedding(!this.unifiedOn, this.unifiedCost, this.unifiedBaseline);
      await this.refreshUnified(); this.unifiedCost = false; this.unifiedBaseline = false;
      this.message = this.unifiedOn ? '已开启自动入库' : '已关闭自动入库';
    } catch { this.message = '请先在「我的 → API Key 管理」保存硅基流动 Key，并确认发送范围、费用与当前配置'; }
    finally { this.unifiedSaving = false; }
  }
  service: EmbeddingService | undefined = undefined;
  onBack: () => void = (): void => {};
  onKeys: () => void = (): void => {};
  @Prop clearEpoch: number = 0;
  @State credential: string = 'Missing';
  @State detection: string = 'Untested';
  @State message: string = '';
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.changed(); });
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.changed(); }
  aboutToDisappear(): void { this.unifiedRefreshEpoch++; this.service?.unsubscribe(this.listener); }
  changed(): void {
    if (this.service === undefined) { this.message = '本机配置服务不可用'; this.feedbackVisible = true; return; }
    this.credential = this.service.state.credential; this.detection = this.service.state.detection.status;
    this.busy = this.service.state.busy;
    const binding: string = embeddingConfigBinding(this.service.state.config) + ':' + this.service.state.config.credentialRevision.toString();
    if (binding !== this.unifiedObservedBinding) {
      this.unifiedObservedBinding = binding; this.unifiedCost = false; this.unifiedBaseline = false;
    }
    void this.refreshUnified();
  }
  private statusText(): string {
    if (this.credential === EmbeddingCredentialStatus.Unavailable) { return '暂不可用'; }
    if (this.credential !== EmbeddingCredentialStatus.Configured) { return '未保存 Key'; }
    if (this.detection === EmbeddingDetectionStatus.Running) { return '正在确认'; }
    return this.detection === EmbeddingDetectionStatus.Passed ? '可用' : 'Key 已保存';
  }
  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('r2-embedding-back').accessibilityText('返回').onClick((): void => { this.onBack(); })
        Column({ space: 3 }) {
          Text('嵌入模型').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('把资料变成可以“按意思”搜索的内容').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.feedbackVisible && this.message.length > 0) { Text(this.message).fontColor(Theme.amber).fontSize(13).lineHeight(21).width('100%') }
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Column({ space: 4 }) {
            Text('模型').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
            Text('硅基流动 · BAAI/bge-m3').fontColor(Theme.muted).fontSize(12).width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text(this.statusText()).fontSize(11).fontColor(this.credential === EmbeddingCredentialStatus.Configured ? Theme.accent : Theme.muted)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(10).id('upd-embedding-status')
        }.width('100%')
        Text('Key 在「API Key 管理」中保存和修改。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        Button('管理 API Key').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-embedding-open-keys').onClick((): void => { this.onKeys(); })
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Column({ space: 12 }) {
        Text('自动入库').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
        Text('开启后，新导入资料的正文、图片文字和图片描述会自动发送到硅基流动，准备成可以按意思搜索的内容，可能产生费用。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        if (this.unifiedNeedsConfirmation) { Text('配置或 Key 已变化，请重新确认发送范围、费用与当前配置后恢复自动入库。').fontColor(Theme.amber).fontSize(13).width('100%').id('upd-embedding-config-changed') }
        if (!this.unifiedOn) {
          Row({ space: 8 }) {
            Checkbox().selectedColor(Theme.accent).id('upd-embedding-cost').select(this.unifiedCost).onChange((v: boolean): void=> { this.unifiedCost=v; })
            Text('我确认上述内容会自动发送，并接受可能费用').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
          }.width('100%')
          Row({ space: 8 }) {
            Checkbox().selectedColor(Theme.accent).id('upd-embedding-baseline').select(this.unifiedBaseline).onChange((v: boolean): void=> { this.unifiedBaseline=v; })
            Text('用 BAAI/bge-m3 处理我的资料').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
          }.width('100%')
        }
        Button(this.unifiedOn?'关闭自动入库':this.unifiedNeedsConfirmation?'重新确认并恢复自动入库':'开启自动入库').fontSize(14).fontColor(this.unifiedOn ? Theme.accent : Color.White).backgroundColor(this.unifiedOn ? Theme.soft : Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-embedding-enable').enabled(this.unifiedSettings!==undefined && !this.busy && !this.unifiedSaving && (this.unifiedOn || this.unifiedCost && this.unifiedBaseline)).onClick((): void=> { this.saveUnified(); })
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
