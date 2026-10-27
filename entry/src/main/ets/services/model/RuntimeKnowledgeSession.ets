import { AgentRuntimeEventType, AgentTaskStatus } from '@harmony_agent/agent-contracts';
import {
  AgentFrontendAuthorizationPrompt, AgentFrontendClarificationPrompt, AgentFrontendEvent, AgentFrontendEventListener,
  AgentFrontendSubscription, AgentFrontendTaskRequest
} from '@harmony_agent/agent-runtime';
import {
  KnowledgeRagReadiness, KnowledgeRagSearchPort, KnowledgeRuntimeCitation, KnowledgeRuntimeSearchRequest,
  KnowledgeRuntimeSearchResult
} from '../../knowledge/domain/KnowledgeRuntimePorts';
import { ParsedCancellation } from '../../knowledge/domain/ParsedDocumentModels';
import { KnowledgeAnswerContext, parseKnowledgeAnswer, parseKnowledgeInsufficient } from './KnowledgeAnswerTaskSupport';
import { KNOWLEDGE_RUNTIME_TOOL_ID, parseKnowledgeToolResult } from './KnowledgeTaskSupport';
import { ShuviRuntimeController, ShuviRuntimeState } from './ShuviRuntimeController';
import { ShuviRuntimeSessionFactory } from './ShuviRuntimeSession';

export class RuntimeKnowledgeView {
  lifecycle: ShuviRuntimeState = ShuviRuntimeState.IDLE;
  busy: boolean = false;
  stage: string = 'idle';
  message: string = '尚未启用本机知识库检索。';
  query: string = '';
  answer: string = '';
  citations: KnowledgeRuntimeCitation[] = [];
  consent: boolean = false;
  clearEpoch: number = 0;
}
class KnowledgeListener implements AgentFrontendEventListener {
  private readonly owner: RuntimeKnowledgeSession; private readonly generation: number; private readonly answering: boolean;
  constructor(owner: RuntimeKnowledgeSession, generation: number, answering: boolean) {
    this.owner = owner; this.generation = generation; this.answering = answering;
  }
  onEvent(event: AgentFrontendEvent): void { this.owner.event(this.generation, this.answering, event); }
  onAuthorizationRequired(prompt: AgentFrontendAuthorizationPrompt): void {
    this.owner.authorization(this.generation, this.answering, prompt);
  }
  onClarificationRequired(_prompt: AgentFrontendClarificationPrompt): void { this.owner.unexpected(this.generation); }
}

/** Two bounded tasks: local retrieval first, then a consent-gated PERSONAL DeepSeek answer. */
export class RuntimeKnowledgeSession {
  readonly knowledge: ShuviRuntimeController = new ShuviRuntimeController();
  readonly answer: ShuviRuntimeController = new ShuviRuntimeController();
  readonly answerContext: KnowledgeAnswerContext = new KnowledgeAnswerContext();
  private view: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  private listener?: (view: RuntimeKnowledgeView) => void;
  private generation: number = 0; private taskId: string = ''; private sequence: number = 0;
  private subscription?: AgentFrontendSubscription; private timer?: number; private stopping: boolean = false;
  private consentGranted: boolean = false; private answering: boolean = false; private localOnly: boolean = false;
  private modelTaskDispatched: boolean = false; private cancelRequested: boolean = false;
  private rag: KnowledgeRagSearchPort | undefined = undefined;
  private ragCancel: ParsedCancellation | undefined = undefined;
  private ragPrepared: boolean = false;

  attach(listener: (view: RuntimeKnowledgeView) => void): void { this.listener = listener; this.publish(); }
  detach(): void { this.listener = undefined; void this.stop(); }
  snapshot(): RuntimeKnowledgeView { return copyRuntimeKnowledgeView(this.view); }
  clearConversation(): void {
    if (this.view.busy) { return; }
    this.answerContext.clear(); this.view.query = ''; this.view.answer = ''; this.view.citations = [];
    this.view.stage = 'idle'; this.publish();
  }
  private publish(): void { this.listener?.(this.snapshot()); }
  private active(generation: number): boolean {
    return this.generation === generation && this.view.busy && !this.stopping &&
      (this.consentGranted || this.localOnly);
  }
  onForeground(): void { this.knowledge.onForeground(); this.answer.onForeground(); }
  async onBackground(): Promise<void> {
    await this.stop(); await this.knowledge.onBackground(); await this.answer.onBackground();
  }
  async onDestroy(): Promise<void> { await this.onBackground(); }

  /** Prepares the PERSONAL answer session without sending a question or granting RAG query egress. */
  async prepareRag(search: KnowledgeRagSearchPort, answerFactory: ShuviRuntimeSessionFactory,
    key: Uint8Array): Promise<void> {
    if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.READY ||
      this.view.lifecycle === ShuviRuntimeState.BLOCKED || this.stopping || this.rag !== undefined) {
      key.fill(0); return;
    }
    const generation: number = ++this.generation; this.rag = search; this.ragPrepared = false;
    this.consentGranted = false; this.localOnly = false; this.answering = false;
    this.modelTaskDispatched = false; this.cancelRequested = false;
    this.view.consent = false; this.view.stage = 'starting'; this.view.lifecycle = ShuviRuntimeState.STARTING;
    this.view.clearEpoch++; this.view.message = '正在准备知识库 RAG 会话…'; this.publish();
    try {
      await search.open();
      if (generation !== this.generation) { return; }
      await this.answer.start(answerFactory, key);
      if (generation !== this.generation) { return; }
      this.ragPrepared = true; this.answerContext.clear();
      this.view.query = ''; this.view.answer = ''; this.view.citations = [];
      this.view.lifecycle = ShuviRuntimeState.READY;
      this.view.message = '知识库 RAG 后端已准备；开启知识库后才允许问题向量化和资料整理。';
      this.publish();
    } catch {
      if (generation === this.generation) {
        let closeFailed: boolean = false;
        try { await search.close(); } catch { closeFailed = true; }
        try { await this.answer.stop(); } catch { closeFailed = true; }
        this.rag = undefined; this.ragPrepared = false; this.view.consent = false;
        this.view.lifecycle = closeFailed || this.answer.lifecycleState() === ShuviRuntimeState.BLOCKED ?
          ShuviRuntimeState.BLOCKED : ShuviRuntimeState.FAILED;
        this.view.message = closeFailed ? 'RAG 准备失败且资源关闭未确认，请重启应用排查。' :
          '知识库 RAG 准备失败；普通对话仍可继续。';
        this.view.clearEpoch++; this.publish();
      }
    } finally { key.fill(0); }
  }

  async activateRag(): Promise<KnowledgeRagReadiness> {
    const unavailable: KnowledgeRagReadiness = new KnowledgeRagReadiness();
    if (!this.ragPrepared || this.rag === undefined || this.view.lifecycle !== ShuviRuntimeState.READY) {
      unavailable.code = 'RagSessionUnavailable'; unavailable.message = '知识库 RAG 会话尚未准备好。';
      this.consentGranted = false; this.view.consent = false; this.view.message = unavailable.message; this.publish();
      return unavailable;
    }
    const generation: number = this.generation; const rag: KnowledgeRagSearchPort = this.rag;
    const readiness: KnowledgeRagReadiness = await rag.readiness();
    if (generation !== this.generation || this.rag !== rag || !this.ragPrepared || this.stopping ||
      this.view.lifecycle !== ShuviRuntimeState.READY) {
      unavailable.code = 'RagSessionChanged'; unavailable.message = '知识库 RAG 会话状态已变化，请重新开启。';
      return unavailable;
    }
    this.consentGranted = readiness.ready; this.view.consent = readiness.ready;
    this.view.message = readiness.message; this.publish(); return readiness;
  }

  async deactivateRag(): Promise<void> {
    if (this.view.busy) { await this.cancelCurrent(); }
    else { ++this.generation; }
    this.consentGranted = false; this.view.consent = false; this.answerContext.clear();
    if (this.ragPrepared && this.view.lifecycle === ShuviRuntimeState.READY) {
      this.view.message = '知识库 RAG 已关闭；普通 DeepSeek 对话仍保持就绪。';
    }
    this.publish();
  }

  async start(toolFactory: ShuviRuntimeSessionFactory, answerFactory: ShuviRuntimeSessionFactory,
    key: Uint8Array, consent: boolean): Promise<void> {
    if (!consent) {
      key.fill(0);
      if (this.view.lifecycle === ShuviRuntimeState.READY || this.view.lifecycle === ShuviRuntimeState.STARTING) {
        await this.stop();
      } else {
        this.view.consent = false;
        this.view.message = '未同意数据发送范围，未启用知识库问答。'; this.publish();
      }
      return;
    }
    if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.READY ||
      this.view.lifecycle === ShuviRuntimeState.BLOCKED || this.stopping || this.rag !== undefined) {
      key.fill(0); return;
    }
    const generation: number = ++this.generation; const answerKey: Uint8Array = key.slice();
    this.consentGranted = true; this.answering = false; this.localOnly = false; this.modelTaskDispatched = false; this.cancelRequested = false;
    this.view.consent = true; this.view.stage = 'starting'; this.view.lifecycle = ShuviRuntimeState.STARTING;
    this.view.clearEpoch++; this.view.message = '正在打开本机检索与回答会话…'; this.publish();
    try {
      await this.knowledge.start(toolFactory, key);
      if (generation !== this.generation) { return; }
      await this.answer.start(answerFactory, answerKey);
      if (generation !== this.generation) { return; }
      this.answerContext.clear(); this.view.query = ''; this.view.answer = ''; this.view.citations = [];
      this.view.lifecycle = ShuviRuntimeState.READY;
      this.view.message = '已就绪。发送问题后先检索本机片段，再按你同意的范围请求 DeepSeek 回答。';
      this.publish();
    } catch {
      if (generation === this.generation) {
        this.consentGranted = false; this.view.consent = false;
        await this.stop();
        if (this.knowledge.lifecycleState() !== ShuviRuntimeState.BLOCKED &&
          this.answer.lifecycleState() !== ShuviRuntimeState.BLOCKED) {
          this.view.lifecycle = ShuviRuntimeState.FAILED;
          this.view.message = '知识库问答启动失败；没有发送问题或片段，也没有修改资料。';
        } else {
          this.view.lifecycle = ShuviRuntimeState.BLOCKED;
        }
        this.publish();
      }
    } finally { key.fill(0); answerKey.fill(0); }
  }

  /** Legacy page path: local citations only, no model session and no consent. */
  async startLocal(toolFactory: ShuviRuntimeSessionFactory): Promise<void> {
    if (this.view.lifecycle === ShuviRuntimeState.STARTING || this.view.lifecycle === ShuviRuntimeState.READY ||
      this.view.lifecycle === ShuviRuntimeState.BLOCKED || this.stopping || this.rag !== undefined) { return; }
    const generation: number = ++this.generation;
    this.localOnly = true; this.consentGranted = false; this.answering = false; this.modelTaskDispatched = false; this.cancelRequested = false;
    this.view.consent = false; this.view.stage = 'starting'; this.view.lifecycle = ShuviRuntimeState.STARTING;
    this.view.clearEpoch++; this.view.message = '正在打开本机知识库检索会话…'; this.publish();
    const marker: Uint8Array = new Uint8Array([108, 111, 99, 97, 108]);
    try {
      await this.knowledge.start(toolFactory, marker);
      if (generation !== this.generation) { return; }
      this.answerContext.clear(); this.view.query = ''; this.view.answer = ''; this.view.citations = [];
      this.view.lifecycle = ShuviRuntimeState.READY;
      this.view.message = '已就绪。发送问题后只读检索本机当前有效正文，不调用外部模型。'; this.publish();
    } catch {
      if (generation === this.generation) {
        await this.stop();
        if (this.knowledge.lifecycleState() !== ShuviRuntimeState.BLOCKED) {
          this.view.lifecycle = ShuviRuntimeState.FAILED;
          this.view.message = '本机知识库检索启动失败；没有读取结果，也没有修改资料。';
        } else {
          this.view.lifecycle = ShuviRuntimeState.BLOCKED;
        }
        this.publish();
      }
    } finally { marker.fill(0); }
  }

  async stop(): Promise<void> {
    if (this.stopping) { return; }
    if (this.view.lifecycle === ShuviRuntimeState.IDLE &&
      this.knowledge.lifecycleState() === ShuviRuntimeState.IDLE &&
      this.answer.lifecycleState() === ShuviRuntimeState.IDLE) {
      this.clearWatch();
      this.consentGranted = false; this.answering = false; this.localOnly = false; this.modelTaskDispatched = false; this.cancelRequested = false;
      this.answerContext.clear(); this.ragCancel = undefined; this.ragPrepared = false;
      const idleRag: KnowledgeRagSearchPort | undefined = this.rag; this.rag = undefined;
      if (idleRag !== undefined) { try { await idleRag.close(); } catch { this.view.lifecycle = ShuviRuntimeState.BLOCKED; } }
      this.view.consent = false; this.view.clearEpoch++; this.publish(); return;
    }
    const mayBill: boolean = this.modelTaskDispatched;
    this.stopping = true; ++this.generation; this.clearWatch();
    this.consentGranted = false; this.answering = false; this.localOnly = false; this.modelTaskDispatched = false; this.cancelRequested = false;
    this.answerContext.clear(); if (this.ragCancel !== undefined) { this.ragCancel.invalid = true; } this.ragCancel = undefined;
    this.view.consent = false; this.view.busy = false; this.view.clearEpoch++;
    this.view.lifecycle = ShuviRuntimeState.STOPPING; this.view.message = '正在停止并清除凭据…'; this.publish();
    let failed: boolean = false;
    try { await this.knowledge.stop(); } catch { failed = true; }
    try { await this.answer.stop(); } catch { failed = true; }
    const rag: KnowledgeRagSearchPort | undefined = this.rag; this.rag = undefined; this.ragPrepared = false;
    if (rag !== undefined) { try { await rag.close(); } catch { failed = true; } }
    this.stopping = false; this.view.lifecycle = failed ? ShuviRuntimeState.BLOCKED : ShuviRuntimeState.STOPPED;
    this.view.stage = 'stopped';
    this.view.message = failed ? '资源关闭未确认，请重启应用排查；资料未删除。' : (mayBill ?
      '会话已停止；凭据已清除，已显示的引用保留；已发送的模型请求仍可能计费。' :
      '会话已停止；凭据已清除，已显示的引用保留；未发送模型请求。');
    this.publish();
  }

  async send(query: string): Promise<boolean> {
    const value: string = query.trim();
    if (this.view.busy || this.view.lifecycle !== ShuviRuntimeState.READY || (!this.consentGranted && !this.localOnly) ||
      value !== query || !value || value.length > 500) { return false; }
    this.answerContext.clear(); this.view.query = value; this.view.answer = ''; this.view.citations = [];
    this.view.busy = true; this.view.stage = 'retrieving'; this.view.message = '正在检索本机知识库…';
    this.answering = false; this.cancelRequested = false; const generation: number = ++this.generation; this.watch(generation);
    this.publish();
    if (this.ragPrepared && this.rag !== undefined) { void this.retrieveRag(generation, value); }
    else { await this.submit(generation, false); }
    return true;
  }

  private async retrieveRag(generation: number, query: string): Promise<void> {
    const rag: KnowledgeRagSearchPort | undefined = this.rag;
    if (rag === undefined) { this.finish('retrievalFailed', '知识库 RAG 会话不可用；未调用 DeepSeek。'); return; }
    const cancel: ParsedCancellation = new ParsedCancellation(); this.ragCancel = cancel;
    const request: KnowledgeRuntimeSearchRequest = new KnowledgeRuntimeSearchRequest(); request.query = query; request.maxResults = 5;
    try {
      const result: KnowledgeRuntimeSearchResult = await rag.search(request, cancel);
      // The query session invalidates this shared token when it closes, even after success.
      // Generation is the staleness signal: cancel, stop, deactivate and the watchdog all advance it.
      if (!this.active(generation)) { return; }
      this.ragCancel = undefined; this.view.citations = result.citations;
      if (result.route !== 'local-rag') {
        this.finish('retrievalFailed', 'RAG 检索结果类型无效；未调用 DeepSeek。'); return;
      }
      if (result.citations.length === 0) {
        this.finish('empty', '本机正文、标签与向量检索均无可引用结果；未调用 DeepSeek。'); return;
      }
      if (!this.answerContext.freeze(this.view.query, result.citations)) {
        this.finish('retrievalFailed', 'RAG 证据无法安全固定；未调用 DeepSeek。'); return;
      }
      this.view.stage = 'answering'; this.view.message = '本机 RAG 检索完成；正在请求 DeepSeek 整理回答…';
      this.publish(); this.clearWatch(); const next: number = ++this.generation;
      if (!this.active(next)) { return; }
      this.modelTaskDispatched = true; this.answering = true; this.watch(next); void this.submit(next, true);
    } catch {
      if (this.active(generation)) {
        this.ragCancel = undefined;
        this.finish('retrievalFailed', '本机 RAG 检索未完成；没有向 DeepSeek 发送知识片段。');
      }
    }
  }

  private watch(generation: number): void {
    this.timer = setTimeout((): void => { if (this.active(generation)) { void this.stop(); } }, 120000);
  }
  private clearWatch(): void {
    if (this.timer !== undefined) { clearTimeout(this.timer); } this.timer = undefined;
    this.subscription?.close(); this.subscription = undefined;
  }
  private async submit(generation: number, answering: boolean): Promise<void> {
    const controller: ShuviRuntimeController = answering ? this.answer : this.knowledge;
    this.taskId = ''; this.sequence = 0; let submittedTaskId: string = '';
    const request: AgentFrontendTaskRequest = new AgentFrontendTaskRequest(); request.intent = this.view.query;
    try {
      const handle = await controller.submit(request); if (!this.active(generation)) { return; }
      submittedTaskId = handle.taskId; this.taskId = handle.taskId;
      const subscription = await controller.subscribe(handle.taskId, new KnowledgeListener(this, generation, answering), 0);
      if (!this.active(generation) || this.taskId !== handle.taskId) { subscription.close(); return; }
      this.subscription = subscription;
      const state = await controller.getTask(handle.taskId);
      if (this.active(generation) && this.taskId === handle.taskId) {
        this.apply(generation, answering, state.status, state.resultJson);
      }
    } catch {
      if (this.active(generation)) {
        if (submittedTaskId.length > 0) {
          try { await controller.cancel(submittedTaskId); } catch { /* best effort; late events are generation-gated. */ }
        }
        if (this.active(generation)) {
          this.finish(answering ? 'answerFailed' : 'retrievalFailed', answering ?
            'DeepSeek 回答未完成；本机引用已保留，可仅重试回答。' :
            '本机检索未完成；未调用模型，也未修改资料。');
        }
      }
    }
  }

  authorization(generation: number, answering: boolean, prompt: AgentFrontendAuthorizationPrompt): void {
    if (!this.active(generation) || prompt.taskId !== this.taskId) { return; }
    if (answering || prompt.toolId !== KNOWLEDGE_RUNTIME_TOOL_ID || prompt.estimatedCostMicros !== 0) {
      this.unexpected(generation); return;
    }
    try { this.knowledge.authorize(prompt, true).then((receipt): void => {
      if (!this.active(generation) || !receipt.accepted) { this.unexpected(generation); }
    }).catch((): void => { this.unexpected(generation); }); } catch { this.unexpected(generation); }
  }
  unexpected(generation: number): void { if (this.active(generation)) { void this.stop(); } }

  toolOutcomeRejected(taskId: string): void {
    if (this.active(this.generation) && this.taskId === taskId && !this.answering) {
      this.finish('retrievalFailed', '本机检索结果未能可靠保存；未调用模型。');
    }
  }
  answerOutcomeRejected(taskId: string): void {
    if (this.active(this.generation) && this.taskId === taskId) {
      this.finish('answerFailed', 'DeepSeek 回答结果未能可靠保存；本机引用已保留，可仅重试回答。');
    }
  }

  event(generation: number, answering: boolean, event: AgentFrontendEvent): void {
    if (!this.active(generation) || event.taskId !== this.taskId ||
      !Number.isSafeInteger(event.sequence) || event.sequence <= this.sequence) { return; }
    this.sequence = event.sequence;
    if (event.eventType === AgentRuntimeEventType.TASK_COMPLETED) {
      this.apply(generation, answering, AgentTaskStatus.COMPLETED, event.payloadJson);
    } else if (event.eventType === AgentRuntimeEventType.TASK_FAILED) {
      this.apply(generation, answering, AgentTaskStatus.FAILED, event.payloadJson);
    } else if (event.eventType === AgentRuntimeEventType.TASK_CANCELLED) {
      this.apply(generation, answering, AgentTaskStatus.CANCELLED, event.payloadJson);
    }
  }

  private apply(generation: number, answering: boolean, status: AgentTaskStatus, json: string): void {
    if (status === AgentTaskStatus.COMPLETED) {
      if (answering) {
        if (this.cancelRequested) {
          this.finish('answerFailed', '已取消 DeepSeek 回答；本机引用保留，可仅重试回答。'); return;
        }
        const answer = parseKnowledgeAnswer(json, this.view.citations.length);
        if (answer !== undefined) {
          this.view.answer = answer.text;
          this.finish('complete', '本机检索与 DeepSeek 回答均已完成；下方回答不是原始资料。'); return;
        }
        if (parseKnowledgeInsufficient(json) !== undefined) {
          this.view.answer = '';
          this.finish('insufficient', '资料中没有足够依据；本机引用已保留。'); return;
        }
        this.finish('answerFailed', '回答格式或引用编号无效；本机引用已保留，可仅重试回答。');
      } else {
        if (this.view.stage === 'answering') { return; }
        if (this.cancelRequested) {
          const cancelledResult = parseKnowledgeToolResult(json, this.view.query);
          if (cancelledResult !== undefined) { this.view.citations = cancelledResult.citations; }
          this.finish('retrievalFailed', '已取消本机检索；未调用模型。'); return;
        }
        const result = parseKnowledgeToolResult(json, this.view.query);
        if (result === undefined) { this.finish('retrievalFailed', '本机检索结果未通过校验，未调用模型。'); return; }
        this.view.citations = result.citations;
        if (result.citations.length === 0) { this.finish('empty', '本机知识库没有直接正文命中；未调用模型。'); return; }
        if (this.localOnly) {
          this.view.answer = '已找到 ' + result.citations.length.toString() + ' 条本机直接证据。请按编号核对下方原文片段。';
          this.finish('complete', '本机知识库检索已完成；片段未发送给外部模型。');
          return;
        }
        if (!this.answerContext.freeze(this.view.query, result.citations)) {
          this.finish('retrievalFailed', '本机证据无法安全固定，未调用模型。'); return;
        }
        this.subscription?.close(); this.subscription = undefined;
        this.view.stage = 'answering'; this.view.message = '本机检索完成；正在请求 DeepSeek 整理回答…';
        this.publish();
        this.clearWatch(); const next: number = ++this.generation;
        if (!this.active(next)) { return; }
        this.modelTaskDispatched = true; this.answering = true; this.watch(next); void this.submit(next, true);
      }
    } else if (status === AgentTaskStatus.FAILED || status === AgentTaskStatus.CANCELLED) {
      this.finish(answering ? 'answerFailed' : 'retrievalFailed', answering ?
        'DeepSeek 回答失败或已取消；本机引用已保留，可仅重试回答。' :
        '本机检索失败或已取消；未调用模型。');
    }
  }

  private finish(stage: string, message: string): void {
    this.clearWatch(); ++this.generation; this.view.busy = false; this.view.stage = stage;
    this.view.message = message; this.answering = false; this.cancelRequested = false;
    if (stage !== 'answerFailed') { this.answerContext.clear(); }
    this.publish();
  }

  async retryAnswer(): Promise<void> {
    if (this.view.busy || this.view.lifecycle !== ShuviRuntimeState.READY || this.view.stage !== 'answerFailed' ||
      !this.consentGranted || this.view.citations.length === 0 ||
      this.answerContext.snapshotFor(this.view.query) === undefined) { return; }
    this.view.busy = true; this.view.stage = 'answering';
    this.view.message = '仅重试 DeepSeek 回答，不重新检索本机资料。';
    this.modelTaskDispatched = true; this.answering = true; this.cancelRequested = false;
    const generation: number = ++this.generation; this.watch(generation);
    this.publish(); await this.submit(generation, true);
  }

  async cancelCurrent(): Promise<void> {
    if (!this.view.busy) { return; }
    const generation: number = this.generation; const taskId: string = this.taskId; const answering: boolean = this.answering;
    if (!answering && this.ragCancel !== undefined) {
      this.cancelRequested = true; this.ragCancel.invalid = true; this.ragCancel = undefined;
      this.finish('retrievalFailed', '已取消本机 RAG 检索；未调用 DeepSeek 回答。'); return;
    }
    if (!taskId) { await this.stop(); return; }
    this.cancelRequested = true;
    this.view.message = '正在取消当前任务…'; this.publish();
    try {
      const controller: ShuviRuntimeController = answering ? this.answer : this.knowledge;
      const receipt = await controller.cancel(taskId);
      if (!this.active(generation)) { return; }
      if (receipt.accepted) {
        this.finish(answering ? 'answerFailed' : 'retrievalFailed', answering ?
          '已取消 DeepSeek 回答；本机引用保留，可仅重试回答。已发送请求仍可能计费。' :
          '已取消本机检索；未调用模型。');
      } else {
        const state = await controller.getTask(taskId);
        if (this.active(generation)) {
          this.apply(generation, answering, state.status, state.resultJson);
          if (this.active(generation)) { await this.stop(); }
        }
      }
    } catch { if (this.active(generation)) { await this.stop(); } }
  }
}

function copyRuntimeKnowledgeView(value: RuntimeKnowledgeView): RuntimeKnowledgeView {
  const copy: RuntimeKnowledgeView = new RuntimeKnowledgeView();
  copy.lifecycle = value.lifecycle; copy.busy = value.busy; copy.stage = value.stage; copy.message = value.message;
  copy.query = value.query; copy.answer = value.answer; copy.consent = value.consent;
  copy.citations = value.citations.map((source: KnowledgeRuntimeCitation): KnowledgeRuntimeCitation => {
    const citation: KnowledgeRuntimeCitation = new KnowledgeRuntimeCitation(); citation.citationId = source.citationId;
    citation.evidenceId = source.evidenceId; citation.documentId = source.documentId;
    citation.generation = source.generation; citation.title = source.title;
    citation.excerpt = source.excerpt; citation.kind = source.kind; citation.evidence = source.evidence;
    return citation;
  });
  copy.clearEpoch = value.clearEpoch; return copy;
}
