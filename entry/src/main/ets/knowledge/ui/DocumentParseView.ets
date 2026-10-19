import { Theme } from '../../components/Theme';
import { DocumentParseViewState, DocumentCredentialStatus, DocumentOriginal, DocumentTestAcknowledgement, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseStage, DocumentParseFormat } from '../domain/DocumentParseModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { parseFailureSummary } from '../pipeline/ParseFailurePolicy';
import { documentIsImage } from '../pipeline/DocumentParsePolicy';

@Component
export struct DocumentParseView {
  @Link @Watch('updateTaskRows') parseState: DocumentParseViewState;
  @Prop settingsMode: boolean = true;
  service: DocumentParseService | undefined = undefined;
  onClose: () => void = (): void => {};
  onPreparePdf: (resultId: string) => void = (_resultId: string): void => {};
  onPrepareImage: (resultId: string) => void = (_resultId: string): void => {};
  onOpenImages: () => void = (): void => {};
  @Prop @Watch('clearSecret') clearEpoch: number = 0;
  @State private tokenInput: string = '';
  @State private credentialFeedback: string = '';
  @State private resumeId: string = '';
  @State private deleteId: string = '';
  @State private slotConfirm: boolean = false;
  @State private showSettings: boolean = true;
  @State private taskRows: DocumentParseTaskPresentation[] = [];
  private tokenController: TextInputController = new TextInputController();
  clearSecret(): void { this.tokenInput = ''; this.tokenController.stopEditing(); }
  aboutToAppear(): void {
    this.showSettings = this.settingsMode;
    this.updateTaskRows();
    if (this.service === undefined) { this.credentialFeedback = '安全配置服务不可用，保存未执行'; }
  }
  aboutToDisappear(): void { this.clearSecret(); this.service?.clearInput(); }
  updateTaskRows(): void {
    const next: DocumentParseTaskPresentation[] = [];
    for (const task of this.parseState.snapshot.tasks) {
      const prior: DocumentParseTaskPresentation | undefined = this.taskRows.find((row: DocumentParseTaskPresentation): boolean => row.taskId === task.id);
      const row: DocumentParseTaskPresentation = prior ?? new DocumentParseTaskPresentation();
      const original: DocumentOriginal | undefined = this.parseState.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === task.originalId);
      row.update(task, original?.bytes ?? 0, original?.title ?? task.dataId); next.push(row);
    }
    this.taskRows = next;
  }
  private async saveCredential(): Promise<void> {
    let input: string = this.tokenInput;
    const service: DocumentParseService | undefined = this.service;
    const replace: boolean = this.parseState.credential === DocumentCredentialStatus.Configured;
    this.credentialFeedback = ''; this.clearSecret();
    try {
      if (service === undefined) { this.credentialFeedback = '安全配置服务不可用，保存未执行'; return; }
      await service.saveToken(input, replace);
    } catch { this.credentialFeedback = '安全配置动作失败，未确认保存；请重新打开设置查看状态'; }
    finally { input = ''; this.clearSecret(); }
  }
  private isPdfResult(result: DocumentParseResultEnvelope): boolean {
    const task: DocumentParseTask | undefined = this.parseState.snapshot.tasks.find((item: DocumentParseTask): boolean => item.id === result.taskId);
    return this.parseState.snapshot.originals.some((original: DocumentOriginal): boolean => original.id === task?.originalId && original.format === DocumentParseFormat.Pdf);
  }
  private isImageResult(result: DocumentParseResultEnvelope): boolean {
    const task = this.parseState.snapshot.tasks.find((item: DocumentParseTask): boolean => item.id === result.taskId);
    return this.parseState.snapshot.originals.some((original: DocumentOriginal): boolean => original.id === task?.originalId && documentIsImage(original.format));
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
      Text(this.parseState.message).fontSize(13).fontColor(Theme.muted).width('100%')
      if (this.credentialFeedback.length > 0) {
        Text(this.credentialFeedback).fontSize(13).fontColor(Theme.amber).width('100%')
      }
      if (this.showSettings) {
      Text(this.parseState.credential).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.tokenInput, placeholder: '输入 Token', controller: this.tokenController })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true)
        .enableAutoFill(false).enablePreviewText(false)
        .maxLength(1025).onChange((text: string): void => { this.tokenInput = text; })
      Row({ space: 12 }) {
        Button('保存 / 更新').enabled(this.service !== undefined && !this.parseState.busy && this.tokenInput.length > 0)
          .onClick((): void => { this.saveCredential(); })
        Button('删除凭据').enabled(!this.parseState.busy && this.parseState.credential === DocumentCredentialStatus.Configured)
          .onClick((): void => { this.clearSecret(); this.service?.removeToken(); })
      }.width('100%')
      }
      Text(this.parseState.limitation).fontSize(13).fontColor(Theme.muted).width('100%')
      Text(this.service?.capabilitySummary() ?? '解析能力不可用').fontSize(13).fontColor(Theme.muted).width('100%')
      Row({ space: 12 }) {
        Text('启用解析（默认关闭）').layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.parseState.snapshot.config.enabled })
          .onChange((isOn: boolean): void => { this.service?.setEnabled(isOn); })
      }.width('100%')
      Text('PDF/Office 保持逐件非敏感免费测试许可；普通图片在“图片解析与入库”逐图确认完整文件、元数据与免费资格。保存不代表同意上传。')
        .fontSize(13).fontColor(Theme.muted).width('100%')
      if (!this.showSettings) {
      Text('解析任务').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      if (this.parseState.busy) {
        Row({ space: 8 }) {
          LoadingProgress().width(20).height(20)
          Text(this.parseState.message).fontSize(13).layoutWeight(1)
        }.width('100%')
      }
      Button('暂停本机动作').onClick((): void => { this.clearSecret(); this.service?.pause(); })
      if (this.parseState.snapshot.occupancy.taskId.length > 0 && !this.parseState.snapshot.occupancy.terminalObserved) {
        Text(this.parseState.snapshot.occupancy.retired ? '已停止本机跟踪先前云占用；不代表云端删除或取消，远端记录可能仍保留。' : '有未决云占用；本机暂停/删除不会解除。远端任务可能继续，留存与删除能力未知。')
          .fontSize(13).fontColor(this.parseState.snapshot.occupancy.retired ? Theme.muted : Theme.amber).width('100%')
        Button('核对原云任务').onClick((): void => { this.slotConfirm = true; })
        if (this.service?.canRetireOccupancy() ?? false) {
          Text('远端确认仍是 waiting-file（文件从未送达）。如你确认不再上传或等待该测试件，可停止本机跟踪；停止后本机不再阻止提交新测试件，不表示云端删除或取消。').fontSize(13).fontColor(Theme.amber).width('100%')
          Row({ space: 12 }) {
            Button('停止本机跟踪').onClick((): void => { this.service?.retireOccupancy(true); })
            Button('继续等待').onClick((): void => { this.service?.dismissRetireOccupancy(); })
          }.width('100%')
        }
      }
      ForEach(this.taskRows, (row: DocumentParseTaskPresentation) => {
        DocumentParseTaskRow({ taskRow: row, actionBusy: this.parseState.busy,
          onResume: (id: string): void => { this.resumeId = id; } })
      }, (row: DocumentParseTaskPresentation): string => row.taskId)
      ForEach(this.parseState.snapshot.results, (result: DocumentParseResultEnvelope) => {
        Column({ space: 6 }) {
          Text('解析服务成功，ZIP 已保存，内容待结构校验').fontWeight(FontWeight.Medium).width('100%')
          Text(`${result.bytes} 字节 · ${result.assetId}`).fontSize(12).width('100%')
          Text(`${this.parseState.resultDirectory}/${result.assetId}`).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
          Text(`任务 ${result.taskId} · 原件 SHA256 ${result.originalHash}`).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
          Text(`SHA256 ${result.hash}`).fontSize(11).width('100%')
          Text(`接收时间 ${new Date(result.receivedAt).toLocaleString()} · 不可检索，未校验成员或CRC`).fontSize(12).fontColor(Theme.muted).width('100%')
          if (this.isPdfResult(result)) {
            Button('校验并准备入库').constraintSize({ minHeight: 44 }).enabled(!this.parseState.busy)
              .onClick((): void => { this.onPreparePdf(result.assetId); })
          }
          if (this.isImageResult(result)) {
            Button('校验图片 ZIP 与审查正文').id('image-result-review-'+result.assetId).enabled(!this.parseState.busy)
              .onClick((): void => { this.onPrepareImage(result.assetId); })
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (result: DocumentParseResultEnvelope): string => result.assetId)
      Button('选择文件，仅保存原件').enabled(!this.parseState.busy).onClick((): void => { this.service?.prepare(); })
      Button('图片解析与入库').id('parse-open-images').enabled(!this.parseState.busy).onClick(this.onOpenImages)
      ForEach(this.parseState.snapshot.originals, (original: DocumentOriginal) => {
        if (!documentIsImage(original.format)) {
          DocumentParseOriginalRow({ original: original, service: this.service, refreshEpoch: this.parseState.inputEpoch,
            submitBlockReason: this.service?.submitReason(original) ?? '解析能力不可用' })
        }
      }, (original: DocumentOriginal): string => original.id)
      Text('本机副本管理').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      ForEach(this.parseState.snapshot.originals, (saved: DocumentOriginal) => {
        Button(`删除本机副本：${saved.title}`, { type: ButtonType.Normal }).width('100%')
          .onClick((): void => { this.deleteId = saved.id; })
      }, (saved: DocumentOriginal): string => `delete-${saved.id}`)
      if (this.resumeId.length > 0 || this.slotConfirm) {
         Text('确认当前凭据为先前同账号，查询同一测试任务，不申请新批次。图片禁止补传；旧PDF/Office仅原有许可内对同一对象最多补传一次，凭据已变只能复核占用。').fontSize(13).width('100%')
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

@Observed
class DocumentParseTaskPresentation {
  taskId: string = ''; title: string = ''; stageText: string = ''; remoteText: string = '';
  queryText: string = ''; uploadText: string = ''; downloadText: string = ''; pageText: string = '';
  lastActionText: string = ''; failureText: string = ''; failureDetail: string = '';
  uploading: boolean = false; downloading: boolean = false; terminal: boolean = false;
  suppliedBytes: number = 0; originalBytes: number = 0; writtenBytes: number = 0; resultTotal: number = 0;
  update(task: DocumentParseTask, originalBytes: number, title: string): void {
    this.taskId = task.id; this.title = title; this.stageText = task.stage; this.remoteText = `云阶段 ${task.remote || '尚未观察'}`;
    this.queryText = `累计查询 ${task.queries} 次 · 最后响应 ${task.lastQueryAt > 0 ? new Date(task.lastQueryAt).toLocaleString() : '未记录'}`;
    this.uploading = task.stage === DocumentParseStage.Uploading; this.downloading = task.stage === DocumentParseStage.Downloading;
    this.terminal = task.stage === DocumentParseStage.Received || task.stage === DocumentParseStage.RemoteFailed;
    this.suppliedBytes = task.uploadBytes; this.originalBytes = originalBytes; this.writtenBytes = task.downloadBytes; this.resultTotal = task.downloadTotal;
    this.uploadText = `本次已供给 SDK ${task.uploadBytes}/${originalBytes} 字节 · ${task.uploaded ? 'PUT 200 及原字节校验已确认' : '未确认上传成功'}`;
    this.downloadText = `ZIP 本次实际写入 ${task.downloadBytes} 字节${task.downloadTotal > 0 ? ' / HTTP 长度 ' + task.downloadTotal : ' · 总长度未知'}`;
    this.pageText = task.totalPages > 0 ? `服务报告 ${task.extractedPages}/${task.totalPages} 页` : '服务未报告页进度';
    this.lastActionText = `${task.lastAction || task.checkpoint} · 同对象补传${task.recoveryUploadUsed ? '已耗用' : '未耗用'}`;
    this.failureText = task.failure; this.failureDetail = task.failureStage.length > 0 ? `失败阶段 ${task.failureStage}\n${parseFailureSummary(task.failureDetail)}\n${task.stage === DocumentParseStage.Received ? '云结果已收，仅本机处理恢复' : task.batchId.length > 0 ? '只查询原任务；图片不补传或新建' : '身份未知，停止待核，不新建任务'}` : '';
  }
}

@Component
struct DocumentParseTaskRow {
  @ObjectLink taskRow: DocumentParseTaskPresentation;
  @Prop actionBusy: boolean = false;
  onResume: (id: string) => void = (_id: string): void => {};
  build() {
    Column({ space: 6 }) {
      Text(this.taskRow.title).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
      Text(this.taskRow.stageText).fontWeight(FontWeight.Medium).width('100%')
      Text(this.taskRow.taskId).fontSize(11).fontColor(Theme.muted).width('100%').wordBreak(WordBreak.BREAK_ALL)
      Text(this.taskRow.remoteText).fontSize(13).width('100%')
      Text(this.taskRow.queryText).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.taskRow.uploadText).fontSize(12).width('100%')
      if (this.taskRow.uploading && this.taskRow.originalBytes > 0) {
        Progress({ value: this.taskRow.suppliedBytes, total: this.taskRow.originalBytes, type: ProgressType.Linear }).width('100%')
      }
      Text(this.taskRow.pageText).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.taskRow.downloadText).fontSize(12).width('100%')
      if (this.taskRow.downloading && this.taskRow.resultTotal > 0) {
        Progress({ value: this.taskRow.writtenBytes, total: this.taskRow.resultTotal, type: ProgressType.Linear }).width('100%')
      }
      Text(this.taskRow.lastActionText).fontSize(12).fontColor(Theme.muted).width('100%')
      if (this.taskRow.failureText.length > 0) {
        Text(this.taskRow.failureText).fontSize(13).fontColor(Theme.amber).width('100%')
        Text(this.taskRow.failureDetail).fontSize(12).fontColor(Theme.muted).width('100%')
      }
      if (!this.taskRow.terminal) {
        Button('继续查询同一任务').enabled(!this.actionBusy).onClick((): void => { this.onResume(this.taskRow.taskId); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 10, bottom: 10 })
      .border({ width: { bottom: 1 }, color: Theme.line })
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
