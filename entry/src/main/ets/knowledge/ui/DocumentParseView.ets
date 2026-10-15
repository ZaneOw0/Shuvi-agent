import { Theme } from '../../components/Theme';
import { DocumentParseViewState, DocumentCredentialStatus, DocumentOriginal, DocumentTestAcknowledgement, DocumentParseTask, DocumentParseResultEnvelope } from '../domain/DocumentParseModels';
import { DocumentParseService } from '../application/DocumentParseService';

@Component
export struct DocumentParseView {
  @Link parseState: DocumentParseViewState;
  @Prop settingsMode: boolean = true;
  service: DocumentParseService | undefined = undefined;
  onClose: () => void = (): void => {};
  @Prop @Watch('clearSecret') clearEpoch: number = 0;
  @State private tokenInput: string = '';
  @State private resumeId: string = '';
  @State private deleteId: string = '';
  @State private slotConfirm: boolean = false;
  @State private showSettings: boolean = true;
  private tokenController: TextInputController = new TextInputController();
  clearSecret(): void { this.tokenInput = ''; this.tokenController.stopEditing(); }
  aboutToAppear(): void { this.showSettings = this.settingsMode; }
  aboutToDisappear(): void { this.clearSecret(); this.service?.clearInput(); }
  private async saveCredential(): Promise<void> {
    let input: string = this.tokenInput; this.clearSecret();
    try { await this.service?.saveToken(input, this.parseState.credential === DocumentCredentialStatus.Configured); }
    finally { input = ''; this.clearSecret(); }
  }
  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button('返回').onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.onClose(); })
        Text('MinerU 精准 · vlm').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%')
      Row({ space: 12 }) {
        Button('引擎设置', { type: ButtonType.Normal }).onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.showSettings = true; })
        Button('解析准备 / 任务', { type: ButtonType.Normal }).onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.showSettings = false; })
      }.width('100%')
      if (this.showSettings) {
      Text(this.parseState.credential).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.tokenInput, placeholder: '输入 Token', controller: this.tokenController })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true)
        .enableAutoFill(false).enablePreviewText(false)
        .maxLength(1025).onChange((text: string): void => { this.tokenInput = text; })
      Row({ space: 12 }) {
        Button('保存 / 更新').enabled(!this.parseState.busy && this.tokenInput.length > 0)
          .onClick((): void => { this.saveCredential(); })
        Button('删除凭据').enabled(!this.parseState.busy && this.parseState.credential === DocumentCredentialStatus.Configured)
          .onClick((): void => { this.clearSecret(); this.service?.removeToken(); })
      }.width('100%')
      }
      Text(this.parseState.message).fontSize(13).fontColor(Theme.muted).width('100%')
      Text(this.parseState.limitation).fontSize(13).fontColor(Theme.muted).width('100%')
      Text(this.service?.capabilitySummary() ?? '解析能力不可用').fontSize(13).fontColor(Theme.muted).width('100%')
      Row({ space: 12 }) {
        Text('启用解析（默认关闭）').layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.parseState.snapshot.config.enabled })
          .onChange((isOn: boolean): void => { this.service?.setEnabled(isOn); })
      }.width('100%')
      Text('普通个人资料外发门禁未通过。仅允许逐件非敏感免费测试；保存原件不代表同意上传。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      if (!this.showSettings) {
      Button('选择文件，仅保存原件').enabled(!this.parseState.busy).onClick((): void => { this.service?.prepare(); })
      ForEach(this.parseState.snapshot.originals, (original: DocumentOriginal) => {
        DocumentParseOriginalRow({ original: original, service: this.service, refreshEpoch: this.parseState.inputEpoch,
          submitBlockReason: this.service?.submitReason(original) ?? '解析能力不可用' })
      }, (original: DocumentOriginal): string => original.id)
      Text('解析任务').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      Button('暂停本机动作').onClick((): void => { this.clearSecret(); this.service?.pause(); })
      if (this.parseState.snapshot.occupancy.taskId.length > 0 && !this.parseState.snapshot.occupancy.terminalObserved) {
        Text('有未决云占用；本机暂停/删除不会解除。远端任务可能继续，留存与删除能力未知。').fontSize(13).fontColor(Theme.amber).width('100%')
        Button('核对原云任务').onClick((): void => { this.slotConfirm = true; })
      }
      ForEach(this.parseState.snapshot.tasks, (task: DocumentParseTask) => {
        Column({ space: 6 }) {
          Text(task.stage).fontWeight(FontWeight.Medium).width('100%')
          Text(`${task.dataId} · 查询 ${task.queries} 次 · ${task.extractedPages}/${task.totalPages || '未知'} 服务页`).fontSize(12).fontColor(Theme.muted).width('100%')
          Text(task.failure).fontSize(12).fontColor(Theme.muted).width('100%')
          Button('继续查询同一任务').enabled(!this.parseState.busy)
            .onClick((): void => { this.resumeId = task.id; })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (task: DocumentParseTask): string => task.id)
      ForEach(this.parseState.snapshot.results, (result: DocumentParseResultEnvelope) => {
        Column({ space: 6 }) {
          Text('结果已接收，待结构校验').fontWeight(FontWeight.Medium).width('100%')
          Text(`${result.bytes} 字节 · ${result.assetId}`).fontSize(12).width('100%')
          Text(`SHA256 ${result.hash}`).fontSize(11).width('100%')
          Text(`接收时间 ${result.receivedAt} · 不可检索，未校验成员或CRC`).fontSize(12).fontColor(Theme.muted).width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (result: DocumentParseResultEnvelope): string => result.assetId)
      Text('本机副本管理').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      ForEach(this.parseState.snapshot.originals, (saved: DocumentOriginal) => {
        Button(`删除本机副本：${saved.title}`, { type: ButtonType.Normal }).width('100%')
          .onClick((): void => { this.deleteId = saved.id; })
      }, (saved: DocumentOriginal): string => `delete-${saved.id}`)
      if (this.resumeId.length > 0 || this.slotConfirm) {
        Text('确认当前凭据为先前同账号，继续查询已同意的同一非敏感免费测试任务；不重提原件。凭据已变时只能复核占用，不能自动下载。').fontSize(13).width('100%')
        Row({ space: 12 }) {
          Button('确认继续').onClick((): void => {
            if (this.slotConfirm) { this.service?.inspectOccupancy(true); } else { this.service?.resume(this.resumeId, true); }
            this.resumeId = ''; this.slotConfirm = false;
          })
          Button('取消').onClick((): void => { this.resumeId = ''; this.slotConfirm = false; })
        }
      }
      if (this.deleteId.length > 0) {
        Text('仅删除本轮解析原件与包的本机副本，不影响 txt/md 资料，不保证删除云端数据；未决云占用保留。').fontSize(13).width('100%')
        Row({ space: 12 }) {
          Button('确认本机删除').onClick((): void => { this.service?.deleteOriginal(this.deleteId); this.deleteId = ''; })
          Button('取消').onClick((): void => { this.deleteId = ''; })
        }
      }
      if (this.parseState.snapshot.cleanup.length > 0) {
        Text('本轮资产待清理，仍计入磁盘预算').fontSize(13).fontColor(Theme.amber)
        Button('重试本机清理').enabled(!this.parseState.busy).onClick((): void => { this.service?.retryCleanup(); })
      }
      }
    }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
struct DocumentParseOriginalRow {
  @Prop original: DocumentOriginal = new DocumentOriginal();
  service: DocumentParseService | undefined = undefined;
  @Prop refreshEpoch: number = 0;
  @Prop submitBlockReason: string = '解析能力不可用';
  @State private whole: boolean = false;
  @State private images: boolean = false;
  @State private nonSensitive: boolean = false;
  @State private unknownPrivacy: boolean = false;
  @State private free: boolean = false;
  private confirmFile(): void {
    const a: DocumentTestAcknowledgement = new DocumentTestAcknowledgement();
    a.fullFile = this.whole; a.embeddedImages = this.images; a.nonSensitive = this.nonSensitive; a.privacyUnknown = this.unknownPrivacy; a.freeEligible = this.free;
    this.service?.confirm(this.original.id, a);
    this.whole = false; this.images = false; this.nonSensitive = false; this.unknownPrivacy = false; this.free = false;
  }
  build() {
    Column({ space: 8 }) {
      Text(this.original.title).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      Text(`${this.original.format} · ${this.original.bytes} 字节 · 原页 ${this.original.pages || '未核定'}`).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.original.preflightReason || this.original.preflight).fontSize(12).fontColor(Theme.muted).width('100%')
      Row() {
        Checkbox().select(this.whole).onChange((v: boolean): void => { this.whole = v; }).accessibilityText('同意发送本件完整原文件')
        Text('完整原文件发送给 MinerU 精准服务').layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().select(this.images).onChange((v: boolean): void => { this.images = v; }).accessibilityText('确认包含全部内嵌图')
        Text('包括文件中的全部内嵌图').layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().select(this.nonSensitive).onChange((v: boolean): void => { this.nonSensitive = v; }).accessibilityText('声明本件为有权使用的非敏感测试文件')
        Text('本件是有权使用的非敏感测试文件').layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().select(this.unknownPrivacy).onChange((v: boolean): void => { this.unknownPrivacy = v; }).accessibilityText('知悉未知隐私条件仍确认本件测试')
        Text('留存、删除、训练用途与转处理方未知，仍同意本件测试').layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().select(this.free).onChange((v: boolean): void => { this.free = v; }).accessibilityText('确认本次免费资格，不授权收费')
        Text('确认本次有免费资格，不授权收费；额度未知则停止').layoutWeight(1)
      }.width('100%')
      Text('固定策略：vlm、表格/行内公式识别、ch、OCR 参数关闭；不代表扫描质量已验证').fontSize(12).fontColor(Theme.muted)
      Button('确认本件测试用途').enabled(this.whole && this.images && this.nonSensitive && this.unknownPrivacy && this.free)
        .onClick((): void => { this.confirmFile(); })
      Text(this.submitBlockReason).fontSize(12).fontColor(Theme.muted).width('100%')
      Button('提交本件测试').enabled(this.submitBlockReason === '')
        .onClick((): void => { this.service?.submit(this.original.id); })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 14 })
      .border({ width: { bottom: 1 }, color: Theme.line })
  }
}
