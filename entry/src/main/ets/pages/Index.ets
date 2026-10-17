/*
 * Original entry template Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { Theme } from '../components/Theme';
import { WorkbenchPage, ProfilePage } from '../components/FeaturePages';
import { TextKnowledgeView } from '../knowledge/ui/TextKnowledgeView';
import { TextKnowledgeAssembly } from '../knowledge/infra/TextKnowledgeAssembly';
import { TextKnowledgeService } from '../knowledge/application/TextKnowledgeService';
import { TextViewState, TextHit } from '../knowledge/domain/TextKnowledgeModels';
import { DocumentParseAssembly } from '../knowledge/infra/DocumentParseAssembly';
import { DocumentParseService } from '../knowledge/application/DocumentParseService';
import { DocumentParseViewState } from '../knowledge/domain/DocumentParseModels';
import { DocumentParseView } from '../knowledge/ui/DocumentParseView';
import { KnowledgeAssembly } from '../knowledge/infra/KnowledgeAssembly';
import { EmbeddingSettingsView } from '../knowledge/ui/EmbeddingSettingsView';
import { EmbeddingService } from '../knowledge/application/EmbeddingService';
import { PdfIngestionService } from '../knowledge/application/PdfIngestionService';
import { PdfIngestionView } from '../knowledge/ui/PdfIngestionView';
import { KnowledgeView } from '../knowledge/ui/KnowledgeView';
import { KnowledgeSearchService } from '../knowledge/application/KnowledgeSearchService';
import { KnowledgeHit, KnowledgeSourceKind } from '../knowledge/domain/KnowledgeSearchModels';
import { PdfPageAdapter } from '../knowledge/infra/PdfPageAdapter';
import { PdfSourceView } from '../knowledge/ui/PdfSourceView';
import { PdfSourceBinding, PdfLocator, PdfKnowledgeDocument } from '../knowledge/domain/PdfKnowledgeModels';
import { KnowledgeDerivedLifecycle } from '../knowledge/application/KnowledgeLifecycleService';
import { KnowledgeDocumentListPort } from '../knowledge/domain/KnowledgePorts';
import {
  AssistantService, CalendarDraft, ChatMessage, DEMO_SCENARIOS, DemoScenario,
  OperationResult, OperationState, RequestState
} from '../model/AssistantModels';
import { MockAssistantService } from '../mock/MockAssistantService';
import { KnowledgePlatformDiagnostics } from '../knowledge/ui/KnowledgePlatformDiagnostics';
import { PdfPageReferenceState, ResultPageReference } from '../knowledge/domain/PdfLocalModels';
import { KnowledgeCancellation } from '../knowledge/domain/PdfKnowledgeModels';

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State calendarOpen: boolean = false;
  @State input: string = '';
  @State messages: ChatMessage[] = [];
  @State draft: CalendarDraft | undefined = undefined;
  @State result: OperationResult | undefined = undefined;
  @State records: OperationResult[] = [];
  @State generating: boolean = false;
  @State executing: boolean = false;
  @State requestState: RequestState = RequestState.Unsupported;
  @State scenario: DemoScenario = DemoScenario.Normal;
  @State showScenarios: boolean = false;
  @State noticeTitle: string = '';
  @State noticeText: string = '';
  @State knowledgeState: TextViewState = new TextViewState();
  @State knowledgeService: TextKnowledgeService | undefined = undefined;
  private knowledgeAssembly: TextKnowledgeAssembly | undefined = undefined;
  @State parseState: DocumentParseViewState = new DocumentParseViewState();
  @State parseService: DocumentParseService | undefined = undefined;
  @State parseOpen: boolean = false;
  @State parseSettings: boolean = false;
  @State embeddingOpen: boolean = false;
  @State pdfIngestionOpen: boolean = false;
  @State pdfIngestionService: PdfIngestionService | undefined = undefined;
  @State unifiedSearchService: KnowledgeSearchService | undefined = undefined;
  @State pdfSourceOpen: boolean = false;
  @State pdfSourceBinding: PdfSourceBinding = new PdfSourceBinding();
  @State pdfSourceLocator: PdfLocator = new PdfLocator();
  @State pdfPageAdapter: PdfPageAdapter | undefined = undefined;
  @State derivedLifecycle: KnowledgeDerivedLifecycle | undefined = undefined;
  @State pdfDocumentsPort: KnowledgeDocumentListPort | undefined = undefined;
  @State embeddingService: EmbeddingService | undefined = undefined;
  @State embeddingClearEpoch: number = 0;
  @State platformDiagnosticsOpen: boolean = false;
  private sharedKnowledge: KnowledgeAssembly | undefined = undefined;
  private parseAssembly: DocumentParseAssembly | undefined = undefined;
  private service: AssistantService = new MockAssistantService();
  private requestId: string = '';
  private operationId: string = '';
  private alive: boolean = true;
  private scroller: Scroller = new Scroller();
  private inputController: TextAreaController = new TextAreaController();
  private tabNames: string[] = ['助手', '工作台', '知识库', '我的'];
  private tabMarks: string[] = ['休', '办', '知', '我'];

  aboutToAppear(): void {
    this.alive = true;
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.service.cancel(this.requestId);
    this.knowledgeAssembly = undefined;
    this.parseAssembly?.close();
    this.embeddingService?.pause(); this.sharedKnowledge?.release();
  }

  onBackPress(): boolean {
    if (this.platformDiagnosticsOpen) { this.platformDiagnosticsOpen = false; return true; }
    if (this.pdfSourceOpen) { this.pdfSourceOpen = false; return true; }
    if (this.pdfIngestionOpen) { this.pdfIngestionOpen = false; return true; }
    if (this.embeddingOpen) { this.closeEmbedding(); return true; }
    if (this.parseOpen) { this.closeParse(); return true; }
    if (this.tab === 2 && this.knowledgeService?.back()) { return true; }
    if (this.noticeTitle.length > 0) {
      this.noticeTitle = '';
      return true;
    }
    if (this.showScenarios) {
      this.showScenarios = false;
      return true;
    }
    if (this.calendarOpen) {
      this.calendarOpen = false;
      return true;
    }
    if (this.tab !== 0) {
      this.changeTab(0);
      return true;
    }
    return false;
  }

  private notice(title: string, message: string): void {
    this.inputController.stopEditing();
    this.noticeTitle = title;
    this.noticeText = message;
    this.scroller.scrollEdge(Edge.Top);
  }

  private changeTab(index: number): void {
    if (index !== this.tab) { this.pdfIngestionOpen = false; }
    if (index !== this.tab && this.embeddingOpen) { this.closeEmbedding(); }
    if (index !== this.tab && this.parseOpen) { this.closeParse(); }
    if (index !== this.tab && this.generating) {
      this.cancelGeneration();
    }
    this.inputController.stopEditing();
    this.tab = index;
    if (index === 2) { this.openKnowledge(); }
    this.calendarOpen = false;
    this.showScenarios = false;
    this.noticeTitle = '';
    this.scroller.scrollEdge(Edge.Top);
  }

  private async openKnowledge(): Promise<void> {
    if (this.knowledgeAssembly !== undefined) { return; }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { this.knowledgeState.message = '本机上下文不可用，资料未修改'; return; }
    const shared: KnowledgeAssembly = this.sharedKnowledge ?? KnowledgeAssembly.forContext(context);
    if (this.sharedKnowledge === undefined) { this.sharedKnowledge = shared; try { await shared.acquire(); } catch { this.sharedKnowledge = undefined; this.knowledgeState.message = '用户库打开失败，资料保留'; return; } }
    const assembly: TextKnowledgeAssembly = shared.text;
    shared.subscribe((): void => { if (this.alive) { this.knowledgeState = assembly.service.viewState(); } });
    this.knowledgeAssembly = assembly;
    try {
      this.knowledgeService = assembly.service; this.knowledgeState = assembly.service.viewState();
       this.unifiedSearchService = shared.search;
       this.embeddingService = shared.repository.ready() ? shared.embedding : undefined;
      this.derivedLifecycle = shared.derivedLifecycle; this.pdfDocumentsPort = shared.repository;
    }
    catch {
      this.knowledgeAssembly = undefined; this.knowledgeService = undefined;
      this.knowledgeState = assembly.service.viewState(); this.knowledgeState.message = '用户知识库打开失败，资料保留，可重试';
    }
  }
  private async openKnowledgeHit(hit: KnowledgeHit): Promise<void> {
    if (hit.sourceKind === KnowledgeSourceKind.Text) {
      const text: TextHit = new TextHit(); text.documentId = hit.documentId; text.documentVersion = hit.originalVersion; text.originalHash = hit.originalHash;
      text.generation = hit.generation; text.snapshotId = hit.snapshotId; text.chunkId = hit.chunkId; text.text = hit.text; text.ranges = hit.locator.textRanges;
      await this.knowledgeService?.openHit(text); return;
    }
    const doc: PdfKnowledgeDocument | undefined = await this.sharedKnowledge?.repository.get(hit.documentId); const context = this.getUIContext().getHostContext();
    if (doc === undefined || doc.tombstone || context === undefined) { return; }
    if (this.sharedKnowledge === undefined) { return; }
    const sourceJob = await this.sharedKnowledge.repository.generationJob(hit.generation);
    if (doc.activeContentGeneration !== hit.generation || doc.binding.originalHash !== hit.originalHash) { return; }
    let pageReference: ResultPageReference;
    try { pageReference = await this.sharedKnowledge.pages.resolve(hit,new KnowledgeCancellation()); if (pageReference.state !== PdfPageReferenceState.Verified) { return; } } catch { this.knowledgeState.message = '原页依据或原件已失效，未跳转'; return; }
    if (sourceJob.binding === undefined || sourceJob.snapshotId !== hit.snapshotId || sourceJob.snapshotHash !== hit.snapshotHash || sourceJob.binding.originalHash !== hit.originalHash || sourceJob.binding.originalVersion !== hit.originalVersion) { return; }
    this.pdfSourceBinding = sourceJob.binding; this.pdfSourceLocator = hit.locator.pdfRegions[0] ?? new PdfLocator();
    const adapter: PdfPageAdapter = new PdfPageAdapter(context.filesDir);
    if (this.sharedKnowledge === undefined) { return; }
    adapter.attachLease(this.sharedKnowledge.repository,this.sharedKnowledge.sourceReadLease(sourceJob.sourceId,hit.generation));
    adapter.attachSnapshot(this.sharedKnowledge.repository,this.sharedKnowledge.assets,hit.snapshotId,hit.snapshotHash);
    adapter.attachPageReference(pageReference);
    adapter.attachNodeIds(await this.sharedKnowledge.repository.chunkSources(hit.chunkId,hit.generation));
    try { if (this.pdfPageAdapter !== undefined) { await this.sharedKnowledge.sources.release(this.pdfPageAdapter); } this.sharedKnowledge.sources.adopt(adapter); this.pdfPageAdapter = adapter; this.pdfSourceOpen = true; } catch { this.knowledgeState.message = '原件读租约释放待确认，请重试释放'; }
  }
  private closeParse(): void {
    this.parseService?.clearInput(); this.parseOpen = false;
  }
  private closeEmbedding(): void { this.embeddingClearEpoch++; this.embeddingService?.clearInput(); this.embeddingOpen = false; }
  private async openEmbedding(): Promise<void> {
    this.embeddingOpen = true;
    if (this.sharedKnowledge !== undefined) { this.embeddingService = this.sharedKnowledge.repository.ready() ? this.sharedKnowledge.embedding : undefined; return; }
    const context = this.getUIContext().getHostContext(); if (context === undefined) { return; }
    const assembly: KnowledgeAssembly = KnowledgeAssembly.forContext(context); this.sharedKnowledge = assembly;
    try { await assembly.acquire(); this.embeddingService = assembly.repository.ready() ? assembly.embedding : undefined; }
    catch { this.sharedKnowledge = undefined; this.embeddingService = undefined; }
  }
  private async preparePdf(resultId: string): Promise<void> {
    this.pdfIngestionOpen = true;
    const context = this.getUIContext().getHostContext(); if (context === undefined || this.parseService === undefined) { return; }
    if (this.sharedKnowledge === undefined) { this.sharedKnowledge = KnowledgeAssembly.forContext(context); try { await this.sharedKnowledge.acquire(); } catch { return; } }
    this.pdfIngestionService = this.sharedKnowledge.ingestion; this.derivedLifecycle = this.sharedKnowledge.derivedLifecycle; this.pdfIngestionService.prepare(this.parseService,resultId);
  }
  private async openPdfJobs(): Promise<void> {
    const context = this.getUIContext().getHostContext(); if (context === undefined) { return; }
    if (this.sharedKnowledge === undefined) { this.sharedKnowledge = KnowledgeAssembly.forContext(context); await this.sharedKnowledge.acquire(); }
    this.pdfIngestionService = this.sharedKnowledge.ingestion; this.derivedLifecycle = this.sharedKnowledge.derivedLifecycle;
    await this.pdfIngestionService.refreshJobs(); this.pdfIngestionOpen = true;
  }
  private async openParse(settings: boolean): Promise<void> {
    this.parseSettings = settings; this.parseOpen = true; this.scroller.scrollEdge(Edge.Top);
    if (this.parseAssembly !== undefined) { this.parseService?.clearInput(); return; }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { this.parseState.message = '本机上下文不可用，解析准备未打开'; return; }
    const assembly: DocumentParseAssembly = new DocumentParseAssembly(context, (): void => {
      if (this.alive) { this.parseState = assembly.service.viewState(); }
    });
    this.parseAssembly = assembly;
    try { await assembly.initialize(); this.parseService = assembly.service; this.parseState = assembly.service.viewState(); }
    catch { await assembly.close(); this.parseAssembly = undefined; this.parseService = undefined; this.parseState = assembly.service.viewState(); }
  }

  private addMessage(text: string, isUser: boolean = false): void {
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: isUser, text: text };
    this.messages = this.messages.concat([message]);
  }

  private blocked(): boolean {
    return this.generating || this.executing || this.draft !== undefined;
  }

  private useSample(): void {
    this.input = this.service.sampleText;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private async send(): Promise<void> {
    if (this.blocked() || this.input.trim().length === 0 || this.input.length > 500) {
      return;
    }
    const id = this.service.nextId('request');
    this.requestId = id;
    this.result = undefined;
    this.generating = true;
    this.requestState = RequestState.Unsupported;
    this.inputController.stopEditing();
    this.addMessage(this.input, true);
    const selected = this.scenario;
    // Execution scenarios remain selected until confirmation.
    if (selected === DemoScenario.ModelFailure || selected === DemoScenario.InvalidDraft ||
      selected === DemoScenario.Clarification || selected === DemoScenario.GenerationTimeout) {
      this.scenario = DemoScenario.Normal;
    }
    try {
      const reply = await this.service.generate(id, this.input, selected);
      if (!this.alive || this.requestId !== id) {
        return;
      }
      this.generating = false;
      this.requestState = reply.state;
      this.draft = reply.draft;
      this.operationId = reply.draft ? this.service.nextId('operation') : '';
      this.addMessage(reply.message);
      this.scroller.scrollEdge(Edge.Bottom);
    } catch {
      if (this.alive && this.requestId === id) {
        this.generating = false;
        this.requestState = RequestState.Failed;
        this.addMessage('生成失败，输入已保留，请重试。');
      }
    }
  }

  private cancelGeneration(): void {
    this.service.cancel(this.requestId);
    this.requestId = '';
    this.generating = false;
    this.requestState = RequestState.Cancelled;
    this.addMessage('已取消生成，没有创建日程。');
  }

  private cancelDraft(): void {
    if (this.draft && !this.executing) {
      this.service.discard(this.draft.draftId);
      this.draft = undefined;
      this.result = undefined;
      this.operationId = '';
      this.addMessage('已取消草稿，没有新增演示日程。你可以修改输入后重新发送。');
    }
  }

  private async confirm(): Promise<void> {
    if (!this.draft || this.executing) {
      return;
    }
    this.executing = true;
    const selected = this.scenario;
    this.scenario = DemoScenario.Normal;
    try {
      const outcome = await this.service.confirm(this.draft, this.operationId, selected);
      if (!this.alive) {
        return;
      }
      this.result = outcome;
      this.records = this.service.records();
      if (outcome.calendarCreated) {
        this.draft = undefined;
        this.input = '';
      }
    } catch {
      if (this.alive) {
        this.notice('模拟操作失败', '草稿已保留，请使用原操作重试。');
      }
    } finally {
      if (this.alive) {
        this.executing = false;
      }
    }
  }

  private async retryReminder(operationId: string): Promise<void> {
    if (this.executing) {
      return;
    }
    this.executing = true;
    try {
      const outcome = await this.service.retryReminder(operationId);
      if (this.alive) {
        this.result = outcome;
        this.records = this.service.records();
      }
    } catch {
      if (this.alive) {
        this.notice('提醒重试失败', '演示日程仍保留，请稍后再试。');
      }
    } finally {
      if (this.alive) {
        this.executing = false;
      }
    }
  }

  @Builder
  header() {
    Row({ space: 12 }) {
      Text('休').fontSize(22).fontWeight(FontWeight.Bold).fontColor(Theme.accent)
        .width(44).height(44).textAlign(TextAlign.Center).borderRadius(14).backgroundColor(Theme.soft)
      Column({ space: 3 }) {
        Text(this.tab === 0 ? 'Shuvi 休比' : this.tabNames[this.tab])
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
        Text('让想法，成为行动').fontSize(11).fontColor(Theme.muted)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('演示模式').fontSize(11).fontColor(Theme.amber).padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(Theme.warning).borderRadius(8)
    }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 16 })
  }

  @Builder
  assistant() {
    Column({ space: 16 }) {
      if (this.messages.length === 0) {
        Column({ space: 14 }) {
          Text('今天，有什么\n想一起完成？').fontSize(30).fontWeight(FontWeight.Bold)
            .fontColor(Theme.ink).lineHeight(42).width('100%')
          Text('安排日程、整理资料，或记下一闪而过的想法。')
            .fontSize(14).fontColor(Theme.muted).lineHeight(23)
          Button({ type: ButtonType.Normal }) {
            Column({ space: 8 }) {
              Text('从一场会议开始  ↗').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Theme.accent)
              Text('试试创建日程 · 固定样例').fontSize(12).fontColor(Theme.muted)
              Text('10 月 20 日  15:00—16:00').fontSize(14).fontColor(Theme.ink)
            }.alignItems(HorizontalAlign.Start).padding(20).width('100%')
          }.backgroundColor(Theme.soft).borderRadius(18).width('100%').onClick(() => this.useSample())
          Text('可以从工作台了解各项功能。当前不连接真实模型，请使用样例体验。')
            .fontSize(12).fontColor(Theme.muted).lineHeight(20)
        }.alignItems(HorizontalAlign.Start).padding({ top: 28, bottom: 8 }).width('100%')
      }
      ForEach(this.messages, (message: ChatMessage) => {
        Column({ space: 6 }) {
          Text(message.isUser ? '你' : '休比 · 演示').fontSize(11).fontColor(Theme.muted)
          Text(message.text).fontSize(15).fontColor(Theme.ink).lineHeight(24)
            .padding(16).backgroundColor(message.isUser ? Theme.soft : Theme.surface).borderRadius(16)
        }.width('100%').alignItems(message.isUser ? HorizontalAlign.End : HorizontalAlign.Start)
      }, (message: ChatMessage) => message.id)
      if (this.generating) {
        Row({ space: 12 }) {
          LoadingProgress().width(24).height(24).color(Theme.accent)
          Text('正在生成演示草稿…').fontSize(14).fontColor(Theme.muted).layoutWeight(1)
          Button('取消').fontSize(13).backgroundColor(Theme.soft).fontColor(Theme.accent)
            .onClick(() => this.cancelGeneration())
        }.width('100%')
      }
      if (this.draft) {
        this.draftCard(this.draft)
      }
      if (this.result) {
        this.resultCard(this.result)
      }
      if (!this.blocked() && this.requestState === RequestState.Failed) {
        Button('重试生成').fontColor(Theme.accent).backgroundColor(Theme.soft).onClick(() => this.send())
      }
      if (!this.blocked() && this.requestState === RequestState.Clarification) {
        Button('取消澄清，使用完整样例').fontColor(Theme.accent).backgroundColor(Theme.soft)
          .onClick(() => {
            this.requestState = RequestState.Cancelled;
            this.addMessage('已取消本次澄清，请重新发送完整样例。');
            this.useSample();
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
  }

  @Builder
  draftDetails(draft: CalendarDraft) {
    Text(draft.title).fontSize(22).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
    Text(`${draft.startAt.substring(0, 10)}  ${draft.startAt.substring(11, 16)}—${draft.endAt.substring(11, 16)}`)
      .fontSize(15).fontColor(Theme.ink)
    Text(`${draft.timeZone} · 提前 ${draft.reminderMinutesBefore} 分钟提醒`)
      .fontSize(12).fontColor(Theme.muted)
  }

  @Builder
  draftCard(draft: CalendarDraft) {
    Column({ space: 12 }) {
      Text(this.executing ? '正在模拟执行' : '日程草稿 · 尚未创建')
        .fontSize(12).fontColor(Theme.accent).fontWeight(FontWeight.Medium)
      this.draftDetails(draft)
      Divider().color(Theme.line)
      Text('确认后仅添加至演示列表，不会写入系统或实际提醒。').fontSize(12).fontColor(Theme.muted).lineHeight(20)
      Button(this.executing ? '处理中…' : '确认（演示）', { type: ButtonType.Normal })
        .width('100%').constraintSize({ minHeight: 44 }).borderRadius(12)
        .fontColor(Color.White).backgroundColor(Theme.accent).enabled(!this.executing)
        .onClick(() => this.confirm())
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        Button('取消草稿').fontSize(13).fontColor(Theme.muted).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft())
        Button('重新描述').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft())
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20)
      .backgroundColor(Theme.surface).borderRadius(18).border({ width: 1, color: Theme.line })
  }

  @Builder
  resultCard(result: OperationResult) {
    Column({ space: 10 }) {
      Text(result.state === OperationState.Success ? '演示完成' :
        (result.state === OperationState.Partial ? '部分完成 · 提醒待重试' : '本次未完成'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text(result.message).fontSize(13).lineHeight(21).fontColor(Theme.muted)
      Text(`日程：${result.calendarCreated ? '已模拟创建' : '未创建'}\n提醒：${result.reminderRegistered ? '已模拟注册，不会送达' : '未注册'}`)
        .fontSize(12).lineHeight(21).fontColor(Theme.muted)
      if (result.state === OperationState.Partial) {
        Button(this.executing ? '处理中…' : '重试提醒（演示）').fontSize(13)
          .fontColor(Theme.accent).backgroundColor(Theme.soft).enabled(!this.executing)
          .onClick(() => this.retryReminder(result.operationId))
      }
      if (result.calendarCreated && !this.calendarOpen) {
        Button('查看演示日程 →').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .onClick(() => {
            this.changeTab(1);
            this.calendarOpen = true;
          })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
      .backgroundColor(result.state === OperationState.Success ? Theme.soft : Theme.warning).borderRadius(16)
  }

  @Builder
  calendar() {
    Column({ space: 16 }) {
      Button('‹ 返回工作台').fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
        .onClick(() => this.calendarOpen = false)
      Text('演示日程').fontSize(28).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('仅保留本次演示数据，退出重启后重置。').fontSize(12).fontColor(Theme.muted)
      if (this.records.length === 0) {
        Column({ space: 16 }) {
          Text('还没有安排').fontSize(20).fontColor(Theme.ink)
          Text('从一条样例开始，体验日程确认流程。').fontSize(13).fontColor(Theme.muted)
          Button('去助手创建').backgroundColor(Theme.accent).fontColor(Color.White)
            .onClick(() => {
              this.changeTab(0);
              if (!this.blocked()) {
                this.useSample();
              }
            })
        }.width('100%').padding({ top: 48, bottom: 48 })
      }
      ForEach(this.records, (record: OperationResult) => {
        Column({ space: 12 }) {
          this.draftDetails(record.draft)
          this.resultCard(record)
        }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
          .backgroundColor(Theme.surface).borderRadius(18)
      }, (record: OperationResult) => `${record.operationId}-${record.reminderRegistered}`)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 24 })
  }

  @Builder
  composer() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('图片').fontSize(12).fontColor(Theme.muted).backgroundColor(Theme.paper)
          .onClick(() => this.notice('图片输入', '图片选择与理解待接入，本次不会打开相册。'))
        Button('语音').fontSize(12).fontColor(Theme.muted).backgroundColor(Theme.paper)
          .onClick(() => this.notice('语音输入', '语音录制与识别待接入，本次不会开启麦克风。'))
        Blank()
        Button('使用样例').fontSize(12).fontColor(Theme.accent).backgroundColor(Theme.soft)
          .enabled(!this.blocked()).onClick(() => this.useSample())
      }.width('100%')
      Row({ space: 10 }) {
        TextArea({ text: this.input, placeholder: '写下想做的事…', controller: this.inputController })
          .fontSize(15).fontColor(Theme.ink).placeholderColor(Theme.muted).backgroundColor(Theme.paper)
          .height(72).layoutWeight(1).borderRadius(12).enabled(!this.blocked())
          .onChange((value: string) => this.input = value)
        Button('发送', { type: ButtonType.Normal }).fontSize(14).fontColor(Color.White)
          .backgroundColor(Theme.accent).borderRadius(12).width(62).constraintSize({ minHeight: 48 })
          .enabled(!this.blocked() && this.input.trim().length > 0 && this.input.length <= 500)
          .onClick(() => this.send())
      }.width('100%')
      if (this.input.length > 500) {
        Text(`已输入 ${this.input.length} 字，最多 500 字，请缩短后发送。`).fontSize(12).fontColor(Theme.danger)
      }
    }.padding({ left: 20, right: 20, top: 12, bottom: 12 }).width('100%').backgroundColor(Theme.surface)
  }

  @Builder
  scenarioPanel() {
    Column({ space: 10 }) {
      Text('选择下一次演示场景').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('仅模拟界面状态，不改变系统设置。场景执行后恢复正常；提醒重试默认成功。')
        .fontSize(12).fontColor(Theme.muted).lineHeight(20)
      ForEach(DEMO_SCENARIOS, (item: DemoScenario) => {
        Button(item === this.scenario ? `✓ ${item}` : item, { type: ButtonType.Normal })
          .width('100%').constraintSize({ minHeight: 44 }).fontSize(14).borderRadius(10)
          .backgroundColor(item === this.scenario ? Theme.accent : Theme.surface)
          .fontColor(item === this.scenario ? Color.White : Theme.ink)
          .onClick(() => {
            this.scenario = item;
            this.showScenarios = false;
          })
      }, (item: DemoScenario) => item)
      Button('返回页面').fontColor(Theme.accent).backgroundColor(Theme.soft)
        .onClick(() => this.showScenarios = false)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
  }

  @Builder
  navigation() {
    Row() {
      ForEach(this.tabNames, (name: string, index: number) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 4 }) {
            Text(this.tabMarks[index]).fontSize(18).fontWeight(FontWeight.Medium)
              .fontColor(this.tab === index ? Theme.accent : Theme.muted)
              .width(40).height(28).textAlign(TextAlign.Center).borderRadius(8)
              .backgroundColor(this.tab === index ? Theme.soft : Color.Transparent)
            Text(name).fontSize(11).fontColor(this.tab === index ? Theme.accent : Theme.muted)
          }.padding({ top: 8, bottom: 8 })
        }.layoutWeight(1).backgroundColor(Theme.surface).onClick(() => this.changeTab(index))
          .accessibilityText(`${name}${this.tab === index ? '，已选中' : ''}`)
      }, (name: string) => name)
    }.width('100%').backgroundColor(Theme.surface).border({ width: { top: 1 }, color: Theme.line })
  }

  build() {
    Column() {
      this.header()
      Row() {
        Text(this.tab === 2 || this.parseOpen ? '本机真实资料 · 重启后保留 · 未同步' : '演示数据 · 重启后重置')
          .fontSize(11).fontColor(Theme.muted).layoutWeight(1)
        Button(`演示场景：${this.scenario}`, { type: ButtonType.Normal }).fontSize(11)
          .fontColor(Theme.accent).backgroundColor(Color.Transparent).constraintSize({ minHeight: 36 })
          .enabled(this.tab !== 2 && !this.generating && !this.executing)
          .onClick(() => {
            this.inputController.stopEditing();
            this.showScenarios = !this.showScenarios;
            this.scroller.scrollEdge(Edge.Top);
          })
      }.padding({ left: 20, right: 12 }).width('100%')
      Scroll(this.scroller) {
        Column() {
           if (this.platformDiagnosticsOpen) {
             KnowledgePlatformDiagnostics({ onBack: (): void => { this.platformDiagnosticsOpen = false; } })
           } else if (this.noticeTitle.length > 0) {
            Column({ space: 16 }) {
              Text(this.noticeTitle).fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
              Text(this.noticeText).fontSize(15).fontColor(Theme.muted).lineHeight(25)
              Button('知道了，返回').fontColor(Color.White).backgroundColor(Theme.accent)
                .onClick(() => this.noticeTitle = '')
            }.alignItems(HorizontalAlign.Start).padding(24).width('100%')
              .backgroundColor(Theme.surface).borderRadius(18).margin({ top: 16, bottom: 20 })
          } else if (this.showScenarios) {
            this.scenarioPanel()
           } else if (this.pdfSourceOpen) {
              PdfSourceView({ adapter: this.pdfPageAdapter, session: this.sharedKnowledge?.sources, binding: this.pdfSourceBinding, locator: this.pdfSourceLocator, onBack: (): void => { this.pdfSourceOpen = false; } })
           } else if (this.pdfIngestionOpen) {
             if (this.pdfIngestionService !== undefined) {
               PdfIngestionView({ service: this.pdfIngestionService, lifecycle: this.derivedLifecycle, onBack: (): void => { this.pdfIngestionOpen = false; } })
             } else { Text('PDF 准备服务尚未就绪，原件和 ZIP 保留').width('100%') }
           } else if (this.embeddingOpen) {
             if (this.embeddingService !== undefined) {
               EmbeddingSettingsView({ service: this.embeddingService, clearEpoch: this.embeddingClearEpoch, onBack: (): void => { this.closeEmbedding(); } })
             } else {
               Text('本机配置服务尚未就绪或不可用，未发送请求').width('100%')
               Button('返回').onClick((): void => { this.closeEmbedding(); })
             }
           } else if (this.parseOpen) {
             if (this.parseService !== undefined) {
               DocumentParseView({ parseState: this.parseState, service: this.parseService,
                 settingsMode: this.parseSettings, clearEpoch: this.parseState.inputEpoch,
                  onClose: (): void => { this.closeParse(); }, onPreparePdf: (resultId: string): void => { this.preparePdf(resultId); } })
             } else {
               Column({ space: 12 }) {
                 Text(this.parseState.message || '正在打开独立解析准备区…').fontSize(14).width('100%')
                 Button('重试打开解析准备').onClick((): void => { this.openParse(this.parseSettings); })
                 Button('返回').onClick((): void => { this.closeParse(); })
               }.width('100%').padding(20)
             }
           } else if (this.tab === 0) {
            this.assistant()
          } else if (this.tab === 1) {
            if (this.calendarOpen) {
              this.calendar()
            } else {
              WorkbenchPage({ recordCount: this.records.length,
                onCalendar: () => this.calendarOpen = true,
                onNotice: (title: string, message: string) => this.notice(title, message) })
            }
           } else if (this.tab === 2) {
             if (this.knowledgeService !== undefined) {
                 Button('PDF 本机任务').id('r2-pdf-jobs').onClick((): void => { this.openPdfJobs(); })
                 KnowledgeView({ textState: this.knowledgeState, textService: this.knowledgeService, service: this.unifiedSearchService, embedding: this.embeddingService, semantic: this.sharedKnowledge?.workflow,
                  documentsPort: this.pdfDocumentsPort, lifecycle: this.derivedLifecycle,
                  onRetryOpen: (): void => { this.openKnowledge(); },
                  onParsePrepare: (): void => { this.openParse(false); }, onOpenHit: (hit: KnowledgeHit): void => { this.openKnowledgeHit(hit); } })
            } else {
              Column({ space: 12 }) {
                Text(this.knowledgeState.message.length > 0 ? this.knowledgeState.message : '正在打开本机知识库…')
                  .fontSize(15).fontColor(Theme.muted).width('100%')
                Button('重试打开', { type: ButtonType.Normal }).constraintSize({ minHeight: 44 })
                  .onClick((): void => { this.openKnowledge(); })
              }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 20, bottom: 20 })
            }
           } else {
              Button('ROUND2 Native Diagnostics').id('r2-open-diagnostics').onClick((): void => { this.platformDiagnosticsOpen = true; })
              Button('嵌入模型设置').id('r2-open-embedding').onClick((): void => { this.openEmbedding(); })
             ProfilePage({ onNotice: (title: string, message: string) => this.notice(title, message),
               onParseSettings: (): void => { this.openParse(true); }, onEmbeddingSettings: (): void => { this.openEmbedding(); } })
          }
        }.width('100%').constraintSize({ maxWidth: this.tab === 2 ? 1200 : 640 }).padding({ left: 20, right: 20 })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
      if (this.tab === 0 && !this.showScenarios && this.noticeTitle.length === 0) {
        this.composer()
      }
      this.navigation()
    }.width('100%').height('100%').backgroundColor(Theme.paper)
  }
}
