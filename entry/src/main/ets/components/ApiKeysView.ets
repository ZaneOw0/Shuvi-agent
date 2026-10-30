import util from '@ohos.util';
import { Theme } from './Theme';
import { DeepSeekKeyService, DeepSeekKeyStatus, TavilyKeyService } from '../services/model/DeepSeekCredentialStore';
import { EmbeddingService } from '../knowledge/application/EmbeddingService';
import { DocumentParseService } from '../knowledge/application/DocumentParseService';
import { EmbeddingCredentialStatus, EmbeddingDetectionStatus, EmbeddingProvider } from '../knowledge/domain/EmbeddingModels';
import { EmbeddingPinnedBasis } from '../knowledge/domain/EmbeddingBasisModels';
import { DocumentCredentialStatus } from '../knowledge/domain/DocumentParseModels';
import { KnowledgeCallbackListener } from '../knowledge/domain/KnowledgePorts';
import { UnifiedSettingsService } from '../knowledge/application/UnifiedSettingsService';
import { UnifiedProcessingSettings } from '../knowledge/domain/UnifiedKnowledgeModels';
import { ApiKeySync } from '../services/model/ApiKeySync';

/** One provider's key: a password field that is cleared on every save, plus save/update and delete. */
@Component
struct ApiKeyCard {
  @Prop name: string = '';
  @Prop usage: string = '';
  @Prop secretName: string = 'Key';
  @Prop idPrefix: string = 'api-keys';
  @Prop saved: boolean = false;
  @Prop unavailable: boolean = false;
  @Prop ready: boolean = true;
  @Prop busy: boolean = false;
  @Prop note: string = '';
  @Prop @Watch('clearInput') clearEpoch: number = 0;
  @State input: string = '';
  onSave: (value: string) => void = (_value: string): void => {};
  onRemove: () => void = (): void => {};
  private controller: TextInputController = new TextInputController();

  aboutToDisappear(): void { this.input = ''; }
  private clearInput(): void { this.input = ''; this.controller.stopEditing(); }
  private save(): void {
    const value: string = this.input.trim(); this.clearInput();
    if (value.length > 0) { this.onSave(value); }
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.name).fontSize(Theme.titleSize).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
        Text(this.unavailable ? '暂不可用' : (this.saved ? '已保存' : '未保存')).fontSize(11)
          .fontColor(this.saved ? Theme.ok : Theme.muted).backgroundColor(this.saved ? Theme.okSoft : Theme.soft)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).borderRadius(10).id(`${this.idPrefix}-status`)
      }.width('100%')
      Text(this.usage).fontSize(Theme.noteSize).fontColor(Theme.muted).lineHeight(19).width('100%')
      TextInput({ text: this.input, placeholder: this.saved ? `输入新 ${this.secretName} 以替换` : `${this.name} ${this.secretName}`,
        controller: this.controller })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(false)
        .enableAutoFill(false).enablePreviewText(false).maxLength(2048).enabled(!this.busy && this.ready)
        .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight })
        .accessibilityText(`${this.name} ${this.secretName}，允许粘贴`).id(`${this.idPrefix}-input`)
        .onChange((value: string): void => { this.input = value; })
      Row({ space: 10 }) {
        Button(this.saved ? '更新' : '保存').fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent)
          .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).layoutWeight(1)
          .enabled(!this.busy && this.ready && this.input.trim().length > 0).id(`${this.idPrefix}-save`)
          .onClick((): void => { this.save(); })
        Button('删除').fontSize(14).fontColor(Theme.danger).backgroundColor(Theme.soft)
          .borderRadius(Theme.radius).constraintSize({ minHeight: Theme.controlHeight }).layoutWeight(1)
          .enabled(!this.busy && this.ready && this.saved).id(`${this.idPrefix}-remove`)
          .onClick((): void => { this.clearInput(); this.onRemove(); })
      }.width('100%')
      if (this.note.length > 0) { Text(this.note).fontSize(12).fontColor(Theme.muted).width('100%').id(`${this.idPrefix}-note`) }
    }.width('100%').padding(16).backgroundColor(Theme.surface).borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
  }
}

/**
 * One place to store and change the API keys the app uses. Keys go only to the device Asset Store (never synced or
 * shown again). This page does not test connectivity; the only request it makes is the single fixed embedding sentence
 * the knowledge base needs to learn the vector dimension, sent automatically after a SiliconFlow key is saved.
 */
@Component
export struct ApiKeysView {
  embedding: EmbeddingService | undefined = undefined;
  parse: DocumentParseService | undefined = undefined;
  /** Knowledge-base settings: image understanding keeps a copy of the DeepSeek key, auto-ingest binds the SiliconFlow key. */
  settings: UnifiedSettingsService | undefined = undefined;
  @Prop parseCredential: string = '';
  onBack: () => void = (): void => {};
  onDeepSeekChanged: () => void = (): void => {};
  @State deepSeekStatus: DeepSeekKeyStatus = DeepSeekKeyStatus.Checking;
  @State deepSeekNote: string = '';
  @State embeddingNote: string = '';
  @State embeddingSaved: boolean = false;
  @State embeddingUnavailable: boolean = false;
  @State mineruNote: string = '';
  @State tavilyStatus: DeepSeekKeyStatus = DeepSeekKeyStatus.Checking;
  @State tavilyNote: string = '';
  @State busy: boolean = false;
  @State clearEpoch: number = 0;
  private listener: KnowledgeCallbackListener = new KnowledgeCallbackListener((): void => { this.embeddingChanged(); });

  aboutToAppear(): void {
    void this.refreshDeepSeek(); void this.refreshTavily();
    this.embedding?.subscribe(this.listener); this.embeddingChanged();
  }
  aboutToDisappear(): void { this.clearEpoch++; this.embedding?.unsubscribe(this.listener); }
  private embeddingChanged(): void {
    const service: EmbeddingService | undefined = this.embedding;
    this.embeddingSaved = service !== undefined && service.state.credential === EmbeddingCredentialStatus.Configured;
    this.embeddingUnavailable = service === undefined || service.state.credential === EmbeddingCredentialStatus.Unavailable;
  }
  private async refreshDeepSeek(): Promise<void> {
    try { this.deepSeekStatus = await DeepSeekKeyService.store.status(); }
    catch { this.deepSeekStatus = DeepSeekKeyStatus.Unavailable; }
  }

  private async refreshTavily(): Promise<void> {
    try { this.tavilyStatus = await TavilyKeyService.store.status(); }
    catch { this.tavilyStatus = DeepSeekKeyStatus.Unavailable; }
  }
  private async saveTavily(value: string): Promise<void> {
    if (this.busy) { return; }
    const key: Uint8Array = new util.TextEncoder().encodeInto(value);
    this.busy = true; this.tavilyNote = '';
    try {
      await TavilyKeyService.store.save(key);
      this.tavilyNote = '已保存。在助手页打开「搜索」即可使用；之前没连上的话，点「重新连接」。';
    }
    catch { this.tavilyNote = '没有保存：Key 格式不正确或本机安全存储暂不可用。'; }
    finally { key.fill(0); await this.refreshTavily(); this.busy = false; }
  }
  private async removeTavily(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try { await TavilyKeyService.store.remove(); this.tavilyNote = '已删除。'; }
    catch { this.tavilyNote = '删除没有完成，请稍后重试。'; }
    finally { await this.refreshTavily(); this.busy = false; }
  }

  private async visionWasOn(): Promise<boolean> {
    try { return (await this.settings?.setting('Vision'))?.enabled ?? false; } catch { return false; }
  }
  private async saveDeepSeek(value: string): Promise<void> {
    if (this.busy) { return; }
    const key: Uint8Array = new util.TextEncoder().encodeInto(value);
    this.busy = true; this.deepSeekNote = '';
    try {
      await DeepSeekKeyService.store.save(key);
      // Image understanding uses the same DeepSeek key; replacing it pauses automatic image understanding until re-enabled.
      const visionOn: boolean = await this.visionWasOn();
      const followed: boolean = await ApiKeySync.followDeepSeek(this.settings, value, false);
      this.deepSeekNote = '已保存。回到助手页会自动连接。' + (!followed && this.settings !== undefined ? '图片理解暂时没能同步这个 Key，可稍后重新保存。' :
        (visionOn ? '自动图片理解已暂停，需要时到「我的 → 图片理解」重新开启。' : ''));
    }
    catch { this.deepSeekNote = '没有保存：Key 格式不正确或本机安全存储暂不可用。'; }
    finally { key.fill(0); await this.refreshDeepSeek(); this.busy = false; this.onDeepSeekChanged(); }
  }
  private async removeDeepSeek(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      await DeepSeekKeyService.store.remove();
      await ApiKeySync.followDeepSeek(this.settings, '', true);
      this.deepSeekNote = '已删除。';
    }
    catch { this.deepSeekNote = '删除没有完成，请稍后重试。'; }
    finally { await this.refreshDeepSeek(); this.busy = false; this.onDeepSeekChanged(); }
  }

  /** A new SiliconFlow key keeps auto-ingest on when the user had already turned it on and accepted its scope and cost. */
  private async keepAutoIngest(): Promise<boolean> {
    const settings: UnifiedSettingsService | undefined = this.settings;
    if (settings === undefined) { return false; }
    try {
      const current: UnifiedProcessingSettings = await settings.setting('Embedding');
      if (!current.enabled || !current.costAcknowledged || !current.baselineAccepted) { return false; }
      await settings.enableEmbedding(true, true, true); return true;
    } catch { return false; }
  }

  private async saveEmbedding(value: string): Promise<void> {
    const service: EmbeddingService | undefined = this.embedding;
    if (this.busy || service === undefined) { return; }
    this.busy = true; this.embeddingNote = '正在保存…';
    try {
      // The product uses one fixed embedding model; set it only when it is not already the saved configuration.
      if (service.state.config.provider !== EmbeddingProvider.SiliconFlow) { await service.select(EmbeddingProvider.SiliconFlow); }
      if (service.state.config.modelId !== EmbeddingPinnedBasis.model || service.state.config.mutationPending) {
        await service.preparePinnedModel();
      }
      await service.changeCredential(value, service.state.credential === EmbeddingCredentialStatus.Configured);
      if (service.state.credential !== EmbeddingCredentialStatus.Configured) {
        this.embeddingNote = '没有保存：Key 格式不正确或本机安全存储暂不可用。'; return;
      }
      // One fixed, non-sensitive sentence that records the vector dimension the knowledge base needs. Never retried.
      this.embeddingNote = '已保存，正在确认 Key…';
      await service.probe(true);
      if (service.state.detection.status !== EmbeddingDetectionStatus.Passed) {
        this.embeddingNote = '已保存，但硅基流动没有确认这个 Key（Key 无效、余额不足或网络不可用）。检查后可重新保存。'; return;
      }
      this.embeddingNote = await this.keepAutoIngest() ? '已保存，自动入库保持开启。' :
        '已保存。到「我的 → 嵌入模型」开启自动入库后，新资料会自动准备好检索。';
    } catch { this.embeddingNote = '保存没有完成，请稍后重试。'; }
    finally { this.busy = false; this.embeddingChanged(); }
  }
  private async removeEmbedding(): Promise<void> {
    const service: EmbeddingService | undefined = this.embedding;
    if (this.busy || service === undefined) { return; }
    this.busy = true;
    try {
      await service.changeCredential('', false, true);
      this.embeddingNote = service.state.credential === EmbeddingCredentialStatus.Missing ?
        '已删除。已完成的资料和检索结果会保留。' : '删除没有完成，请稍后重试。';
    }
    catch { this.embeddingNote = '删除没有完成，请稍后重试。'; }
    finally { this.busy = false; this.embeddingChanged(); }
  }

  private async saveMineru(value: string): Promise<void> {
    const service: DocumentParseService | undefined = this.parse;
    if (this.busy || service === undefined) { return; }
    this.busy = true; this.mineruNote = '';
    try {
      // Saving a token always switches cloud parsing off until the user turns it on again in 解析引擎.
      await service.saveToken(value, this.parseCredential === DocumentCredentialStatus.Configured);
      this.mineruNote = service.state.credential === DocumentCredentialStatus.Configured ?
        '已保存。需要时到「我的 → 解析引擎」开启云端解析。' : '没有保存：Token 格式不正确或本机安全存储暂不可用。';
    }
    catch { this.mineruNote = '没有保存：Token 格式不正确或本机安全存储暂不可用。'; }
    finally { this.busy = false; }
  }
  private async removeMineru(): Promise<void> {
    const service: DocumentParseService | undefined = this.parse;
    if (this.busy || service === undefined) { return; }
    this.busy = true;
    try {
      await service.removeToken();
      this.mineruNote = service.state.credential === DocumentCredentialStatus.Missing ? '已删除。已导入的资料不受影响。' : '删除没有完成，请稍后重试。';
    }
    catch { this.mineruNote = '删除没有完成，请稍后重试。'; }
    finally { this.busy = false; }
  }

  private confirm(title: string, message: string, action: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title, message: message,
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: action }
    });
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).id('api-keys-back').accessibilityText('返回')
          .onClick((): void => { this.clearEpoch++; this.onBack(); })
        Column({ space: 3 }) {
          Text('API Key 管理').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('只保存在本机系统安全存储，不同步，保存后不再显示').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')

      ApiKeyCard({ name: 'DeepSeek', idPrefix: 'api-keys-deepseek', busy: this.busy, clearEpoch: this.clearEpoch,
        saved: this.deepSeekStatus === DeepSeekKeyStatus.Saved, unavailable: this.deepSeekStatus === DeepSeekKeyStatus.Unavailable,
        note: this.deepSeekNote,
        usage: '用于助手对话、日程、文档、知识库回答和图片理解。保存即表示同意：发送消息时，对话内容、你附带的图片（压缩后发送，不含文件名和位置信息）和模型选用的文档正文会发送到 DeepSeek（api.deepseek.com），可能产生费用，以供应商账单为准。',
        onSave: (value: string): void => { void this.saveDeepSeek(value); },
        onRemove: (): void => {
          this.confirm('删除 DeepSeek Key？', '删除后助手、知识库回答和图片理解都需要重新保存 Key 才能使用。',
            (): void => { void this.removeDeepSeek(); });
        } })

      ApiKeyCard({ name: '硅基流动', idPrefix: 'api-keys-embedding', busy: this.busy, clearEpoch: this.clearEpoch,
        saved: this.embeddingSaved, unavailable: this.embeddingUnavailable, ready: this.embedding !== undefined,
        note: this.embedding === undefined ? '本机资料库还没打开，请稍后重新进入本页。' : this.embeddingNote,
        usage: '嵌入模型 BAAI/bge-m3，让知识库能“按意思”找到相关资料。保存后会自动发送一条固定短句，确认向量格式；开启自动入库后，资料正文会发送到硅基流动，可能产生费用。',
        onSave: (value: string): void => { void this.saveEmbedding(value); },
        onRemove: (): void => {
          this.confirm('删除硅基流动 Key？', '删除后不能再为新资料生成检索内容，知识库问答也会暂停。已完成的资料和检索结果会保留。',
            (): void => { void this.removeEmbedding(); });
        } })

      ApiKeyCard({ name: 'MinerU', secretName: 'Token', idPrefix: 'api-keys-mineru', busy: this.busy, clearEpoch: this.clearEpoch,
        saved: this.parseCredential === DocumentCredentialStatus.Configured,
        unavailable: this.parseCredential === DocumentCredentialStatus.Unavailable, ready: this.parse !== undefined,
        note: this.parse === undefined ? '文档解析服务还没打开，请稍后重新进入本页。' : this.mineruNote,
        usage: '文档解析，用于识别 PDF、Word 和图片里的文字、表格与版式。保存不会上传任何文件；文件在导入时逐份确认后才发送。',
        onSave: (value: string): void => { void this.saveMineru(value); },
        onRemove: (): void => {
          this.confirm('删除 MinerU Token？', '删除后需要重新保存 Token 才能继续使用云端解析。已导入的资料不受影响。',
            (): void => { void this.removeMineru(); });
        } })

      ApiKeyCard({ name: 'Tavily', idPrefix: 'api-keys-tavily', busy: this.busy, clearEpoch: this.clearEpoch,
        saved: this.tavilyStatus === DeepSeekKeyStatus.Saved, unavailable: this.tavilyStatus === DeepSeekKeyStatus.Unavailable,
        note: this.tavilyNote,
        usage: '用于助手页的联网搜索。保存即表示同意：每次搜索前会先请你确认关键词，确认后关键词会从本机直接发送到 Tavily（api.tavily.com），可能消耗额度、产生费用，以供应商账单为准。',
        onSave: (value: string): void => { void this.saveTavily(value); },
        onRemove: (): void => {
          this.confirm('删除 Tavily Key？', '删除后联网搜索需要重新保存 Key 才能使用。已有的搜索结果不受影响。',
            (): void => { void this.removeTavily(); });
        } })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }
}
