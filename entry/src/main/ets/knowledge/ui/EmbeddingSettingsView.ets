import { Theme } from '../../components/Theme';
import { EmbeddingService, copyEmbeddingConfig } from '../application/EmbeddingService';
import { EmbeddingConfig, EmbeddingProvider, EmbeddingRegion, EmbeddingAccess, EmbeddingModelInfo, EmbeddingModelSource } from '../domain/EmbeddingModels';
import { KnowledgeCallbackListener } from '../domain/KnowledgePorts';
import { embeddingFingerprint } from '../pipeline/EmbeddingPolicy';
import { embeddingPublicAudit } from '../infra/EmbeddingPublicAudit';
import { UnifiedSettingsService } from '../application/UnifiedSettingsService';
import { UnifiedProcessingSettings } from '../domain/UnifiedKnowledgeModels';

@Component
export struct EmbeddingSettingsView {
  unifiedSettings: UnifiedSettingsService | undefined=undefined;
  @State unifiedCost: boolean=false;
  @State unifiedBaseline: boolean=false;
  @State unifiedOn: boolean=false;
  private async saveUnified(): Promise<void> { try { await this.unifiedSettings?.enableEmbedding(!this.unifiedOn,this.unifiedCost,this.unifiedBaseline); this.unifiedOn=(await this.unifiedSettings?.setting('Embedding'))?.enabled ?? false; this.unifiedCost=false; this.unifiedBaseline=false; this.message='统一自动全量设置已保存'; } catch { this.message='统一模式需当前配置/工程基线与可能费用确认'; } }
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
  aboutToAppear(): void { this.service?.subscribe(this.listener); this.changed(); this.unifiedSettings?.setting('Embedding').then((s: UnifiedProcessingSettings): void=> { this.unifiedOn=s.enabled; }).catch((): void=> { this.message='统一设置读取失败'; }); }
  aboutToDisappear(): void { this.clearSecret(); this.service?.unsubscribe(this.listener); }
  clearSecret(): void { this.secretInput = ''; this.passwordController.stopEditing(); }
  changed(): void {
    if (this.service === undefined) { this.message = '本机配置服务不可用，未发送请求'; return; }
    this.config = copyEmbeddingConfig(this.service.state.config); this.credentialLabel = this.service.state.credential;
    this.message = this.service.state.message; this.busy = this.service.state.busy; this.modelRows = this.service.state.models.slice();
    this.detectionLabel = `${this.service.state.detection.status} · ${this.service.state.detection.dimension} 维 · ${this.service.state.detection.elapsedMs} ms`;
    this.clearSecret();
  }
  private async selectProvider(index: number): Promise<void> {
    this.clearSecret(); this.freeList = false; this.freeProbe = false;
    const providers: EmbeddingProvider[] = [EmbeddingProvider.SiliconFlow,EmbeddingProvider.Bailian,EmbeddingProvider.Gemini,EmbeddingProvider.OpenAI];
    try { await this.service?.select(providers[index]); } catch { this.message = '配置读取失败，未联网'; }
  }
  private async saveConfiguration(): Promise<void> {
    this.clearSecret(); try { await this.service?.saveConfiguration(this.config); } catch { this.message = '配置未保存，输入不合法或本机能力失败'; }
  }
  private async saveCredential(): Promise<void> {
    let input: string = this.secretInput; this.clearSecret();
    try { if (this.service === undefined) { this.message = '安全存储服务不可用'; return; } await this.service.changeCredential(input,this.credentialLabel === 'Configured'); }
    catch { this.message = '安全存储操作未确认，没有明文降级'; }
    finally { input = ''; this.clearSecret(); }
  }
  private configurationSaved(): boolean { return this.service !== undefined && embeddingFingerprint(this.config) === embeddingFingerprint(this.service.state.config); }
  private networkEnabled(): boolean { return this.configurationSaved() && (this.config.provider === EmbeddingProvider.SiliconFlow || this.config.provider === EmbeddingProvider.Bailian); }
  private async auditPublic(): Promise<void> { const context = this.getUIContext().getHostContext(); if (context !== undefined) { await embeddingPublicAudit(context); } }
  build() {
    Column({ space: 14 }) {
      Row() {
        Button('‹ 返回').id('r2-embedding-back').onClick((): void => { this.clearSecret(); this.onBack(); }).constraintSize({ minHeight: 44 })
      Text('嵌入模型').fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%')
      Text('统一新导入自动全量：正文/OCR与图片描述+标签。接收方为当前硅基流动 BGE-M3，可能收费；旧免费许可不授权此模式。').fontSize(13).width('100%')
      Row() { Checkbox().id('upd-embedding-cost').select(this.unifiedCost).onChange((v: boolean): void=> { this.unifiedCost=v; }); Text('确认全部上述实际文本自动发送及可能费用').layoutWeight(1) }.width('100%')
      Row() { Checkbox().id('upd-embedding-baseline').select(this.unifiedBaseline).onChange((v: boolean): void=> { this.unifiedBaseline=v; }); Text('接受当前配置的新统一policy工程基线；非供应商用量保证').layoutWeight(1) }.width('100%')
      Button(this.unifiedOn?'关闭统一自动嵌入':'启用统一自动全量嵌入').id('upd-embedding-enable').enabled(this.unifiedSettings!==undefined && (this.unifiedOn || this.unifiedCost && this.unifiedBaseline)).onClick((): void=> { this.saveUnified(); })
      Select([{ value: '硅基流动' },{ value: '阿里云百炼' },{ value: 'Gemini' },{ value: 'OpenAI' }])
        .value(this.config.provider).enabled(!this.busy).onSelect((index: number): void => { this.selectProvider(index); })
      if (this.config.provider === EmbeddingProvider.Bailian) {
        Select([{ value: '未选择地域' },{ value: '北京' },{ value: '新加坡' }]).value(this.config.region).enabled(!this.busy)
          .onSelect((index: number): void => { const regions: EmbeddingRegion[] = [EmbeddingRegion.Unselected,EmbeddingRegion.Beijing,EmbeddingRegion.Singapore]; this.config.region = regions[index]; this.clearSecret(); })
        Select([{ value: '官方公共接入' },{ value: '官方 Workspace 接入' }]).value(this.config.access).enabled(!this.busy)
          .onSelect((index: number): void => { this.config.access = index === 0 ? EmbeddingAccess.Public : EmbeddingAccess.Workspace; this.clearSecret(); })
        if (this.config.access === EmbeddingAccess.Workspace) {
          TextInput({ text: this.config.workspaceId, placeholder: 'Workspace ID（非 Host）' }).maxLength(63).enabled(!this.busy)
            .onChange((text: string): void => { this.config.workspaceId = text; })
        }
        Text('自动发现未支持，手填官方模型 ID；不同地域和接入的 Key 不共用').fontSize(13).fontColor(Theme.muted)
      }
      TextInput({ text: this.config.modelId, placeholder: '官方模型 ID' }).maxLength(512).enabled(!this.busy)
        .onChange((text: string): void => { this.config.modelId = text; this.config.modelSource = EmbeddingModelSource.Manual; })
      Text(`模型来源：${this.config.modelSource}`).fontSize(13).fontColor(Theme.muted)
      Button('保存本机配置').enabled(this.service !== undefined && !this.busy).constraintSize({ minHeight: 44 }).onClick((): void => { this.saveConfiguration(); })
      Text(`Key：${this.credentialLabel}`).fontSize(14)
      TextInput({ text: this.secretInput, placeholder: '输入新 Key，不回显已保存值', controller: this.passwordController })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true).enableAutoFill(false).enablePreviewText(false).maxLength(1024).enabled(!this.busy)
        .onChange((text: string): void => { this.secretInput = text; })
      Row({ space: 12 }) {
        Button('保存 / 更新 Key').enabled(this.configurationSaved() && !this.busy && this.secretInput.length > 0).constraintSize({ minHeight: 44 }).onClick((): void => { this.saveCredential(); })
        Button('删除 Key').enabled(this.configurationSaved() && !this.busy && this.credentialLabel === 'Configured').constraintSize({ minHeight: 44 })
          .onClick((): void => { this.clearSecret(); this.service?.changeCredential('',false,true); })
      }.width('100%')
      if (!this.networkEnabled()) { Text('ContractUnverified：官方正文未核，模型发现与真实请求禁用').fontSize(14).fontColor(Theme.amber) }
      Row({ space: 10 }) {
        Checkbox().id('r2-models-free').select(this.freeList).enabled(!this.busy).onChange((checked: boolean): void => { this.freeList = checked; })
        Text('确认本次模型列表请求的免费资格；客户端不保证余额').fontSize(13).layoutWeight(1)
      }.width('100%')
      Button('获取当前 Key 的嵌入模型').id('r2-models-request').constraintSize({ minHeight: 44 })
        .enabled(this.configurationSaved() && !this.busy && this.config.provider === EmbeddingProvider.SiliconFlow && this.freeList)
        .onClick((): void => { const free: boolean = this.freeList; this.freeList = false; this.service?.discover(free); })
      ForEach(this.modelRows, (model: EmbeddingModelInfo) => {
        Button(model.id).width('100%').constraintSize({ minHeight: 44 }).enabled(!this.busy)
          .onClick((): void => { this.config.modelId = model.id; this.config.modelSource = model.source; })
      }, (model: EmbeddingModelInfo): string => model.id)
      Text(this.message).fontSize(14).fontColor(Theme.ink).width('100%')
      Row({ space: 10 }) {
        Checkbox().id('r2-probe-free').select(this.freeProbe).enabled(!this.busy).onChange((checked: boolean): void => { this.freeProbe = checked; })
        Text('同意本次仅发送一条固定非敏感短句，并确认免费资格；不发送资料或问题').fontSize(13).layoutWeight(1)
      }.width('100%')
      Button('检测固定短句（一次请求）').id('r2-probe-request').constraintSize({ minHeight: 44 })
        .enabled(this.service !== undefined && !this.busy && this.networkEnabled() && this.freeProbe && this.credentialLabel === 'Configured')
        .onClick((): void => { const free: boolean = this.freeProbe; this.freeProbe = false; this.service?.probe(free); })
      Text(this.detectionLabel).fontSize(14).fontColor(Theme.ink).width('100%')
      Button('仅审计公开请求状态').id('r2-embedding-audit').onClick((): void => { this.auditPublic(); })
      Text(`${this.service?.corpusGate() ?? 'InputLimitUnverified'}：保存、列表和固定句检测不构成文档或问题外发同意`).fontSize(13).fontColor(Theme.amber).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
