import { Theme } from '../../components/Theme';
import { DocumentParseViewState, DocumentCredentialStatus, DocumentOriginal, DocumentTestAcknowledgement, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseStage, DocumentParseFormat } from '../domain/DocumentParseModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { parseFailureSummary } from '../pipeline/ParseFailurePolicy';
import { documentIsImage } from '../pipeline/DocumentParsePolicy';

@Component
export struct DocumentParseView {
  @State capabilityOpen: boolean = false;
  @State resultDetailsOpen: boolean = false;
  @Link @Watch('updateTaskRows') parseState: DocumentParseViewState;
  @Prop settingsMode: boolean = true;
  service: DocumentParseService | undefined = undefined;
  onClose: () => void = (): void => {};
  onPreparePdf: (resultId: string) => void = (_resultId: string): void => {};
  onPrepareImage: (resultId: string) => void = (_resultId: string): void => {};
  onOpenImages: () => void = (): void => {};
  onOpenDocx: () => void = (): void => {};
  @Prop @Watch('clearSecret') clearEpoch: number = 0;
  @State private tokenInput: string = '';
  @State private credentialFeedback: string = '';
  @State private resumeId: string = '';
  @State private deleteFeedback: string = '';
  @State private deletingCopy: boolean = false;
  @State private deleteId: string = '';
  @State private slotConfirm: boolean = false;
  @State private copyManager: boolean=false;
  @State private copyFilter: string='';
  private copyController: TextInputController=new TextInputController();
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
  private async deleteLocalCopy(): Promise<void> {
    if (this.service===undefined || this.deletingCopy || this.parseState.busy) { return; }
    const id: string=this.deleteId; this.deletingCopy=true; this.deleteFeedback='正在核对本机引用并删除…';
    try {
      await this.service.deleteOriginal(id); const current=this.service.viewState();
      if (current.snapshot.originals.some((o: DocumentOriginal): boolean=>o.id===id)) { this.deleteFeedback='未删除：'+current.message+'。若资料已入库，请先在「我的资料」删除对应资料以释放引用。'; }
      else { this.deleteFeedback='本机副本已删除。'+(current.snapshot.cleanup.length>0?'物理文件仍待清理，可重试本机清理。':''); this.deleteId=''; }
    } catch { this.deleteFeedback='本机副本删除未确认，原记录保留，请重试。'; }
    finally { this.deletingCopy=false; }
  }
  private isPdfResult(result: DocumentParseResultEnvelope): boolean {
    const task: DocumentParseTask | undefined = this.parseState.snapshot.tasks.find((item: DocumentParseTask): boolean => item.id === result.taskId);
    return this.parseState.snapshot.originals.some((original: DocumentOriginal): boolean => original.id === task?.originalId && original.format === DocumentParseFormat.Pdf);
  }
  private isImageResult(result: DocumentParseResultEnvelope): boolean {
    const task = this.parseState.snapshot.tasks.find((item: DocumentParseTask): boolean => item.id === result.taskId);
    return this.parseState.snapshot.originals.some((original: DocumentOriginal): boolean => original.id === task?.originalId && documentIsImage(original.format));
  }
  private isDocxResult(result: DocumentParseResultEnvelope): boolean {
    const task: DocumentParseTask | undefined = this.parseState.snapshot.tasks.find((t: DocumentParseTask): boolean => t.id === result.taskId);
    return this.parseState.snapshot.originals.some((o: DocumentOriginal): boolean => o.id === task?.originalId && o.format === DocumentParseFormat.Docx);
  }
  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button('返回').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.onClose(); })
        Text('MinerU 精准 · vlm').fontColor(Theme.ink).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%')
      Row({ space: 12 }) {
        Button('设置', { type: ButtonType.Normal }).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).layoutWeight(1).onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.copyManager=false; this.showSettings = true; })
        Button('解析任务', { type: ButtonType.Normal }).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).layoutWeight(1).onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.copyManager=false; this.showSettings = false; })
        Button('本机副本', { type: ButtonType.Normal }).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('parse-open-copies').layoutWeight(1).onClick((): void=> { this.clearSecret(); this.showSettings=false; this.copyManager=true; })
      }.width('100%')
      Text(this.parseState.message).fontColor(Theme.ink).fontSize(13).fontColor(Theme.muted).width('100%')
      if (this.credentialFeedback.length > 0) {
        Text(this.credentialFeedback).fontColor(Theme.ink).fontSize(13).fontColor(Theme.amber).width('100%')
      }
      if (!this.copyManager) { Button('导入与管理资料').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('parse-open-docx').onClick(this.onOpenDocx) }
      if (this.showSettings) {
      Text(this.parseState.credential).fontColor(Theme.ink).fontColor(Theme.muted).width('100%')
      TextInput({ text: this.tokenInput, placeholder: '输入 Token', controller: this.tokenController }).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line })
        .type(InputType.Password).showPasswordIcon(false).copyOption(CopyOptions.None).selectionMenuHidden(true)
        .enableAutoFill(false).enablePreviewText(false)
        .maxLength(1025).onChange((text: string): void => { this.tokenInput = text; })
      Row({ space: 12 }) {
        Button('保存 / 更新').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(this.service !== undefined && !this.parseState.busy && this.tokenInput.length > 0)
          .onClick((): void => { this.saveCredential(); })
        Button('删除凭据').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.parseState.busy && this.parseState.credential === DocumentCredentialStatus.Configured)
          .onClick((): void => { this.clearSecret(); this.service?.removeToken(); })
      }.width('100%')
      }
      if (!this.copyManager) {
      Text('云解析完成后，在「我的资料」查看正文、图片与入库进度。保存凭据不会上传文件。').fontSize(13).fontColor(Theme.muted).lineHeight(21).width('100%')
      Button(this.capabilityOpen ? '收起服务能力说明' : '查看服务能力说明').id('parse-capability-details').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).onClick((): void => { this.capabilityOpen = !this.capabilityOpen; })
      if (this.capabilityOpen) {
        Text('以下为云解析转发环节的能力说明；本机入库结果以资料详情为准。').fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.parseState.limitation).fontColor(Theme.ink).fontSize(13).fontColor(Theme.muted).width('100%')
      Text(this.service?.capabilitySummary() ?? '解析能力不可用').fontColor(Theme.ink).fontSize(13).fontColor(Theme.muted).width('100%')
      }
      Row({ space: 12 }) {
        Text('云解析').fontColor(Theme.ink).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.parseState.snapshot.config.enabled }).selectedColor(Theme.accent)
          .onChange((isOn: boolean): void => { this.service?.setEnabled(isOn); })
      }.width('100%')
      Text('PDF、DOCX 与图片在「我的资料」逐份确认完整文件发送、非敏感测试用途与免费资格。保存不会上传。').fontColor(Theme.ink)
        .fontSize(13).fontColor(Theme.muted).width('100%')
      }
      if (!this.showSettings && !this.copyManager) {
      Text('解析任务').fontColor(Theme.ink).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      if (this.parseState.busy) {
        Row({ space: 8 }) {
          LoadingProgress().width(20).height(20)
          Text(this.parseState.message).fontColor(Theme.ink).fontSize(13).layoutWeight(1)
        }.width('100%')
      }
      Button('暂停本机动作').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.clearSecret(); this.service?.pause(); })
      if (this.parseState.snapshot.occupancy.taskId.length > 0 && !this.parseState.snapshot.occupancy.terminalObserved) {
        Text(this.parseState.snapshot.occupancy.retired ? '已停止本机跟踪先前云占用；不代表云端删除或取消，远端记录可能仍保留。' : '有未决云占用；本机暂停/删除不会解除。远端任务可能继续，留存与删除能力未知。').fontColor(Theme.ink)
          .fontSize(13).fontColor(this.parseState.snapshot.occupancy.retired ? Theme.muted : Theme.amber).width('100%')
        Button('核对原云任务').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.slotConfirm = true; })
        if (this.service?.canRetireOccupancy() ?? false) {
          Text('远端确认仍是 waiting-file（文件从未送达）。如你确认不再上传或等待该测试件，可停止本机跟踪；停止后本机不再阻止提交新测试件，不表示云端删除或取消。').fontColor(Theme.ink).fontSize(13).fontColor(Theme.amber).width('100%')
          Row({ space: 12 }) {
            Button('停止本机跟踪').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.service?.retireOccupancy(true); })
            Button('继续等待').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.service?.dismissRetireOccupancy(); })
          }.width('100%')
        }
      }
      ForEach(this.taskRows, (row: DocumentParseTaskPresentation) => {
        DocumentParseTaskRow({ taskRow: row, actionBusy: this.parseState.busy,
          onResume: (id: string): void => { this.resumeId = id; } })
      }, (row: DocumentParseTaskPresentation): string => row.taskId)
      if (this.parseState.snapshot.results.length > 0) { Button(this.resultDetailsOpen ? '收起结果技术信息' : '查看结果技术信息').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('parse-result-details').onClick((): void => { this.resultDetailsOpen = !this.resultDetailsOpen; }) }
      ForEach(this.parseState.snapshot.results, (result: DocumentParseResultEnvelope) => {
        Column({ space: 6 }) {
          Text('解析服务成功，ZIP 已保存，内容待结构校验').fontColor(Theme.ink).fontWeight(FontWeight.Medium).width('100%')
          if (this.resultDetailsOpen) {
          Text(`${result.bytes} 字节 · ${result.assetId}`).fontColor(Theme.ink).fontSize(12).width('100%')
          Text(`${this.parseState.resultDirectory}/${result.assetId}`).fontColor(Theme.ink).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
          Text(`任务 ${result.taskId} · 原件 SHA256 ${result.originalHash}`).fontColor(Theme.ink).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
          Text(`SHA256 ${result.hash}`).fontColor(Theme.ink).fontSize(11).width('100%')
          Text(`接收时间 ${new Date(result.receivedAt).toLocaleString()} · 不可检索，未校验成员或CRC`).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
          }
          if (this.isPdfResult(result)) {
            Button('校验并准备入库').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).constraintSize({ minHeight: 44 }).enabled(!this.parseState.busy)
              .onClick((): void => { this.onPreparePdf(result.assetId); })
          }
          if (this.isImageResult(result)) {
            Button('校验图片 ZIP 与审查正文').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('image-result-review-'+result.assetId).enabled(!this.parseState.busy)
              .onClick((): void => { this.onPrepareImage(result.assetId); })
          }
          if (this.isDocxResult(result)) { Button('打开DOCX原生工作区').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('docx-result-open-'+result.assetId).enabled(!this.parseState.busy).onClick(this.onOpenDocx) }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (result: DocumentParseResultEnvelope): string => result.assetId)
      Button('选择文件，仅保存原件').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.parseState.busy).onClick((): void => { this.service?.prepare(); })
      Button('图片解析与入库').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('parse-open-images').enabled(!this.parseState.busy).onClick(this.onOpenImages)
      ForEach(this.parseState.snapshot.originals, (original: DocumentOriginal) => {
        if (!documentIsImage(original.format) && original.format !== DocumentParseFormat.Docx) {
          DocumentParseOriginalRow({ original: original, service: this.service, refreshEpoch: this.parseState.inputEpoch,
            submitBlockReason: this.service?.submitReason(original) ?? '解析能力不可用' })
        }
      }, (original: DocumentOriginal): string => original.id)
      if (this.resumeId.length > 0 || this.slotConfirm) {
         Text('确认当前凭据为先前同账号，先查询原批次。明确待文件时最多补传同一原件一次；失败结果包最多显式重取两次，可能产生流量或费用。旧固定测试许可不扩展，凭据已变只能复核占用。').fontColor(Theme.ink).fontSize(13).width('100%')
        Row({ space: 12 }) {
          Button('确认继续').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => {
            if (this.slotConfirm) { this.service?.inspectOccupancy(true); } else { this.service?.resume(this.resumeId, true); }
            this.resumeId = ''; this.slotConfirm = false;
          })
          Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.resumeId = ''; this.slotConfirm = false; })
        }
      }
      }
      if (this.copyManager) {
      Text('本机副本管理').fontColor(Theme.ink).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      TextInput({text:this.copyFilter,placeholder:'按文件名筛选副本',controller:this.copyController}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('parse-copy-filter').onChange((v: string): void=> { this.copyFilter=v; })
      ForEach(this.parseState.snapshot.originals.filter((o: DocumentOriginal): boolean=>o.title.toLowerCase().includes(this.copyFilter.trim().toLowerCase())), (saved: DocumentOriginal) => {
        Button(`删除本机副本：${saved.title}`, { type: ButtonType.Normal }).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).width('100%')
          .id('parse-delete-copy-'+saved.id).enabled(!this.parseState.busy && !this.deletingCopy).onClick((): void => { this.copyController.stopEditing(); this.deleteId = saved.id; this.deleteFeedback=''; })
      }, (saved: DocumentOriginal): string => `delete-${saved.id}`)
      }
      if (this.deleteId.length > 0) {
        Text('仅删除本轮解析原件与包的本机副本，不影响 txt/md 资料，不保证删除云端数据；未决云占用保留。').fontColor(Theme.ink).fontSize(13).width('100%')
        Row({ space: 12 }) {
          Button('确认本机删除').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).id('parse-confirm-delete-copy').enabled(!this.parseState.busy && !this.deletingCopy).onClick((): void => { this.deleteLocalCopy(); })
          Button('取消').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.deleteId = ''; })
        }
      }
      if (this.deleteFeedback.length>0) { Text(this.deleteFeedback).fontColor(Theme.ink).id('parse-delete-copy-feedback').fontSize(14).fontColor(Theme.amber).width('100%') }
      if (this.parseState.snapshot.cleanup.length > 0) {
        Text('本轮资产待清理，仍计入磁盘预算').fontColor(Theme.ink).fontSize(13).fontColor(Theme.amber)
        Button('重试本机清理').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.parseState.busy).onClick((): void => { this.service?.retryCleanup(); })
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
    this.failureText = task.failure; this.failureDetail = task.failureStage.length > 0 ? `失败阶段 ${task.failureStage}\n${parseFailureSummary(task.failureDetail)}\n${task.stage === DocumentParseStage.Received ? '云结果已收，仅本机处理恢复' : task.batchId.length > 0 ? '先核对原任务；仅在身份与许可一致且服务明确待文件时允许一次补传，不新建任务' : '身份未知，停止待核，不新建任务'}` : '';
  }
}

@Component
struct DocumentParseTaskRow {
  @State taskDetailsOpen: boolean = false;
  @ObjectLink taskRow: DocumentParseTaskPresentation;
  @Prop actionBusy: boolean = false;
  onResume: (id: string) => void = (_id: string): void => {};
  build() {
    Column({ space: 6 }) {
      Text(this.taskRow.title).fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%')
      Text(this.taskRow.stageText).fontColor(Theme.ink).fontWeight(FontWeight.Medium).width('100%')
      if (this.taskDetailsOpen) {
      Text(this.taskRow.taskId).fontColor(Theme.ink).fontSize(11).fontColor(Theme.muted).width('100%').wordBreak(WordBreak.BREAK_ALL)
      Text(this.taskRow.remoteText).fontColor(Theme.ink).fontSize(13).width('100%')
      Text(this.taskRow.queryText).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.taskRow.uploadText).fontColor(Theme.ink).fontSize(12).width('100%')
      if (this.taskRow.uploading && this.taskRow.originalBytes > 0) {
        Progress({ value: this.taskRow.suppliedBytes, total: this.taskRow.originalBytes, type: ProgressType.Linear }).width('100%')
      }
      Text(this.taskRow.pageText).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.taskRow.downloadText).fontColor(Theme.ink).fontSize(12).width('100%')
      if (this.taskRow.downloading && this.taskRow.resultTotal > 0) {
        Progress({ value: this.taskRow.writtenBytes, total: this.taskRow.resultTotal, type: ProgressType.Linear }).width('100%')
      }
      Text(this.taskRow.lastActionText).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      }
      if (this.taskRow.failureText.length > 0) {
        Text(this.taskRow.failureText).fontColor(Theme.ink).fontSize(13).fontColor(Theme.amber).width('100%')
        Text(this.taskRow.failureDetail).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      }
      Button(this.taskDetailsOpen ? '收起任务记录' : '查看任务记录').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).onClick((): void => { this.taskDetailsOpen = !this.taskDetailsOpen; })
      if (!this.taskRow.terminal) {
        Button('继续查询同一任务').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(!this.actionBusy).onClick((): void => { this.onResume(this.taskRow.taskId); })
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
      Text(this.original.title).fontColor(Theme.ink).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      Text(`${this.original.format} · ${this.original.bytes} 字节 · 原页 ${this.original.pages || '未核定'}`).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      Text(this.original.preflightReason || this.original.preflight).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      Row() {
        Checkbox().selectedColor(Theme.accent).select(this.whole).onChange((v: boolean): void => { this.whole = v; }).accessibilityText('同意发送本件完整原文件')
        Text('完整原文件发送给 MinerU 精准服务').fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().selectedColor(Theme.accent).select(this.images).onChange((v: boolean): void => { this.images = v; }).accessibilityText('确认包含全部内嵌图')
        Text('包括文件中的全部内嵌图').fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().selectedColor(Theme.accent).select(this.nonSensitive).onChange((v: boolean): void => { this.nonSensitive = v; }).accessibilityText('声明本件为有权使用的非敏感测试文件')
        Text('本件是有权使用的非敏感测试文件').fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().selectedColor(Theme.accent).select(this.unknownPrivacy).onChange((v: boolean): void => { this.unknownPrivacy = v; }).accessibilityText('知悉未知隐私条件仍确认本件测试')
        Text('留存、删除、训练用途与转处理方未知，仍同意本件测试').fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Row() {
        Checkbox().selectedColor(Theme.accent).select(this.free).onChange((v: boolean): void => { this.free = v; }).accessibilityText('确认本次免费资格，不授权收费')
        Text('确认本次有免费资格，不授权收费；额度未知则停止').fontColor(Theme.ink).layoutWeight(1)
      }.width('100%')
      Text('固定策略：vlm、表格/行内公式识别、ch、OCR 参数关闭；不代表扫描质量已验证').fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted)
      Button('确认本件测试用途').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(this.whole && this.images && this.nonSensitive && this.unknownPrivacy && this.free)
        .onClick((): void => { this.confirmFile(); })
      Text(this.submitBlockReason).fontColor(Theme.ink).fontSize(12).fontColor(Theme.muted).width('100%')
      Button('提交本件测试').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14, top: 10, bottom: 10 }).enabled(this.submitBlockReason === '')
        .onClick((): void => { this.service?.submit(this.original.id); })
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 14 })
      .border({ width: { bottom: 1 }, color: Theme.line })
  }
}
