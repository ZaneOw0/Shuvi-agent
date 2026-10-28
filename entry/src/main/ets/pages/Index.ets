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
import { VoiceMessageBubble } from '../components/VoiceMessageBubble';
import { VoiceClip, composeVoiceMessage } from '../services/speech/VoiceAudio';
import { SpeechService } from '../services/speech/SpeechService';
import { SpeechView, SpeechPhase } from '../services/speech/SpeechSession';
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
import { AssistantWelcome, CalendarDraftCard } from '../components/ChatVisuals';
import { AppIcon } from '../components/AppIcon';
import { ModeChip } from '../components/ModeChip';
import { BrandAvatar } from '../components/BrandAvatar';
import { CalendarCapabilityCheck } from '../components/CalendarCapabilityCheck';
import {
  AssistantService, CalendarDraft, ChatMessage, DEMO_SCENARIOS, DemoScenario,
  OperationResult, OperationState, RequestState
} from '../model/AssistantModels';
import { MockAssistantService } from '../mock/MockAssistantService';
import { KnowledgePlatformDiagnostics } from '../knowledge/ui/KnowledgePlatformDiagnostics';
import { PdfPageReferenceState, ResultPageReference } from '../knowledge/domain/PdfLocalModels';
import { KnowledgeCancellation } from '../knowledge/domain/PdfKnowledgeModels';
import { ImageIngestionService } from '../knowledge/application/ImageIngestionService';
import { ImageIngestionView } from '../knowledge/ui/ImageIngestionView';
import { ImageSourceView } from '../knowledge/ui/ImageSourceView';
import { ImageOriginalAdapter } from '../knowledge/infra/ImageOriginalAdapter';
import { ImageProcessingAdapter } from '../knowledge/infra/ImageProcessingAdapter';
import { ImageResultReader } from '../knowledge/infra/ImageResultReader';
import { KnowledgePlatformIdentity } from '../knowledge/infra/KnowledgeAssembly';
import { KnowledgeStorageScope } from '../knowledge/domain/KnowledgeStorageScope';
import { ImageDocument } from '../knowledge/domain/ImageKnowledgeModels';
import { ImageVectorRepository } from '../knowledge/infra/ImageVectorRepository';
import { DocxIngestionService } from '../knowledge/application/DocxIngestionService';
import { DocxIngestionView } from '../knowledge/ui/DocxIngestionView';
import { DocxSourceView } from '../knowledge/ui/DocxSourceView';
import { DocxProcessingAdapter } from '../knowledge/infra/DocxProcessingAdapter';
import { DocxResultReader } from '../knowledge/infra/DocxResultReader';
import { DocxFailure } from '../knowledge/domain/DocxKnowledgeModels';
import { KnowledgeFailure } from '../knowledge/domain/PdfKnowledgeModels';
import { UnifiedKnowledgeView } from '../knowledge/ui/UnifiedKnowledgeView';
import { ParsedDocumentView } from '../knowledge/ui/ParsedDocumentView';
import { ParsedDocumentIngestionService } from '../knowledge/application/ParsedDocumentIngestionService';
import { ParsedDocumentImportAdapter } from '../knowledge/infra/ParsedDocumentImportAdapter';
import { VisionSettingsView } from '../knowledge/ui/VisionSettingsView';
import { ImageKnowledgeView } from '../knowledge/ui/ImageKnowledgeView';
import { KnowledgeMigrationView } from '../knowledge/ui/KnowledgeMigrationView';
import { UnifiedSearchCard } from '../knowledge/domain/UnifiedQueryModels';
import { FloatingAssistantPlacement } from '../model/FloatingAssistantPlacement';
import { SearchResultCard } from '../components/SearchResultCard';
import { MockSearchSession } from '../mock/MockSearchSession';
import { SEARCH_SAMPLE, SEARCH_SCENARIOS, SearchScenario, SearchSource, SearchState, SearchTurn,
  searchIsBusy } from '../model/SearchModels';
import { SourceLinkService } from '../services/SourceLinkService';
import { DEBUG } from 'BuildProfile';
import { RuntimeChatSetup } from '../components/RuntimeChatSetup';
import { RuntimeChatService } from '../services/model/RuntimeChatService';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { RuntimeSearchView } from '../services/model/RuntimeSearchSession';
import { RuntimeSearchPanel } from '../components/RuntimeSearchPanel';
import { RuntimeKnowledgePanel } from '../components/RuntimeKnowledgePanel';
import { searchRuntimeFactory } from '../services/model/SearchRuntimeAssembly';
import { ChatRuntimeFactory } from '../services/model/ChatRuntimeAssembly';
import { NativeAgentRdbOpen } from '../services/model/AgentRdbResources';
import { AssistantView } from '../services/calendar/AssistantRuntimeSession';
import { RuntimeCalendarCard } from '../components/RuntimeCalendarCard';
import { CalendarCreatedCard } from '../components/CalendarCreatedCard';
import { CalendarCreatedSummary } from '../services/calendar/CalendarPresentation';
import { CalendarProbeDraft } from '../services/calendar/CalendarProbeSession';
import { RuntimeKnowledgeService } from '../services/model/RuntimeKnowledgeService';
import { RuntimeKnowledgeView } from '../services/model/RuntimeKnowledgeSession';
import { ShuviRuntimeState } from '../services/model/ShuviRuntimeController';
import { RuntimeAssistantCoordinator } from '../services/model/RuntimeAssistantCoordinator';
import { KnowledgeRagReadiness } from '../knowledge/domain/KnowledgeRuntimePorts';

@Entry
@Component
struct Index {
  @State realChatMode: boolean = false;
  @State runtimeChat: AssistantView = new AssistantView();
  @State runtimeSearch: RuntimeSearchView = new RuntimeSearchView();
  @State runtimeKnowledge: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  @State runtimeSwitching: boolean = false;
  private lastRuntimeReply: number = 0;
  @State migrationOpen: boolean=false;
  @State visionSettingsOpen: boolean=false;
  @State imageKnowledgeOpen: boolean=false;
  @State imageKnowledgeOccurrence: string='';
  @State parsedImportOpen: boolean = false;
  @State developerToolsOpen: boolean = false;
  @State parsedOpen: boolean = false;
  @State knowledgeOpening: boolean = false;
  @State knowledgeMessage: string = '';
  private knowledgeLoad: Promise<void> | undefined = undefined;
  @State knowledgeReady: boolean = false;
  @State parsedDocumentId: string = '';
  @State parsedOpening: boolean = false;
  @State parsedMessage: string = '';
  private parsedService: ParsedDocumentIngestionService | undefined = undefined;
  private parsedImports: ParsedDocumentImportAdapter | undefined = undefined;
  @State tab: number = 0;
  @State calendarOpen: boolean = false;
  @State realCalendarOpen: boolean = false;
  @State input: string = '';
  @State speech: SpeechView = new SpeechView();
  private lastSpeechResult: number = 0;
  @State voiceDraft: VoiceClip | undefined = undefined;
  private voiceText: string = '';
  @State voiceArchive: VoiceClip[] = [];
  @State voiceArchiveOpen: boolean = false;
  @State voicePlayingId: string = '';
  @State voiceMessage: string = '';
  private hiddenVoiceQueries: Set<string> = new Set<string>();
  @State searchVoiceQuery: boolean = false;
  @State knowledgeVoiceQuery: boolean = false;
  @State messages: ChatMessage[] = [];
  @State draft: CalendarDraft | undefined = undefined;
  @State result: OperationResult | undefined = undefined;
  @State records: OperationResult[] = [];
  @State generating: boolean = false;
  @State executing: boolean = false;
  @State requestState: RequestState = RequestState.Unsupported;
  @State scenario: DemoScenario = DemoScenario.Normal;
  @State showScenarios: boolean = false;
  @State knowledgeState: TextViewState = new TextViewState();
  private knowledgeService: TextKnowledgeService | undefined = undefined;
  private knowledgeAssembly: TextKnowledgeAssembly | undefined = undefined;
  @State parseState: DocumentParseViewState = new DocumentParseViewState();
  private parseService: DocumentParseService | undefined = undefined;
  @State parseOpen: boolean = false;
  @State parseSettings: boolean = false;
  @State embeddingOpen: boolean = false;
  @State pdfIngestionOpen: boolean = false;
  private pdfIngestionService: PdfIngestionService | undefined = undefined;
  private unifiedSearchService: KnowledgeSearchService | undefined = undefined;
  @State pdfSourceOpen: boolean = false;
  @State pdfSourceBinding: PdfSourceBinding = new PdfSourceBinding();
  @State pdfSourceLocator: PdfLocator = new PdfLocator();
  private pdfPageAdapter: PdfPageAdapter | undefined = undefined;
  private derivedLifecycle: KnowledgeDerivedLifecycle | undefined = undefined;
  private pdfDocumentsPort: KnowledgeDocumentListPort | undefined = undefined;
  private embeddingService: EmbeddingService | undefined = undefined;
  @State embeddingClearEpoch: number = 0;
  @State platformDiagnosticsOpen: boolean = false;
  @State imageIngestionOpen: boolean = false;
  @State imageSourceOpen: boolean = false;
  @State docxIngestionOpen: boolean = false;
  @State docxSourceOpen: boolean = false;
  private docxIngestionService: DocxIngestionService | undefined = undefined;
  @State docxOpening: boolean = false;
  @State docxEntryMessage: string = '';
  private imageIngestionService: ImageIngestionService | undefined = undefined;
  private sharedKnowledge: KnowledgeAssembly | undefined = undefined;
  private knowledgeListener: () => void=(): void=> { if (this.alive && this.knowledgeAssembly!==undefined) { this.knowledgeState=this.knowledgeAssembly.service.viewState(); } };
  private parseAssembly: DocumentParseAssembly | undefined = undefined;
  @State drawerOpen: boolean = false;
  @State floatingAssistantEnabled: boolean = true;
  @State floatingPlacement: FloatingAssistantPlacement = new FloatingAssistantPlacement();
  @State contentHeight: number = 0;
  @State searchEnabled: boolean = false;
  @State knowledgeEnabled: boolean = false;
  @State ragPreparing: boolean = false;
  @State searchBusy: boolean = false;
  @State searchScenario: SearchScenario = SearchScenario.Normal;
  @State searchTurns: SearchTurn[] = [];
  private searchSession: MockSearchSession = new MockSearchSession();
  private floatingHostWidth: number = 0;
  private floatingHostHeight: number = 0;
  private floatingHeaderHeight: number = 68;
  private service: AssistantService = new MockAssistantService();
  private requestId: string = '';
  private operationId: string = '';
  private alive: boolean = true;
  private scroller: Scroller = new Scroller();
  private inputController: TextAreaController = new TextAreaController();
  private tabNames: string[] = ['助手', '工作台', '知识库', '我的'];
  private tabIcons: Resource[] = [
    $r('app.media.chat_chat'), $r('app.media.chat_grid'), $r('app.media.chat_book'), $r('app.media.chat_user')
  ];

  aboutToAppear(): void {
    this.alive = true;
    this.refreshVoiceArchive();
    SpeechService.playback.attach((id: string, message: string): void => {
      if (this.alive) { this.voicePlayingId = id; this.voiceMessage = message; }
    });
    this.lastSpeechResult = SpeechService.session.snapshot().resultId;
    SpeechService.session.attach((view: SpeechView): void => {
      if (!this.alive) return;
      this.speech = view;
      if (view.clip !== undefined) this.refreshVoiceArchive();
      if (view.phase === SpeechPhase.Ready && view.resultId > this.lastSpeechResult) {
        this.lastSpeechResult = view.resultId;
        // The transcript is private dispatch data; never bind it to any text control or message bubble.
        if (this.tab === 0 && this.input.trim().length === 0) {
          this.voiceDraft = view.clip; this.voiceText = view.text;
        }
        this.refreshVoiceArchive();
      }
    });
    RuntimeSearchService.session.attach((view: RuntimeSearchView): void => {
      if (this.searchVoiceQuery) {
        if (view.query.length > 0) this.hiddenVoiceQueries.add(view.query);
        if (view.preview !== undefined) this.hiddenVoiceQueries.add(view.preview.query);
      }
      this.runtimeSearch = view;
    });
    RuntimeKnowledgeService.session.attach((view: RuntimeKnowledgeView): void => {
      if (this.knowledgeVoiceQuery && view.query.length > 0) this.hiddenVoiceQueries.add(view.query);
      this.runtimeKnowledge = view;
    });
    this.lastRuntimeReply = RuntimeChatService.session.snapshot().replyId;
    RuntimeChatService.session.attach((view: AssistantView): void => {
      const newCalendarCard = view.preview !== undefined && view.preview.requestId !== this.runtimeChat.preview?.requestId;
      this.runtimeChat = view;
      if (this.alive && view.replyId > this.lastRuntimeReply) {
        this.lastRuntimeReply = view.replyId;
        this.addMessage(view.reply, false, view.created);
        this.scroller.scrollEdge(Edge.Bottom);
      }
      if (this.alive && newCalendarCard) this.scroller.scrollEdge(Edge.Bottom);
    });
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    this.alive = false;
    SpeechService.session.detach();
    SpeechService.playback.detach();
    RuntimeChatService.session.detach();
    RuntimeSearchService.session.detach();
    RuntimeKnowledgeService.session.detach();
    this.docxIngestionService?.pause();
    this.service.cancel(this.requestId);
    this.searchSession.cancel();
    this.knowledgeAssembly = undefined;
    this.embeddingService?.pause(); this.closeKnowledgeSession().catch((): void => { this.parsedMessage='会话释放未确认；保留本机持有，可重试释放'; });
  }
  private async closeKnowledgeSession(): Promise<void> {
    this.sharedKnowledge?.unsubscribe(this.knowledgeListener);
    await this.sharedKnowledge?.quiesceUnified();
    await this.docxIngestionService?.close(); await this.sharedKnowledge?.docxSources.close();
    await this.parseAssembly?.close(); await this.sharedKnowledge?.release();
  }

  onPageHide(): void { void SpeechService.session.cancel(); void SpeechService.playback.stop().catch((): void => {}); }

  onBackPress(): boolean {
    if (this.speech.busy) { SpeechService.session.cancel(); return true; }
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.migrationOpen) { this.migrationOpen=false; return true; }
    if (this.visionSettingsOpen) { this.visionSettingsOpen=false; return true; }
    if (this.imageKnowledgeOpen) { this.imageKnowledgeOpen=false; return true; }
    if (this.parsedOpen) { this.parsedOpen = false; return true; }
    if (this.docxSourceOpen) { this.docxSourceOpen = false; this.sharedKnowledge?.docxSources.close().catch((): void => {}); return true; }
    if (this.docxIngestionOpen) { this.docxIngestionOpen = false; this.docxIngestionService?.pause(); return true; }
    if (this.imageSourceOpen) { this.imageSourceOpen = false; this.sharedKnowledge?.imageSources.close().catch((): void => {}); return true; }
    if (this.imageIngestionOpen) { this.imageIngestionOpen = false; this.imageIngestionService?.pause(); return true; }
    if (this.platformDiagnosticsOpen) { this.platformDiagnosticsOpen = false; return true; }
    if (this.pdfSourceOpen) { this.pdfSourceOpen = false; return true; }
    if (this.pdfIngestionOpen) { this.pdfIngestionOpen = false; return true; }
    if (this.embeddingOpen) { this.closeEmbedding(); return true; }
    if (this.parseOpen) { this.closeParse(); return true; }
    if (this.tab === 2 && this.knowledgeService?.back()) { return true; }
    if (this.showScenarios) {
      this.showScenarios = false;
      return true;
    }
    if (this.calendarOpen) {
      this.calendarOpen = false;
      return true;
    }
    if (this.realCalendarOpen) { this.realCalendarOpen = false; return true; }
    if (this.tab !== 0) {
      this.changeTab(0);
      return true;
    }
    return false;
  }

  private notice(title: string, message: string): void {
    this.inputController.stopEditing();
    this.getUIContext().showAlertDialog({
      title: title, message: message,
      primaryButton: { value: '知道了', action: () => {} }
    });
  }

  private changeTab(index: number): void {
    if (index !== this.tab) SpeechService.session.cancel();
    if (index !== this.tab && this.tab === 0) {
      void RuntimeSearchService.session.stop();
      void RuntimeAssistantCoordinator.stop().catch((): void => {});
      this.runtimeChat.clearEpoch++;
    }
    this.floatingPlacement.cancelDrag();
    if (index!==this.tab) { this.migrationOpen=false; }
    if (index!==this.tab) { this.visionSettingsOpen=false; this.imageKnowledgeOpen=false; }
    if (index !== this.tab) { this.parsedOpen = false; }
    if (index !== this.tab) { this.docxIngestionOpen = false; this.docxSourceOpen = false; this.docxIngestionService?.pause(); this.sharedKnowledge?.docxSources.close().catch((): void => {}); }
    if (index !== this.tab) { this.imageIngestionOpen = false; this.imageSourceOpen = false; this.imageIngestionService?.pause(); this.sharedKnowledge?.imageSources.close().catch((): void => {}); }
    if (index !== this.tab) { this.pdfIngestionOpen = false; }
    if (index !== this.tab && this.embeddingOpen) { this.closeEmbedding(); }
    if (index !== this.tab && this.parseOpen) { this.closeParse(); }
    if (index !== this.tab && this.generating) {
      this.cancelGeneration();
    }
    if (index !== this.tab && this.searchBusy) {
      this.cancelSearch();
    }
    this.inputController.stopEditing();
    this.tab = index;
    if (index === 2) { this.openKnowledge(); }
    this.calendarOpen = false;
    this.realCalendarOpen = false;
    this.showScenarios = false;
    this.drawerOpen = false;
    this.scroller.scrollEdge(Edge.Top);
  }

  private async openKnowledge(): Promise<void> {
    const pending: Promise<void> | undefined = this.knowledgeLoad;
    if (pending !== undefined) { return pending; }
    this.knowledgeOpening = true; this.knowledgeMessage = '';
    const operation: Promise<void> = this.loadKnowledge(); this.knowledgeLoad = operation;
    try { await operation; }
    catch (error) { this.knowledgeMessage = '资料库打开未完成，资料保留。原因：' + (error instanceof KnowledgeFailure || error instanceof DocxFailure ? error.category : 'LocalInitializationFailed'); }
    finally { this.knowledgeLoad = undefined; this.knowledgeOpening = false; }
  }
  private async loadKnowledge(): Promise<void> {
    if (this.knowledgeAssembly !== undefined) {
      const shared = this.sharedKnowledge;
      if (shared !== undefined && !shared.unified.ready()) { await shared.retryUnifiedInitialization(); }
      this.knowledgeReady = shared?.unified.ready() ?? false; return;
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) { this.knowledgeMessage = '本机上下文不可用，资料未修改'; return; }
    const shared: KnowledgeAssembly = this.sharedKnowledge ?? KnowledgeAssembly.forContext(context);
    if (this.sharedKnowledge === undefined) { this.sharedKnowledge = shared; try { await shared.acquire(); } catch { this.sharedKnowledge = undefined; this.knowledgeMessage = '用户库打开失败，资料保留'; return; } }
    const assembly: TextKnowledgeAssembly = shared.text;
    shared.subscribe(this.knowledgeListener);
    this.knowledgeAssembly = assembly;
    try {
       this.knowledgeService = assembly.service; this.knowledgeState = assembly.service.viewState();
       assembly.service.attachUnifiedImport(async (): Promise<void> => { await this.openParsed(); await shared.unifiedImports.importText(); });
       this.unifiedSearchService = shared.search;
       this.embeddingService = shared.repository.ready() ? shared.embedding : undefined;
      this.derivedLifecycle = shared.derivedLifecycle; this.pdfDocumentsPort = shared.repository;
      this.knowledgeReady = shared.unified.ready();
      if (!this.knowledgeReady) { this.knowledgeMessage = shared.unifiedMessage || '资料库暂时不可用，请重试打开'; }
    }
    catch {
      this.knowledgeAssembly = undefined; this.knowledgeService = undefined;
      this.knowledgeState = assembly.service.viewState(); this.knowledgeMessage = '用户知识库打开失败，资料保留，可重试';
    }
  }
  private async openKnowledgeHit(hit: KnowledgeHit): Promise<void> {
    if (hit.sourceKind === KnowledgeSourceKind.Docx) {
      const shared = this.sharedKnowledge; if (shared === undefined) { return; } const document = await shared.docx.get(hit.documentId); if (document === undefined) { return; }
      try { await shared.docxSources.open(document,hit); this.docxSourceOpen = true; } catch { this.knowledgeState.message = 'DOCX来源已变化或释放未确认'; } return;
    }
    if (hit.sourceKind === KnowledgeSourceKind.Image) {
      const doc = await this.sharedKnowledge?.images.get(hit.documentId); if (doc === undefined || this.sharedKnowledge === undefined) { return; }
      this.imageSourceOpen = true; try { await this.sharedKnowledge.imageSources.open(doc,hit); } catch { this.knowledgeState.message = '图片来源核验或释放未完成'; } return;
    }
    if (hit.sourceKind === KnowledgeSourceKind.Text) {
      const text: TextHit = new TextHit(); text.documentId = hit.documentId; text.documentVersion = hit.originalVersion; text.originalHash = hit.originalHash;
      text.generation = hit.generation; text.snapshotId = hit.snapshotId; text.chunkId = hit.chunkId; text.text = hit.text; text.ranges = hit.locator.textRanges;
      await this.knowledgeService?.openHit(text); return;
    }
    if (hit.sourceKind !== KnowledgeSourceKind.Pdf) { return; }
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
    this.parseService?.clearInput(); this.parseOpen = false; this.scroller.scrollEdge(Edge.Top);
  }
  private async openImages(): Promise<void> { await this.openParsed(); }
  private async openParsed(importNow: boolean = false): Promise<void> {
    this.parsedImportOpen = importNow;
    if (this.parsedOpening) { return; } this.parsedOpen = true; this.parsedOpening = true; this.parsedMessage = ''; this.scroller.scrollEdge(Edge.Top);
    try {
      await this.openKnowledge(); const shared = this.sharedKnowledge;
      if (shared === undefined) { throw new Error('用户库尚未就绪'); }
      if (!shared.unified.ready()) { await shared.retryUnifiedInitialization(); }
      if (this.parseService === undefined) { await this.openParse(false); this.parseOpen = false; }
      this.parsedService = shared.unifiedIngestion; this.parsedImports = shared.unifiedImports; await this.parsedService.refresh();
      if (this.parseService === undefined) { this.parsedMessage = '解析准备不可用；TXT/MD与已发布内容可用，可重试打开'; }
    } catch (error) { this.parsedMessage = error instanceof Error ? error.message : '统一服务打开失败，资料保留'; }
    finally { this.parsedOpening = false; }
  }
  private async openVisionSettings(): Promise<void> { await this.openParsed(); this.parsedOpen=false; this.visionSettingsOpen=true; }
  private async openImageKnowledge(): Promise<void> { await this.openParsed(); this.parsedOpen=false; this.imageKnowledgeOpen=true; }
  private async openUnifiedCard(card: UnifiedSearchCard): Promise<void> {
    if (!card.current) { return; }
    try { if (card.kind==='Image') { this.imageKnowledgeOccurrence=card.occurrenceId; const images=this.sharedKnowledge?.imageKnowledge; if (images===undefined) { throw new Error('ImageSourceUnavailable'); } this.imageKnowledgeOccurrence=await images.currentOccurrence(card.imageHash,card.effectiveId,this.imageKnowledgeOccurrence); await this.openImageKnowledge(); }
      else { this.parsedDocumentId = card.documentKey; await this.openParsed(); }
    } catch { this.knowledgeState.message='统一来源已变或不可读，保留查询证据'; }
  }
  private async openMigration(): Promise<void> { await this.openParsed(); this.parsedOpen=false; this.migrationOpen=true; }
  private async openLegacyImages(): Promise<void> {
    await this.openKnowledge(); if (this.parseService === undefined) { await this.openParse(false); this.parseOpen = false; }
    const context = this.getUIContext().getHostContext(); const shared = this.sharedKnowledge;
    if (context === undefined || shared === undefined || this.parseService === undefined || !shared.images.ready()) { this.knowledgeState.message = '图片准备区不可用，原件未修改'; return; }
    if (this.imageIngestionService === undefined) { this.imageIngestionService = new ImageIngestionService(this.parseService,shared.images,new ImageOriginalAdapter(context.filesDir),new ImageProcessingAdapter(),new KnowledgePlatformIdentity(),KnowledgeStorageScope.production()); const metadata = shared.vectorMetadata; if (metadata instanceof ImageVectorRepository) { this.imageIngestionService.attachVectorCleanup(async (id: string): Promise<void> => { const cleanup: Promise<void> = metadata.cleanupDeleted(id,shared.vectors); await cleanup; }); } await this.imageIngestionService.initialize(); }
    this.imageIngestionService.attachResults(new ImageResultReader(context.filesDir,this.parseService));
    this.imageIngestionService.attachVectorSync(async (id: string): Promise<void> => { await shared.workflow.sync(id); });
    await this.imageIngestionService.adoptPrepared();
    this.imageIngestionOpen = true;
  }
  private async openDocx(): Promise<void> { await this.openParsed(); }
  private async openLegacyDocx(): Promise<void> {
    if (this.docxOpening) { return; }
    this.docxIngestionOpen = true; this.docxOpening = true; this.docxEntryMessage = '正在打开 DOCX 解析与入库…';
    this.imageIngestionOpen = false; this.docxSourceOpen = false; this.scroller.scrollEdge(Edge.Top);
    try {
      await this.openKnowledge();
      if (this.parseService === undefined) { await this.openParse(false); this.parseOpen = false; }
      const shared = this.sharedKnowledge; const context = this.getUIContext().getHostContext(); const parse = this.parseService;
      if (shared === undefined || context === undefined || parse === undefined) { this.docxEntryMessage = '解析准备打开未完成。'+(this.parseState.message || this.knowledgeState.message || '本机服务暂不可用')+'；原件和已有资料保留，可重试。'; return; }
      await shared.ensureDocxReady();
      this.embeddingService = shared.embedding;
      if (this.docxIngestionService === undefined) {
        const identity: KnowledgePlatformIdentity = new KnowledgePlatformIdentity(); const service: DocxIngestionService = new DocxIngestionService(parse,shared.docx);
        service.attachProcessing(new DocxProcessingAdapter(`${context.filesDir}/knowledge_parse_v1`,identity,new DocxResultReader(`${context.filesDir}/knowledge_parse_v1`,parse,identity)),identity);
        service.attachManagement((id: string) => shared.docx.latestOriginal(id),(id: string) => shared.docx.abandon(id),(): Promise<void> => shared.cleanupDocx(parse),(id: string) => shared.docxVectors.cleanupDeleted(id,shared.vectors),(id: string) => shared.workflow.sync(id));
        this.docxIngestionService = service;
      }
      await this.docxIngestionService.adoptPrepared(); this.docxEntryMessage = '';
    } catch (error) {
      const reason: string = error instanceof DocxFailure || error instanceof KnowledgeFailure ? `${error.category} · ${error.stage}` : 'LocalDocxPreparationFailed';
      this.docxEntryMessage = 'DOCX 准备未完成：'+reason+'。原件和已有资料保留，可重试。';
    } finally { this.docxOpening = false; }
  }
  private openDocxSearch(): void {
    this.docxIngestionService?.pause(); this.embeddingService?.pause(); this.docxIngestionOpen = false;
    this.docxSourceOpen = false; this.parseOpen = false; this.embeddingOpen = false; this.tab = 2;
    this.scroller.scrollEdge(Edge.Top);
  }
  private async openDocxSource(id: string): Promise<void> { const shared = this.sharedKnowledge; if (shared === undefined) { return; } const document = await shared.docx.get(id); if (document === undefined) { return; } try { await shared.docxSources.open(document); this.docxSourceOpen = true; } catch { this.knowledgeState.message = 'DOCX原生来源不可用'; } }
  private async openImageOriginal(document: ImageDocument): Promise<void> {
    if (this.sharedKnowledge === undefined) { return; } this.imageSourceOpen = true;
    try { await this.sharedKnowledge.imageSources.open(document); } catch { this.knowledgeState.message = '图片来源核验或释放未完成'; }
  }
  private async prepareImage(resultId: string): Promise<void> {
    await this.consumeParsed(resultId);
  }
  private async consumeParsed(id: string): Promise<void> {
    this.closeParse(); await this.openParsed();
    try { if (this.parseService !== undefined && this.parsedImports !== undefined) { await this.parsedImports.consume(this.parseService,id); } }
    catch (error) { this.parsedMessage = error instanceof Error ? error.message : '统一产物未完成，原件/ZIP保留'; }
  }
  private closeEmbedding(): void { this.embeddingClearEpoch++; this.embeddingService?.clearInput(); this.embeddingOpen = false; this.scroller.scrollEdge(Edge.Top); }
  private async openEmbedding(): Promise<void> {
    this.embeddingOpen = true; this.scroller.scrollEdge(Edge.Top);
    if (this.sharedKnowledge !== undefined) { this.embeddingService = this.sharedKnowledge.repository.ready() ? this.sharedKnowledge.embedding : undefined; return; }
    const context = this.getUIContext().getHostContext(); if (context === undefined) { return; }
    const assembly: KnowledgeAssembly = KnowledgeAssembly.forContext(context); this.sharedKnowledge = assembly;
    try { await assembly.acquire(); this.embeddingService = assembly.repository.ready() ? assembly.embedding : undefined; }
    catch { this.sharedKnowledge = undefined; this.embeddingService = undefined; }
  }
  private async preparePdf(resultId: string): Promise<void> {
    await this.consumeParsed(resultId);
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

  private resizeFloatingHost(width: number, height: number): void {
    this.floatingHostWidth = width;
    this.floatingHostHeight = height;
    this.floatingPlacement.resize(width, height, this.floatingHeaderHeight);
  }

  private addMessage(text: string, isUser: boolean = false, calendar?: CalendarCreatedSummary): void {
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: isUser, text: text, calendar: calendar };
    this.messages = this.messages.concat([message]);
  }
  private openCalendarRecords(): void {
    // Leaving the assistant tab ends the chat session as before; the workbench lists the verified native records.
    this.changeTab(1);
    this.realCalendarOpen = true;
  }

  private async startRuntimeChat(key: Uint8Array): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined || !DEBUG || !this.realChatMode || this.searchEnabled || this.knowledgeEnabled || this.tab !== 0) return;
      // The coordinator composes the calendar-capable assistant session and the PERSONAL RAG answer session.
      await RuntimeAssistantCoordinator.start(context, DEBUG, key);
    } finally { key.fill(0); }
  }


  private async switchChatMode(): Promise<void> {
    if (this.blocked()) return;
    this.runtimeSwitching = true;
    try {
      await RuntimeSearchService.session.stop(); await RuntimeAssistantCoordinator.stop();
      if (!this.alive || this.tab !== 0) return;
      this.resetConversation(); this.searchEnabled = false; this.knowledgeEnabled = false; this.realChatMode = !this.realChatMode;
    } catch { this.notice('会话尚未关闭', '请重启应用后排查资源释放。'); }
    finally { this.runtimeSwitching = false; }
  }

  private async startRuntimeSearch(key: Uint8Array): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined || !DEBUG || !this.realChatMode || !this.searchEnabled || this.tab !== 0) return;
      await RuntimeAssistantCoordinator.stop();
      if (!this.alive || this.tab !== 0 || !this.searchEnabled || !this.realChatMode) return;
      await RuntimeSearchService.session.start(searchRuntimeFactory(context, DEBUG),
        new ChatRuntimeFactory(new NativeAgentRdbOpen(context), DEBUG, RuntimeSearchService.session.context), key);
    } finally { key.fill(0); }
  }

  private async toggleSearch(): Promise<void> {
    if (this.blocked()) return;
    if (!this.realChatMode) { this.searchEnabled = !this.searchEnabled; return; }
    this.runtimeSwitching = true;
    try {
      await RuntimeSearchService.session.stop(); await RuntimeAssistantCoordinator.stop();
      if (this.alive && this.tab === 0) { this.searchEnabled = !this.searchEnabled; this.knowledgeEnabled = false; }
    } catch { this.notice('会话尚未关闭', '请重启应用后排查资源释放。'); }
    finally { this.runtimeSwitching = false; }
  }

  private async toggleKnowledge(): Promise<void> {
    if (this.blocked()) return;
    if (!this.realChatMode) { this.notice('请先打开真实功能', '知识库 RAG 不会回退为演示数据。请先切换到真实功能模式。'); return; }
    this.runtimeSwitching = true;
    try {
      if (this.knowledgeEnabled) {
        await RuntimeAssistantCoordinator.disableKnowledge();
        if (this.alive && this.tab === 0) { this.knowledgeEnabled = false; }
        return;
      }
      if (this.searchEnabled || this.runtimeChat.lifecycle !== ShuviRuntimeState.READY) {
        this.notice('请先启用普通对话', '请先使用同一份 DeepSeek Key 启用普通对话，再开启知识库 RAG。'); return;
      }
      this.ragPreparing = true;
      const readiness: KnowledgeRagReadiness = await RuntimeAssistantCoordinator.enableKnowledge();
      if (!readiness.ready) { this.notice('知识库 RAG 尚不可用', readiness.message); return; }
      if (this.alive && this.tab === 0) { this.knowledgeEnabled = true; this.searchEnabled = false; }
    } catch { this.notice('会话尚未关闭', '请重启应用后排查资源释放。'); }
    finally { this.runtimeSwitching = false; this.ragPreparing = false; }
  }

  @Builder
  private runtimeChatControls() {
    Column({ space: 10 }) {
      Button(this.realChatMode ? '清空对话并切回演示' : '清空对话并打开真实功能')
        .fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 })
        .enabled(!this.blocked() && this.runtimeChat.lifecycle !== ShuviRuntimeState.STARTING &&
          this.runtimeChat.lifecycle !== ShuviRuntimeState.STOPPING)
        .id('runtime-chat-mode').onClick((): void => { void this.switchChatMode(); })
      if (this.realChatMode && this.knowledgeEnabled) {
        RuntimeKnowledgePanel({ view: this.runtimeKnowledge, hideQuery: this.knowledgeVoiceQuery || this.hiddenVoiceQueries.has(this.runtimeKnowledge.query), onDisable: (): void => { void this.toggleKnowledge(); } })
      } else if (this.realChatMode && this.searchEnabled) {
        RuntimeSearchPanel({ view: this.runtimeSearch, hideQuery: this.searchVoiceQuery || this.hiddenVoiceQueries.has(this.runtimeSearch.query) ||
          this.hiddenVoiceQueries.has(this.runtimeSearch.preview?.query ?? ''), onStart: (key: Uint8Array): void => {
          void this.startRuntimeSearch(key).catch((): void => {});
        } })
      } else if (this.realChatMode) {
        if (this.runtimeChat.lifecycle === ShuviRuntimeState.READY || this.runtimeChat.lifecycle === ShuviRuntimeState.STARTING) {
          // Enabled session collapses to one status row instead of a full card.
          Row({ space: 8 }) {
            Circle({ width: 8, height: 8 }).fill(this.runtimeChat.lifecycle === ShuviRuntimeState.READY ? Theme.ok : Theme.muted)
            Text(this.runtimeChat.lifecycle === ShuviRuntimeState.READY ?
              `已启用 · 剩 ${Math.max(0, this.runtimeChat.maxRequests - this.runtimeChat.requestCount)}/${this.runtimeChat.maxRequests} 轮` : '正在启用…')
              .fontSize(13).fontColor(Theme.ink).layoutWeight(1).id('runtime-chat-status')
            Button('停止').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(18)
              .constraintSize({ minHeight: Theme.controlHeight, minWidth: 64 }).id('runtime-chat-stop')
              .accessibilityText('停止真实对话，清除本次会话凭据')
              .onClick((): void => { void RuntimeAssistantCoordinator.stop().catch((): void => {}); })
          }.width('100%').padding({ left: 14, right: 6, top: 4, bottom: 4 }).backgroundColor(Theme.surface)
            .borderRadius(22).border({ width: 1, color: Theme.line })
          if (this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
            Text('本次启用的对话轮数已用完；点“停止”后可重新启用。').fontSize(Theme.noteSize).fontColor(Theme.amber).width('100%')
          }
        } else {
          if (this.runtimeChat.lifecycle !== ShuviRuntimeState.IDLE && this.runtimeChat.lifecycle !== ShuviRuntimeState.STOPPED) {
            Text(this.runtimeChat.message).fontSize(13).fontColor(Theme.muted).width('100%').id('runtime-chat-message')
          }
          if (this.runtimeChat.lifecycle === ShuviRuntimeState.IDLE || this.runtimeChat.lifecycle === ShuviRuntimeState.STOPPED ||
            this.runtimeChat.lifecycle === ShuviRuntimeState.FAILED) {
            RuntimeChatSetup({ clearEpoch: this.runtimeChat.clearEpoch, onStart: (key: Uint8Array): void => {
              void this.startRuntimeChat(key).catch((): void => {});
            } })
          }
        }
      }
    }.width('100%').padding({ bottom: 12 })
  }

  private blocked(): boolean {
    return this.speech.busy || this.generating || this.executing || this.searchBusy || this.draft !== undefined || this.runtimeChat.busy ||
      this.runtimeSearch.busy || this.runtimeSwitching || this.runtimeSearch.lifecycle === ShuviRuntimeState.STARTING ||
      this.runtimeSearch.lifecycle === ShuviRuntimeState.STOPPING || this.runtimeKnowledge.busy ||
      this.runtimeKnowledge.lifecycle === ShuviRuntimeState.STARTING || this.runtimeKnowledge.lifecycle === ShuviRuntimeState.STOPPING;
  }

  private useSample(): void {
    if (this.blocked()) {
      return;
    }
    this.input = this.sampleText();
    this.scroller.scrollEdge(Edge.Bottom);
  }
  private sampleText(): string {
    return this.realChatMode ? (this.knowledgeEnabled ? '知识库中的 Agent Runtime 是如何设计的？' :
      (this.searchEnabled ? 'HarmonyOS ArkUI 官方开发文档' : '明天下午 3 点到 4 点开项目评审会，提前 10 分钟提醒')) :
      (this.searchEnabled ? SEARCH_SAMPLE : this.service.sampleText);
  }
  private headerConnected(): boolean {
    return this.realChatMode && (this.runtimeChat.lifecycle === ShuviRuntimeState.READY ||
      this.runtimeSearch.lifecycle === ShuviRuntimeState.READY || this.runtimeKnowledge.lifecycle === ShuviRuntimeState.READY);
  }
  private composerHint(): string {
    return this.realChatMode ? (this.knowledgeEnabled ? '回答依据：我的知识库 · 来源可核对' :
      (this.searchEnabled ? '联网搜索 · 每次搜索前会征求你的同意' : '可提问、安排日程或让我写文档；日程创建前会让你确认')) :
      (this.searchEnabled ? '演示模式 · 固定样例，未联网' : '演示模式 · 数据仅本次有效');
  }

  private async send(): Promise<void> {
    if (this.voiceDraft !== undefined) { await this.sendVoice(); return; }
    if (this.blocked() || this.input.trim().length === 0 || this.input.length > 500) {
      return;
    }
    this.searchVoiceQuery = false; this.knowledgeVoiceQuery = false;
    if (this.realChatMode) {
      if (this.knowledgeEnabled) {
        if (this.runtimeKnowledge.lifecycle !== ShuviRuntimeState.READY) {
          this.notice('知识库问答尚未就绪', this.runtimeKnowledge.message); return;
        }
        const query: string = this.input.trim(); this.input = '';
        void RuntimeKnowledgeService.session.send(query).then((sent: boolean): void => {
          if (!sent && this.alive && this.input.length === 0) { this.input = query; }
        });
        return;
      }
      if (this.searchEnabled) {
        if (this.runtimeSearch.lifecycle !== ShuviRuntimeState.READY || !this.runtimeSearch.allowance) {
          this.notice('真实搜索尚不可用', this.runtimeSearch.message); return;
        }
        const query = this.input.trim(); this.input = ''; void RuntimeSearchService.session.send(query); return;
      }
      if (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY) {
        this.notice('真实对话尚未就绪', '请先启用会话。本次未发送，也不会回退为演示回答。'); return;
      }
      if (this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
        this.notice('本次请求次数已用完', '请停止真实对话后重新启用。本次未发送，内容保留在输入框。'); return;
      }
      const message = this.input; this.input = '';
      this.inputController.stopEditing(); this.addMessage(message, true);
      await RuntimeChatService.session.send(message); return;
    }
    if (this.searchEnabled) {
      await this.sendSearch();
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

  private cancelDraft(rephrase: boolean = false): void {
    if (this.draft && !this.executing) {
      this.service.discard(this.draft.draftId);
      this.draft = undefined;
      this.result = undefined;
      this.operationId = '';
      if (!rephrase) {
        this.input = '';
      }
      this.addMessage('已取消草稿，没有新增演示日程。你可以修改输入后重新发送。');
    }
  }

  private openScenarios(): void {
    SpeechService.session.cancel();
    if (this.realChatMode) { this.notice('当前为真实对话', '切换为演示模式后可选择演示场景。'); return; }
    if (this.generating || this.executing || this.searchBusy) {
      return;
    }
    this.drawerOpen = false;
    this.inputController.stopEditing();
    this.showScenarios = !this.showScenarios;
    this.scroller.scrollEdge(Edge.Top);
  }

  private newConversation(): void {
    if (this.speech.busy) SpeechService.session.cancel();
    if (this.blocked()) {
      return;
    }
    this.inputController.stopEditing();
    if (this.messages.length === 0 && this.input.length === 0) {
      this.resetConversation();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '开始新对话？',
      message: '将清空当前对话和未发送文字；已创建的日程和操作记录会保留。',
      primaryButton: { value: '继续当前对话', action: () => {} },
      secondaryButton: { value: '开始新对话', action: () => this.resetConversation() }
    });
  }

  private resetConversation(): void {
    SpeechService.session.cancel();
    RuntimeSearchService.session.clearConversation();
    RuntimeKnowledgeService.session.clearConversation();
    if (this.blocked()) {
      return;
    }
    RuntimeChatService.session.clearConversation();
    this.service.cancel(this.requestId);
    this.searchSession.cancel();
    this.searchTurns = [];
    this.searchBusy = false;
    this.searchScenario = SearchScenario.Normal;
    this.requestId = '';
    this.operationId = '';
    this.messages = [];
    this.input = ''; this.voiceDraft = undefined; this.voiceText = '';
    this.searchVoiceQuery = false; this.knowledgeVoiceQuery = false;
    this.result = undefined;
    this.requestState = RequestState.Unsupported;
    this.scenario = DemoScenario.Normal;
    this.changeTab(0);
  }

  private updateSearch(turn: SearchTurn): void {
    if (!this.alive) {
      return;
    }
    const exists = this.searchTurns.some((item: SearchTurn) => item.id === turn.id);
    this.searchTurns = exists ? this.searchTurns.map((item: SearchTurn) => item.id === turn.id ? turn : item) :
      this.searchTurns.concat([turn]);
    if (!exists) {
      const message: ChatMessage = { id: this.service.nextId('message'), isUser: false,
        text: '联网搜索 · 固定样例演示', searchId: turn.id };
      this.messages = this.messages.concat([message]);
    }
    this.searchBusy = searchIsBusy(turn.state);
  }

  private async sendSearch(): Promise<void> {
    const query = this.input.trim();
    const scenario = this.searchScenario;
    this.inputController.stopEditing();
    this.addMessage(query, true);
    this.input = '';
    this.result = undefined;
    this.requestState = RequestState.Unsupported;
    this.searchScenario = SearchScenario.Normal;
    const pending = this.searchSession.start(query, scenario, (turn: SearchTurn) => this.updateSearch(turn));
    this.scroller.scrollEdge(Edge.Bottom);
    await pending;
  }

  private cancelSearch(): void {
    const turn = this.searchSession.cancel();
    if (turn) {
      this.updateSearch(turn);
    }
  }

  private retrySearch(turn: SearchTurn): void {
    if (this.blocked()) {
      return;
    }
    this.searchEnabled = true;
    this.input = turn.query;
    this.searchScenario = SearchScenario.Normal;
    this.send();
  }

  private editSearch(turn: SearchTurn): void {
    if (this.blocked()) {
      return;
    }
    this.searchEnabled = true;
    this.input = turn.state === SearchState.Unsupported ? SEARCH_SAMPLE : turn.query;
  }

  private async retrySearchAnswer(turn: SearchTurn): Promise<void> {
    if (!this.blocked()) {
      await this.searchSession.retryAnswer(turn, (updated: SearchTurn) => this.updateSearch(updated));
    }
  }

  private async openSource(source: SearchSource): Promise<void> {
    // 跳出应用前结束演示任务，已取得的来源继续保留。
    if (this.searchBusy) {
      this.cancelSearch();
    }
    try {
      await SourceLinkService.open(source.url);
    } catch {
      if (this.alive) {
        this.notice('原文未能打开', `请检查设备是否有可用浏览器或打开方式。\n${source.url}`);
      }
    }
  }

  private showCitation(source: SearchSource): void {
    this.getUIContext().showAlertDialog({
      title: `来源 [${source.number}] ${source.title}`,
      message: `${source.snippet}\n\n${source.url}`,
      primaryButton: { value: '打开原文', action: () => { this.openSource(source); } },
      secondaryButton: { value: '返回回答', action: () => {} }
    });
  }

  private attachments(): void {
    this.inputController.stopEditing();
    this.getUIContext().showAlertDialog({
      title: '添加内容', message: '图片与文件输入待接入，本次不会读取设备内容。',
      primaryButton: { value: '图片 · 待接入', action: () => this.notice('图片输入待接入', '本次不会打开相册或读取图片。') },
      secondaryButton: { value: '文件 · 待接入', action: () => this.notice('文件输入待接入', '本次不会打开文件选择器或读取文件。') }
    });
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
    Stack() {
      Column({ space: 2 }) {
        if (this.tab !== 0) {
          Text(this.tabNames[this.tab]).fontSize(14).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        }
        if (this.tab === 0 && !(this.parsedOpen || this.parseOpen || this.embeddingOpen || this.visionSettingsOpen || this.imageKnowledgeOpen)) {
          Row({ space: 6 }) {
            Circle({ width: 7, height: 7 }).fill(this.headerConnected() ? Theme.ok : Theme.line)
            Text(this.realChatMode ? (this.headerConnected() ? '休比 · 已连接' : '休比 · 未启用') : '休比 · 演示')
              .fontSize(12).fontColor(Theme.ink)
          }.padding({ left: 10, right: 12, top: 5, bottom: 5 }).backgroundColor(Theme.soft).borderRadius(20)
            .id('chat-header-status')
        } else {
          Text(this.tab === 2 || this.parsedOpen || this.parseOpen || this.embeddingOpen || this.visionSettingsOpen || this.imageKnowledgeOpen ? '本机资料 · 未同步' :
            (this.tab === 1 && this.realCalendarOpen ? '系统日历' : '演示模式')).fontSize(11).fontColor(Theme.muted)
            .padding({ left: 9, right: 9, top: 5, bottom: 5 }).backgroundColor(Theme.soft).borderRadius(20)
        }
      }.width('34%')
      Row() {
        Button({ type: ButtonType.Circle }) {
          AppIcon({ source: $r('app.media.chat_menu'), size: 24 })
        }.width(44).height(44).backgroundColor(Theme.surface)
          .shadow({ radius: 16, color: Theme.shadow, offsetY: 3 })
          .accessibilityText('打开导航菜单').id('chat-menu')
          .onClick(() => {
            this.inputController.stopEditing();
            this.drawerOpen = true;
          })
        Blank()
        if (this.tab === 0) {
        Row() {
          Button({ type: ButtonType.Circle }) {
            AppIcon({ source: $r('app.media.chat_sliders') })
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(`演示场景设置，当前${this.searchEnabled ? this.searchScenario : this.scenario}`).id('chat-scenarios')
            .enabled(!this.generating && !this.executing && !this.searchBusy).onClick(() => this.openScenarios())
          Button({ type: ButtonType.Circle }) {
            AppIcon({ source: $r('app.media.chat_newchat') })
          }.width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(this.speech.busy ? '取消语音并开始新对话' : (this.blocked() ? '开始新对话，请先处理当前任务' : '开始新对话'))
            .id('chat-new').enabled(!this.blocked() || this.speech.busy).opacity(this.blocked() && !this.speech.busy ? 0.4 : 1)
            .onClick(() => this.newConversation())
        }.padding({ left: 3, right: 3 }).borderRadius(28).backgroundColor(Theme.surface)
          .shadow({ radius: 16, color: Theme.shadow, offsetY: 3 })
        }
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 68 }).padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .onAreaChange((_oldArea: Area, area: Area) => {
        this.floatingHeaderHeight = Number(area.height);
        this.floatingPlacement.resize(this.floatingHostWidth, this.floatingHostHeight, this.floatingHeaderHeight);
      })
  }

  @Builder
  assistant() {
    Column({ space: 16 }) {
      ForEach(this.messages, (message: ChatMessage) => {
        if (message.isUser) {
          Row() {
            Blank().width('8%')
            if (message.voice !== undefined) {
              Column({ space: 6 }) {
                VoiceMessageBubble({ recording: message.voice, playingId: this.voicePlayingId,
                  onPlay: (clip: VoiceClip): void => this.playVoice(clip) })
                if (message.text.length > 0) {
                  Text(message.text).fontSize(15).fontColor(Theme.ink).padding(15)
                    .backgroundColor(Theme.bubble).borderRadius(20).width('100%')
                    .accessibilityText(`你补充的文字：${message.text}`)
                }
              }.constraintSize({ maxWidth: '92%' }).alignItems(HorizontalAlign.End)
            } else {
              Text(message.text).fontSize(15).fontColor(Theme.ink).padding(15)
                .backgroundColor(Theme.bubble).borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
                .constraintSize({ maxWidth: '92%' }).accessibilityText(`你：${message.text}`)
            }
          }.width('100%').justifyContent(FlexAlign.End)
        } else if (message.searchId !== undefined) {
          Column({ space: 12 }) {
            Row({ space: 8 }) {
              BrandAvatar({ size: 28 })
              Text(message.text).fontSize(11).fontColor(Theme.muted).layoutWeight(1)
            }.width('100%')
            ForEach(this.searchTurns, (turn: SearchTurn, index: number) => {
              if (turn.id === message.searchId) {
                // 轮次 ID 保持稳定；直接绑定状态数组，避免复用卡片时捕获旧 turn。
                SearchResultCard({ turn: this.searchTurns[index], actionsEnabled: !this.blocked(),
                  onCancel: () => this.cancelSearch(),
                  onRetry: (item: SearchTurn) => this.retrySearch(item),
                  onRetryAnswer: (item: SearchTurn) => this.retrySearchAnswer(item),
                  onEdit: (item: SearchTurn) => this.editSearch(item),
                  onOpen: (source: SearchSource) => this.openSource(source),
                  onCitation: (source: SearchSource) => this.showCitation(source) })
              }
            }, (turn: SearchTurn, _index: number) => turn.id)
          }.width('100%')
        } else if (message.calendar !== undefined) {
          Row({ space: 8 }) {
            BrandAvatar({ size: 28 })
            Column() {
              CalendarCreatedCard({ summary: message.calendar as CalendarCreatedSummary,
                onOpen: (): void => this.openCalendarRecords() })
            }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top)
        } else {
          Row({ space: 8 }) {
            BrandAvatar({ size: 28 })
            Column() {
              Text(message.text).fontSize(Theme.bodySize).fontColor(Theme.ink).lineHeight(22)
                .padding({ left: 14, right: 14, top: 10, bottom: 10 }).backgroundColor(Theme.surface)
                .borderRadius({ topLeft: 6, topRight: 20, bottomLeft: 20, bottomRight: 20 })
                .border({ width: 1, color: Theme.line }).accessibilityText(`休比：${message.text}`)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ right: '8%' })
          }.width('100%').alignItems(VerticalAlign.Top)
        }
      }, (message: ChatMessage) => message.id)
      if (this.generating) {
        Row({ space: 10 }) {
          LoadingProgress().width(22).height(22).color(Theme.accent)
          Text('正在生成演示草稿…').fontSize(14).fontColor(Theme.muted).layoutWeight(1)
          Button('取消').fontSize(13).constraintSize({ minHeight: 44 })
            .backgroundColor(Theme.soft).fontColor(Theme.accent).onClick(() => this.cancelGeneration())
        }.width('100%')
      }
      if (this.runtimeChat.preview !== undefined) {
        RuntimeCalendarCard({ preview: this.runtimeChat.preview, writing: this.runtimeChat.calendarStage !== 'authorization',
          pendingLabel: this.runtimeChat.message,
          onConfirm: (): void => { void RuntimeChatService.session.decide(true).catch((): void => {}); },
          onResubmit: (draft: CalendarProbeDraft): Promise<string> => RuntimeChatService.session.resubmit(draft),
          onCancel: (): void => { void RuntimeChatService.session.decide(false).catch((): void => {}); } })
      }
      if (this.runtimeChat.busy && this.runtimeChat.calendarStage !== 'authorization') {
        Row({ space: 10 }) {
          LoadingProgress().width(22).height(22).color(Theme.accent)
          Text(this.runtimeChat.message).fontSize(14).fontColor(Theme.muted).layoutWeight(1)
          Button(this.runtimeChat.calendarStage === 'idle' ? '取消回答' : '停止等待').constraintSize({ minHeight: 44 }).fontColor(Theme.accent).backgroundColor(Theme.soft)
            .id('runtime-chat-cancel').onClick((): void => { void RuntimeChatService.session.cancel().catch((): void => {}); })
        }.width('100%')
      }
      if (this.result && !this.result.calendarCreated) {
        this.resultCard(this.result)
      }
      if (this.draft) {
        CalendarDraftCard({ draft: this.draft, executing: this.executing,
          failed: this.result !== undefined && !this.result.calendarCreated })
      }
      if (this.result && this.result.calendarCreated) {
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
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 14, bottom: 20 })
  }

  @Builder
  draftDetails(draft: CalendarDraft) {
    Text(draft.title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
    Text(`${draft.startAt.substring(0, 10)}  ${draft.startAt.substring(11, 16)}—${draft.endAt.substring(11, 16)}`)
      .fontSize(15).fontColor(Theme.ink)
    Text(`${draft.timeZone} · 提前 ${draft.reminderMinutesBefore} 分钟提醒`)
      .fontSize(12).fontColor(Theme.muted)
  }

  @Builder
  confirmationDock() {
    Column({ space: 8 }) {
      Text(this.executing ? '正在模拟执行，请稍候' : '请先确认或取消，再继续对话')
        .fontSize(11).fontColor(Theme.muted).textAlign(TextAlign.Center).width('100%')
      Button(this.executing ? '处理中…' : (this.result ? '重试创建（演示）' : '确认（演示）'), { type: ButtonType.Normal })
        .width('100%').constraintSize({ minHeight: 48 }).padding(12).borderRadius(16)
        .fontSize(15).fontColor(Color.White).backgroundColor(Theme.accent).enabled(!this.executing)
        .id('chat-confirm').onClick(() => this.confirm())
      Row() {
        Button('取消草稿', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.muted)
          .layoutWeight(1).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft())
        Divider().vertical(true).height(14).color(Theme.line)
        Button('重新描述', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.accent)
          .layoutWeight(1).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent)
          .enabled(!this.executing).onClick(() => this.cancelDraft(true))
      }.width('100%')
    }.width('100%').padding({ left: 20, right: 20, top: 12, bottom: 8 })
      .backgroundColor(Theme.surface).border({ width: { top: 1 }, color: Theme.line })
  }

  @Builder
  resultCard(result: OperationResult) {
    Column({ space: 10 }) {
      Text(result.state === OperationState.Success ? '演示完成' :
        (result.state === OperationState.Partial ? '部分完成 · 提醒待重试' : '本次未完成'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      if (result.calendarCreated && !this.calendarOpen) {
        this.draftDetails(result.draft)
      }
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
                this.searchEnabled = false;
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
  scenarioPanel() {
    Column({ space: 10 }) {
      Text('选择下一次演示场景').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.ink)
      Text('仅模拟界面状态，不改变系统设置。场景执行后恢复正常；提醒重试默认成功。')
        .fontSize(12).fontColor(Theme.muted).lineHeight(20)
      if (this.searchEnabled) {
        Text('联网搜索 · 固定样例演示').fontSize(13).fontColor(Theme.accent)
        ForEach(SEARCH_SCENARIOS, (item: SearchScenario) => {
          Button(item, { type: ButtonType.Normal }).width('100%').constraintSize({ minHeight: 44 })
            .fontSize(14).borderRadius(10)
            .backgroundColor(item === this.searchScenario ? Theme.accent : Theme.surface)
            .fontColor(item === this.searchScenario ? Color.White : Theme.ink)
            .onClick(() => {
              this.searchScenario = item;
              this.showScenarios = false;
            })
        }, (item: SearchScenario) => item)
      } else {
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
      }
      Button('返回页面').fontColor(Theme.accent).backgroundColor(Theme.soft)
        .onClick(() => this.showScenarios = false)
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 20 })
  }

  private refreshVoiceArchive(): void {
    try { this.voiceArchive = SpeechService.archive.list(); } catch (_) { this.voiceMessage = '读取已保存录音失败，请重试。'; }
  }

  private playVoice(clip: VoiceClip): void {
    if (this.speech.busy) return;
    void SpeechService.playback.play(clip).catch((): void => { this.voiceMessage = '录音播放或释放失败，请重试。'; });
  }

  private deleteVoice(clip: VoiceClip): void {
    this.getUIContext().showAlertDialog({ title: '删除这条录音？', message: '只删除这条本机录音，删除后无法恢复。',
      primaryButton: { value: '保留', action: (): void => {} },
      secondaryButton: { value: '删除', action: (): void => {
        void SpeechService.playback.stop().then((): void => {
          SpeechService.archive.remove(clip);
          if (this.voiceDraft?.id === clip.id) { this.voiceDraft = undefined; this.voiceText = ''; }
          this.refreshVoiceArchive();
        }).catch((): void => { this.voiceMessage = '录音删除失败，文件仍保留。'; });
      } }
    });
  }

  private composerLength(): number {
    return this.voiceDraft === undefined ? this.input.length : composeVoiceMessage(this.voiceText, this.input).length;
  }

  private async sendVoice(): Promise<void> {
    const clip = this.voiceDraft; const transcript = this.voiceText; const supplement = this.input;
    const text = composeVoiceMessage(transcript, supplement);
    if (clip === undefined || this.blocked() || text.length === 0 || text.length > 500) return;
    if (!this.realChatMode) { this.notice('请先启用真实对话', '录音已保存在本机。启用助手后可发送语音消息，转写不会显示。'); return; }
    if (this.knowledgeEnabled && this.runtimeKnowledge.lifecycle !== ShuviRuntimeState.READY) {
      this.notice('知识库问答尚未就绪', '录音已保存，请先准备知识库会话。'); return;
    }
    if (this.searchEnabled && !this.knowledgeEnabled &&
      (this.runtimeSearch.lifecycle !== ShuviRuntimeState.READY || !this.runtimeSearch.allowance)) {
      this.notice('真实搜索尚不可用', '录音已保存，请先准备搜索会话。'); return;
    }
    if (!this.knowledgeEnabled && !this.searchEnabled && (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY ||
      this.runtimeChat.requestCount >= this.runtimeChat.maxRequests)) {
      this.notice('真实对话尚不可用', '录音已保存，请启用有剩余次数的会话后发送。'); return;
    }
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: true, text: supplement.trim(), voice: clip };
    this.messages = this.messages.concat([message]); this.voiceDraft = undefined; this.voiceText = ''; this.input = '';
    this.hiddenVoiceQueries.add(text);
    this.searchVoiceQuery = this.searchEnabled && !this.knowledgeEnabled; this.knowledgeVoiceQuery = this.knowledgeEnabled;
    if (this.knowledgeEnabled) {
      const sent = await RuntimeKnowledgeService.session.send(text);
      if (!sent && this.alive) {
        this.messages = this.messages.filter((item: ChatMessage): boolean => item.id !== message.id);
        if (this.voiceDraft === undefined && this.input.length === 0) {
          this.voiceDraft = clip; this.voiceText = transcript; this.input = supplement;
        }
      }
    } else if (this.searchEnabled) { await RuntimeSearchService.session.send(text); }
    else { await RuntimeChatService.session.send(text); }
    this.scroller.scrollEdge(Edge.Bottom);
  }

  @Builder
  voiceArchivePanel() {
    Column({ space: 8 }) {
      Row() {
        Button(this.voiceArchiveOpen ? '收起录音' : `已保存语音 · ${this.voiceArchive.length}`)
          .height(44).fontSize(12).fontColor(Theme.accent).backgroundColor(Color.Transparent).id('voice-archive-toggle')
          .enabled(!this.speech.busy).onClick((): void => { this.refreshVoiceArchive(); this.voiceArchiveOpen = !this.voiceArchiveOpen; })
        Blank()
        if (this.voiceArchiveOpen) { Text('仅本机保存').fontSize(11).fontColor(Theme.muted) }
      }.width('100%')
      if (this.voiceMessage.length > 0) { Text(this.voiceMessage).fontSize(12).fontColor(Theme.danger) }
      if (this.voiceArchiveOpen) {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.voiceArchive, (clip: VoiceClip): void => {
              Row({ space: 6 }) {
                VoiceMessageBubble({ recording: clip, playingId: this.voicePlayingId,
                  onPlay: (item: VoiceClip): void => this.playVoice(item) })
                Blank()
                Button('删除').height(44).fontSize(12).fontColor(Theme.danger).backgroundColor(Color.Transparent)
                  .id(`voice-delete-${clip.id}`).onClick((): void => this.deleteVoice(clip))
              }.width('100%')
            }, (clip: VoiceClip): string => clip.id)
            if (this.voiceArchive.length === 0) { Text('还没有保存的录音').fontSize(12).fontColor(Theme.muted) }
          }.width('100%')
        }.constraintSize({ maxHeight: 180 }).width('100%')
      }
    }.width('100%')
  }

  private startSpeech(): void {
    if (this.blocked() || this.input.trim().length > 0) return;
    this.inputController.stopEditing();
    void SpeechService.playback.stop().then((): void => {
      if (!this.blocked()) void SpeechService.session.start();
    }).catch((): void => { this.voiceMessage = '请先停止播放后再录音。'; });
  }

  @Builder
  speechPanel() {
    if (this.speech.busy || this.speech.message.length > 0) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          AppIcon({ source: $r('app.media.chat_wave'), size: 20 })
          Text(this.speech.message).fontSize(13)
            .fontColor(this.speech.phase === SpeechPhase.Error ? Theme.danger : Theme.accent).layoutWeight(1)
          if (!this.speech.busy) {
            Button({ type: ButtonType.Circle }) {
              AppIcon({ source: $r('app.media.ui_close'), size: 14 })
            }.width(40).height(40).backgroundColor(Color.Transparent)
              .id('speech-dismiss').accessibilityText('关闭语音提示')
              .onClick((): void => SpeechService.session.dismissMessage())
          }
        }.width('100%')
        if (this.speech.busy) {
          Row({ space: 8 }) {
            Text('普通话 · 本机离线识别').fontSize(11).fontColor(Theme.muted).layoutWeight(1)
            if (this.speech.phase === SpeechPhase.Listening) {
              Button('结束').height(44).fontSize(14).fontColor(Color.White).backgroundColor(Theme.accent)
                .id('speech-finish').accessibilityText('结束录音并整理文字')
                .onClick(() => SpeechService.session.finish())
            }
            Button('取消').height(44).fontSize(14).fontColor(Theme.accent).backgroundColor(Theme.inputSurface)
              .id('speech-cancel').accessibilityText('取消语音输入并释放麦克风')
              .onClick(() => SpeechService.session.cancel())
          }.width('100%')
        }
      }.width('100%').padding(12).backgroundColor(Theme.soft).borderRadius(18).id('speech-status')
    }
  }

  @Builder
  composer() {
    Column({ space: 8 }) {
      this.speechPanel()
      this.voiceArchivePanel()
      if (this.input.length === 0 && this.voiceDraft === undefined && !this.blocked()) {
        Row({ space: 6 }) {
          Text('试试').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Text(this.sampleText()).fontSize(13).fontColor(Theme.accent).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 }).backgroundColor(Theme.soft).borderRadius(18)
          .id('chat-sample').accessibilityText(`填入示例：${this.sampleText()}`).onClick(() => this.useSample())
      }
      Column({ space: 6 }) {
        if (this.voiceDraft !== undefined) {
          Row({ space: 8 }) {
            VoiceMessageBubble({ recording: this.voiceDraft, playingId: this.voicePlayingId,
              onPlay: (clip: VoiceClip): void => this.playVoice(clip) })
            Blank()
            Button('移除草稿').height(44).fontSize(12).fontColor(Theme.muted).backgroundColor(Color.Transparent)
              .id('voice-discard').enabled(!this.blocked())
              .onClick((): void => { this.voiceDraft = undefined; this.voiceText = ''; void SpeechService.session.cancel(); })
          }.width('100%')
        }
        TextArea({ text: this.input, placeholder: this.voiceDraft === undefined ? '发消息，或说说你的想法…' :
          '补充文字（可选），和语音一起发送…', controller: this.inputController })
          .fontSize(Theme.bodySize).fontColor(Theme.ink).placeholderColor(Theme.muted).backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 40, maxHeight: 120 }).width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .enabled(!this.blocked()).onChange((value: string) => this.input = value)
          .accessibilityText(this.voiceDraft === undefined ? '写下想做的事，最多 500 字' :
            '补充文字，与语音合计最多 500 字；转写内容不显示').id('chat-input')
        Row({ space: 6 }) {
          ModeChip({ icon: $r('app.media.chat_globe'), label: '搜索', on: this.searchEnabled, disabled: this.blocked(),
            chipId: 'chat-search-toggle',
            a11y: `${this.realChatMode ? '真实联网搜索' : '联网搜索演示'}，${this.searchEnabled ? '已开启，点击关闭' : '已关闭，点击开启'}`,
            onTap: (): void => { void this.toggleSearch(); } })
          ModeChip({ icon: $r('app.media.chat_book'), label: this.ragPreparing ? '准备中…' : '知识库', on: this.knowledgeEnabled,
            disabled: this.blocked(), chipId: 'chat-knowledge-toggle',
            a11y: `本机知识库问答，${this.ragPreparing ? '正在打开本机知识库' : (this.knowledgeEnabled ? '已开启，点击关闭' : '已关闭，点击开启')}`,
            onTap: (): void => { void this.toggleKnowledge(); } })
          Blank()
          Row() {
            Button({ type: ButtonType.Circle }) {
              AppIcon({ source: $r('app.media.chat_plus'), size: 26 })
            }.width(44).height(44).backgroundColor(Color.Transparent).enabled(!this.blocked()).onClick(() => this.attachments())
              .accessibilityText('添加图片或文件，待接入')
            if (this.input.trim().length > 0 || this.voiceDraft !== undefined) {
              Button({ type: ButtonType.Circle }) {
                AppIcon({ source: $r('app.media.chat_up'), size: 22})
              }.width(44).height(44).backgroundColor(Theme.accent).accessibilityText('发送消息').id('chat-send')
                .enabled(!this.blocked() && this.composerLength() <= 500 &&
                  (this.voiceDraft === undefined || this.voiceText.trim().length > 0)).onClick(() => this.send())
            } else {
              Button({ type: ButtonType.Circle }) {
                AppIcon({ source: $r('app.media.chat_wave'), size: 26 })
              }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('开始普通话语音输入')
                .id('chat-speech').enabled(!this.blocked()).onClick(() => this.startSpeech())
            }
          }
        }.width('100%').alignItems(VerticalAlign.Center)
        if (this.composerLength() >= 400) {
          Text(`${this.composerLength()} / 500${this.voiceDraft === undefined ? '' : '（含语音）'}`).fontSize(11)
            .fontColor(this.composerLength() > 500 ? Theme.danger : Theme.muted).width('100%').textAlign(TextAlign.End)
        }
      }.width('100%').padding({ left: 10, right: 8, top: 8, bottom: 6 })
        .backgroundColor(Theme.inputSurface).borderRadius(24)
        .border({ width: 1, color: this.composerLength() > 500 ? Theme.danger : Theme.line })
      if (this.composerLength() > 500) {
        Text(this.voiceDraft === undefined ? '最多 500 字，请缩短后发送。' : '语音与补充文字合计最多 500 字，请减少补充文字或分段录音。').fontSize(12).fontColor(Theme.danger).width('100%')
      }
      Text(this.composerHint()).fontSize(11).fontColor(Theme.muted).textAlign(TextAlign.Center).width('100%')
        .id('chat-composer-hint')
    }.padding({ left: 12, right: 12, top: 8, bottom: 12 }).width('100%').backgroundColor(Theme.surface)
  }

  @Builder
  navigationDrawer() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 6 }) {
          Text('Shuvi 休比').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text(this.realChatMode ? '个人助理 · 真实功能' : '个人助理 · 演示模式').fontSize(12).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppIcon({ source: $r('app.media.ui_close'), size: 22 })
        }.width(44).height(44)
          .backgroundColor(Color.Transparent).accessibilityText('关闭导航菜单')
          .onClick(() => this.drawerOpen = false)
      }.width('100%').padding({ bottom: 24 })
      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.tabNames, (name: string, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                AppIcon({ source: this.tabIcons[index]})
                Text(name).fontSize(16).fontColor(this.tab === index ? Theme.accent : Theme.muted).layoutWeight(1)
                if (index === 0 && this.draft !== undefined) {
                  Text(this.executing ? '处理中' : '待确认').fontSize(11).fontColor(Theme.amber)
                }
                if (index === 1 && this.records.length > 0) {
                  Text(`${this.records.length}`).fontSize(12).fontColor(Theme.accent)
                    .accessibilityText(`${this.records.length} 条演示日程`)
                }
              }.width('100%').padding(14).constraintSize({ minHeight: 52 })
            }.width('100%').borderRadius(15).backgroundColor(this.tab === index ? Theme.soft : Color.Transparent)
              .accessibilityText(`${name}${this.tab === index ? '，已选中' : ''}`).onClick(() => this.changeTab(index))
          }, (name: string) => name)
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
      Button('演示场景设置  ›', { type: ButtonType.Normal }).width('100%').constraintSize({ minHeight: 44 })
        .fontSize(13).fontColor(Theme.accent).backgroundColor(Color.Transparent)
        .enabled(!this.generating && !this.executing && !this.searchBusy).onClick(() => this.openScenarios())
      Text('演示模式不联网、不写日历；真实对话、搜索和日程在助手页开启\n知识库资料保存在本机').fontSize(11).fontColor(Theme.muted)
        .width('100%').padding({ top: 16 })
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: 28, bottom: 24 })
      .backgroundColor(Theme.inputSurface).borderRadius({ topRight: 26, bottomRight: 26 })
  }

  @Builder
  floatingAssistant() {
    Button({ type: ButtonType.Circle }) {
      BrandAvatar({ size: 48 })
    }.width(FloatingAssistantPlacement.size).height(FloatingAssistantPlacement.size).backgroundColor(Theme.surface)
      .border({ width: 1, color: Theme.line })
      .shadow({ radius: 12, color: Theme.shadow, offsetY: 3 })
      .position({ x: this.floatingPlacement.x, y: this.floatingPlacement.y })
      .accessibilityText('回到助手')
      .accessibilityDescription('返回当前对话，保留已输入内容、消息和待确认草稿。可拖动调整位置。')
      .id('floating-assistant')
      .onClick(() => this.changeTab(0))
      .priorityGesture(
        PanGesture({ fingers: 1, direction: PanDirection.All, distance: 8 })
          .onActionStart((event: GestureEvent) => {
            this.floatingPlacement.beginDrag();
            this.floatingPlacement.moveDrag(event.offsetX, event.offsetY);
          })
          .onActionUpdate((event: GestureEvent) => {
            this.floatingPlacement.moveDrag(event.offsetX, event.offsetY);
          })
          .onActionEnd((event: GestureEvent) => {
            this.floatingPlacement.moveDrag(event.offsetX, event.offsetY);
            this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
              this.floatingPlacement.finishDrag();
            });
          })
          .onActionCancel(() => this.floatingPlacement.cancelDrag())
      )
      .onDisAppear(() => this.floatingPlacement.cancelDrag())
  }

  @Builder
  pageContent() {
    Column() {
      this.header()
      if (this.tab === 0 && ((this.searchEnabled && this.searchScenario !== SearchScenario.Normal) ||
        (!this.searchEnabled && this.scenario !== DemoScenario.Normal))) {
        Text(`下一次演示：${this.searchEnabled ? this.searchScenario : this.scenario}`).fontSize(12).fontColor(Theme.amber)
          .width('100%').textAlign(TextAlign.Center).padding({ left: 16, right: 16, bottom: 8 })
      }
      Scroll(this.scroller) {
        Column() {
            if (this.migrationOpen) {
              KnowledgeMigrationView({migration:this.sharedKnowledge?.migration,queue:this.sharedKnowledge?.unifiedQueue,vectors:this.sharedKnowledge?.unifiedVectors,onBack:(): void=> { this.migrationOpen=false; }})
            } else if (this.visionSettingsOpen) {
              VisionSettingsView({service:this.sharedKnowledge?.unifiedSettings,queue:this.sharedKnowledge?.unifiedQueue,onBack:(): void=> { this.visionSettingsOpen=false; this.scroller.scrollEdge(Edge.Top); }})
            } else if (this.imageKnowledgeOpen) {
              ImageKnowledgeView({service:this.sharedKnowledge?.imageKnowledge,previewService:this.parsedService,queue:this.sharedKnowledge?.unifiedQueue,initialOccurrence:this.imageKnowledgeOccurrence,onBack:(): void=> { this.imageKnowledgeOpen=false; this.imageKnowledgeOccurrence=''; }})
            } else if (this.parsedOpen) {
              if (this.parsedOpening) {
                LoadingProgress().width(32).height(32)
                Text('正在打开资料…').padding(16)
              } else {
                ParsedDocumentView({ service: this.parsedService, imports: this.parsedImports, parse: this.parseService, lifecycle: this.sharedKnowledge?.unifiedLifecycle, queue: this.sharedKnowledge?.unifiedQueue,
                  initialImportOpen: this.parsedImportOpen, initialDocument: this.parsedDocumentId, onNavigate: (): void => { this.scroller.scrollEdge(Edge.Top); },
                  onRetryProcessing: (): void => { this.sharedKnowledge?.retryUnifiedProcessing().catch((): void => { this.parsedMessage = '自动处理暂不可用，请重试'; }); },
                  entryFailure: this.parsedMessage, onRetry: (): void => { this.openParsed(); },
                  onBack: (): void => { this.parsedOpen = false; this.parsedDocumentId = ''; },
                  onParseTasks: (): void => { this.parsedOpen = false; this.openParse(true); } })
              }
            } else if (this.docxSourceOpen) {
             DocxSourceView({ session: this.sharedKnowledge?.docxSources, onBack: (): void => { this.docxSourceOpen = false; } })
            } else if (this.docxIngestionOpen) {
              if (this.docxEntryMessage.length > 0 || this.docxOpening || this.docxIngestionService === undefined) {
                Column({ space: 16 }) {
                  Text('DOCX解析与入库').fontSize(20).width('100%')
                  Text(this.docxEntryMessage || 'DOCX 服务尚未就绪，原件保留').id('docx-entry-status').width('100%')
                  if (this.docxOpening) { LoadingProgress().width(32).height(32) }
                  Button('重试打开DOCX').id('docx-entry-retry').enabled(!this.docxOpening).onClick((): void => { this.openDocx(); })
                  Button('返回').id('docx-back').onClick((): void => { this.docxIngestionOpen = false; })
                }.width('100%').padding(16)
              } else {
                DocxIngestionView({ service: this.docxIngestionService, embedding: this.embeddingService, onBack: (): void => { this.docxIngestionOpen = false; this.docxIngestionService?.pause(); }, onParseSettings: (): void => { this.docxIngestionOpen = false; this.openParse(true); }, onEmbeddingSettings: (): void => { this.docxIngestionOpen = false; this.openEmbedding(); }, onSearch: (): void => { this.openDocxSearch(); }, onSource: (id: string): void => { this.openDocxSource(id); } })
              }
           } else if (this.imageSourceOpen) {
             ImageSourceView({ session: this.sharedKnowledge?.imageSources, onBack: (): void => { this.imageSourceOpen = false; this.sharedKnowledge?.imageSources.close().catch((): void => {}); } })
           } else if (this.imageIngestionOpen) {
              ImageIngestionView({ service: this.imageIngestionService, embedding: this.embeddingService, onBack: (): void => { this.imageIngestionOpen = false; this.imageIngestionService?.pause(); }, onOriginal: (document: ImageDocument): void => { this.openImageOriginal(document); },
               onParseSettings: (): void => { this.imageIngestionOpen = false; this.openParse(true); }, onEmbeddingSettings: (): void => { this.imageIngestionOpen = false; this.openEmbedding(); } })
           } else if (this.platformDiagnosticsOpen) {
              KnowledgePlatformDiagnostics({ onBack: (): void => { this.platformDiagnosticsOpen = false; }, onImageHappyPath: (): void => { this.platformDiagnosticsOpen = false; this.openImages(); } })
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
                EmbeddingSettingsView({ service: this.embeddingService, unifiedSettings:this.sharedKnowledge?.unifiedSettings, clearEpoch: this.embeddingClearEpoch, onBack: (): void => { this.closeEmbedding(); } })
             } else {
               Text('本机配置服务尚未就绪或不可用，未发送请求').width('100%')
               Button('返回').onClick((): void => { this.closeEmbedding(); })
             }
           } else if (this.parseOpen) {
             if (this.parseService !== undefined) {
               DocumentParseView({ parseState: this.parseState, service: this.parseService,
                 settingsMode: this.parseSettings, clearEpoch: this.parseState.inputEpoch,
                   onClose: (): void => { this.closeParse(); }, onPreparePdf: (resultId: string): void => { this.preparePdf(resultId); },
                    onPrepareImage: (resultId: string): void => { this.prepareImage(resultId); }, onOpenImages: (): void => { this.closeParse(); this.openImages(); }, onOpenDocx: (): void => { this.closeParse(); this.openDocx(); } })
             } else {
               Column({ space: 12 }) {
                 Text(this.parseState.message || '正在打开独立解析准备区…').fontSize(14).width('100%')
                 Button('重试打开解析准备').onClick((): void => { this.openParse(this.parseSettings); })
                 Button('返回').onClick((): void => { this.closeParse(); })
               }.width('100%').padding(20)
             }
           } else if (this.tab === 0) {
            if (DEBUG) {
              this.runtimeChatControls()
            }
            if (this.messages.length === 0 && !(this.realChatMode && this.searchEnabled && this.runtimeSearch.query.length > 0) &&
              !(this.realChatMode && this.knowledgeEnabled && this.runtimeKnowledge.query.length > 0)) {
              AssistantWelcome({ searchEnabled: this.searchEnabled, realChat: this.realChatMode })
            } else {
              this.assistant()
            }
          } else if (this.tab === 1) {
            if (this.realCalendarOpen) {
              Row() {
                Button('‹ 工作台').fontSize(14).fontColor(Theme.accent).backgroundColor(Color.Transparent)
                  .constraintSize({ minHeight: Theme.controlHeight }).padding({ left: 4, right: 12 })
                  .accessibilityText('返回工作台').id('calendar-back')
                  .onClick((): void => { this.realCalendarOpen = false; })
              }.width('100%')
              CalendarCapabilityCheck()
            } else if (this.calendarOpen) {
              this.calendar()
            } else {
              WorkbenchPage({ recordCount: this.records.length,
                onDocuments: (): void => { this.changeTab(2); this.parsedDocumentId = ''; this.openParsed(); },
                onCalendar: () => this.calendarOpen = true,
                onRealCalendar: (): void => { this.realCalendarOpen = true; },
                onNotice: (title: string, message: string) => this.notice(title, message) })
            }
           } else if (this.tab === 2) {
             if (this.knowledgeReady) {
               UnifiedKnowledgeView({ session: this.sharedKnowledge?.querySession, history: this.sharedKnowledge?.unifiedHistory,
                 onImport: (): void => { this.parsedDocumentId = ''; this.openParsed(true); },
                 onDocuments: (): void => { this.parsedDocumentId = ''; this.openParsed(); },
                 onOpen: (card: UnifiedSearchCard): void => { this.openUnifiedCard(card); } })
            } else {
              Column({ space: 12 }) {
                Text(this.knowledgeMessage || '正在打开本机知识库…')
                  .fontSize(15).fontColor(Theme.muted).width('100%')
                Button(this.knowledgeOpening ? '正在打开…' : '重试打开', { type: ButtonType.Normal }).id('upd-open-retry').enabled(!this.knowledgeOpening).fontColor(Theme.accent).backgroundColor(Theme.soft).constraintSize({ minHeight: 44 })
                  .onClick((): void => { this.openKnowledge(); })
              }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 20, bottom: 20 })
            }
           } else {
              if (this.developerToolsOpen) { Button('本机能力诊断').id('r2-open-diagnostics').onClick((): void => { this.platformDiagnosticsOpen = true; })
              }

             ProfilePage({ floatingAssistantEnabled: this.floatingAssistantEnabled,
               onFloatingAssistantChange: (enabled: boolean): void => { this.floatingAssistantEnabled = enabled; }, onNotice: (title: string, message: string) => this.notice(title, message),
               onVisionSettings: (): void => { this.openVisionSettings(); },
               onParseSettings: (): void => { this.openParse(true); }, onEmbeddingSettings: (): void => { this.openEmbedding(); } })
             Button(this.developerToolsOpen ? '收起高级诊断' : '高级诊断', { type: ButtonType.Normal }).fontSize(13).fontColor(Theme.muted).backgroundColor(Color.Transparent).constraintSize({ minHeight: 44 }).onClick((): void => { this.developerToolsOpen = !this.developerToolsOpen; })
          }
        }.width('100%').constraintSize({ maxWidth: 640,
          minHeight: this.tab === 0 && this.messages.length === 0 && !this.showScenarios ? this.contentHeight : 0 })
          .justifyContent(FlexAlign.Center)
          // 让末尾内容可以完整滚动到悬浮入口上方；菜单打开时保持内容尺寸。
          .padding({ left: 20, right: 20,
            bottom: this.floatingAssistantEnabled && this.tab !== 0 && !this.showScenarios ? 100 : 0 })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
        .onAreaChange((_oldArea: Area, area: Area) => this.contentHeight = Number(area.height))
      if (this.tab === 0 && !this.showScenarios) {
        if (this.draft) {
          this.confirmationDock()
        } else {
          this.composer()
        }
      }
    }.width('100%').height('100%').backgroundColor(Theme.paper)
  }

  build() {
    SideBarContainer(SideBarContainerType.Overlay) {
      Column() {
        this.navigationDrawer()
      }
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.pageContent()
        }.width('100%').height('100%').enabled(!this.drawerOpen)
          .accessibilityLevel(this.drawerOpen ? 'no-hide-descendants' : 'auto')
        if (this.floatingAssistantEnabled && this.floatingPlacement.canPlace &&
          this.tab !== 0 && !this.showScenarios && !this.drawerOpen) {
          this.floatingAssistant()
        }
        if (this.drawerOpen) {
          Button({ type: ButtonType.Normal }) {
            Row().width('100%').height('100%')
          }.width('100%').height('100%').backgroundColor(Theme.overlay).borderRadius(0)
            .accessibilityText('关闭导航菜单').onClick(() => this.drawerOpen = false)
        }
      }.width('100%').height('100%')
        .onAreaChange((_oldArea: Area, area: Area) => this.resizeFloatingHost(Number(area.width), Number(area.height)))
    }.width('100%').height('100%').showSideBar(this.drawerOpen).showControlButton(false)
      .sideBarWidth('84%').minSideBarWidth(200).maxSideBarWidth(320).minContentWidth(0)
      .divider({ strokeWidth: 0 }).onChange((visible: boolean) => this.drawerOpen = visible)
      .backgroundColor(Theme.paper)
  }
}
