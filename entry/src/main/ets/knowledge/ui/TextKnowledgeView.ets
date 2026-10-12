import { Theme } from '../../components/Theme';
import { TextKnowledgeService } from '../application/TextKnowledgeService';
import { TextViewState, TextScreen, TextDocument, TextHit, TextSourceRange, TextJob, TextHistory } from '../domain/TextKnowledgeModels';

@Component
export struct TextKnowledgeView {
  @Link knowledgeState: TextViewState;
  service: TextKnowledgeService | undefined = undefined;
  onRetryOpen: () => void = (): void => {};
  @State renameId: string = '';
  @State renameText: string = '';
  @State confirmationIds: string[] = [];
  @State purgeConfirmation: boolean = false;
  @State contentWidth: number = 0;

  private confirmDelete(): void {
    if (this.purgeConfirmation) { this.service?.purge(true); }
    else { this.service?.deleteDocuments(this.confirmationIds, true); }
    this.confirmationIds = []; this.purgeConfirmation = false;
  }

  @Builder
  documentList() {
    Column({ space: 12 }) {
      if (this.knowledgeState.documents.length === 0) {
        Text('尚无本机资料').fontSize(16).fontColor(Theme.muted).padding({ top: 24, bottom: 24 })
      }
      ForEach(this.knowledgeState.documents, (doc: TextDocument) => {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Checkbox({ name: doc.id }).select(this.knowledgeState.selectedIds.indexOf(doc.id) >= 0)
              .onChange((selected: boolean): void => { this.service?.selectDocument(doc.id, selected); })
              .accessibilityText(`选择 ${doc.title}`)
            Text(doc.title).fontSize(16).fontColor(Theme.ink).layoutWeight(1)
          }.width('100%')
          Button(doc.title, { type: ButtonType.Normal }).width('100%').fontColor(Theme.ink)
            .backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 })
            .onClick(() => this.service?.openDocument(doc.id))
          Text(`${doc.format} · ${doc.original.bytes} 字节 · ${doc.stage}${doc.archived ? ' · 已归档' : ''}`)
            .fontSize(12).fontColor(Theme.muted).width('100%')
          if (doc.failure.length > 0) {
            Text(doc.failure).fontSize(13).fontColor(Theme.danger).width('100%')
          }
          if (doc.warnings.length > 0) {
            Text(doc.warnings.join('\n')).fontSize(13).fontColor(Theme.amber).width('100%')
          }
          Flex({ wrap: FlexWrap.Wrap }) {
            Button('重命名', { type: ButtonType.Normal }).onClick((): void => { this.renameId = doc.id; this.renameText = doc.title; })
            Button('重建索引', { type: ButtonType.Normal }).enabled(!this.knowledgeState.busy).onClick(() => this.service?.rebuild(doc.id))
            Button(doc.archived ? '恢复' : '归档', { type: ButtonType.Normal }).onClick(() => this.service?.setArchived(doc.id, !doc.archived))
            Button('删除', { type: ButtonType.Normal }).onClick((): void => { this.confirmationIds = [doc.id]; })
          }.width('100%')
          Divider().color(Theme.line)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (doc: TextDocument): string => `${doc.id}-${doc.updatedAt}-${doc.stage}-${doc.archived}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  hitList() {
    Column({ space: 12 }) {
      ForEach(this.knowledgeState.result.hits, (hit: TextHit) => {
        Column({ space: 8 }) {
          Text(hit.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.ink).width('100%')
          Text(hit.text).fontSize(15).fontColor(Theme.ink).copyOption(CopyOptions.LocalDevice).width('100%')
          Text(`${hit.channel} · 字面命中计数评分 ${hit.score} · ${hit.kind}`).fontSize(12).fontColor(Theme.muted).width('100%')
          Text(hit.referenceState).fontSize(13).fontColor(Theme.amber).width('100%')
          ForEach(hit.ranges, (range: TextSourceRange) => {
            Text(`${range.headingPath.join(' > ')} · 原文第 ${range.startLine}–${range.endLine} 行 · UTF-16 ${range.originalStart}–${range.originalEnd}`)
              .fontSize(12).fontColor(Theme.muted).width('100%')
          }, (range: TextSourceRange): string => `${range.nodeId}-${range.originalStart}-${range.originalEnd}`)
          Button('核对原文', { type: ButtonType.Normal }).fontColor(Theme.accent).backgroundColor(Theme.soft)
            .constraintSize({ minHeight: 44 }).onClick(() => this.service?.openHit(hit))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(Theme.surface).borderRadius(8)
      }, (hit: TextHit): string => `${hit.chunkId}-${hit.referenceState}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  queryView() {
    Column({ space: 12 }) {
      TextArea({ text: this.knowledgeState.question, placeholder: '输入关键词或字面短语' })
        .height(112).fontSize(16).backgroundColor(Theme.surface)
        .onChange((text: string): void => { this.service?.questionChanged(text); })
      Button(this.knowledgeState.searching ? '检索中…' : '检索', { type: ButtonType.Normal })
        .constraintSize({ minHeight: 44 }).width('100%').backgroundColor(Theme.accent).fontColor(Color.White)
        .enabled(!this.knowledgeState.searching).onClick(() => this.service?.search())
      Text(`L0 · ${this.knowledgeState.result.channel}`).fontSize(12).fontColor(Theme.muted)
      if (this.knowledgeState.result.input.notice.length > 0) {
        Text(this.knowledgeState.result.input.notice).fontSize(13).fontColor(Theme.amber).width('100%')
        Text(`实际输入：${this.knowledgeState.result.input.actualInput}`).fontSize(13).fontColor(Theme.ink).width('100%')
      }
      if (this.knowledgeState.result.notice.length > 0) {
        Text(this.knowledgeState.result.notice).fontSize(13).fontColor(Theme.amber).width('100%')
      }
      this.hitList()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  historyView() {
    Column({ space: 12 }) {
      ForEach(this.knowledgeState.history, (record: TextHistory) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 6 }) {
            Text(record.result.input.fullQuestion).fontSize(16).fontColor(Theme.ink).maxLines(3).width('100%')
            Text(`${new Date(record.createdAt).toLocaleString()} · L0 · ${record.result.channel} · ${record.result.hits.length} 条命中`)
              .fontSize(12).fontColor(Theme.muted).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
        }.width('100%').backgroundColor(Theme.surface).borderRadius(8).onClick(() => this.service?.openHistory(record))
      }, (record: TextHistory): string => record.id)
      Row({ space: 8 }) {
        Button('上一页').constraintSize({ minHeight: 44 }).enabled(this.knowledgeState.historyOffset > 20)
          .onClick(() => this.service?.previousHistoryPage())
        Button('下一页').constraintSize({ minHeight: 44 }).enabled(this.knowledgeState.history.length === 20)
          .onClick(() => this.service?.loadHistory(true))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder
  detailView() {
    Column({ space: 12 }) {
      Text(this.knowledgeState.detail.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.ink).width('100%')
      Text(this.knowledgeState.detail.note).fontSize(12).fontColor(Theme.muted).width('100%')
      ForEach(this.knowledgeState.detail.ranges, (range: TextSourceRange) => {
        Text(`命中：原文第 ${range.startLine}–${range.endLine} 行，UTF-16 ${range.originalStart}–${range.originalEnd}`)
          .fontSize(13).fontColor(Theme.accent).width('100%')
      }, (range: TextSourceRange): string => `${range.nodeId}-${range.originalStart}-${range.originalEnd}`)
      Text(this.knowledgeState.detail.excerpts.join('\n\n')).fontSize(16).fontColor(Theme.accent)
        .copyOption(CopyOptions.LocalDevice).width('100%')
      Text(this.knowledgeState.detail.originalText).fontSize(16).fontColor(Theme.ink)
        .copyOption(CopyOptions.LocalDevice).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 14 }) {
      if (this.service === undefined) { Button('重试打开本机知识库').onClick((): void => { this.onRetryOpen(); }) }
      Text('本机文本资料 · txt / md').fontSize(18).fontWeight(FontWeight.Medium).fontColor(Theme.ink).width('100%')
      Text(this.knowledgeState.channel).fontSize(12).fontColor(Theme.muted).width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('资料', { type: ButtonType.Normal }).onClick(() => this.service?.navigate(TextScreen.Documents))
        Button('检索', { type: ButtonType.Normal }).onClick(() => this.service?.navigate(TextScreen.Search))
        Button('历史', { type: ButtonType.Normal }).onClick(() => this.service?.loadHistory(false))
        Button(this.knowledgeState.busy ? '处理中…' : '导入资料', { type: ButtonType.Normal })
          .enabled(!this.knowledgeState.busy).onClick(() => this.service?.importFiles())
      }.width('100%')
      Row({ space: 8 }) {
        Checkbox({ name: 'include-archived' }).select(this.knowledgeState.includeArchived)
          .onChange((selected: boolean): void => { this.service?.setIncludeArchived(selected); })
        Text('包含归档资料').fontSize(14).fontColor(Theme.muted)
      }.width('100%')
      if (this.knowledgeState.screen === TextScreen.Documents) {
        Flex({ wrap: FlexWrap.Wrap }) {
          Button(`删除所选（${this.knowledgeState.selectedIds.length}）`, { type: ButtonType.Normal })
            .enabled(this.knowledgeState.selectedIds.length > 0)
            .onClick((): void => { this.confirmationIds = this.knowledgeState.selectedIds.slice(); })
          Button('清空本机资料', { type: ButtonType.Normal }).onClick((): void => { this.purgeConfirmation = true; })
        }.width('100%')
      }
      if (this.renameId.length > 0) {
        TextInput({ text: this.renameText, placeholder: '展示标题' }).onChange((text: string): void => { this.renameText = text; })
        Row({ space: 8 }) {
          Button('保存标题').onClick((): void => { this.service?.rename(this.renameId, this.renameText); this.renameId = ''; })
          Button('取消').onClick((): void => { this.renameId = ''; })
        }
      }
      if (this.purgeConfirmation || this.confirmationIds.length > 0) {
        Column({ space: 8 }) {
          Text(this.purgeConfirmation ? '确认清空本机用户知识库全部资料？' : `确认删除所选 ${this.confirmationIds.length} 篇资料？`)
            .fontSize(16).fontColor(Theme.danger).width('100%')
          Text('只删除应用内用户副本，不影响探针和外部原文件。历史问题、命中文本与定位快照仍保留。')
            .fontSize(14).fontColor(Theme.ink).width('100%')
          Row({ space: 8 }) {
            Button('确认删除').onClick((): void => { this.confirmDelete(); })
            Button('取消').onClick((): void => { this.confirmationIds = []; this.purgeConfirmation = false; })
          }
        }.width('100%').padding(12).backgroundColor(Theme.warning).borderRadius(8)
      }
      if (this.knowledgeState.cleanupCount > 0) {
        Button(`重试待清理（${this.knowledgeState.cleanupCount}）`).onClick(() => this.service?.retryCleanup())
      }
      if (this.knowledgeState.busy) {
        Button('暂停处理', { type: ButtonType.Normal }).constraintSize({ minHeight: 44 }).onClick(() => this.service?.cancel())
      }
      ForEach(this.knowledgeState.jobs, (job: TextJob) => {
        Column({ space: 8 }) {
          Text(`阶段：${job.stage} · 完整检查点：${job.checkpoint}`).fontSize(13).fontColor(Theme.muted).width('100%')
          if (job.failure.length > 0) { Text(job.failure).fontSize(13).fontColor(Theme.danger).width('100%') }
          Button('继续处理', { type: ButtonType.Normal }).enabled(!this.knowledgeState.busy)
            .constraintSize({ minHeight: 44 }).onClick(() => this.service?.resume(job.documentId))
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (job: TextJob): string => `${job.id}-${job.stage}-${job.cancelGeneration}`)
      if (this.knowledgeState.screen !== TextScreen.Documents) {
        Button('返回', { type: ButtonType.Normal }).constraintSize({ minHeight: 44 }).onClick(() => this.service?.back())
      }
      if (this.knowledgeState.message.length > 0) {
        Text(this.knowledgeState.message).fontSize(14).fontColor(Theme.muted).width('100%')
      }
      if (this.knowledgeState.message.includes('历史保存失败')) {
        Button('重试保存历史').onClick(() => this.service?.retrySaveHistory())
      }
      if (this.knowledgeState.screen === TextScreen.Documents) {
        if (this.contentWidth >= 760) {
          Row({ space: 24 }) {
            Column() { this.documentList() }.layoutWeight(1)
            Column() { this.queryView() }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        } else {
          this.documentList()
        }
      } else if (this.knowledgeState.screen === TextScreen.Search) {
        this.queryView()
      } else if (this.knowledgeState.screen === TextScreen.History) {
        this.historyView()
      } else if (this.knowledgeState.screen === TextScreen.Record) {
        Text('完整问题').fontSize(13).fontColor(Theme.muted).width('100%')
        Text(this.knowledgeState.result.input.fullQuestion).fontSize(16).fontColor(Theme.ink).copyOption(CopyOptions.LocalDevice).width('100%')
        Text(`实际输入：${this.knowledgeState.result.input.actualInput}`).fontSize(14).fontColor(Theme.muted).width('100%')
        Text(this.knowledgeState.result.input.notice).fontSize(13).fontColor(Theme.amber).width('100%')
        this.hitList()
      } else {
        this.detailView()
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 24 })
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        this.contentWidth = typeof newArea.width === 'number' ? newArea.width : Number(newArea.width);
      })
  }
}
