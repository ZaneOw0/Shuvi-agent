import { Theme } from '../../components/Theme';
import { EmbeddingService, copyEmbeddingConfig } from '../application/EmbeddingService';
import { EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess, EmbeddingModelInfo, EmbeddingModelSource } from '../domain/EmbeddingModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingPublicAudit } from '../infra/EmbeddingPublicAudit';
import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedProcessingSettings } from '../domain/UnifiedKnowledgeModels';
import { embeddingConfigBinding } from '../pipeline/EmbeddingBasisPolicy';

@Component
export struct EmbeddingSettingsView {
  unifiedSettings: UnifiedSettingsService | undefined=undefined;
  @State feedbackVisible: boolean = false;
  @State advancedOpen: boolean = false;
  @State unifiedCost: boolean=false;
  @State unifiedBaseline: boolean=false;
  @State unifiedOn: boolean=false;
  @State unifiedNeedsConfirmation: boolean=false;
  @State unifiedSaving: boolean=false;
  private unifiedRefreshEpoch: number=0;
  private unifiedObservedBinding: string='';
  private async refreshUnified(): Promise<void> {
    const epoch: number=++this.unifiedRefreshEpoch;
    try {
      const settings: UnifiedProcessingSettings | undefined=await this.unifiedSettings?.setting('Embedding');
      if (epoch!==this.unifiedRefreshEpoch || settings===undefined) { return; }
      const matches: boolean=settings.configBinding===embeddingConfigBinding(this.config) && settings.credentialRevision===this.config.credentialRevision && !this.config.mutationPending;
      this.unifiedOn=settings.enabled && settings.baselineAccepted && matches;
      this.unifiedNeedsConfirmation=settings.configBinding.length>0 && (!matches || settings.paused && !settings.baselineAccepted);
    } catch { if (epoch===this.unifiedRefreshEpoch) { this.unifiedOn=false; this.message='自动入库设置读取失败'; } }
  }
  private async saveUnified(): Promise<void> {
    if (this.unifiedSaving || this.busy || this.unifiedSettings===undefined) { return; }
    this.feedbackVisible=true; this.unifiedSaving=true;
    try { await this.unifiedSettings.enableEmbedding(!this.unifiedOn,this.unifiedCost,this.unifiedBaseline); await this.refreshUnified(); this.unifiedCost=false; this.unifiedBaseline=false; this.message='自动入库设置已保存'; }
    catch { this.message='请先确认发送范围与可能费用，并接受当前配置基线'; }
    finally { this.unifiedSaving=false; }
  }
  service: EmbeddingService | undefined = undefined;
  onBack: () => void = (): void => {};
  @Prop @Watch('clearSecret') clearEpoch: number = 0;
  @State config: EmbeddingConfig = new EmbeddingConfig();
  @State credentialLabel: string = 'Missing';
  @State message: string = '';
  @State busy: boolean = false;
  @State secretInput: string = '';
  @State modelRows: EmbeddingModelInfo[] = [];
  @State freeList: boolean = false;
  @State freeProbe: boolean = false;
  @State detectionLabel: string = 'Untested';
  private passwordController: TextInputController = new TextInputController();
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.changed(); });
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.changed(); }
  aboutToDisappear(): void { this.unifiedRefreshEpoch++; this.clearSecret(); this.service?.unsubscribe(this.listener); }
  clearSecret(): void { this.secretInput = ''; this.passwordController.stopEditing(); }
  changed(): void {
    if (this.service === undefined) { this.message = '本机配置服务不可用，未发送请求'; return; }
    this.config = copyEmbeddingConfig(this.service.state.config); this.credentialLabel = this.service.state.credential;
    const binding: string=embeddingConfigBinding(this.config);
    if (this.unifiedObservedBinding!==binding) { this.unifiedObservedBinding=binding; this.unifiedCost=false; this.unifiedBaseline=false; }
    this.message = this.service.state.message; this.busy = this.service.state.busy; this.modelRows = this.service.state.models.slice();
    this.detectionLabel = this.detectionText(this.service.state.detection.status, this.service.state.detection.dimension, this.service.state.detection.elapsedMs);
    this.clearSecret();
    this.refreshUnified();
  }
  private async selectProvider(index: number): Promise<void> {
    this.clearSecret(); this.freeList = false; this.freeProbe = false;
    const providers: EmbeddingProvider[] = [EmbeddingProvider.SiliconFlow,EmbeddingProvider.Bailian,EmbeddingProvider.Gemini,EmbeddingProvider.OpenAI];
    try { await this.service?.select(providers[index]); } catch { this.message = '配置读取失败，未联网'; }
  }
  private async saveConfiguration(): Promise<void> {
    this.feedbackVisible=true; this.clearSecret(); try { await this.service?.saveConfiguration(this.config); } catch { this.message = '配置未保存，输入不合法或本机能力失败'; }
  }
  private async saveCredential(): Promise<void> {
    this.feedbackVisible=true; let input: string = this.secretInput; this.clearSecret();
    try { if (this.service === undefined) { this.message = '安全存储服务不可用'; return; } await this.service.changeCredential(input,this.credentialLabel === 'Configured'); }
    catch { this.message = '安全存储操作未确认，没有明文降级'; }
    finally { input = ''; this.clearSecret(); }
  }
  private confirmRemoveKey(): void {
    this.clearSecret(); this.feedbackVisible = true;
    this.getUIContext().showAlertDialog({
      title: '删除嵌入模型 Key？',
      message: '删除后需要重新填写 Key 才能生成新的语义检索内容。已完成的资料和检索结果会保留。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除 Key', action: (): void => { this.service?.changeCredential('',false,true); } }
    });
  }
  private detectionText(status: string, dimension: number, elapsedMs: number): string {
    const label: string = status === 'Passed' ? '检测通过' : status === 'Failed' ? '检测未通过' : status === 'Running' ? '正在检测' : status === 'Stale' ? '配置已变化，需要重新检测' : '尚未检测';
    if (label !== '检测通过' || dimension <= 0) { return label; }
    return `${label} · ${dimension} 维${elapsedMs > 0 ? ' · ' + String(elapsedMs) + ' ms' : ''}`;
  }
  private providerText(): string {
    if (this.config.provider === EmbeddingProvider.SiliconFlow) { return '硅基流动'; }
    if (this.config.provider === EmbeddingProvider.Bailian) { return '阿里云百炼'; }
    if (this.config.provider === EmbeddingProvider.Gemini) { return 'Gemini'; }
    return 'OpenAI';
  }
  private sourceText(): string { return this.config.modelSource === EmbeddingModelSource.Remote ? '从当前 Key 获取' : '手动填写'; }
  private configurationSaved(): boolean { return this.service !== undefined && embeddingFingerprint(this.config) === embeddingFingerprint(this.service.state.config); }
  private networkEnabled(): boolean { return this.configurationSaved() && (this.config.provider === EmbeddingProvider.SiliconFlow || this.config.provider === EmbeddingProvider.Bailian); }
  private async auditPublic(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await embeddingPublicAudit(context); } }
  private credentialText(): string { return this.credentialLabel === 'Configured' ? '已配置' : this.credentialLabel === 'Missing' ? '未配置' : '暂不可用'; }
  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('r2-embedding-back').accessibilityText('返回').onClick((): void => { this.clearSecret(); this.onBack(); })
        Column({ space: 3 }) {
          Text('嵌入模型').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('把资料变成可以“按意思”搜索的内容').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (this.feedbackVisible && this.message.length > 0) { Text(this.message).fontColor(Theme.amber).fontSize(13).lineHeight(21).width('100%') }
      Column({ space: 12 }) {
        Text('自动入库').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
        Text('开启后，新导入资料的正文、图片文字和图片描述会自动准备成可语义搜索的内容。当前使用硅基流动 BGE-M3，可能产生费用。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        if (this.unifiedNeedsConfirmation) { Text('配置或 Key 已变化，自动入库已暂停。请重新确认当前配置、发送范围与可能费用；已完成内容保留。').fontColor(Theme.amber).fontSize(13).lineHeight(21).width('100%').id('upd-embedding-config-changed') }
        Row({ space: 8 }) {
          Checkbox().selectedColor(Theme.accent).id('upd-embedding-cost').select(this.unifiedCost).onChange((v: boolean): void=> { this.unifiedCost=v; })
          Text('我确认上述内容会自动发送，并接受可能费用').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
        }.width('100%')
        Row({ space: 8 }) {
          Checkbox().selectedColor(Theme.accent).id('upd-embedding-baseline').select(this.unifiedBaseline).onChange((v: boolean): void=> { this.unifiedBaseline=v; })
          Text('接受当前配置作为本次处理的基准（不代表服务商用量保证）').fontColor(Theme.ink).fontSize(13).layoutWeight(1)
        }.width('100%')
        Button(this.unifiedOn?'关闭自动入库':this.unifiedNeedsConfirmation?'重新确认并恢复自动入库':'开启自动入库').fontSize(14).fontColor(this.unifiedOn ? Theme.accent : Color.White).backgroundColor(this.unifiedOn ? Theme.soft : Theme.accent).borderRadius(12).constraintSize({ minHeight: 46 }).width('100%').id('upd-embedding-enable').enabled(this.unifiedSettings!==undefined && !this.busy && !this.unifiedSaving && (this.unifiedOn || this.unifiedCost && this.unifiedBaseline)).onClick((): void=> { this.saveUnified(); })
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Column({ space: 12 }) {
        Row({ space: 10 }) {
          Text('模型与凭据').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
          Text(this.credentialText()).fontSize(11).fontColor(this.credentialLabel === 'Configured' ? Theme.accent : Theme.muted)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(10)
        }.width('100%')
        Select([{ value: '硅基流动' },{ value: '阿里云百炼' },{ value: 'Gemini' },{ value: 'OpenAI' }])
          .value(this.providerText()).enabled(!this.busy).onSelect((index: number): void => { this.selectProvider(index); })
        if (this.config.provider === EmbeddingProvider.Bailian) {
          Select([{ value: '未选择地域' },{ value: '北京' },{ value: '新加坡' }]).value(this.config.region === EmbeddingRegion.Beijing ? '北京' : this.config.region === EmbeddingRegion.Singapore ? '新加坡' : '未选择地域').enabled(!this.busy)
            .onSelect((index: number): void => { const regions: EmbeddingRegion[] = [EmbeddingRegion.Unselected,EmbeddingRegion.Beijing,EmbeddingRegion.Singapore]; this.config.region = regions[index]; this.clearSecret(); })
          Select([{ value: '官方公共接入' },{ value: '官方 Workspace 接入' }]).value(this.config.access === EmbeddingAccess.Workspace ? '官方 Workspace 接入' : '官方公共接入').enabled(!this.busy)
            .onSelect((index: number): void => { this.config.access = index === 0 ? EmbeddingAccess.Public : EmbeddingAccess.Workspace; this.clearSecret(); })
          if (this.config.access === EmbeddingAccess.Workspace) {
            TextInput({ text: this.config.workspaceId, placeholder: 'Workspace ID（非 Host）' }).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).maxLength(63).enabled(!this.busy)
              .onChange((text: string): void => { this.config.workspaceId = text; })
          }
          Text('暂不支持自动发现，请填写官方模型 ID；不同地域与接入方式的 Key 不通用。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        }
        TextInput({ text: this.config.modelId, placeholder: '官方模型 ID' }).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).maxLength(512).enabled(!this.busy)
          .onChange((text: string): void => { this.config.modelId = text; this.config.modelSource = EmbeddingModelSource.Manual; })
        Text(`模型来源：${this.sourceText()}`).fontColor(Theme.muted).fontSize(12).width('100%')
        Button('保存本机配置').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(this.service !== undefined && !this.busy).onClick((): void => { this.saveConfiguration(); })
        TextInput({ text: this.secretInput, placeholder: '输入新 Key，不回显已保存值', controller: this.passwordController }).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line })
          .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true).enableAutoFill(false).enablePreviewText(false).maxLength(1024).enabled(!this.busy)
          .onChange((text: string): void => { this.secretInput = text; })
        Row({ space: 10 }) {
          Button('保存 / 更新 Key').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).enabled(this.configurationSaved() && !this.busy && this.secretInput.length > 0).onClick((): void => { this.saveCredential(); })
          Button('删除 Key').fontSize(14).fontColor(Theme.danger).backgroundColor(Theme.warning).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).enabled(this.configurationSaved() && !this.busy && this.credentialLabel === 'Configured').onClick((): void => { this.confirmRemoveKey(); })
        }.width('100%')
      }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      Button(this.advancedOpen ? '收起模型发现与检测' : '模型发现与检测').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('upd-embedding-advanced').onClick((): void => { this.advancedOpen = !this.advancedOpen; })
      if (this.advancedOpen) {
        Column({ space: 10 }) {
          if (!this.networkEnabled()) { Text('当前配置尚未核验，模型列表与检测暂不可用。').fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%') }
          Row({ space: 8 }) {
            Checkbox().selectedColor(Theme.accent).id('r2-models-free').select(this.freeList).enabled(!this.busy).onChange((checked: boolean): void => { this.freeList = checked; })
            Text('确认本次模型列表请求符合免费条件；客户端不保证账户余额').fontColor(Theme.ink).fontSize(12).layoutWeight(1)
          }.width('100%')
          Button('获取当前 Key 的嵌入模型').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('r2-models-request')
            .enabled(this.configurationSaved() && !this.busy && this.config.provider === EmbeddingProvider.SiliconFlow && this.freeList)
            .onClick((): void => { const free: boolean = this.freeList; this.freeList = false; this.service?.discover(free); })
          ForEach(this.modelRows, (model: EmbeddingModelInfo) => {
            Button(model.id).fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 44 }).width('100%').enabled(!this.busy)
              .onClick((): void => { this.config.modelId = model.id; this.config.modelSource = model.source; })
          }, (model: EmbeddingModelInfo): string => model.id)
          Row({ space: 8 }) {
            Checkbox().selectedColor(Theme.accent).id('r2-probe-free').select(this.freeProbe).enabled(!this.busy).onChange((checked: boolean): void => { this.freeProbe = checked; })
            Text('同意只发送一条固定、非敏感的短句做检测，并确认免费条件').fontColor(Theme.ink).fontSize(12).layoutWeight(1)
          }.width('100%')
          Button('检测固定短句（一次请求）').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('r2-probe-request')
            .enabled(this.service !== undefined && !this.busy && this.networkEnabled() && this.freeProbe && this.credentialLabel === 'Configured')
            .onClick((): void => { const free: boolean = this.freeProbe; this.freeProbe = false; this.service?.probe(free); })
          Text(`检测结果：${this.detectionLabel}`).fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          Button('仅审计公开请求状态').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('r2-embedding-audit').onClick((): void => { this.auditPublic(); })
          Text('保存配置、查看模型列表和固定句检测，都不代表同意发送你的资料或问题。').fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%')
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      }
      Text(this.service?.state.message ?? '').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
