import { Theme } from '../../components/Theme';
import { DocumentParseViewState, DocumentCredentialStatus, DocumentOriginal, DocumentTestAcknowledgement, DocumentParseTask, DocumentParseResultEnvelope, DocumentParseStage, DocumentParseFormat } from '../domain/DocumentParseModels';
import { DocumentParseService } from '../application/DocumentParseService';
import { parseFailureSummary } from '../pipeline/ParseFailurePolicy';
import { documentIsImage } from '../pipeline/DocumentParsePolicy';

class ParseCategory {
  key: string = ''; name: string = ''; count: number = 0;
}

class ParseTaskGroup {
  key: string = ''; name: string = ''; count: number = 0;
}

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
  /** The MinerU token is saved and changed in 我的 → API Key 管理. */
  onKeys: () => void = (): void => {};
  @Prop @Watch('clearSecret') clearEpoch: number = 0;
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
  @State private taskSort: string = 'time';
  @State private taskView: string = 'list';
  @State private taskFolder: string = '';
  @State private taskPage: number = 0;
  @State private resultPage: number = 0;
  @State private copySort: string = 'time';
  @State private copyView: string = 'list';
  @State private copyFolder: string = '';
  @State private copyPage: number = 0;
  /** No secret is typed on this page any more; the watch stays so navigation keeps clearing transient copy input. */
  clearSecret(): void { this.copyController.stopEditing(); }
  aboutToAppear(): void {
    this.showSettings = this.settingsMode;
    this.updateTaskRows();
    if (this.service === undefined) { this.credentialFeedback = '解析服务暂不可用，请稍后重新打开本页'; }
  }
  private credentialText(): string {
    return this.parseState.credential === DocumentCredentialStatus.Configured ? 'Token 已保存' :
      (this.parseState.credential === DocumentCredentialStatus.Missing ? '未保存 Token' : '暂不可用');
  }
  aboutToDisappear(): void { this.clearSecret(); this.service?.clearInput(); }
  updateTaskRows(): void {
    const next: DocumentParseTaskPresentation[] = [];
    for (const task of this.parseState.snapshot.tasks) {
      const prior: DocumentParseTaskPresentation | undefined = this.taskRows.find((row: DocumentParseTaskPresentation): boolean => row.taskId === task.id);
      const row: DocumentParseTaskPresentation = prior ?? new DocumentParseTaskPresentation();
      const original: DocumentOriginal | undefined = this.parseState.snapshot.originals.find((o: DocumentOriginal): boolean => o.id === task.originalId);
      row.update(task, original?.bytes ?? 0, original?.title ?? task.dataId); row.savedAt = original?.savedAt ?? 0; row.format = original?.format ?? ''; next.push(row);
    }
    this.taskRows = next;
    if (this.taskPage * 6 >= this.taskRowsForView().length) { this.taskPage = Math.max(0, Math.ceil(this.taskRowsForView().length / 6) - 1); }
    if (this.resultPage * 3 >= this.parseState.snapshot.results.length) { this.resultPage = Math.max(0, Math.ceil(this.parseState.snapshot.results.length / 3) - 1); }
    if (this.copyPage * 8 >= this.copyRows().length) { this.copyPage = Math.max(0, Math.ceil(this.copyRows().length / 8) - 1); }
  }
  private taskGroupKey(stage: DocumentParseStage): string {
    if (stage === DocumentParseStage.Received) { return 'done'; }
    if ([DocumentParseStage.RemoteFailed,DocumentParseStage.Paused,DocumentParseStage.Failed,DocumentParseStage.Uncertain,DocumentParseStage.UploadUnknown].indexOf(stage) >= 0) { return 'attention'; }
    return 'active';
  }
  private taskGroupName(key: string): string { return key === 'done' ? '已完成' : key === 'attention' ? '需要处理' : '进行中'; }
  private taskRowsForView(): DocumentParseTaskPresentation[] {
    const rows: DocumentParseTaskPresentation[] = this.taskFolder.length === 0 ? this.taskRows.slice() : this.taskRows.filter((row: DocumentParseTaskPresentation): boolean => row.groupKey === this.taskFolder);
    if (this.taskSort === 'name') { rows.sort((a: DocumentParseTaskPresentation, b: DocumentParseTaskPresentation): number => a.title.localeCompare(b.title, 'zh-Hans-CN')); }
    else { rows.sort((a: DocumentParseTaskPresentation, b: DocumentParseTaskPresentation): number => b.savedAt - a.savedAt || a.title.localeCompare(b.title, 'zh-Hans-CN')); }
    return rows;
  }
  private taskPageCount(): number { return Math.max(1, Math.ceil(this.taskRowsForView().length / 6)); }
  private visibleTasks(): DocumentParseTaskPresentation[] { const rows: DocumentParseTaskPresentation[] = this.taskRowsForView(); return rows.slice(this.taskPage * 6, this.taskPage * 6 + 6); }
  private taskGroups(): ParseTaskGroup[] {
    const groups: ParseTaskGroup[] = [];
    for (const key of ['active','attention','done']) {
      const count: number = this.taskRows.filter((row: DocumentParseTaskPresentation): boolean => row.groupKey === key).length;
      if (count > 0) { const group: ParseTaskGroup = new ParseTaskGroup(); group.key = key; group.name = this.taskGroupName(key); group.count = count; groups.push(group); }
    }
    return groups;
  }
  private visibleResults(): DocumentParseResultEnvelope[] {
    const rows: DocumentParseResultEnvelope[] = this.parseState.snapshot.results;
    return rows.slice(this.resultPage * 3, this.resultPage * 3 + 3);
  }
  private resultPageCount(): number { return Math.max(1, Math.ceil(this.parseState.snapshot.results.length / 3)); }
  private copyRows(): DocumentOriginal[] {
    const rows: DocumentOriginal[] = this.parseState.snapshot.originals.filter((o: DocumentOriginal): boolean => o.title.toLowerCase().includes(this.copyFilter.trim().toLowerCase()));
    const filtered: DocumentOriginal[] = this.copyFolder.length === 0 ? rows : rows.filter((o: DocumentOriginal): boolean => this.copyCategory(o) === this.copyFolder);
    if (this.copySort === 'name') { filtered.sort((a: DocumentOriginal, b: DocumentOriginal): number => a.title.localeCompare(b.title, 'zh-Hans-CN')); }
    else { filtered.sort((a: DocumentOriginal, b: DocumentOriginal): number => b.savedAt - a.savedAt || a.title.localeCompare(b.title, 'zh-Hans-CN')); }
    return filtered;
  }
  private copyCategory(original: DocumentOriginal): string {
    if (documentIsImage(original.format)) { return '图片'; }
    if (original.format === DocumentParseFormat.Pdf) { return 'PDF'; }
    if (original.format === DocumentParseFormat.Docx) { return 'Word'; }
    return '其他';
  }
  private copyGroups(): ParseCategory[] {
    const groups: ParseCategory[] = [];
    for (const original of this.parseState.snapshot.originals) {
      const name: string = this.copyCategory(original);
      const found: ParseCategory | undefined = groups.find((g: ParseCategory): boolean => g.name === name);
      if (found === undefined) { const group: ParseCategory = new ParseCategory(); group.key = name; group.name = name; group.count = 1; groups.push(group); }
      else { found.count++; }
    }
    return groups;
  }
  private copyPageCount(): number { return Math.max(1, Math.ceil(this.copyRows().length / 8)); }
  private visibleCopies(): DocumentOriginal[] { return this.copyRows().slice(this.copyPage * 8, this.copyPage * 8 + 8); }
  private pad2(value: number): string { return value < 10 ? '0' + String(value) : String(value); }
  private savedText(savedAt: number): string {
    if (savedAt <= 0) { return ''; }
    const date: Date = new Date(savedAt);
    return `${date.getFullYear()}-${this.pad2(date.getMonth() + 1)}-${this.pad2(date.getDate())}`;
  }
  private sizeText(bytes: number): string {
    if (bytes <= 0) { return '大小未知'; }
    if (bytes >= 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }
  private askDeleteCopy(original: DocumentOriginal): void {
    this.copyController.stopEditing();
    this.getUIContext().showAlertDialog({
      title: '删除本机副本？',
      message: '只会删除本机解析原件与结果包，不影响 txt/md 资料，也不保证删除云端数据。此操作无法撤销。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => { this.deleteId = original.id; this.deleteFeedback=''; this.deleteLocalCopy(); } }
    });
  }
  private confirmRetire(): void {
    this.getUIContext().showAlertDialog({
      title: '停止跟踪这个云端任务？',
      message: '停止后本机不再等待该任务，也不会代表云端删除或取消。之后的云端记录可能仍然保留。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '停止跟踪', action: (): void => { this.service?.retireOccupancy(true); } }
    });
  }
  private async deleteLocalCopy(): Promise<void> {
    if (this.service===undefined || this.deletingCopy || this.parseState.busy) { return; }
    const id: string=this.deleteId; this.deletingCopy=true; this.deleteFeedback='正在核对本机引用并删除…';
    try {
      await this.service.deleteOriginal(id); const current=this.service.viewState();
      if (current.snapshot.originals.some((o: DocumentOriginal): boolean=>o.id===id)) { this.deleteFeedback='未删除：'+current.message+'。若资料已入库，请先在「我的资料」删除对应资料以释放引用。'; }
      else { this.deleteFeedback='本机副本已删除。'+(current.snapshot.cleanup.length>0?'临时文件仍待清理，可重试本机清理。':''); this.deleteId=''; }
    } catch { this.deleteFeedback='本机副本删除未确认，原记录保留，请重试。'; }
    finally { this.deletingCopy=false; this.updateTaskRows(); }
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
        Button({ type: ButtonType.Circle }) {
          Text('‹').fontSize(28).fontColor(Theme.accent).fontWeight(FontWeight.Medium).translate({ y: -2 })
        }.width(40).height(40).backgroundColor(Theme.soft).borderRadius(20).id('parse-back').accessibilityText('返回').onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.onClose(); })
        Column({ space: 3 }) {
          Text('解析引擎').fontColor(Theme.ink).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Text('把 PDF、Word 与图片变成可阅读、可搜索的内容').fontColor(Theme.muted).fontSize(12).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Row({ space: 8 }) {
        Button('设置').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1).id('parse-tab-settings')
          .backgroundColor(this.showSettings && !this.copyManager ? Theme.accent : Theme.soft).fontColor(this.showSettings && !this.copyManager ? Color.White : Theme.accent)
          .onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.copyManager=false; this.showSettings = true; })
        Button('解析任务').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1).id('parse-tab-tasks')
          .backgroundColor(!this.showSettings && !this.copyManager ? Theme.accent : Theme.soft).fontColor(!this.showSettings && !this.copyManager ? Color.White : Theme.accent)
          .onClick((): void => { this.clearSecret(); this.service?.clearInput(); this.copyManager=false; this.showSettings = false; })
        Button('本机副本').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).layoutWeight(1).id('parse-open-copies')
          .backgroundColor(this.copyManager ? Theme.accent : Theme.soft).fontColor(this.copyManager ? Color.White : Theme.accent)
          .onClick((): void=> { this.clearSecret(); this.showSettings=false; this.copyManager=true; })
      }.width('100%')
      Text(this.parseState.message).fontColor(Theme.muted).fontSize(13).lineHeight(21).width('100%')
      if (this.credentialFeedback.length > 0) {
        Text(this.credentialFeedback).fontColor(Theme.amber).fontSize(13).lineHeight(21).width('100%')
      }
      if (this.showSettings && !this.copyManager) {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text('MinerU 精准解析').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).width('100%')
              Text('用于文字、表格与版式的识别，识别结果会保存在本机。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(this.credentialText()).fontSize(11).fontColor(this.parseState.credential === DocumentCredentialStatus.Configured ? Theme.accent : Theme.muted)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(Theme.soft).borderRadius(10)
          }.width('100%')
          Text('Token 在「API Key 管理」中保存和修改。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          Button('管理 API Key').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%')
            .id('parse-open-keys').onClick((): void => { this.onKeys(); })
          Row({ space: 10 }) {
            Text('启用云端解析').fontColor(Theme.ink).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.parseState.snapshot.config.enabled }).selectedColor(Theme.accent)
              .onChange((isOn: boolean): void => { this.service?.setEnabled(isOn); })
          }.width('100%')
          Text('保存 Token 不会上传任何文件。PDF、DOCX 与图片会在「我的资料」逐份确认后发送。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
        Column({ space: 10 }) {
          Row({ space: 10 }) {
            Text('文件与处理').fontColor(Theme.ink).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
          }.width('100%')
          Text('导入和管理资料、查看图片处理，都在「我的资料」中完成。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          Button('导入与管理资料').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('parse-open-docx').onClick(this.onOpenDocx)
          Button('图片解析与入库').fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('parse-open-images').enabled(!this.parseState.busy).onClick(this.onOpenImages)
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
        Column({ space: 10 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 10 }) {
              Text('服务能力说明').fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
              Text(this.capabilityOpen ? '收起' : '查看').fontSize(12).fontColor(Theme.accent)
            }.width('100%')
          }.width('100%').backgroundColor(Color.Transparent).id('parse-capability-details').onClick((): void => { this.capabilityOpen = !this.capabilityOpen; })
          if (this.capabilityOpen) {
            Text('云端只负责文字与版式识别；图片理解、描述与检索准备在「我的 → 图片理解 / 嵌入模型」中单独开启。').fontSize(12).fontColor(Theme.muted).lineHeight(20).width('100%')
            Text(this.parseState.limitation).fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
            Text(this.service?.capabilitySummary() ?? '解析能力暂不可用').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
          }
        }.width('100%').padding(18).backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
      }
      if (!this.showSettings && !this.copyManager) {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            Button('最近').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.taskSort === 'time' ? Theme.accent : Theme.soft).fontColor(this.taskSort === 'time' ? Color.White : Theme.accent)
              .onClick((): void => { this.taskSort = 'time'; this.taskPage = 0; })
            Button('按名称').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.taskSort === 'name' ? Theme.accent : Theme.soft).fontColor(this.taskSort === 'name' ? Color.White : Theme.accent)
              .onClick((): void => { this.taskSort = 'name'; this.taskPage = 0; })
            Blank()
            Button(this.taskView === 'folders' ? '分类中' : '分类').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.taskView === 'folders' ? Theme.accent : Theme.soft).fontColor(this.taskView === 'folders' ? Color.White : Theme.accent)
              .onClick((): void => { this.taskView = this.taskView === 'folders' ? 'list' : 'folders'; this.taskFolder = ''; this.taskPage = 0; })
          }.width('100%')
          if (this.taskView === 'folders' && this.taskFolder.length === 0) {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.taskGroups(), (group: ParseTaskGroup) => {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: 8 }) {
                    Row() { Text(group.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1); Text(String(group.count)).fontSize(12).fontColor(Theme.accent) }.width('100%')
                    Text('打开分类').fontSize(12).fontColor(Theme.muted).width('100%').textAlign(TextAlign.Start)
                  }.width('100%').padding(14).alignItems(HorizontalAlign.Start)
                }.width('44%').margin({ right: '2%', bottom: 10 }).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
                  .onClick((): void => { this.taskFolder = group.key; this.taskPage = 0; })
              }, (group: ParseTaskGroup): string => group.key)
            }.width('100%')
          } else {
            if (this.taskFolder.length > 0) {
              Row({ space: 8 }) {
                Button('‹ 全部分类').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12 }).onClick((): void => { this.taskFolder = ''; this.taskPage = 0; })
                Text(this.taskGroupName(this.taskFolder)).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
              }.width('100%')
            }
            if (this.taskRows.length === 0) { Text('还没有解析任务。导入文件后，这里会显示处理进度。').fontColor(Theme.muted).fontSize(13).lineHeight(21).width('100%').padding(14) }
            ForEach(this.visibleTasks(), (row: DocumentParseTaskPresentation) => {
              DocumentParseTaskRow({ taskRow: row, actionBusy: this.parseState.busy,
                onResume: (id: string): void => { this.resumeId = id; } })
            }, (row: DocumentParseTaskPresentation): string => row.taskId)
            if (this.taskRowsForView().length > 6) {
              Row({ space: 10 }) {
                Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.taskPage > 0).onClick((): void => { this.taskPage--; })
                Text(`${this.taskPage + 1} / ${this.taskPageCount()}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
                Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.taskPage + 1 < this.taskPageCount()).onClick((): void => { this.taskPage++; })
              }.width('100%')
            }
          }
          if (this.parseState.busy) {
            Row({ space: 8 }) {
              LoadingProgress().width(20).height(20).color(Theme.accent)
              Text(this.parseState.message).fontColor(Theme.muted).fontSize(13).layoutWeight(1)
            }.width('100%')
          }
          Button('暂停本机动作').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').onClick((): void => { this.clearSecret(); this.service?.pause(); })
          if (this.parseState.snapshot.occupancy.taskId.length > 0 && !this.parseState.snapshot.occupancy.terminalObserved) {
            Text(this.parseState.snapshot.occupancy.retired ? '已停止跟踪先前云端任务；这不代表云端删除或取消。' : '有一个云端任务还没有结束。暂停或删除本机内容不会解除云端任务。').fontColor(this.parseState.snapshot.occupancy.retired ? Theme.muted : Theme.amber).fontSize(12).lineHeight(20).width('100%')
            Button('核对原云端任务').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').onClick((): void => { this.slotConfirm = true; })
            if (this.service?.canRetireOccupancy() ?? false) {
              Text('如果确认不再上传或等待这个任务，可以停止本机跟踪。停止不代表云端删除或取消。').fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%')
              Row({ space: 10 }) {
                Button('停止本机跟踪').fontSize(13).fontColor(Theme.danger).backgroundColor(Theme.warning).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.confirmRetire(); })
                Button('继续等待').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.service?.dismissRetireOccupancy(); })
              }.width('100%')
            }
          }
          if (this.resumeId.length > 0 || this.slotConfirm) {
            Text('确认当前账号与之前一致后，先查看原任务。服务明确仍需要文件时，最多补传同一份原件一次；失败结果最多重新获取两次，可能产生流量或费用。').fontColor(Theme.ink).fontSize(13).lineHeight(21).width('100%')
            Row({ space: 10 }) {
              Button('取消').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.resumeId = ''; this.slotConfirm = false; })
              Button('继续').fontSize(13).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => {
                if (this.slotConfirm) { this.service?.inspectOccupancy(true); } else { this.service?.resume(this.resumeId, true); }
                this.resumeId = ''; this.slotConfirm = false;
              })
            }.width('100%')
          }
          if (this.parseState.snapshot.results.length > 0) { Button(this.resultDetailsOpen ? '收起技术信息' : '查看技术信息').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('parse-result-details').onClick((): void => { this.resultDetailsOpen = !this.resultDetailsOpen; }) }
          ForEach(this.visibleResults(), (result: DocumentParseResultEnvelope) => {
            Column({ space: 8 }) {
              Text('解析服务已完成，结果已保存在本机').fontColor(Theme.ink).fontWeight(FontWeight.Medium).width('100%')
              if (this.resultDetailsOpen) {
                Text(`接收于 ${new Date(result.receivedAt).toLocaleString()} · ${this.sizeText(result.bytes)}`).fontColor(Theme.muted).fontSize(12).lineHeight(19).width('100%')
                Text('内容待结构校验').fontColor(Theme.muted).fontSize(12).width('100%')
                Text(this.parseState.resultDirectory).fontColor(Theme.muted).fontSize(11).width('100%').wordBreak(WordBreak.BREAK_ALL)
              }
              if (this.isPdfResult(result)) {
                Button('校验并准备入库').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(!this.parseState.busy)
                  .onClick((): void => { this.onPreparePdf(result.assetId); })
              }
              if (this.isImageResult(result)) {
                Button('校验图片并查看正文').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('image-result-review-'+result.assetId).enabled(!this.parseState.busy)
                  .onClick((): void => { this.onPrepareImage(result.assetId); })
              }
              if (this.isDocxResult(result)) { Button('打开 Word 原生内容').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').id('docx-result-open-'+result.assetId).enabled(!this.parseState.busy).onClick(this.onOpenDocx) }
            }.width('100%').padding(14).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
          }, (result: DocumentParseResultEnvelope): string => result.assetId)
          if (this.parseState.snapshot.results.length > 3) {
            Row({ space: 10 }) {
              Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.resultPage > 0).onClick((): void => { this.resultPage--; })
              Text(`${this.resultPage + 1} / ${this.resultPageCount()}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
              Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.resultPage + 1 < this.resultPageCount()).onClick((): void => { this.resultPage++; })
            }.width('100%')
          }
          Button('选择文件，仅保存原件').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(!this.parseState.busy).onClick((): void => { this.service?.prepare(); })
          ForEach(this.parseState.snapshot.originals, (original: DocumentOriginal) => {
            if (!documentIsImage(original.format) && original.format !== DocumentParseFormat.Docx) {
              DocumentParseOriginalRow({ original: original, service: this.service, refreshEpoch: this.parseState.inputEpoch,
                submitBlockReason: this.service?.submitReason(original) ?? '解析能力不可用' })
            }
          }, (original: DocumentOriginal): string => original.id)
        }.width('100%')
      }
      if (this.copyManager) {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            Button('最近').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.copySort === 'time' ? Theme.accent : Theme.soft).fontColor(this.copySort === 'time' ? Color.White : Theme.accent)
              .onClick((): void => { this.copySort = 'time'; this.copyPage = 0; this.updateTaskRows(); })
            Button('按名称').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.copySort === 'name' ? Theme.accent : Theme.soft).fontColor(this.copySort === 'name' ? Color.White : Theme.accent)
              .onClick((): void => { this.copySort = 'name'; this.copyPage = 0; this.updateTaskRows(); })
            Blank()
            Button(this.copyView === 'folders' ? '分类中' : '分类').fontSize(13).constraintSize({ minHeight: 44 }).borderRadius(12).padding({ left: 12, right: 12 })
              .backgroundColor(this.copyView === 'folders' ? Theme.accent : Theme.soft).fontColor(this.copyView === 'folders' ? Color.White : Theme.accent)
              .onClick((): void => { this.copyView = this.copyView === 'folders' ? 'list' : 'folders'; this.copyFolder = ''; this.copyPage = 0; })
          }.width('100%')
          TextInput({text:this.copyFilter,placeholder:'按文件名筛选',controller:this.copyController}).fontColor(Theme.ink).backgroundColor(Theme.inputSurface).borderRadius(12).border({ width: 1, color: Theme.line }).id('parse-copy-filter').onChange((v: string): void=> { this.copyFilter=v; this.copyPage=0; })
          if (this.copyView === 'folders' && this.copyFolder.length === 0) {
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.copyGroups(), (group: ParseCategory) => {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: 8 }) {
                    Row() { Text(group.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1); Text(String(group.count)).fontSize(12).fontColor(Theme.accent) }.width('100%')
                    Text('打开分类').fontSize(12).fontColor(Theme.muted).width('100%').textAlign(TextAlign.Start)
                  }.width('100%').padding(14).alignItems(HorizontalAlign.Start)
                }.width('44%').margin({ right: '2%', bottom: 10 }).backgroundColor(Theme.surface).borderRadius(16).border({ width: 1, color: Theme.line })
                  .onClick((): void => { this.copyFolder = group.name; this.copyPage = 0; this.updateTaskRows(); })
              }, (group: ParseCategory): string => group.key)
            }.width('100%')
          } else {
            if (this.copyFolder.length > 0) {
              Row({ space: 8 }) {
                Button('‹ 全部分类').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 12, right: 12 }).onClick((): void => { this.copyFolder = ''; this.copyPage = 0; this.updateTaskRows(); })
                Text(this.copyFolder).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).layoutWeight(1)
              }.width('100%')
            }
            if (this.visibleCopies().length === 0) { Text('没有找到本机副本').fontColor(Theme.muted).fontSize(13).lineHeight(21).width('100%').padding(14) }
            ForEach(this.visibleCopies(), (saved: DocumentOriginal) => {
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Text(saved.title).fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${saved.format} · ${this.sizeText(saved.bytes)}${this.savedText(saved.savedAt).length > 0 ? ' · ' + this.savedText(saved.savedAt) : ''}`).fontColor(Theme.muted).fontSize(12).width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button('删除').fontSize(12).fontColor(Theme.danger).backgroundColor(Theme.warning).borderRadius(10).constraintSize({ minHeight: 44 })
                  .id('parse-delete-copy-'+saved.id).enabled(!this.parseState.busy && !this.deletingCopy).onClick((): void => { this.askDeleteCopy(saved); })
              }.width('100%').padding(14).backgroundColor(Theme.surface).borderRadius(14).border({ width: 1, color: Theme.line })
            }, (saved: DocumentOriginal): string => `delete-${saved.id}`)
            if (this.copyRows().length > 8) {
              Row({ space: 10 }) {
                Button('上一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.copyPage > 0).onClick((): void => { this.copyPage--; })
                Text(`${this.copyPage + 1} / ${this.copyPageCount()}`).fontSize(13).fontColor(Theme.ink).layoutWeight(1).textAlign(TextAlign.Center)
                Button('下一页').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).padding({ left: 14, right: 14 }).enabled(this.copyPage + 1 < this.copyPageCount()).onClick((): void => { this.copyPage++; })
              }.width('100%')
            }
          }
        }.width('100%')
      }
      if (this.deleteFeedback.length>0) { Text(this.deleteFeedback).fontColor(Theme.amber).id('parse-delete-copy-feedback').fontSize(13).lineHeight(21).width('100%') }
      if (this.parseState.snapshot.cleanup.length > 0) {
        Text('本机还有可清理的临时文件，仍占用存储空间').fontColor(Theme.amber).fontSize(12).width('100%')
        Button('重试本机清理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(!this.parseState.busy).onClick((): void => { this.service?.retryCleanup(); })
      }
    }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Observed
class DocumentParseTaskPresentation {
  taskId: string = ''; title: string = ''; stageText: string = ''; stageLabel: string = ''; remoteText: string = '';
  queryText: string = ''; uploadText: string = ''; downloadText: string = ''; pageText: string = '';
  lastActionText: string = ''; failureText: string = ''; failureDetail: string = '';
  uploading: boolean = false; downloading: boolean = false; terminal: boolean = false;
  suppliedBytes: number = 0; originalBytes: number = 0; writtenBytes: number = 0; resultTotal: number = 0;
  savedAt: number = 0; format: string = ''; groupKey: string = '';
  update(task: DocumentParseTask, originalBytes: number, title: string): void {
    this.taskId = task.id; this.title = title; this.stageText = task.stage; this.stageLabel = this.stageName(task.stage); this.remoteText = `云阶段 ${task.remote || '尚未观察'}`;
    this.groupKey = task.stage === DocumentParseStage.Received ? 'done' : [DocumentParseStage.RemoteFailed,DocumentParseStage.Paused,DocumentParseStage.Failed,DocumentParseStage.Uncertain,DocumentParseStage.UploadUnknown].indexOf(task.stage) >= 0 ? 'attention' : 'active';
    this.queryText = `累计查询 ${task.queries} 次 · 最后响应 ${task.lastQueryAt > 0 ? new Date(task.lastQueryAt).toLocaleString() : '未记录'}`;
    this.uploading = task.stage === DocumentParseStage.Uploading; this.downloading = task.stage === DocumentParseStage.Downloading;
    this.terminal = task.stage === DocumentParseStage.Received || task.stage === DocumentParseStage.RemoteFailed;
    this.suppliedBytes = task.uploadBytes; this.originalBytes = originalBytes; this.writtenBytes = task.downloadBytes; this.resultTotal = task.downloadTotal;
    this.uploadText = `本次已供给 SDK ${task.uploadBytes}/${originalBytes} 字节 · ${task.uploaded ? 'PUT 200 及原字节校验已确认' : '未确认上传成功'}`;
    this.downloadText = `ZIP 本次实际写入 ${task.downloadBytes} 字节${task.downloadTotal > 0 ? ' / HTTP 长度 ' + task.downloadTotal : ' · 总长度未知'}`;
    this.pageText = task.totalPages > 0 ? `已处理 ${task.extractedPages}/${task.totalPages} 页` : '服务未报告页进度';
    this.lastActionText = `${task.lastAction || task.checkpoint} · 同对象补传${task.recoveryUploadUsed ? '已使用' : '未使用'}`;
    this.failureText = task.stage === DocumentParseStage.RemoteFailed ? '云端没有完成这次解析，可以稍后重新提交。' : task.failure.length > 0 ? '这项任务没有完成，之前成功的内容已保留。' : '';
    this.failureDetail = task.failureStage.length > 0 ? `失败阶段 ${task.failureStage}\n${parseFailureSummary(task.failureDetail)}\n${task.stage === DocumentParseStage.Received ? '云结果已接收，仅本机处理恢复' : task.batchId.length > 0 ? '先核对原任务；仅在身份与许可一致且服务明确待文件时允许一次补传，不新建任务' : '身份未知，停止待核，不新建任务'}` : '';
  }
  private stageName(stage: DocumentParseStage): string {
    switch (stage) {
      case DocumentParseStage.Saved: return '已保存，等待开始';
      case DocumentParseStage.Allocation: return '正在准备上传';
      case DocumentParseStage.Uncertain: return '等待确认状态';
      case DocumentParseStage.LeaseReady: return '准备上传';
      case DocumentParseStage.Uploading: return '正在上传';
      case DocumentParseStage.UploadUnknown: return '上传结果待确认';
      case DocumentParseStage.Waiting: return '等待云端接收';
      case DocumentParseStage.Pending: return '排队中';
      case DocumentParseStage.Converting: return '正在转换';
      case DocumentParseStage.Running: return '正在识别';
      case DocumentParseStage.Done: return '识别完成，正在接收';
      case DocumentParseStage.RemoteFailed: return '云端处理失败';
      case DocumentParseStage.Downloading: return '正在接收结果';
      case DocumentParseStage.Received: return '已完成';
      case DocumentParseStage.Paused: return '已暂停';
      case DocumentParseStage.Failed: return '本机处理失败';
      default: return '处理中';
    }
  }
}

@Component
struct DocumentParseTaskRow {
  @State taskDetailsOpen: boolean = false;
  @State taskAdvancedOpen: boolean = false;
  @ObjectLink taskRow: DocumentParseTaskPresentation;
  @Prop actionBusy: boolean = false;
  onResume: (id: string) => void = (_id: string): void => {};
  private sizeText(bytes: number): string {
    if (bytes <= 0) { return '大小未知'; }
    if (bytes >= 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }
  private savedText(time: number): string {
    if (time <= 0) { return ''; }
    const date: Date = new Date(time);
    const pad = (v: number): string => v < 10 ? '0' + String(v) : String(v);
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  }
  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.taskRow.title).fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.savedText(this.taskRow.savedAt)}${this.savedText(this.taskRow.savedAt).length > 0 ? ' · ' : ''}${this.sizeText(this.taskRow.originalBytes)}`).fontColor(Theme.muted).fontSize(11).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.taskRow.stageLabel).fontColor(this.taskRow.groupKey === 'attention' ? Theme.amber : Theme.accent).fontSize(12)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).backgroundColor(this.taskRow.groupKey === 'attention' ? Theme.warning : Theme.soft).borderRadius(10)
      }.width('100%')
      if (this.taskRow.uploading && this.taskRow.originalBytes > 0) {
        Progress({ value: this.taskRow.suppliedBytes, total: this.taskRow.originalBytes, type: ProgressType.Linear }).width('100%').color(Theme.accent)
      }
      if (this.taskRow.downloading && this.taskRow.resultTotal > 0) {
        Progress({ value: this.taskRow.writtenBytes, total: this.taskRow.resultTotal, type: ProgressType.Linear }).width('100%').color(Theme.accent)
      }
      if (this.taskRow.failureText.length > 0) { Text(this.taskRow.failureText).fontColor(Theme.amber).fontSize(12).lineHeight(20).width('100%') }
      Row({ space: 10 }) {
        if (!this.taskRow.terminal) {
          Button('继续处理').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).enabled(!this.actionBusy).onClick((): void => { this.onResume(this.taskRow.taskId); })
        }
        Button(this.taskDetailsOpen ? '收起详情' : '查看详情').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).layoutWeight(1).onClick((): void => { this.taskDetailsOpen = !this.taskDetailsOpen; })
      }.width('100%')
      if (this.taskDetailsOpen) {
        Column({ space: 6 }) {
          Text(`当前阶段：${this.taskRow.stageLabel}`).fontColor(Theme.ink).fontSize(12).width('100%')
          Text(this.taskRow.pageText).fontColor(Theme.muted).fontSize(12).width('100%')
          Text(this.taskRow.queryText).fontColor(Theme.muted).fontSize(12).width('100%')
          Button(this.taskAdvancedOpen ? '收起技术信息' : '技术信息（排障用）').fontSize(12).fontColor(Theme.muted).backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 44 }).width('100%').onClick((): void => { this.taskAdvancedOpen = !this.taskAdvancedOpen; })
          if (this.taskAdvancedOpen) {
            Text(this.taskRow.remoteText).fontColor(Theme.muted).fontSize(11).width('100%')
            Text(this.taskRow.uploadText).fontColor(Theme.muted).fontSize(11).width('100%')
            Text(this.taskRow.downloadText).fontColor(Theme.muted).fontSize(11).width('100%')
            Text(this.taskRow.lastActionText).fontColor(Theme.muted).fontSize(11).width('100%')
            if (this.taskRow.failureDetail.length > 0) { Text(this.taskRow.failureDetail).fontColor(Theme.muted).fontSize(11).lineHeight(18).width('100%') }
          }
        }.width('100%').padding(12).backgroundColor(Theme.inputSurface).borderRadius(12)
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 12 })
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
  @State private open: boolean = false;
  private confirmFile(): void {
    const a: DocumentTestAcknowledgement = new DocumentTestAcknowledgement();
    a.fullFile = this.whole; a.embeddedImages = this.images; a.nonSensitive = this.nonSensitive; a.privacyUnknown = this.unknownPrivacy; a.freeEligible = this.free;
    this.service?.confirm(this.original.id, a);
    this.whole = false; this.images = false; this.nonSensitive = false; this.unknownPrivacy = false; this.free = false;
  }
  private sizeText(bytes: number): string {
    if (bytes <= 0) { return '大小未知'; }
    if (bytes >= 1024 * 1024) { return `${(bytes / (1024 * 1024)).toFixed(1)} MB`; }
    return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  }
  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.original.title).fontColor(Theme.ink).fontSize(15).fontWeight(FontWeight.Medium).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.original.format} · ${this.sizeText(this.original.bytes)}${this.original.pages > 0 ? ' · ' + String(this.original.pages) + ' 页' : ''}`).fontColor(Theme.muted).fontSize(11).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button(this.open ? '收起' : '开始解析').fontSize(12).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(10).constraintSize({ minHeight: 44 }).onClick((): void => { this.open = !this.open; })
      }.width('100%')
      if (this.open) {
        Text(this.original.preflightReason || '发送前需要确认以下内容。').fontColor(Theme.muted).fontSize(12).lineHeight(20).width('100%')
        Row() { Checkbox().selectedColor(Theme.accent).select(this.whole).onChange((v: boolean): void => { this.whole = v; }).accessibilityText('同意发送完整原文件'); Text('发送完整原文件').fontColor(Theme.ink).fontSize(13).layoutWeight(1) }.width('100%')
        Row() { Checkbox().selectedColor(Theme.accent).select(this.images).onChange((v: boolean): void => { this.images = v; }).accessibilityText('确认包含全部内嵌图'); Text('包含文件中的全部内嵌图').fontColor(Theme.ink).fontSize(13).layoutWeight(1) }.width('100%')
        Row() { Checkbox().selectedColor(Theme.accent).select(this.nonSensitive).onChange((v: boolean): void => { this.nonSensitive = v; }).accessibilityText('确认文件为非敏感测试文件'); Text('这是一份有权使用、且不含敏感信息的测试文件').fontColor(Theme.ink).fontSize(13).layoutWeight(1) }.width('100%')
        Row() { Checkbox().selectedColor(Theme.accent).select(this.unknownPrivacy).onChange((v: boolean): void => { this.unknownPrivacy = v; }).accessibilityText('知悉服务留存条件未知'); Text('我知悉服务的留存与使用条件尚不明确，仍同意本次解析').fontColor(Theme.ink).fontSize(13).layoutWeight(1) }.width('100%')
        Row() { Checkbox().selectedColor(Theme.accent).select(this.free).onChange((v: boolean): void => { this.free = v; }).accessibilityText('确认本次免费资格'); Text('本次有免费解析资格，不授权收费').fontColor(Theme.ink).fontSize(13).layoutWeight(1) }.width('100%')
        Text('固定使用 vlm 模式，开启表格与行内公式识别；扫描质量仍需以结果为准。').fontColor(Theme.muted).fontSize(11).lineHeight(18).width('100%')
        Button('确认本件用途').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(this.whole && this.images && this.nonSensitive && this.unknownPrivacy && this.free)
          .onClick((): void => { this.confirmFile(); })
        Text(this.submitBlockReason).fontColor(Theme.muted).fontSize(11).width('100%')
        Button('开始云端解析').fontSize(13).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(12).constraintSize({ minHeight: 44 }).width('100%').enabled(this.submitBlockReason === '')
          .onClick((): void => { this.service?.submit(this.original.id); })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 14 })
      .border({ width: { bottom: 1 }, color: Theme.line })
  }
}
