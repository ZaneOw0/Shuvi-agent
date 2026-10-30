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
import { ProfilePage } from '../components/FeaturePages';
import { ApiKeysView } from '../components/ApiKeysView';
import { DeepSeekKeyService, DeepSeekKeyStatus } from '../services/model/DeepSeekCredentialStore';
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
import { PdfJsSurface } from '../knowledge/ui/PdfJsSurface';
import { PdfJsRuntime } from '../knowledge/infra/PdfJsRuntime';
import { PdfJsSourcePreview } from '../knowledge/infra/PdfJsSourcePreview';
import { KnowledgeReadLease } from '../knowledge/domain/PdfKnowledgeModels';
import { EmbeddingService } from '../knowledge/application/EmbeddingService';
import { PdfIngestionService } from '../knowledge/application/PdfIngestionService';
import { PdfIngestionView } from '../knowledge/ui/PdfIngestionView';
import { KnowledgeView } from '../knowledge/ui/KnowledgeView';
import { KnowledgeSearchService } from '../knowledge/application/KnowledgeSearchService';
import { KnowledgeHit, KnowledgeSourceKind } from '../knowledge/domain/KnowledgeSearchModels';
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
import { ResponsiveLayoutPolicy } from '../model/ResponsiveLayoutPolicy';
import { SearchResultCard } from '../components/SearchResultCard';
import { MockSearchSession } from '../mock/MockSearchSession';
import { SEARCH_SAMPLE, SEARCH_SCENARIOS, SearchScenario, SearchSource, SearchState, SearchTurn,
  searchIsBusy } from '../model/SearchModels';
import { SourceLinkService } from '../services/SourceLinkService';
import { DEBUG } from 'BuildProfile';
import { RuntimeChatService } from '../services/model/RuntimeChatService';
import { RuntimeSearchService } from '../services/model/RuntimeSearchService';
import { RuntimeSearchView } from '../services/model/RuntimeSearchSession';
import { RuntimeSearchPanel } from '../components/RuntimeSearchPanel';
import { RuntimeKnowledgePanel } from '../components/RuntimeKnowledgePanel';
import { AssistantReplyBubble } from '../components/AssistantReplyBubble';
import { ChatKnowledgeReply, chatKnowledgeReply, chatKnowledgeStoredReply } from '../components/ChatKnowledgeSources';
import { ChatKnowledgeSource, ChatKnowledgeSnapshot } from '../model/ChatKnowledgeModels';
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
import { EmbeddingCredentialStatus, EmbeddingDetectionStatus } from '../knowledge/domain/EmbeddingModels';
import { ApiKeySync } from '../services/model/ApiKeySync';
import { ASSISTANT_IMAGE_DEFAULT_PROMPT, AssistantImageInput } from '../services/model/AssistantImageInput';
import { VisionChatImage } from '../services/model/VisionChatProtocol';
import { ConversationSummary, ConversationView } from '../services/conversation/AssistantConversations';
import { AssistantConversationRdb } from '../services/conversation/AssistantConversationRdb';

@Entry
@Component
struct Index {
  // The demo mode has no entry in the product UI any more; its code stays for the host tests and later removal.
  @State realChatMode: boolean = true;
  @State deepSeekStatus: DeepSeekKeyStatus = DeepSeekKeyStatus.Checking;
  @State connecting: boolean = false;
  @State apiKeysOpen: boolean = false;
  @State apiKeysReady: boolean = false;
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
  /** Picker URI shown as the composer thumbnail; the sanitized bytes live in imageDraft (memory only, not state). */
  @State imageDraftUri: string = '';
  @State imagePreparing: boolean = false;
  private imageDraft: VisionChatImage | undefined = undefined;
  // Real-chat messages are saved with the current conversation on every change (see messagesChanged).
  @State @Watch('messagesChanged') messages: ChatMessage[] = [];
  @State conversations: ConversationView = new ConversationView();
  private restoringMessages: boolean = false;
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
  @State embeddingOpening: boolean = false;
  @State pdfIngestionOpen: boolean = false;
  private pdfIngestionService: PdfIngestionService | undefined = undefined;
  private unifiedSearchService: KnowledgeSearchService | undefined = undefined;
  private derivedLifecycle: KnowledgeDerivedLifecycle | undefined = undefined;
  private pdfDocumentsPort: KnowledgeDocumentListPort | undefined = undefined;
  private embeddingService: EmbeddingService | undefined = undefined;
  @State embeddingClearEpoch: number = 0;
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
  @State windowWidth: number = 0;
  @State contentWidth: number = 0;
  @State wideLayout: boolean = false;
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
  private tabNames: string[] = ['助手', '日程', '知识库', '我的'];
  private tabIcons: Resource[] = [
    $r('app.media.chat_chat'), $r('app.media.chat_calendar'), $r('app.media.chat_book'), $r('app.media.chat_user')
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
      this.runtimeKnowledge = view; this.knowledgeEnabled = view.consent;
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
    RuntimeChatService.conversations.attach((view: ConversationView): void => { if (this.alive) this.conversations = view; });
    void this.openConversations();
    void this.ensureAssistant();
  }

  /** Restores the most recent saved conversation (what was shown and what the model remembers). */
  private async openConversations(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) return;
    const restored: ChatMessage[] = await RuntimeChatService.conversations.open(
      new AssistantConversationRdb(new NativeAgentRdbOpen(context)));
    if (this.alive && this.realChatMode && this.messages.length === 0 && restored.length > 0) {
      this.showMessages(restored);
    }
  }
  private showMessages(list: ChatMessage[]): void {
    this.restoringMessages = true;
    try { this.messages = list; } finally { this.restoringMessages = false; }
    this.scroller.scrollEdge(Edge.Bottom);
  }
  messagesChanged(_name: string): void {
    if (!this.restoringMessages && this.realChatMode) RuntimeChatService.conversations.saveMessages(this.messages);
  }

  // Going to the background ends every model session (EntryAbility); coming back reconnects with the stored key.
  onPageShow(): void { void this.ensureAssistant(); }
  onPageHide(): void {
    this.knowledgeEnabled = false;
    void SpeechService.session.cancel(); void SpeechService.playback.stop().catch((): void => {});
  }

  aboutToDisappear(): void {
    PdfJsRuntime.shared.closePreview();
    this.alive = false;
    RuntimeChatService.conversations.detach();
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
    await PdfJsRuntime.shared.closeAndWait();
    this.sharedKnowledge?.unsubscribe(this.knowledgeListener);
    await this.sharedKnowledge?.quiesceUnified();
    await this.docxIngestionService?.close(); await this.sharedKnowledge?.docxSources.close();
    await this.parseAssembly?.close(); await this.sharedKnowledge?.release();
  }

  onBackPress(): boolean {
    if (this.speech.busy) { SpeechService.session.cancel(); return true; }
    if (PdfJsRuntime.shared.expanded) { PdfJsRuntime.shared.closePreview(); return true; }
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.apiKeysOpen) { this.apiKeysOpen = false; return true; }
    if (this.migrationOpen) { this.migrationOpen=false; return true; }
    if (this.visionSettingsOpen) { this.visionSettingsOpen=false; return true; }
    if (this.imageKnowledgeOpen) { this.imageKnowledgeOpen=false; return true; }
    if (this.parsedOpen) { this.parsedOpen = false; return true; }
    if (this.docxSourceOpen) { this.docxSourceOpen = false; this.sharedKnowledge?.docxSources.close().catch((): void => {}); return true; }
    if (this.docxIngestionOpen) { this.docxIngestionOpen = false; this.docxIngestionService?.pause(); return true; }
    if (this.imageSourceOpen) { this.imageSourceOpen = false; this.sharedKnowledge?.imageSources.close().catch((): void => {}); return true; }
    if (this.imageIngestionOpen) { this.imageIngestionOpen = false; this.imageIngestionService?.pause(); return true; }
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
    const entering: boolean = index === 0 && this.tab !== 0;
    if (index !== this.tab && this.tab === 0) {
      void RuntimeSearchService.session.stop();
      void RuntimeAssistantCoordinator.stop().catch((): void => {});
      this.runtimeChat.clearEpoch++;
      // Stopping the assistant also ends knowledge-base answering; the chip comes back off.
      this.knowledgeEnabled = false;
    }
    this.floatingPlacement.cancelDrag();
    if (index !== this.tab) { this.apiKeysOpen = false; }
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
    if (entering) { void this.ensureAssistant(); }
  }

  private openApiKeys(): void {
    if (this.tab !== 3) { this.changeTab(3); }
    void this.openApiKeysPage();
  }
  private async openApiKeysPage(): Promise<void> {
    this.apiKeysReady = false; this.apiKeysOpen = true; this.scroller.scrollEdge(Edge.Top);
    // The SiliconFlow and MinerU cards need their services; open them without showing their own pages.
    try {
      if (this.embeddingService === undefined) { await this.openEmbedding(); this.embeddingOpen = false; }
      if (this.parseService === undefined) { await this.openParse(false); this.parseOpen = false; }
    } finally { this.apiKeysReady = true; }
  }
  private sessionState(): ShuviRuntimeState {
    return this.searchEnabled ? this.runtimeSearch.lifecycle : this.runtimeChat.lifecycle;
  }
  private async refreshDeepSeekStatus(): Promise<void> {
    try { this.deepSeekStatus = await DeepSeekKeyService.store.status(); }
    catch { this.deepSeekStatus = DeepSeekKeyStatus.Unavailable; }
  }

  /**
   * Connects the assistant — or the search session while 搜索 is on — with the DeepSeek key saved in 我的 → API Key 管理.
   * Connecting sends no model request. A failed start is retried only when the user asks (retry), never in a loop.
   */
  private async ensureAssistant(retry: boolean = false): Promise<void> {
    if (!DEBUG || !this.realChatMode || this.connecting || this.runtimeSwitching || !this.alive || this.tab !== 0 ||
      this.knowledgeEnabled) { return; }
    // Leaving and re-entering the assistant quickly can find the previous session still stopping.
    for (let i = 0; i < 40 && this.alive && this.tab === 0 && this.sessionState() === ShuviRuntimeState.STOPPING; i++) {
      await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 100); });
    }
    if (this.connecting || !this.alive || this.tab !== 0 || this.knowledgeEnabled) { return; }
    const state: ShuviRuntimeState = this.sessionState();
    if (state !== ShuviRuntimeState.IDLE && state !== ShuviRuntimeState.STOPPED && !(retry && state === ShuviRuntimeState.FAILED)) {
      return;
    }
    this.connecting = true;
    try {
      await this.refreshDeepSeekStatus();
      if (this.deepSeekStatus !== DeepSeekKeyStatus.Saved || !this.alive || this.tab !== 0) { return; }
      const key: Uint8Array | undefined = await DeepSeekKeyService.store.load();
      if (key === undefined) { await this.refreshDeepSeekStatus(); return; }
      if (this.searchEnabled) { await this.startRuntimeSearch(key); } else { await this.startRuntimeChat(key); }
    } catch {
      // The session view carries the failure message; the key stays only in the device store.
    } finally { this.connecting = false; }
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
    const shared=this.sharedKnowledge; const context=this.getUIContext().getHostContext();
    if (shared===undefined || context===undefined) { return; }
    try { await new PdfJsSourcePreview(context.filesDir+'/knowledge_parse_v1',shared.repository,shared.pages,shared.lifecycle,(source: string,generation: string): KnowledgeReadLease=>shared.sourceReadLease(source,generation)).open(hit); }
    catch (error) { if (this.alive) { this.knowledgeState.message=error instanceof Error?error.message:'PDF原件预览未完成'; } }
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
  private async openVisionSettings(): Promise<void> {
    await this.openParsed(); this.parsedOpen=false;
    await ApiKeySync.fillVisionKey(this.sharedKnowledge?.unifiedSettings);
    this.visionSettingsOpen=true;
  }
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
    if (this.embeddingOpening) { return; }
    this.embeddingOpen = true; this.embeddingOpening = true; this.scroller.scrollEdge(Edge.Top);
    try {
      if (this.sharedKnowledge !== undefined) { this.embeddingService = this.sharedKnowledge.repository.ready() ? this.sharedKnowledge.embedding : undefined; return; }
      const context = this.getUIContext().getHostContext(); if (context === undefined) { return; }
      const assembly: KnowledgeAssembly = KnowledgeAssembly.forContext(context); this.sharedKnowledge = assembly;
      await assembly.acquire(); this.embeddingService = assembly.repository.ready() ? assembly.embedding : undefined;
    }
    catch { this.sharedKnowledge = undefined; this.embeddingService = undefined; }
    finally { this.embeddingOpening = false; }
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

  private resizeWindow(width: number): void {
    if (!Number.isFinite(width) || width <= 0 || this.windowWidth === width) return;
    const embedded: boolean = ResponsiveLayoutPolicy.embedded(width);
    if (this.wideLayout !== embedded) { this.drawerOpen = false; }
    this.windowWidth = width; this.wideLayout = embedded;
  }

  private contentLimit(): number { return ResponsiveLayoutPolicy.contentLimit(this.windowWidth, this.tab === 0); }

  private resizeFloatingHost(width: number, height: number): void {
    if (Number.isFinite(width) && width > 0) { this.contentWidth = width; }
    this.floatingHostWidth = width;
    this.floatingHostHeight = height;
    this.floatingPlacement.resize(width, height, this.floatingHeaderHeight);
  }

  private addMessage(text: string, isUser: boolean = false, calendar?: CalendarCreatedSummary): void {
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: isUser, text: text, calendar: calendar };
    if (!isUser) {
      const reply: ChatKnowledgeReply = chatKnowledgeReply(text, RuntimeKnowledgeService.session.snapshot().citations);
      if (reply.sources.length > 0) {
        const snapshot: ChatKnowledgeSnapshot = new ChatKnowledgeSnapshot(); snapshot.sources = reply.sources;
        message.knowledgeSources = snapshot;
      }
    }
    this.messages = this.messages.concat([message]);
  }

  private assistantReply(message: ChatMessage): ChatKnowledgeReply {
    return chatKnowledgeStoredReply(message.text, message.knowledgeSources);
  }

  private async openChatKnowledgeSource(source: ChatKnowledgeSource): Promise<void> {
    try {
      await this.openKnowledge();
      const shared = this.sharedKnowledge;
      if (shared === undefined) { throw new Error('KnowledgeUnavailable'); }
      const document = await shared.unified.get(source.documentId);
      if (document === undefined || document.tombstone || document.archived || document.activeGeneration !== source.generation) {
        this.notice('来源已变化', '这份来源已换版、归档或删除，无法打开当时的版本。回答中的来源编号仍保留供核对。'); return;
      }
      this.parsedDocumentId = source.documentId;
      await this.openParsed();
    } catch {
      this.notice('暂时无法打开来源', '文件详情读取失败，请稍后重试。回答与来源仍保留。');
    }
  }
  private openCalendarRecords(): void {
    // Leaving the assistant tab ends the chat session as before; the 日程 tab lists the verified native records.
    this.changeTab(1);
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
    } catch { this.notice('切换没有完成', '请稍后重试；如果一直这样，请重启应用。'); return; }
    finally { this.runtimeSwitching = false; }
    // 搜索 on connects the search session, off reconnects the assistant; both use the saved DeepSeek key.
    await this.ensureAssistant();
  }

  private async toggleKnowledge(): Promise<void> {
    if (this.blocked() && !this.knowledgeEnabled) return;
    if (!this.realChatMode) { this.notice('请先打开真实功能', '知识库 RAG 不会回退为演示数据。请先切换到真实功能模式。'); return; }
    this.runtimeSwitching = true;
    try {
      if (this.knowledgeEnabled) {
        await RuntimeAssistantCoordinator.disableKnowledge();
        if (this.alive && this.tab === 0) { this.knowledgeEnabled = false; }
        return;
      }
      if (this.searchEnabled) { this.notice('请先关闭搜索', '联网搜索和知识库问答不能同时开启。'); return; }
      if (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY) {
        this.notice('助手还没有连接', this.deepSeekStatus === DeepSeekKeyStatus.Saved ? '请稍候片刻再试。' :
          '请先在「我的 → API Key 管理」保存 DeepSeek Key。'); return;
      }
      const choice: number = await new Promise<number>((resolve: (value: number) => void): void => {
        AlertDialog.show({ title: '允许助手按需使用个人知识库',
          message: '允许本会话读取当前未归档资料，并将命中片段发送给 DeepSeek 回答。语义查询还会将提炼后的查询发送给已配置的 Embedding Provider，可能计费。授权不启动资料入库，关闭或新对话即撤销。',
          primaryButton: { value: '允许语义查询', action: (): void => { resolve(1); } },
          secondaryButton: { value: '仅本机检索', action: (): void => { resolve(0); } },
          cancel: (): void => { resolve(-1); } });
      });
      if (choice < 0 || !this.alive || this.tab !== 0) { return; }
      this.ragPreparing = true;
      const readiness: KnowledgeRagReadiness = await RuntimeAssistantCoordinator.enableKnowledge(choice === 1);
      if (!readiness.ready) { this.notice('个人知识库尚不可用', readiness.message); return; }
      if (this.alive && this.tab === 0) { this.knowledgeEnabled = true; this.searchEnabled = false; }
    } catch { this.notice('切换没有完成', '请稍后重试；如果一直这样，请重启应用。'); }
    finally { this.runtimeSwitching = false; this.ragPreparing = false; }
  }

  @Builder
  private runtimeChatControls() {
    Column({ space: 10 }) {
      if (this.knowledgeEnabled) {
        RuntimeKnowledgePanel({ view: this.runtimeKnowledge, hideQuery: this.knowledgeVoiceQuery || this.hiddenVoiceQueries.has(this.runtimeKnowledge.query), onDisable: (): void => { void this.toggleKnowledge(); } })
      }
      if (this.searchEnabled) {
        RuntimeSearchPanel({ view: this.runtimeSearch, hideQuery: this.searchVoiceQuery || this.hiddenVoiceQueries.has(this.runtimeSearch.query) ||
          this.hiddenVoiceQueries.has(this.runtimeSearch.preview?.query ?? ''), keySaved: this.deepSeekStatus === DeepSeekKeyStatus.Saved,
          connecting: this.connecting, onConnect: (): void => { void this.ensureAssistant(true); },
          onKeys: (): void => { this.openApiKeys(); } })
      } else if (this.deepSeekStatus === DeepSeekKeyStatus.Missing || this.deepSeekStatus === DeepSeekKeyStatus.Unavailable) {
        // No key yet: the only setup step left in the assistant. Keys are managed in 我的 → API Key 管理.
        Column({ space: 10 }) {
          Text('设置 DeepSeek Key 后即可开始对话').fontSize(Theme.titleSize).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
          Text(this.deepSeekStatus === DeepSeekKeyStatus.Unavailable ? '本机安全存储暂时不可用，请稍后重试。' :
            '休比用 DeepSeek 回答问题、安排日程和读写文档。Key 只保存在本机，可以在「我的 → API Key 管理」随时修改或删除。')
            .fontSize(13).fontColor(Theme.muted).width('100%').lineHeight(20)
          Button('去设置').fontSize(15).fontColor(Color.White).backgroundColor(Theme.accent).borderRadius(Theme.radius)
            .width('100%').constraintSize({ minHeight: Theme.controlHeight }).id('runtime-chat-open-keys')
            .onClick((): void => { this.openApiKeys(); })
        }.width('100%').padding(16).alignItems(HorizontalAlign.Start).backgroundColor(Theme.surface)
          .borderRadius(Theme.cardRadius).border({ width: 1, color: Theme.line })
      } else if (this.runtimeChat.lifecycle === ShuviRuntimeState.FAILED || this.runtimeChat.lifecycle === ShuviRuntimeState.BLOCKED ||
        (this.runtimeChat.lifecycle === ShuviRuntimeState.STOPPED && !this.connecting && !this.runtimeSwitching)) {
        Row({ space: 8 }) {
          Text(this.runtimeChat.lifecycle === ShuviRuntimeState.BLOCKED ? '助手没能正常关闭，请重启应用。' :
            (this.runtimeChat.lifecycle === ShuviRuntimeState.STOPPED ? '助手已断开。' : '助手没有连接上。'))
            .fontSize(13).fontColor(Theme.ink).layoutWeight(1).id('runtime-chat-message')
          if (this.runtimeChat.lifecycle !== ShuviRuntimeState.BLOCKED) {
            Button('重新连接').fontSize(13).fontColor(Theme.accent).backgroundColor(Theme.soft).borderRadius(18)
              .constraintSize({ minHeight: Theme.controlHeight }).enabled(!this.connecting).id('runtime-chat-retry')
              .onClick((): void => { void this.ensureAssistant(true); })
          }
        }.width('100%').padding({ left: 14, right: 6, top: 4, bottom: 4 }).backgroundColor(Theme.surface)
          .borderRadius(22).border({ width: 1, color: Theme.line })
      } else if (this.runtimeChat.lifecycle === ShuviRuntimeState.READY && this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
        Text('这段对话已经很长了，点右上角「开始新对话」继续。').fontSize(Theme.noteSize).fontColor(Theme.amber).width('100%')
          .id('runtime-chat-limit')
      }
    }.width('100%').padding({ bottom: 12 })
  }

  private blocked(): boolean { return this.speech.busy || this.busyExceptSpeech(); }
  /** Speech can always be cancelled; cancelling it is busy for a moment (releasing the microphone). */
  private busyExceptSpeech(): boolean {
    return this.imagePreparing || this.generating || this.executing || this.searchBusy || this.draft !== undefined || this.runtimeChat.busy ||
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
  private headerStatus(): string {
    if (this.headerConnected()) { return '休比 · 已连接'; }
    if (this.connecting || this.sessionState() === ShuviRuntimeState.STARTING) { return '休比 · 连接中'; }
    return this.deepSeekStatus === DeepSeekKeyStatus.Missing ? '休比 · 未设置 Key' : '休比 · 未连接';
  }
  private composerHint(): string {
    return this.realChatMode ? (this.knowledgeEnabled ? '已授权个人知识库 · 按需查询并展示来源' :
      (this.searchEnabled ? '联网搜索 · 每次搜索前会征求你的同意' : '可提问、安排日程、写文档，也能发图片；日程创建前会让你确认')) :
      (this.searchEnabled ? '演示模式 · 固定样例，未联网' : '演示模式 · 数据仅本次有效');
  }

  private async send(): Promise<void> {
    if (this.imageDraftUri.length > 0) { await this.sendImage(); return; }
    if (this.voiceDraft !== undefined) { await this.sendVoice(); return; }
    if (this.blocked() || this.input.trim().length === 0 || this.input.length > 500) {
      return;
    }
    this.searchVoiceQuery = false; this.knowledgeVoiceQuery = false;
    if (this.realChatMode) {
      if (this.searchEnabled) {
        if (this.runtimeSearch.lifecycle !== ShuviRuntimeState.READY || !this.runtimeSearch.allowance) {
          this.notice('联网搜索暂不可用', this.runtimeSearch.message); return;
        }
        const query = this.input.trim(); this.input = ''; void RuntimeSearchService.session.send(query); return;
      }
      if (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY) {
        this.notice('助手还没有连接', (this.deepSeekStatus === DeepSeekKeyStatus.Saved ? '请稍候片刻再发送。' :
          '请先在「我的 → API Key 管理」保存 DeepSeek Key。') + '本次没有发送，内容保留在输入框。'); return;
      }
      if (this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
        this.notice('这段对话已经很长了', '请点右上角「开始新对话」继续。本次没有发送，内容保留在输入框。'); return;
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
    if (this.busyExceptSpeech()) {
      return;
    }
    this.inputController.stopEditing();
    // The current conversation stays under 历史对话 in the menu; nothing is deleted, so no confirmation is needed.
    this.resetConversation();
  }

  private resetConversation(): void {
    // Checked before cancelling speech: the cancel itself reports busy while the microphone is released.
    if (this.busyExceptSpeech()) {
      return;
    }
    void SpeechService.session.cancel();
    RuntimeSearchService.session.clearConversation();
    RuntimeKnowledgeService.session.clearConversation();
    // Keeps the previous conversation saved and starts one with empty model memory; no session restart is needed.
    RuntimeChatService.conversations.startNew();
    RuntimeChatService.session.context.clear();
    this.service.cancel(this.requestId);
    this.searchSession.cancel();
    this.searchTurns = [];
    this.searchBusy = false;
    this.searchScenario = SearchScenario.Normal;
    this.requestId = '';
    this.operationId = '';
    this.showMessages([]);
    this.input = ''; this.voiceDraft = undefined; this.voiceText = ''; this.discardImage();
    this.searchVoiceQuery = false; this.knowledgeVoiceQuery = false;
    this.result = undefined;
    this.requestState = RequestState.Unsupported;
    this.scenario = DemoScenario.Normal;
    this.changeTab(0);
  }

  /** Opens a saved conversation from the menu: its messages come back and the model remembers it again. */
  private async openConversation(id: string): Promise<void> {
    if (this.blocked()) { this.notice('请稍候', '等这次回答完成后再切换对话。'); return; }
    this.drawerOpen = false;
    if (id === this.conversations.currentId) { this.changeTab(0); return; }
    SpeechService.session.cancel();
    this.inputController.stopEditing();
    this.discardImage(); this.voiceDraft = undefined; this.voiceText = '';
    RuntimeKnowledgeService.session.clearConversation();
    RuntimeChatService.session.context.clear();
    const restored: ChatMessage[] | undefined = await RuntimeChatService.conversations.switchTo(id);
    if (!this.alive) return;
    this.showMessages(restored === undefined ? [] : restored);
    if (restored === undefined) this.notice('打不开这段对话', '它可能已被删除，已为你开始一段新对话。');
    this.changeTab(0);
  }

  private deleteConversation(item: ConversationSummary): void {
    if (this.blocked() && item.id === this.conversations.currentId) {
      this.notice('请稍候', '等这次回答完成后再删除当前对话。'); return;
    }
    this.getUIContext().showAlertDialog({
      title: '删除这段对话？',
      message: `「${item.title}」的聊天记录和休比对这段对话的记忆都会删除，无法恢复。已创建的日程和文档不受影响。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { void this.removeConversation(item.id); } }
    });
  }
  private async removeConversation(id: string): Promise<void> {
    const current: boolean = id === this.conversations.currentId;
    if (current && this.blocked()) { this.notice('请稍候', '等这次回答完成后再删除当前对话。'); return; }
    if (current) { RuntimeKnowledgeService.session.clearConversation(); RuntimeChatService.session.context.clear(); }
    const wasCurrent: boolean = await RuntimeChatService.conversations.remove(id);
    if (wasCurrent && this.alive) {
      this.showMessages([]); this.discardImage(); this.voiceDraft = undefined; this.voiceText = '';
    }
  }
  private conversationTime(time: number): string {
    const date: Date = new Date(time); const now: Date = new Date();
    const pad = (value: number): string => (value < 10 ? '0' : '') + value;
    if (date.toDateString() === now.toDateString()) return `今天 ${pad(date.getHours())}:${pad(date.getMinutes())}`;
    return date.getFullYear() === now.getFullYear() ? `${date.getMonth() + 1}月${date.getDate()}日` :
      `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
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
            Text(this.realChatMode ? this.headerStatus() : '休比 · 演示')
              .fontSize(12).fontColor(Theme.ink)
          }.padding({ left: 10, right: 12, top: 5, bottom: 5 }).backgroundColor(Theme.soft).borderRadius(20)
            .id('chat-header-status')
        } else if (this.tab === 1 || this.tab === 2) {
          Text(this.tab === 1 ? '系统日历' : '本机资料').fontSize(11).fontColor(Theme.muted)
            .padding({ left: 9, right: 9, top: 5, bottom: 5 }).backgroundColor(Theme.soft).borderRadius(20)
        }
      }.width('34%')
      Row() {
        Button({ type: ButtonType.Circle }) {
          AppIcon({ source: $r('app.media.chat_menu'), size: 24 })
        }.width(44).height(44).backgroundColor(Theme.surface)
          .shadow({ radius: 16, color: Theme.shadow, offsetY: 3 })
          .visibility(this.wideLayout ? Visibility.Hidden : Visibility.Visible)
          .accessibilityText('打开导航菜单').id('chat-menu')
          .onClick(() => {
            this.inputController.stopEditing();
            this.drawerOpen = true;
          })
        Blank()
        if (this.tab === 0) {
        Row() {
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
            if (message.image !== undefined || message.imageMissing === true) {
              Column({ space: 6 }) {
                if (message.image !== undefined) {
                  Image(message.image).width(180).constraintSize({ maxHeight: 240 }).objectFit(ImageFit.Cover)
                    .borderRadius(16).border({ width: 1, color: Theme.line }).accessibilityText('你发送的图片')
                } else {
                  // Restored conversations never contain the picture itself.
                  Row({ space: 6 }) {
                    AppIcon({ source: $r('app.media.ui_image'), size: 18 })
                    Text('图片（原图未保存）').fontSize(13).fontColor(Theme.muted)
                  }.padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor(Theme.soft).borderRadius(14)
                    .accessibilityText('你曾发送一张图片，原图没有保存')
                }
                if (message.voice !== undefined) {
                  VoiceMessageBubble({ recording: message.voice, playingId: this.voicePlayingId,
                    onPlay: (clip: VoiceClip): void => this.playVoice(clip) })
                }
                if (message.text.length > 0) {
                  Text(message.text).fontSize(15).fontColor(Theme.ink).padding(15)
                    .backgroundColor(Theme.bubble).borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 6 })
                    .accessibilityText(`你：${message.text}`)
                }
              }.constraintSize({ maxWidth: '92%' }).alignItems(HorizontalAlign.End)
            } else if (message.voice !== undefined) {
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
              AssistantReplyBubble({ reply: this.assistantReply(message),
                onOpenSource: (source: ChatKnowledgeSource): void => { void this.openChatKnowledgeSource(source); } })
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
    if (this.imageDraft !== undefined) { await this.sendImage(); return; }
    const clip = this.voiceDraft; const transcript = this.voiceText; const supplement = this.input;
    const text = composeVoiceMessage(transcript, supplement);
    if (clip === undefined || this.blocked() || text.length === 0 || text.length > 500) return;
    if (!this.realChatMode) { this.notice('请先启用真实对话', '录音已保存在本机。启用助手后可发送语音消息，转写不会显示。'); return; }
    if (this.searchEnabled && (this.runtimeSearch.lifecycle !== ShuviRuntimeState.READY || !this.runtimeSearch.allowance)) {
      this.notice('真实搜索尚不可用', '录音已保存，请先准备搜索会话。'); return;
    }
    if (!this.searchEnabled && (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY ||
      this.runtimeChat.requestCount >= this.runtimeChat.maxRequests)) {
      if (this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
        this.notice('这段对话已经很长了', '录音已保存，点右上角「开始新对话」后再发送。'); return;
      }
      this.notice('助手还没有连接', '录音已保存。请稍候再发送；如果还没保存 DeepSeek Key，请先到「我的 → API Key 管理」保存。'); return;
    }
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: true, text: supplement.trim(), voice: clip };
    this.messages = this.messages.concat([message]); this.voiceDraft = undefined; this.voiceText = ''; this.input = '';
    this.hiddenVoiceQueries.add(text);
    this.searchVoiceQuery = this.searchEnabled; this.knowledgeVoiceQuery = this.knowledgeEnabled && !this.searchEnabled;
    try {
      if (this.searchEnabled) { await RuntimeSearchService.session.send(text); }
      else { await RuntimeChatService.session.send(text); }
    } catch {
      if (this.alive) {
        this.messages = this.messages.filter((item: ChatMessage): boolean => item.id !== message.id);
        if (this.voiceDraft === undefined && this.input.length === 0) {
          this.voiceDraft = clip; this.voiceText = transcript; this.input = supplement;
        }
        this.notice('本次语音消息未确认接收', '草稿已保留；请核对会话状态后重试。');
      }
    }
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private async pickImage(fromFiles: boolean): Promise<void> {
    if (this.blocked()) return;
    if (!this.realChatMode || this.searchEnabled || this.knowledgeEnabled) {
      this.notice('图片只能在普通对话里发送', '请先关闭联网搜索或知识库，再添加图片。'); return;
    }
    this.inputController.stopEditing();
    let uri: string = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (fromFiles && context === undefined) throw new Error('NO_CONTEXT');
      uri = fromFiles && context !== undefined ? await AssistantImageInput.pickFile(context) : await AssistantImageInput.pick();
    } catch { this.notice(fromFiles ? '没能打开文件选择' : '没能打开图库', '请稍后再试。'); return; }
    if (uri.length === 0 || !this.alive) return;
    this.imagePreparing = true;
    try {
      const image: VisionChatImage = await AssistantImageInput.prepare(uri);
      if (!this.alive) { image.bytes.fill(0); return; }
      this.discardImage(); this.imageDraft = image; this.imageDraftUri = uri;
    } catch (error) {
      this.notice('这张图片不能发送', AssistantImageInput.failureText(error as Object));
    } finally { this.imagePreparing = false; }
  }

  private discardImage(): void {
    this.imageDraft?.bytes.fill(0); this.imageDraft = undefined; this.imageDraftUri = '';
  }

  /** Image + optional voice + optional text in one assistant turn; the transcript stays hidden as in sendVoice. */
  private async sendImage(): Promise<void> {
    const image: VisionChatImage | undefined = this.imageDraft; const uri: string = this.imageDraftUri;
    const clip: VoiceClip | undefined = this.voiceDraft; const transcript: string = this.voiceText; const supplement: string = this.input;
    if (image === undefined || this.blocked() || (clip !== undefined && transcript.trim().length === 0)) return;
    const spoken: string = clip === undefined ? supplement.trim() : composeVoiceMessage(transcript, supplement);
    if (spoken.length > 500) return;
    if (!this.realChatMode || this.searchEnabled || this.knowledgeEnabled) {
      this.notice('图片只能在普通对话里发送', '请先关闭联网搜索或知识库；图片和文字都还在输入框里。'); return;
    }
    if (this.runtimeChat.lifecycle !== ShuviRuntimeState.READY) {
      this.notice('助手还没有连接', (this.deepSeekStatus === DeepSeekKeyStatus.Saved ? '请稍候片刻再发送。' :
        '请先在「我的 → API Key 管理」保存 DeepSeek Key。') + '本次没有发送，图片和文字都保留着。'); return;
    }
    if (this.runtimeChat.requestCount >= this.runtimeChat.maxRequests) {
      this.notice('这段对话已经很长了', '请点右上角「开始新对话」继续。本次没有发送。'); return;
    }
    const message: ChatMessage = { id: this.service.nextId('message'), isUser: true, text: supplement.trim(), voice: clip, image: uri };
    this.messages = this.messages.concat([message]);
    // The session takes ownership of the bytes (it zeroes them after the turn); the composer only forgets them.
    this.imageDraft = undefined; this.imageDraftUri = ''; this.voiceDraft = undefined; this.voiceText = ''; this.input = '';
    this.inputController.stopEditing();
    if (clip !== undefined) { this.hiddenVoiceQueries.add(spoken); }
    await RuntimeChatService.session.send(spoken.length > 0 ? spoken : ASSISTANT_IMAGE_DEFAULT_PROMPT, image);
    this.scroller.scrollEdge(Edge.Bottom);
  }

  @Builder
  voiceArchivePanel() {
    Column({ space: 8 }) {
      // The saved-recordings row only appears once there is something to list.
      if (this.voiceArchive.length > 0 || this.voiceArchiveOpen) {
        Row() {
          Button(this.voiceArchiveOpen ? '收起录音' : `已保存语音 · ${this.voiceArchive.length}`)
            .height(44).fontSize(12).fontColor(Theme.accent).backgroundColor(Color.Transparent).id('voice-archive-toggle')
            .enabled(!this.speech.busy).onClick((): void => { this.refreshVoiceArchive(); this.voiceArchiveOpen = !this.voiceArchiveOpen; })
          Blank()
          if (this.voiceArchiveOpen) { Text('仅本机保存').fontSize(11).fontColor(Theme.muted) }
        }.width('100%')
      }
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
      if (this.input.length === 0 && this.voiceDraft === undefined && this.imageDraftUri.length === 0 && !this.blocked()) {
        Row({ space: 6 }) {
          Text('试试').fontSize(Theme.noteSize).fontColor(Theme.muted)
          Text(this.sampleText()).fontSize(13).fontColor(Theme.accent).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 }).backgroundColor(Theme.soft).borderRadius(18)
          .id('chat-sample').accessibilityText(`填入示例：${this.sampleText()}`).onClick(() => this.useSample())
      }
      Column({ space: 6 }) {
        if (this.imagePreparing) {
          Row({ space: 8 }) {
            LoadingProgress().width(20).height(20).color(Theme.accent)
            Text('正在处理图片（去掉位置等信息并压缩）…').fontSize(12).fontColor(Theme.muted).layoutWeight(1)
          }.width('100%').padding({ left: 6, right: 6 }).id('chat-image-preparing')
        } else if (this.imageDraftUri.length > 0) {
          Row({ space: 10 }) {
            Image(this.imageDraftUri).width(56).height(56).objectFit(ImageFit.Cover).borderRadius(12)
              .border({ width: 1, color: Theme.line }).accessibilityText('待发送的图片')
            Column({ space: 2 }) {
              Text('图片 · 发送时一起交给助手').fontSize(13).fontColor(Theme.ink)
              Text('只发送压缩后的图片内容，不含文件名和位置信息').fontSize(11).fontColor(Theme.muted)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Button('移除').height(44).fontSize(12).fontColor(Theme.muted).backgroundColor(Color.Transparent)
              .id('chat-image-remove').enabled(!this.blocked()).accessibilityText('移除待发送的图片')
              .onClick((): void => this.discardImage())
          }.width('100%').padding({ left: 4 }).id('chat-image-draft')
        }
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
        TextArea({ text: this.input, placeholder: this.voiceDraft !== undefined ? '补充文字（可选），和语音一起发送…' :
          (this.imageDraftUri.length > 0 ? '想让我看什么？也可以直接发送…' : '发消息，或说说你的想法…'), controller: this.inputController })
          .fontSize(Theme.bodySize).fontColor(Theme.ink).placeholderColor(Theme.muted).backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 40, maxHeight: 120 }).width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
          .enabled(!this.blocked()).onChange((value: string) => this.input = value)
          .accessibilityText(this.voiceDraft === undefined ? '写下想做的事，最多 500 字' :
            '补充文字，与语音合计最多 500 字；转写内容不显示').id('chat-input')
        Row({ space: 6 }) {
          ModeChip({ icon: $r('app.media.chat_globe'), label: '搜索', on: this.searchEnabled, disabled: this.blocked(),
            chipId: 'chat-search-toggle',
            a11y: `联网搜索，${this.searchEnabled ? '已开启，点击关闭' : '已关闭，点击开启'}`,
            onTap: (): void => { void this.toggleSearch(); } })
          ModeChip({ icon: $r('app.media.chat_book'), label: this.ragPreparing ? '准备中…' : (ResponsiveLayoutPolicy.compactActions(this.contentWidth) ? '知识库授权' : '允许使用个人知识库'), on: this.knowledgeEnabled,
            disabled: this.blocked() && !this.knowledgeEnabled, chipId: 'chat-knowledge-toggle',
            a11y: `个人知识库授权，${this.ragPreparing ? '正在只读恢复' : (this.knowledgeEnabled ? '已允许按需使用，点击撤销' : '未授权，点击允许读取及已说明的查询与片段外发')}`,
            onTap: (): void => { void this.toggleKnowledge(); } })
          Blank()
          Row({ space: 2 }) {
            if (this.realChatMode && this.imageDraftUri.length === 0) {
              Button({ type: ButtonType.Circle }) {
                AppIcon({ source: $r('app.media.ui_image'), size: 24 })
              }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('添加一张图片发给助手：从图库或文件中选择')
                .id('chat-image').enabled(!this.blocked())
                .bindMenu([
                  { value: '从图库选择', action: (): void => { void this.pickImage(false); } },
                  { value: '从文件选择', action: (): void => { void this.pickImage(true); } }
                ])
            }
            if (this.input.trim().length === 0 && this.voiceDraft === undefined) {
              Button({ type: ButtonType.Circle }) {
                AppIcon({ source: $r('app.media.ui_microphone'), size: 24 })
              }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText('开始普通话语音输入')
                .id('chat-speech').enabled(!this.blocked()).onClick(() => this.startSpeech())
            }
            if (this.input.trim().length > 0 || this.voiceDraft !== undefined || this.imageDraftUri.length > 0) {
              Button({ type: ButtonType.Circle }) {
                AppIcon({ source: $r('app.media.chat_up'), size: 22})
              }.width(44).height(44).backgroundColor(Theme.accent).accessibilityText('发送消息').id('chat-send')
                .enabled(!this.blocked() && this.composerLength() <= 500 &&
                  (this.voiceDraft === undefined || this.voiceText.trim().length > 0)).onClick(() => this.send())
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
    }.padding({ left: 12, right: 12, top: 8, bottom: 12 }).width('100%').constraintSize({ maxWidth: this.contentLimit() }).backgroundColor(Theme.surface)
  }

  @Builder
  conversationList() {
    Column({ space: 4 }) {
      Row() {
        Text('历史对话').fontSize(13).fontColor(Theme.muted).layoutWeight(1)
        Button('新对话').height(44).fontSize(12).fontColor(Theme.accent).backgroundColor(Color.Transparent)
          .id('drawer-new-conversation').enabled(!this.blocked())
          .onClick(() => { this.drawerOpen = false; this.newConversation(); })
      }.width('100%').padding({ left: 6, top: 16 })
      if (this.conversations.message.length > 0) {
        Text(this.conversations.message).fontSize(12).fontColor(Theme.amber).width('100%').padding({ left: 6, right: 6 })
      }
      if (this.conversations.list.length === 0) {
        Text(this.conversations.ready ? '还没有保存的对话' : '对话记录准备中…').fontSize(12).fontColor(Theme.muted)
          .width('100%').padding({ left: 6, top: 4 })
      }
      ForEach(this.conversations.list, (item: ConversationSummary) => {
        Row({ space: 4 }) {
          Column({ space: 2 }) {
            Text(item.title).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(item.id === this.conversations.currentId ? Theme.accent : Theme.ink)
            Text(this.conversationTime(item.updatedAt)).fontSize(11).fontColor(Theme.muted)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            AppIcon({ source: $r('app.media.ui_close'), size: 14 })
          }.width(44).height(44).backgroundColor(Color.Transparent).accessibilityText(`删除对话：${item.title}`)
            .onClick(() => this.deleteConversation(item))
        }.width('100%').padding({ left: 14, right: 2, top: 4, bottom: 4 }).constraintSize({ minHeight: 52 }).borderRadius(15)
          .backgroundColor(item.id === this.conversations.currentId ? Theme.soft : Color.Transparent)
          .accessibilityText(`${item.title}，${this.conversationTime(item.updatedAt)}${item.id === this.conversations.currentId ? '，当前对话' : ''}`)
          .onClick(() => { void this.openConversation(item.id); })
      }, (item: ConversationSummary) => item.id + ':' + item.updatedAt + ':' + item.title)
    }.width('100%').id('drawer-conversations')
  }

  @Builder
  navigationDrawer() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 6 }) {
          Text('Shuvi 休比').fontSize(22).fontWeight(FontWeight.Medium).fontColor(Theme.ink)
          Text('个人助理').fontSize(12).fontColor(Theme.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          AppIcon({ source: $r('app.media.ui_close'), size: 22 })
        }.width(44).height(44)
          .backgroundColor(Color.Transparent).visibility(this.wideLayout ? Visibility.Hidden : Visibility.Visible).accessibilityText('关闭导航菜单')
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
              }.width('100%').padding(14).constraintSize({ minHeight: 52 })
            }.width('100%').borderRadius(15).backgroundColor(this.tab === index ? Theme.soft : Color.Transparent)
              .id('drawer-tab-' + index.toString())
              .accessibilityText(`${name}${this.tab === index ? '，已选中' : ''}`).onClick(() => this.changeTab(index))
          }, (name: string) => name)
          if (this.realChatMode) {
            this.conversationList()
          }
        }.width('100%')
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
      Text('资料和 API Key 只保存在本机').fontSize(11).fontColor(Theme.muted)
        .width('100%').padding({ top: 16 })
    }.width('100%').height('100%').padding({ left: 18, right: 18, top: 28, bottom: 24 })
      .backgroundColor(Theme.inputSurface).borderRadius({ topRight: this.wideLayout ? 0 : 26, bottomRight: this.wideLayout ? 0 : 26 })
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
            if (this.apiKeysOpen) {
              if (this.apiKeysReady) {
                ApiKeysView({ embedding: this.embeddingService, parse: this.parseService, parseCredential: this.parseState.credential,
                  settings: this.sharedKnowledge?.unifiedSettings,
                  onBack: (): void => { this.apiKeysOpen = false; this.scroller.scrollEdge(Edge.Top); },
                  onDeepSeekChanged: (): void => { void this.refreshDeepSeekStatus(); } })
              } else {
                LoadingProgress().width(32).height(32).color(Theme.accent).margin({ top: 48 })
              }
            } else if (this.migrationOpen) {
              KnowledgeMigrationView({migration:this.sharedKnowledge?.migration,queue:this.sharedKnowledge?.unifiedQueue,vectors:this.sharedKnowledge?.unifiedVectors,onBack:(): void=> { this.migrationOpen=false; }})
            } else if (this.visionSettingsOpen) {
              VisionSettingsView({service:this.sharedKnowledge?.unifiedSettings,queue:this.sharedKnowledge?.unifiedQueue,onBack:(): void=> { this.visionSettingsOpen=false; this.scroller.scrollEdge(Edge.Top); },
                onKeys: (): void => { this.openApiKeys(); }})
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
          } else if (this.showScenarios) {
            this.scenarioPanel()
           } else if (this.pdfIngestionOpen) {
             if (this.pdfIngestionService !== undefined) {
               PdfIngestionView({ service: this.pdfIngestionService, lifecycle: this.derivedLifecycle, onBack: (): void => { this.pdfIngestionOpen = false; } })
             } else { Text('PDF 准备服务尚未就绪，原件和 ZIP 保留').width('100%') }
           } else if (this.embeddingOpen) {
             if (this.embeddingService !== undefined) {
                EmbeddingSettingsView({ service: this.embeddingService, unifiedSettings:this.sharedKnowledge?.unifiedSettings, clearEpoch: this.embeddingClearEpoch, onBack: (): void => { this.closeEmbedding(); },
                  onKeys: (): void => { this.openApiKeys(); } })
             } else {
               Text('本机配置服务尚未就绪或不可用，未发送请求').width('100%')
               Button('返回').onClick((): void => { this.closeEmbedding(); })
             }
           } else if (this.parseOpen) {
             if (this.parseService !== undefined) {
               DocumentParseView({ parseState: this.parseState, service: this.parseService,
                 settingsMode: this.parseSettings, clearEpoch: this.parseState.inputEpoch,
                   onClose: (): void => { this.closeParse(); }, onPreparePdf: (resultId: string): void => { this.preparePdf(resultId); },
                    onPrepareImage: (resultId: string): void => { this.prepareImage(resultId); }, onOpenImages: (): void => { this.closeParse(); this.openImages(); }, onOpenDocx: (): void => { this.closeParse(); this.openDocx(); },
                    onKeys: (): void => { this.openApiKeys(); } })
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
            if (this.calendarOpen) {
              this.calendar()
            } else {
              CalendarCapabilityCheck({ onKeys: (): void => { this.openApiKeys(); } })
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
             ProfilePage({ floatingAssistantEnabled: this.floatingAssistantEnabled,
               onFloatingAssistantChange: (enabled: boolean): void => { this.floatingAssistantEnabled = enabled; }, onNotice: (title: string, message: string) => this.notice(title, message),
               onApiKeys: (): void => { this.openApiKeys(); },
               onVisionSettings: (): void => { this.openVisionSettings(); },
               onParseSettings: (): void => { this.openParse(true); }, onEmbeddingSettings: (): void => { this.openEmbedding(); } })
          }
        }.width('100%').constraintSize({ maxWidth: this.contentLimit(),
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
    Stack({ alignContent: Alignment.TopStart }) {
      SideBarContainer(this.wideLayout ? SideBarContainerType.Embed : SideBarContainerType.Overlay) {
        Column() {
          this.navigationDrawer()
        }
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            this.pageContent()
          }.width('100%').height('100%').enabled(this.wideLayout || !this.drawerOpen)
            .accessibilityLevel(!this.wideLayout && this.drawerOpen ? 'no-hide-descendants' : 'auto')
          if (this.floatingAssistantEnabled && this.floatingPlacement.canPlace &&
            this.tab !== 0 && !this.showScenarios && (this.wideLayout || !this.drawerOpen)) {
            this.floatingAssistant()
          }
          if (!this.wideLayout && this.drawerOpen) {
            Button({ type: ButtonType.Normal }) {
              Row().width('100%').height('100%')
            }.width('100%').height('100%').backgroundColor(Theme.overlay).borderRadius(0)
              .accessibilityText('关闭导航菜单').onClick(() => this.drawerOpen = false)
          }
        }.width('100%').height('100%')
          .onAreaChange((_oldArea: Area, area: Area) => this.resizeFloatingHost(Number(area.width), Number(area.height)))
      }.width('100%').height('100%').showSideBar(this.wideLayout || this.drawerOpen).showControlButton(false)
        .sideBarWidth(this.wideLayout ? ResponsiveLayoutPolicy.sideWidth(this.windowWidth) : '84%')
        .minSideBarWidth(this.wideLayout ? 240 : 200).maxSideBarWidth(this.wideLayout ? 280 : 320).minContentWidth(0)
        .divider({ strokeWidth: this.wideLayout ? 1 : 0, color: Theme.line })
        .onChange((visible: boolean): void => { if (!this.wideLayout) { this.drawerOpen = visible; } })
        .backgroundColor(Theme.paper)
      // One Web surface above BOTH navigation and content; responsive sidebar changes never recreate the engine.
      PdfJsSurface()
    }.width('100%').height('100%').id('responsive-shell')
      .onAreaChange((_oldArea: Area, area: Area): void => { this.resizeWindow(Number(area.width)); })
      .backgroundColor(Theme.paper)
  }
}
